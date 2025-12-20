const std = @import("std");
const zbench = @import("zbench");
const precompiles = @import("precompiles");
const ecrecover = precompiles.ecrecover;

// Test data for ECRECOVER (128 bytes: hash32, v32, r32, s32)
const test_input = [_]u8{
    // hash (32 bytes)
    0x47, 0x17, 0x32, 0x85, 0xa8, 0xd7, 0x34, 0x1e,
    0x5e, 0x97, 0x2f, 0xc6, 0x77, 0x28, 0x63, 0x84,
    0xf8, 0x02, 0xf8, 0xef, 0x42, 0xa5, 0xec, 0x5f,
    0x03, 0xbb, 0xfa, 0x25, 0x4c, 0xb0, 0x1f, 0xad,
    // v (32 bytes, padded, last byte = 28)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1c, // v=28
    // r (32 bytes)
    0x69, 0x9a, 0x08, 0x7a, 0x83, 0x91, 0xef, 0xd3,
    0xf4, 0xb7, 0x17, 0x8d, 0x41, 0x2b, 0x3a, 0x7e,
    0xd1, 0x8c, 0x1f, 0x2b, 0x8e, 0x0f, 0x12, 0x5f,
    0x63, 0x09, 0x1e, 0x8e, 0x39, 0x90, 0x07, 0x3d,
    // s (32 bytes)
    0x7a, 0xdb, 0xc9, 0x4e, 0x8f, 0x29, 0x36, 0x1c,
    0x92, 0x7f, 0x63, 0x51, 0xa8, 0x2f, 0xb9, 0x62,
    0xe3, 0x7f, 0xf4, 0x12, 0x9f, 0xf3, 0x85, 0xd6,
    0x1a, 0x8c, 0x4f, 0xb1, 0x23, 0x94, 0xc2, 0x16,
};

// Benchmark: ECRECOVER execute with valid signature
fn benchEcrecoverExecute(allocator: std.mem.Allocator) void {
    const result = ecrecover.execute(allocator, &test_input, 1_000_000) catch return;
    defer result.deinit(allocator);
}

// Benchmark: ECRECOVER with minimum gas
fn benchEcrecoverMinGas(allocator: std.mem.Allocator) void {
    const result = ecrecover.execute(allocator, &test_input, ecrecover.GAS) catch return;
    defer result.deinit(allocator);
}

// Benchmark: ECRECOVER with short input (should pad)
fn benchEcrecoverShortInput(allocator: std.mem.Allocator) void {
    const short_input = test_input[0..64]; // Only hash + v
    const result = ecrecover.execute(allocator, short_input, 1_000_000) catch return;
    defer result.deinit(allocator);
}

// Benchmark: ECRECOVER with invalid signature (returns zero)
fn benchEcrecoverInvalidSignature(allocator: std.mem.Allocator) void {
    const invalid_input = [_]u8{0x00} ** 128; // All zeros
    const result = ecrecover.execute(allocator, &invalid_input, 1_000_000) catch return;
    defer result.deinit(allocator);
}

// Benchmark: ECRECOVER with v=27
fn benchEcrecoverV27(allocator: std.mem.Allocator) void {
    var input = test_input;
    input[63] = 0x1b; // v=27
    const result = ecrecover.execute(allocator, &input, 1_000_000) catch return;
    defer result.deinit(allocator);
}

pub fn main() !void {
    var buf: [8192]u8 = undefined;
    var stdout_file = std.fs.File.stdout();
    var writer_instance = stdout_file.writer(&buf);
    var writer = &writer_instance.interface;
    var bench = zbench.Benchmark.init(std.heap.page_allocator, .{});
    defer bench.deinit();

    try bench.add("ECRECOVER execute (valid)", benchEcrecoverExecute, .{});
    try bench.add("ECRECOVER (minimum gas)", benchEcrecoverMinGas, .{});
    try bench.add("ECRECOVER (short input)", benchEcrecoverShortInput, .{});
    try bench.add("ECRECOVER (invalid sig)", benchEcrecoverInvalidSignature, .{});
    try bench.add("ECRECOVER (v=27)", benchEcrecoverV27, .{});

    try writer.writeAll("\n");
    try bench.run(writer);
}
