const std = @import("std");
const zbench = @import("zbench");
const crypto = @import("crypto");
const eip712 = crypto.Eip712;
const Crypto = crypto.Crypto;

// Fixed test private key (Hardhat's first default account) for deterministic benchmarks
const TEST_PRIVATE_KEY: [32]u8 = .{
    0xac, 0x09, 0x74, 0xbe, 0xc3, 0x9a, 0x17, 0xe3,
    0x6b, 0xa4, 0xa6, 0xb4, 0xd2, 0x38, 0xff, 0x94,
    0x4b, 0xac, 0xb4, 0x78, 0xcb, 0xed, 0x5e, 0xfc,
    0xae, 0x78, 0x4d, 0x7b, 0xf4, 0xf2, 0xff, 0x80,
};

// Build a simple TypedData with a Message type { name: string, age: uint256 }
fn buildSimpleTypedData(allocator: std.mem.Allocator) !eip712.TypedData {
    var typed = eip712.TypedData.init(allocator);

    // Domain
    typed.domain = try eip712.create_domain(allocator, "MyDApp", "1", 1, null);

    // Primary type
    typed.primary_type = try allocator.dupe(u8, "Message");

    // Define Message type
    const props = [_]eip712.TypeProperty{
        .{ .name = "name", .type = "string" },
        .{ .name = "age", .type = "uint256" },
    };
    try typed.types.put(allocator, "Message", &props);

    // Message values
    try typed.message.put(try allocator.dupe(u8, "name"), eip712.MessageValue{ .string = try allocator.dupe(u8, "Alice") });
    try typed.message.put(try allocator.dupe(u8, "age"), eip712.MessageValue{ .number = 30 });

    return typed;
}

// Benchmark: hash typed data (simple)
fn benchHashTypedData(allocator: std.mem.Allocator) void {
    var typed = buildSimpleTypedData(allocator) catch return;
    defer typed.deinit(allocator);
    const h = eip712.unaudited_hashTypedData(allocator, &typed) catch return;
    _ = h;
}

// Benchmark: sign typed data (simple)
fn benchSignTypedData(allocator: std.mem.Allocator) void {
    var typed = buildSimpleTypedData(allocator) catch return;
    defer typed.deinit(allocator);
    const sig = eip712.unaudited_signTypedData(allocator, &typed, TEST_PRIVATE_KEY) catch return;
    _ = sig;
}

// Benchmark: verify typed data (simple)
fn benchVerifyTypedData(allocator: std.mem.Allocator) void {
    var typed = buildSimpleTypedData(allocator) catch return;
    defer typed.deinit(allocator);
    const sig = eip712.unaudited_signTypedData(allocator, &typed, TEST_PRIVATE_KEY) catch return;
    const pub_key = Crypto.unaudited_getPublicKey(TEST_PRIVATE_KEY) catch return;
    const addr = pub_key.toAddress();
    const ok = eip712.unaudited_verifyTypedData(allocator, &typed, sig, addr) catch return;
    _ = ok;
}

pub fn main() !void {
    var buf: [8192]u8 = undefined;
    var stdout_file = std.fs.File.stdout();
    var writer_instance = stdout_file.writer(&buf);
    var writer = &writer_instance.interface;
    var bench = zbench.Benchmark.init(std.heap.page_allocator, .{});
    defer bench.deinit();

    try bench.add("EIP712 hashTypedData", benchHashTypedData, .{});
    try bench.add("EIP712 signTypedData", benchSignTypedData, .{});
    try bench.add("EIP712 verifyTypedData", benchVerifyTypedData, .{});

    try writer.writeAll("\n");
    try bench.run(writer);
}
