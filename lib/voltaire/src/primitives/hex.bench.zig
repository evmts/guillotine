const std = @import("std");
const zbench = @import("zbench");
const primitives = @import("voltaire");
const Hex = primitives.Hex;

// Benchmark: Hex.hexToBytes
fn benchToBytes(allocator: std.mem.Allocator) void {
    const hex_str = "0xdeadbeef";
    const bytes = Hex.hexToBytes(allocator, hex_str) catch unreachable;
    defer allocator.free(bytes);
}

// Benchmark: Hex.bytesToHex (dynamic)
fn benchBytesToHex(allocator: std.mem.Allocator) void {
    const bytes = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    const hex_str = Hex.bytesToHex(allocator, &bytes) catch unreachable;
    defer allocator.free(hex_str);
}

// Benchmark: Hex.hexToBytesFixed (20 bytes - address size)
fn benchToBytesFixed20(allocator: std.mem.Allocator) void {
    const hex_str = "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0";
    const bytes = Hex.hexToBytesFixed(20, hex_str) catch unreachable;
    _ = bytes;
    _ = allocator;
}

// Benchmark: Hex.bytesToHexFixed (32 bytes - hash size)
fn benchBytesToHexFixed32(allocator: std.mem.Allocator) void {
    const bytes = [_]u8{0xab} ** 32;
    const hex_arr = Hex.bytesToHexFixed(32, bytes);
    _ = hex_arr;
    _ = allocator;
}

// Benchmark: Hex.hexToU256
fn benchToU256(allocator: std.mem.Allocator) void {
    const hex_str = "0x1234567890abcdef";
    const value = Hex.hexToU256(hex_str) catch unreachable;
    _ = value;
    _ = allocator;
}

// Benchmark: Hex.u256ToHex
fn benchU256ToHex(allocator: std.mem.Allocator) void {
    const value: u256 = 0x1234567890abcdef;
    const hex_str = Hex.u256ToHex(allocator, value) catch unreachable;
    defer allocator.free(hex_str);
}

// Benchmark: Hex.hexToU64
fn benchToU64(allocator: std.mem.Allocator) void {
    const hex_str = "0x1234567890abcdef";
    const value = Hex.hexToU64(hex_str) catch unreachable;
    _ = value;
    _ = allocator;
}

// Benchmark: Hex.u64ToHex
fn benchU64ToHex(allocator: std.mem.Allocator) void {
    const value: u64 = 0x1234567890abcdef;
    const hex_str = Hex.u64ToHex(allocator, value) catch unreachable;
    defer allocator.free(hex_str);
}

// Benchmark: Hex.isHex
fn benchIsHex(allocator: std.mem.Allocator) void {
    const hex_str = "0xdeadbeef";
    const result = Hex.isHex(hex_str);
    _ = result;
    _ = allocator;
}

// Benchmark: Hex.padLeft (pad to 32 bytes)
fn benchPadLeft(allocator: std.mem.Allocator) void {
    const bytes = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    const padded = Hex.padLeft(allocator, &bytes, 32) catch unreachable;
    defer allocator.free(padded);
}

// Benchmark: Hex.trimLeftZeros (no allocation)
fn benchTrimLeftZeros(allocator: std.mem.Allocator) void {
    const bytes = [_]u8{ 0x00, 0x00, 0xde, 0xad, 0xbe, 0xef };
    const trimmed = Hex.trimLeftZeros(&bytes);
    _ = trimmed;
    _ = allocator;
}

// Benchmark: Hex.concat (two byte arrays)
fn benchConcat(allocator: std.mem.Allocator) void {
    const bytes1 = [_]u8{ 0xde, 0xad };
    const bytes2 = [_]u8{ 0xbe, 0xef };
    const arrays = [_][]const u8{ &bytes1, &bytes2 };
    const result = Hex.concat(allocator, &arrays) catch unreachable;
    defer allocator.free(result);
}

pub fn main() !void {
    var buf: [8192]u8 = undefined;
    var stdout_file = std.fs.File.stdout();
    var writer_instance = stdout_file.writer(&buf);
    var writer = &writer_instance.interface;
    var bench = zbench.Benchmark.init(std.heap.page_allocator, .{});
    defer bench.deinit();

    try bench.add("Hex.toBytes", benchToBytes, .{});
    try bench.add("Hex.bytesToHex", benchBytesToHex, .{});
    try bench.add("Hex.toBytesFixed (20 bytes)", benchToBytesFixed20, .{});
    try bench.add("Hex.bytesToHexFixed (32 bytes)", benchBytesToHexFixed32, .{});
    try bench.add("Hex.toU256", benchToU256, .{});
    try bench.add("Hex.u256ToHex", benchU256ToHex, .{});
    try bench.add("Hex.toU64", benchToU64, .{});
    try bench.add("Hex.u64ToHex", benchU64ToHex, .{});
    try bench.add("Hex.isHex", benchIsHex, .{});
    try bench.add("Hex.padLeft (to 32 bytes)", benchPadLeft, .{});
    try bench.add("Hex.trimLeftZeros", benchTrimLeftZeros, .{});
    try bench.add("Hex.concat (2 arrays)", benchConcat, .{});

    try writer.writeAll("\n");
    try bench.run(writer);
}
