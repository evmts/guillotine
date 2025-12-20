const std = @import("std");
const zbench = @import("zbench");
const precompiles = @import("precompiles");
const bn254_add = precompiles.bn254_add;

// Test data: BN254 curve points
// Point 1: (x1, y1) - Generator point
const test_input_g1 = [_]u8{
    // x coordinate (32 bytes)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    // y coordinate (32 bytes)
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
};

// Point 2: Same as Point 1 for doubling
const test_input_double = test_input_g1 ++ test_input_g1;

// Point at infinity: (0, 0)
const test_input_infinity = [_]u8{0x00} ** 64;

// Point 1 + infinity
const test_input_with_infinity = test_input_g1 ++ test_input_infinity;

// Benchmark: BN254_ADD - two valid points
fn benchBn254AddValid(allocator: std.mem.Allocator) void {
    const result = bn254_add.execute(allocator, &test_input_double, 1_000_000) catch return;
    defer result.deinit(allocator);
}

// Benchmark: BN254_ADD - minimum gas
fn benchBn254AddMinGas(allocator: std.mem.Allocator) void {
    const result = bn254_add.execute(allocator, &test_input_double, bn254_add.GAS) catch return;
    defer result.deinit(allocator);
}

// Benchmark: BN254_ADD - point + infinity
fn benchBn254AddInfinity(allocator: std.mem.Allocator) void {
    const result = bn254_add.execute(allocator, &test_input_with_infinity, 1_000_000) catch return;
    defer result.deinit(allocator);
}

// Benchmark: BN254_ADD - empty input (should pad to zero)
fn benchBn254AddEmpty(allocator: std.mem.Allocator) void {
    const input = [_]u8{};
    const result = bn254_add.execute(allocator, &input, 1_000_000) catch return;
    defer result.deinit(allocator);
}

// Benchmark: BN254_ADD - short input (should pad)
fn benchBn254AddShortInput(allocator: std.mem.Allocator) void {
    const input = test_input_g1[0..32]; // Only x coordinate
    const result = bn254_add.execute(allocator, input, 1_000_000) catch return;
    defer result.deinit(allocator);
}

pub fn main() !void {
    var buf: [8192]u8 = undefined;
    var stdout_file = std.fs.File.stdout();
    var writer_instance = stdout_file.writer(&buf);
    var writer = &writer_instance.interface;
    var bench = zbench.Benchmark.init(std.heap.page_allocator, .{});
    defer bench.deinit();

    try bench.add("BN254_ADD (valid points)", benchBn254AddValid, .{});
    try bench.add("BN254_ADD (minimum gas)", benchBn254AddMinGas, .{});
    try bench.add("BN254_ADD (point + infinity)", benchBn254AddInfinity, .{});
    try bench.add("BN254_ADD (empty input)", benchBn254AddEmpty, .{});
    try bench.add("BN254_ADD (short input)", benchBn254AddShortInput, .{});

    try writer.writeAll("\n");
    try bench.run(writer);
}
