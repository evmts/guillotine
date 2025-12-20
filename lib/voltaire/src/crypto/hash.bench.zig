const std = @import("std");
const zbench = @import("zbench");
const crypto = @import("crypto");
const HashUtils = crypto.HashUtils;

// Benchmark: Keccak256 - small input (4 bytes)
fn benchKeccak256Small(allocator: std.mem.Allocator) void {
    const data = "test";
    const hash = HashUtils.keccak256(data);
    _ = hash;
    _ = allocator;
}

// Benchmark: Keccak256 - medium input (32 bytes)
fn benchKeccak256Medium(allocator: std.mem.Allocator) void {
    const data = [_]u8{0xab} ** 32;
    const hash = HashUtils.keccak256(&data);
    _ = hash;
    _ = allocator;
}

// Benchmark: Keccak256 - large input (1KB)
fn benchKeccak256Large(allocator: std.mem.Allocator) void {
    const data = [_]u8{0xab} ** 1024;
    const hash = HashUtils.keccak256(&data);
    _ = hash;
    _ = allocator;
}

// Benchmark: Keccak256 - very large input (64KB)
fn benchKeccak256VeryLarge(allocator: std.mem.Allocator) void {
    const data = [_]u8{0xab} ** 65536;
    const hash = HashUtils.keccak256(&data);
    _ = hash;
    _ = allocator;
}

// Benchmark: selectorFromSignature (Keccak256 + slice)
fn benchComputeFunctionSelector(allocator: std.mem.Allocator) void {
    const signature = "transfer(address,uint256)";
    const selector = HashUtils.selectorFromSignature(signature);
    _ = selector;
    _ = allocator;
}

// Benchmark: eip191HashMessage (EIP-191 personal sign)
fn benchHashMessage(allocator: std.mem.Allocator) void {
    const message = "Hello, Ethereum!";
    const hash = HashUtils.eip191HashMessage(message, allocator) catch unreachable;
    _ = hash;
}

// Benchmark: eip191HashMessage with bytes
fn benchHashMessageBytes(allocator: std.mem.Allocator) void {
    const message = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    const hash = HashUtils.eip191HashMessage(&message, allocator) catch unreachable;
    _ = hash;
}

pub fn main() !void {
    var buf: [8192]u8 = undefined;
    var stdout_file = std.fs.File.stdout();
    var writer_instance = stdout_file.writer(&buf);
    var writer = &writer_instance.interface;
    var bench = zbench.Benchmark.init(std.heap.page_allocator, .{});
    defer bench.deinit();

    try bench.add("Keccak256 (4 bytes)", benchKeccak256Small, .{});
    try bench.add("Keccak256 (32 bytes)", benchKeccak256Medium, .{});
    try bench.add("Keccak256 (1 KB)", benchKeccak256Large, .{});
    try bench.add("Keccak256 (64 KB)", benchKeccak256VeryLarge, .{});
    try bench.add("computeFunctionSelector", benchComputeFunctionSelector, .{});
    try bench.add("hashMessage (EIP-191)", benchHashMessage, .{});
    try bench.add("hashMessageBytes", benchHashMessageBytes, .{});

    try writer.writeAll("\n");
    try bench.run(writer);
}
