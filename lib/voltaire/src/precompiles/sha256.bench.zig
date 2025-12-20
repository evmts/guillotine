const std = @import("std");
const zbench = @import("zbench");
const precompiles = @import("precompiles");
const sha256 = precompiles.sha256;

// Benchmark: SHA256 - empty input
fn benchSha256Empty(allocator: std.mem.Allocator) void {
    const input = [_]u8{};
    const result = sha256.execute(allocator, &input, 1_000_000) catch unreachable;
    defer result.deinit(allocator);
}

// Benchmark: SHA256 - small input (4 bytes)
fn benchSha256Small(allocator: std.mem.Allocator) void {
    const input = "test";
    const result = sha256.execute(allocator, input, 1_000_000) catch unreachable;
    defer result.deinit(allocator);
}

// Benchmark: SHA256 - single word (32 bytes)
fn benchSha256SingleWord(allocator: std.mem.Allocator) void {
    const input = [_]u8{0xab} ** 32;
    const result = sha256.execute(allocator, &input, 1_000_000) catch unreachable;
    defer result.deinit(allocator);
}

// Benchmark: SHA256 - two words (64 bytes)
fn benchSha256TwoWords(allocator: std.mem.Allocator) void {
    const input = [_]u8{0xab} ** 64;
    const result = sha256.execute(allocator, &input, 1_000_000) catch unreachable;
    defer result.deinit(allocator);
}

// Benchmark: SHA256 - large input (1KB)
fn benchSha256Large(allocator: std.mem.Allocator) void {
    const input = [_]u8{0xab} ** 1024;
    const result = sha256.execute(allocator, &input, 100_000_000) catch unreachable;
    defer result.deinit(allocator);
}

// Benchmark: SHA256 - very large input (64KB)
fn benchSha256VeryLarge(allocator: std.mem.Allocator) void {
    const input = [_]u8{0xab} ** 65536;
    const result = sha256.execute(allocator, &input, 10_000_000_000) catch unreachable;
    defer result.deinit(allocator);
}

// Benchmark: SHA256 - known test vector "abc"
fn benchSha256TestVector(allocator: std.mem.Allocator) void {
    const input = "abc";
    const result = sha256.execute(allocator, input, 1_000_000) catch unreachable;
    defer result.deinit(allocator);
}

pub fn main() !void {
    var buf: [8192]u8 = undefined;
    var stdout_file = std.fs.File.stdout();
    var writer_instance = stdout_file.writer(&buf);
    var writer = &writer_instance.interface;
    var bench = zbench.Benchmark.init(std.heap.page_allocator, .{});
    defer bench.deinit();

    try bench.add("SHA256 (empty)", benchSha256Empty, .{});
    try bench.add("SHA256 (4 bytes)", benchSha256Small, .{});
    try bench.add("SHA256 (32 bytes)", benchSha256SingleWord, .{});
    try bench.add("SHA256 (64 bytes)", benchSha256TwoWords, .{});
    try bench.add("SHA256 (1 KB)", benchSha256Large, .{});
    try bench.add("SHA256 (64 KB)", benchSha256VeryLarge, .{});
    try bench.add("SHA256 (test vector 'abc')", benchSha256TestVector, .{});

    try writer.writeAll("\n");
    try bench.run(writer);
}
