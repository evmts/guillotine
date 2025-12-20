const std = @import("std");
const zbench = @import("zbench");
const primitives = @import("voltaire");
const rlp = primitives.Rlp;

// Benchmark: RLP encode small byte string
fn benchEncodeSmallBytes(allocator: std.mem.Allocator) void {
    const data = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    const encoded = rlp.encodeBytes(allocator, &data) catch unreachable;
    defer allocator.free(encoded);
}

// Benchmark: RLP encode large byte string (>55 bytes)
fn benchEncodeLargeBytes(allocator: std.mem.Allocator) void {
    const data = [_]u8{0xab} ** 100;
    const encoded = rlp.encodeBytes(allocator, &data) catch unreachable;
    defer allocator.free(encoded);
}

// Benchmark: RLP encode single byte
fn benchEncodeSingleByte(allocator: std.mem.Allocator) void {
    const data = [_]u8{0x42};
    const encoded = rlp.encodeBytes(allocator, &data) catch unreachable;
    defer allocator.free(encoded);
}

// Benchmark: RLP encode empty string
fn benchEncodeEmptyString(allocator: std.mem.Allocator) void {
    const data = [_]u8{};
    const encoded = rlp.encodeBytes(allocator, &data) catch unreachable;
    defer allocator.free(encoded);
}

// Benchmark: RLP encode u64 (generic encode)
fn benchEncodeU64(allocator: std.mem.Allocator) void {
    const value: u64 = 1234567890;
    const encoded = rlp.encode(allocator, value) catch unreachable;
    defer allocator.free(encoded);
}

// Benchmark: RLP encode u256 (generic encode)
fn benchEncodeU256(allocator: std.mem.Allocator) void {
    const value: u256 = 0x123456789abcdef0;
    const encoded = rlp.encode(allocator, value) catch unreachable;
    defer allocator.free(encoded);
}

// Benchmark: RLP encode list (3 items) using generic encode
fn benchEncodeList(allocator: std.mem.Allocator) void {
    const item1 = [_]u8{ 0xde, 0xad };
    const item2 = [_]u8{ 0xbe, 0xef };
    const item3 = [_]u8{ 0xca, 0xfe };

    const items = [_][]const u8{ &item1, &item2, &item3 };
    const list_encoded = rlp.encode(allocator, &items) catch unreachable;
    defer allocator.free(list_encoded);
}

// Benchmark: RLP decode small byte string (generic decode)
fn benchDecodeSmallBytes(allocator: std.mem.Allocator) void {
    const encoded = [_]u8{ 0x84, 0xde, 0xad, 0xbe, 0xef };
    const decoded = rlp.decode(allocator, &encoded, false) catch unreachable;
    defer decoded.data.deinit(allocator);
}

// Benchmark: RLP decode list (generic decode)
fn benchDecodeList(allocator: std.mem.Allocator) void {
    // Encoded list of [0xdead, 0xbeef, 0xcafe]
    // 0xc9 = list with 9-byte payload
    const encoded = [_]u8{ 0xc9, 0x82, 0xde, 0xad, 0x82, 0xbe, 0xef, 0x82, 0xca, 0xfe };
    const decoded = rlp.decode(allocator, &encoded, false) catch unreachable;
    defer decoded.data.deinit(allocator);
}

pub fn main() !void {
    var buf: [8192]u8 = undefined;
    var stdout_file = std.fs.File.stdout();
    var writer_instance = stdout_file.writer(&buf);
    var writer = &writer_instance.interface;
    var bench = zbench.Benchmark.init(std.heap.page_allocator, .{});
    defer bench.deinit();

    try bench.add("RLP.encodeBytes (4 bytes)", benchEncodeSmallBytes, .{});
    try bench.add("RLP.encodeBytes (100 bytes)", benchEncodeLargeBytes, .{});
    try bench.add("RLP.encodeBytes (single byte)", benchEncodeSingleByte, .{});
    try bench.add("RLP.encodeBytes (empty)", benchEncodeEmptyString, .{});
    try bench.add("RLP.encodeInteger (u64)", benchEncodeU64, .{});
    try bench.add("RLP.encodeInteger (u256)", benchEncodeU256, .{});
    try bench.add("RLP.encodeList (3 items)", benchEncodeList, .{});
    try bench.add("RLP.decodeBytes (4 bytes)", benchDecodeSmallBytes, .{});
    try bench.add("RLP.decodeList (3 items)", benchDecodeList, .{});

    try writer.writeAll("\n");
    try bench.run(writer);
}
