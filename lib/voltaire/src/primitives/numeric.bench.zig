const std = @import("std");
const zbench = @import("zbench");
const primitives = @import("voltaire");
const Numeric = primitives.Numeric;

// Benchmark: parseEther
fn benchParseEther(allocator: std.mem.Allocator) void {
    const ether_str = "1.5";
    const value = Numeric.parseEther(ether_str) catch unreachable;
    _ = value;
    _ = allocator;
}

// Benchmark: parseGwei
fn benchParseGwei(allocator: std.mem.Allocator) void {
    const gwei_str = "50";
    const value = Numeric.parseGwei(gwei_str) catch unreachable;
    _ = value;
    _ = allocator;
}

// Benchmark: formatEther
fn benchFormatEther(allocator: std.mem.Allocator) void {
    const value: u256 = 1_500_000_000_000_000_000; // 1.5 ether
    const formatted = Numeric.formatEther(allocator, value) catch unreachable;
    defer allocator.free(formatted);
}

// Benchmark: formatGwei
fn benchFormatGwei(allocator: std.mem.Allocator) void {
    const value: u256 = 50_000_000_000; // 50 gwei
    const formatted = Numeric.formatGwei(allocator, value) catch unreachable;
    defer allocator.free(formatted);
}

// Benchmark: wei->gwei via convertUnits
fn benchWeiToGwei(allocator: std.mem.Allocator) void {
    const wei: u256 = 50_000_000_000;
    const gwei = Numeric.convertUnits(wei, .wei, .gwei) catch unreachable;
    _ = gwei;
    _ = allocator;
}

// Benchmark: gwei->wei via convertUnits
fn benchGweiToWei(allocator: std.mem.Allocator) void {
    const gwei: u256 = 50;
    const wei = Numeric.convertUnits(gwei, .gwei, .wei) catch unreachable;
    _ = wei;
    _ = allocator;
}

// Benchmark: ether->wei via convertUnits
fn benchEtherToWei(allocator: std.mem.Allocator) void {
    const ether: u256 = 1;
    const wei = Numeric.convertUnits(ether, .ether, .wei) catch unreachable;
    _ = wei;
    _ = allocator;
}

// Benchmark: wei->ether via convertUnits
fn benchWeiToEther(allocator: std.mem.Allocator) void {
    const wei: u256 = 1_000_000_000_000_000_000;
    const ether = Numeric.convertUnits(wei, .wei, .ether) catch unreachable;
    _ = ether;
    _ = allocator;
}

// Benchmark: safeAdd (optional)
fn benchSafeAdd(allocator: std.mem.Allocator) void {
    const a: u256 = 1000;
    const b: u256 = 2000;
    const result = Numeric.safeAdd(a, b) orelse 0;
    _ = result;
    _ = allocator;
}

// Benchmark: safeSub (optional)
fn benchSafeSub(allocator: std.mem.Allocator) void {
    const a: u256 = 2000;
    const b: u256 = 1000;
    const result = Numeric.safeSub(a, b) orelse 0;
    _ = result;
    _ = allocator;
}

// Benchmark: safeMul (optional)
fn benchSafeMul(allocator: std.mem.Allocator) void {
    const a: u256 = 1000;
    const b: u256 = 2000;
    const result = Numeric.safeMul(a, b) orelse 0;
    _ = result;
    _ = allocator;
}

// Benchmark: safeDiv (optional)
fn benchSafeDiv(allocator: std.mem.Allocator) void {
    const a: u256 = 2000;
    const b: u256 = 10;
    const result = Numeric.safeDiv(a, b) orelse 0;
    _ = result;
    _ = allocator;
}

// Benchmark: calculateGasCost
fn benchCalculateGasCost(allocator: std.mem.Allocator) void {
    const gas_used: u64 = 21000;
    const gas_price: u256 = 50_000_000_000; // 50 gwei
    const cost = Numeric.calculateGasCost(gas_used, gas_price);
    _ = cost;
    _ = allocator;
}

// Benchmark: calculatePercentageOf (plain u256)
fn benchCalculatePercentageOf(allocator: std.mem.Allocator) void {
    const percentage: u256 = 15; // 15%
    const whole: u256 = 1000;
    const result = Numeric.calculatePercentageOf(percentage, whole);
    _ = result;
    _ = allocator;
}

pub fn main() !void {
    var buf: [8192]u8 = undefined;
    var stdout_file = std.fs.File.stdout();
    var writer_instance = stdout_file.writer(&buf);
    var writer = &writer_instance.interface;
    var bench = zbench.Benchmark.init(std.heap.page_allocator, .{});
    defer bench.deinit();

    try bench.add("Numeric.parseEther", benchParseEther, .{});
    try bench.add("Numeric.parseGwei", benchParseGwei, .{});
    try bench.add("Numeric.formatEther", benchFormatEther, .{});
    try bench.add("Numeric.formatGwei", benchFormatGwei, .{});
    try bench.add("Numeric.weiToGwei", benchWeiToGwei, .{});
    try bench.add("Numeric.gweiToWei", benchGweiToWei, .{});
    try bench.add("Numeric.etherToWei", benchEtherToWei, .{});
    try bench.add("Numeric.weiToEther", benchWeiToEther, .{});
    try bench.add("Numeric.safeAdd", benchSafeAdd, .{});
    try bench.add("Numeric.safeSub", benchSafeSub, .{});
    try bench.add("Numeric.safeMul", benchSafeMul, .{});
    try bench.add("Numeric.safeDiv", benchSafeDiv, .{});
    try bench.add("Numeric.calculateGasCost", benchCalculateGasCost, .{});
    try bench.add("Numeric.calculatePercentageOf", benchCalculatePercentageOf, .{});

    try writer.writeAll("\n");
    try bench.run(writer);
}
