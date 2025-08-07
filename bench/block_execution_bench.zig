const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

/// Benchmark configuration
const BenchmarkConfig = struct {
    iterations: u32 = 1000,
    warmup_iterations: u32 = 100,
    show_details: bool = false,
};

/// Benchmark result
const BenchmarkResult = struct {
    name: []const u8,
    regular_ns: u64,
    block_ns: u64,
    speedup: f64,
    gas_used: u64,
    
    pub fn print(self: *const BenchmarkResult) void {
        std.log.info("{s}:", .{self.name});
        std.log.info("  Regular: {}ns", .{self.regular_ns});
        std.log.info("  Block:   {}ns", .{self.block_ns});
        std.log.info("  Speedup: {d:.2}x", .{self.speedup});
        std.log.info("  Gas:     {}", .{self.gas_used});
    }
};

/// Run a benchmark comparing regular and block execution
fn runBenchmark(
    allocator: std.mem.Allocator,
    name: []const u8,
    bytecode: []const u8,
    config: BenchmarkConfig,
) !BenchmarkResult {
    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    // Warmup
    var i: u32 = 0;
    while (i < config.warmup_iterations) : (i += 1) {
        const code_hash = [_]u8{0} ** 32;
        var contract = evm.Contract.init(
            primitives.Address.ZERO, // caller
            primitives.Address.ZERO, // address
            0, // value
            1000000, // gas
            bytecode, // code
            code_hash, // code_hash
            &.{}, // input
            false // is_static
        );
        defer contract.deinit(allocator, null);
        
        const result = try vm.interpret(&contract, &.{}, false);
        defer if (result.output) |output| allocator.free(output);
    }
    
    // Benchmark regular execution
    var regular_total_ns: u64 = 0;
    var gas_used: u64 = 0;
    
    i = 0;
    while (i < config.iterations) : (i += 1) {
        const code_hash = [_]u8{0} ** 32;
        var contract = evm.Contract.init(
            primitives.Address.ZERO, // caller
            primitives.Address.ZERO, // address
            0, // value
            1000000, // gas
            bytecode, // code
            code_hash, // code_hash
            &.{}, // input
            false // is_static
        );
        defer contract.deinit(allocator, null);
        
        const start = std.time.nanoTimestamp();
        var j: u32 = 0;
        while (j < 100) : (j += 1) {
            const result = try vm.interpret(&contract, &.{}, false);
            gas_used = result.gas_used;
            if (result.output) |output| allocator.free(output);
        }
        regular_total_ns += @intCast(std.time.nanoTimestamp() - start);
    }
    
    // Benchmark block execution
    var block_total_ns: u64 = 0;
    
    i = 0;
    while (i < config.iterations) : (i += 1) {
        const code_hash = [_]u8{0} ** 32;
        var contract = evm.Contract.init(
            primitives.Address.ZERO, // caller
            primitives.Address.ZERO, // address
            0, // value
            1000000, // gas
            bytecode, // code
            code_hash, // code_hash
            &.{}, // input
            false // is_static
        );
        defer contract.deinit(allocator, null);
        
        const start = std.time.nanoTimestamp();
        var j: u32 = 0;
        while (j < 100) : (j += 1) {
            const result = try vm.interpret_block_write(&contract, &.{});
            if (result.output) |output| allocator.free(output);
        }
        block_total_ns += @intCast(std.time.nanoTimestamp() - start);
    }
    
    const regular_avg = regular_total_ns / config.iterations;
    const block_avg = block_total_ns / config.iterations;
    const speedup = @as(f64, @floatFromInt(regular_avg)) / @as(f64, @floatFromInt(block_avg));
    
    return BenchmarkResult{
        .name = name,
        .regular_ns = regular_avg,
        .block_ns = block_avg,
        .speedup = speedup,
        .gas_used = gas_used,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const config = BenchmarkConfig{
        .iterations = 1000,
        .warmup_iterations = 100,
        .show_details = false,
    };
    
    std.log.info("Block-based Execution Performance Benchmarks", .{});
    std.log.info("============================================", .{});
    std.log.info("Iterations: {} (warmup: {})", .{ config.iterations, config.warmup_iterations });
    std.log.info("", .{});
    
    // Benchmark 1: Simple arithmetic
    const simple_arithmetic = &[_]u8{
        0x60, 0x05,  // PUSH1 5
        0x60, 0x03,  // PUSH1 3
        0x02,        // MUL
        0x60, 0x02,  // PUSH1 2
        0x01,        // ADD
        0x00,        // STOP
    };
    
    var result1 = try runBenchmark(allocator, "Simple Arithmetic", simple_arithmetic, config);
    result1.print();
    std.log.info("", .{});
    
    // Benchmark 2: Stack operations
    const stack_ops = &[_]u8{
        0x60, 0x01,  // PUSH1 1
        0x60, 0x02,  // PUSH1 2
        0x60, 0x03,  // PUSH1 3
        0x80,        // DUP1
        0x81,        // DUP2
        0x82,        // DUP3
        0x90,        // SWAP1
        0x91,        // SWAP2
        0x50,        // POP
        0x50,        // POP
        0x50,        // POP
        0x00,        // STOP
    };
    
    var result2 = try runBenchmark(allocator, "Stack Operations", stack_ops, config);
    result2.print();
    std.log.info("", .{});
    
    // Benchmark 3: Memory operations
    const memory_ops = &[_]u8{
        0x60, 0x42,  // PUSH1 0x42
        0x60, 0x00,  // PUSH1 0
        0x52,        // MSTORE
        0x60, 0x00,  // PUSH1 0
        0x51,        // MLOAD
        0x60, 0x20,  // PUSH1 32
        0x52,        // MSTORE
        0x00,        // STOP
    };
    
    var result3 = try runBenchmark(allocator, "Memory Operations", memory_ops, config);
    result3.print();
    std.log.info("", .{});
    
    // Benchmark 4: Many push operations
    const many_pushes = &[_]u8{
        0x60, 0x01,  // PUSH1 1
        0x60, 0x02,  // PUSH1 2
        0x60, 0x03,  // PUSH1 3
        0x60, 0x04,  // PUSH1 4
        0x60, 0x05,  // PUSH1 5
        0x60, 0x06,  // PUSH1 6
        0x60, 0x07,  // PUSH1 7
        0x60, 0x08,  // PUSH1 8
        0x60, 0x09,  // PUSH1 9
        0x60, 0x0A,  // PUSH1 10
        0x00,        // STOP
    };
    
    var result4 = try runBenchmark(allocator, "Many PUSH Operations", many_pushes, config);
    result4.print();
    std.log.info("", .{});
    
    // Summary
    std.log.info("Summary", .{});
    std.log.info("=======", .{});
    
    const avg_speedup = (result1.speedup + result2.speedup + result3.speedup + result4.speedup) / 4.0;
    std.log.info("Average speedup: {d:.2}x", .{avg_speedup});
    
    if (avg_speedup > 1.0) {
        std.log.info("Block-based execution is FASTER! 🎉", .{});
    } else if (avg_speedup < 1.0) {
        std.log.info("Block-based execution is slower (needs optimization)", .{});
    } else {
        std.log.info("Performance is equivalent", .{});
    }
}

test "benchmark simple arithmetic" {
    const allocator = std.testing.allocator;
    
    const bytecode = &[_]u8{
        0x60, 0x05,  // PUSH1 5
        0x60, 0x03,  // PUSH1 3
        0x02,        // MUL
        0x00,        // STOP
    };
    
    const config = BenchmarkConfig{
        .iterations = 10,
        .warmup_iterations = 2,
        .show_details = false,
    };
    
    const result = try runBenchmark(allocator, "Test", bytecode, config);
    
    // Just verify it runs without error
    try std.testing.expect(result.regular_ns > 0);
    try std.testing.expect(result.block_ns > 0);
    try std.testing.expect(result.gas_used > 0);
}