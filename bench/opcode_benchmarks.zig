/// Simple but comprehensive benchmarks for EVM opcode execution performance
///
/// This module provides performance benchmarks for key EVM opcodes by executing
/// them through complete EVM interpretation rather than direct function calls.
/// This approach ensures we benchmark the real-world execution path including
/// opcode dispatch, gas accounting, and all associated overhead.
const std = @import("std");
const Allocator = std.mem.Allocator;
const timing = @import("timing.zig");
const BenchmarkSuite = timing.BenchmarkSuite;
const BenchmarkConfig = timing.BenchmarkConfig;

// EVM imports
const evm = @import("evm");
const Vm = evm.Evm;
const Frame = evm.Frame;
const Contract = evm.Contract;
const MemoryDatabase = evm.MemoryDatabase;
const Address = @import("primitives").Address;

/// Helper function to benchmark EVM bytecode execution
fn benchmark_bytecode(allocator: Allocator, bytecode: []const u8) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    var contract = try Contract.init(allocator, bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();

    // Execute the bytecode
    const result = try vm.interpret(&frame);

    // Prevent optimization
    std.mem.doNotOptimizeAway(result.gas_used);
}

/// Individual benchmark functions that can be called with allocator
fn benchmark_add_opcode(allocator: Allocator) void {
    benchmark_bytecode(allocator, &[_]u8{
        0x60, 0x2A, // PUSH1 42
        0x60, 0x64, // PUSH1 100
        0x01, // ADD
        0x00, // STOP
    }) catch unreachable;
}

/// Benchmark arithmetic operations
pub fn benchmark_arithmetic_operations(allocator: Allocator) !BenchmarkSuite {
    var suite = BenchmarkSuite.init(allocator);
    const alloc = allocator; // Make allocator available to inner functions

    // Store allocator for use in inner functions

    // ADD: Push two values and add them
    try suite.benchmark(BenchmarkConfig{
        .name = "ADD_opcode",
        .iterations = 5000,
        .warmup_iterations = 500,
    }, struct {
        fn run() void {
            benchmark_add_opcode(alloc);
        }
    }.run);

    // MUL: Multiply two values
    try suite.benchmark(BenchmarkConfig{
        .name = "MUL_opcode",
        .iterations = 5000,
        .warmup_iterations = 500,
    }, struct {
        fn run() void {
            benchmark_bytecode(allocator, &[_]u8{
                0x60, 0x05, // PUSH1 5
                0x60, 0x0A, // PUSH1 10
                0x02, // MUL
                0x00, // STOP
            }) catch unreachable;
        }
    }.run);

    // SUB: Subtract two values
    try suite.benchmark(BenchmarkConfig{
        .name = "SUB_opcode",
        .iterations = 5000,
        .warmup_iterations = 500,
    }, struct {
        fn run() void {
            benchmark_bytecode(allocator, &[_]u8{
                0x60, 0x64, // PUSH1 100
                0x60, 0x2A, // PUSH1 42
                0x03, // SUB
                0x00, // STOP
            }) catch unreachable;
        }
    }.run);

    // DIV: Divide two values
    try suite.benchmark(BenchmarkConfig{
        .name = "DIV_opcode",
        .iterations = 5000,
        .warmup_iterations = 500,
    }, struct {
        fn run() void {
            benchmark_bytecode(allocator, &[_]u8{
                0x60, 0x64, // PUSH1 100
                0x60, 0x0A, // PUSH1 10
                0x04, // DIV
                0x00, // STOP
            }) catch unreachable;
        }
    }.run);

    return suite;
}

/// Benchmark stack operations
pub fn benchmark_stack_operations(allocator: Allocator) !BenchmarkSuite {
    var suite = BenchmarkSuite.init(allocator);

    // PUSH1 operation
    try suite.benchmark(BenchmarkConfig{
        .name = "PUSH1_opcode",
        .iterations = 10000,
        .warmup_iterations = 1000,
    }, struct {
        fn run() void {
            benchmark_bytecode(allocator, &[_]u8{
                0x60, 0xFF, // PUSH1 0xFF
                0x00, // STOP
            }) catch unreachable;
        }
    }.run);

    // POP operation
    try suite.benchmark(BenchmarkConfig{
        .name = "POP_opcode",
        .iterations = 8000,
        .warmup_iterations = 800,
    }, struct {
        fn run() void {
            benchmark_bytecode(allocator, &[_]u8{
                0x60, 0xFF, // PUSH1 0xFF
                0x50, // POP
                0x00, // STOP
            }) catch unreachable;
        }
    }.run);

    // DUP1 operation
    try suite.benchmark(BenchmarkConfig{
        .name = "DUP1_opcode",
        .iterations = 6000,
        .warmup_iterations = 600,
    }, struct {
        fn run() void {
            benchmark_bytecode(allocator, &[_]u8{
                0x60, 0xFF, // PUSH1 0xFF
                0x80, // DUP1
                0x00, // STOP
            }) catch unreachable;
        }
    }.run);

    // SWAP1 operation
    try suite.benchmark(BenchmarkConfig{
        .name = "SWAP1_opcode",
        .iterations = 6000,
        .warmup_iterations = 600,
    }, struct {
        fn run() void {
            benchmark_bytecode(allocator, &[_]u8{
                0x60, 0xFF, // PUSH1 0xFF
                0x60, 0xAA, // PUSH1 0xAA
                0x90, // SWAP1
                0x00, // STOP
            }) catch unreachable;
        }
    }.run);

    return suite;
}

/// Benchmark memory operations
pub fn benchmark_memory_operations(allocator: Allocator) !BenchmarkSuite {
    var suite = BenchmarkSuite.init(allocator);

    // MSTORE operation
    try suite.benchmark(BenchmarkConfig{
        .name = "MSTORE_opcode",
        .iterations = 3000,
        .warmup_iterations = 300,
    }, struct {
        fn run() void {
            benchmark_bytecode(allocator, &[_]u8{
                0x60, 0xFF, // PUSH1 0xFF
                0x60, 0x00, // PUSH1 0 (offset)
                0x52, // MSTORE
                0x00, // STOP
            }) catch unreachable;
        }
    }.run);

    // MLOAD operation
    try suite.benchmark(BenchmarkConfig{
        .name = "MLOAD_opcode",
        .iterations = 3000,
        .warmup_iterations = 300,
    }, struct {
        fn run() void {
            benchmark_bytecode(allocator, &[_]u8{
                0x60, 0xFF, // PUSH1 0xFF
                0x60, 0x00, // PUSH1 0 (offset)
                0x52, // MSTORE
                0x60, 0x00, // PUSH1 0 (offset)
                0x51, // MLOAD
                0x00, // STOP
            }) catch unreachable;
        }
    }.run);

    return suite;
}

/// Benchmark comparison operations
pub fn benchmark_comparison_operations(allocator: Allocator) !BenchmarkSuite {
    var suite = BenchmarkSuite.init(allocator);

    // LT (less than) operation
    try suite.benchmark(BenchmarkConfig{
        .name = "LT_opcode",
        .iterations = 8000,
        .warmup_iterations = 800,
    }, struct {
        fn run() void {
            benchmark_bytecode(allocator, &[_]u8{
                0x60, 0x0A, // PUSH1 10
                0x60, 0x14, // PUSH1 20
                0x10, // LT
                0x00, // STOP
            }) catch unreachable;
        }
    }.run);

    // EQ (equal) operation
    try suite.benchmark(BenchmarkConfig{
        .name = "EQ_opcode",
        .iterations = 8000,
        .warmup_iterations = 800,
    }, struct {
        fn run() void {
            benchmark_bytecode(allocator, &[_]u8{
                0x60, 0x2A, // PUSH1 42
                0x60, 0x2A, // PUSH1 42
                0x14, // EQ
                0x00, // STOP
            }) catch unreachable;
        }
    }.run);

    // ISZERO operation
    try suite.benchmark(BenchmarkConfig{
        .name = "ISZERO_opcode",
        .iterations = 8000,
        .warmup_iterations = 800,
    }, struct {
        fn run() void {
            benchmark_bytecode(allocator, &[_]u8{
                0x60, 0x00, // PUSH1 0
                0x15, // ISZERO
                0x00, // STOP
            }) catch unreachable;
        }
    }.run);

    return suite;
}

/// Run comprehensive opcode benchmarks
pub fn run_comprehensive_opcode_benchmarks(allocator: Allocator) !void {
    std.log.info("Starting comprehensive opcode benchmarks...", .{});

    // Run arithmetic benchmarks
    std.log.info("Benchmarking arithmetic operations...", .{});
    var arithmetic_suite = try benchmark_arithmetic_operations(allocator);
    defer arithmetic_suite.deinit();

    // Run stack benchmarks
    std.log.info("Benchmarking stack operations...", .{});
    var stack_suite = try benchmark_stack_operations(allocator);
    defer stack_suite.deinit();

    // Run memory benchmarks
    std.log.info("Benchmarking memory operations...", .{});
    var memory_suite = try benchmark_memory_operations(allocator);
    defer memory_suite.deinit();

    // Run comparison benchmarks
    std.log.info("Benchmarking comparison operations...", .{});
    var comparison_suite = try benchmark_comparison_operations(allocator);
    defer comparison_suite.deinit();

    // Print comprehensive results
    std.log.info("\n=== COMPREHENSIVE OPCODE BENCHMARK RESULTS ===", .{});

    std.log.info("\n--- Arithmetic Operations ---", .{});
    arithmetic_suite.print_results();

    std.log.info("\n--- Stack Operations ---", .{});
    stack_suite.print_results();

    std.log.info("\n--- Memory Operations ---", .{});
    memory_suite.print_results();

    std.log.info("\n--- Comparison Operations ---", .{});
    comparison_suite.print_results();

    // Analyze performance
    var suites = [_]*BenchmarkSuite{
        &arithmetic_suite,
        &stack_suite,
        &memory_suite,
        &comparison_suite,
    };
    try analyze_performance(&suites);
}

/// Analyze and report performance insights
fn analyze_performance(suites: []*BenchmarkSuite) !void {
    std.log.info("\n=== PERFORMANCE ANALYSIS ===", .{});

    var fastest_time: u64 = std.math.maxInt(u64);
    var slowest_time: u64 = 0;
    var fastest_op: []const u8 = "";
    var slowest_op: []const u8 = "";
    var total_operations: u32 = 0;
    var total_time: u64 = 0;

    for (suites) |suite| {
        for (suite.results.items) |result| {
            total_operations += 1;
            total_time += result.mean_time_ns;

            if (result.mean_time_ns < fastest_time) {
                fastest_time = result.mean_time_ns;
                fastest_op = result.name;
            }
            if (result.mean_time_ns > slowest_time) {
                slowest_time = result.mean_time_ns;
                slowest_op = result.name;
            }
        }
    }

    const avg_time = if (total_operations > 0) total_time / @as(u64, total_operations) else 0;

    std.log.info("Overall Statistics:", .{});
    std.log.info("  Total operations benchmarked: {d}", .{total_operations});
    std.log.info("  Average execution time: {d:.3}ns", .{avg_time});
    std.log.info("  Fastest operation: {s} ({d:.3}ns)", .{ fastest_op, fastest_time });
    std.log.info("  Slowest operation: {s} ({d:.3}ns)", .{ slowest_op, slowest_time });

    if (slowest_time > 0) {
        const performance_ratio = @as(f64, @floatFromInt(slowest_time)) / @as(f64, @floatFromInt(fastest_time));
        std.log.info("  Performance spread: {d:.2}x", .{performance_ratio});
    }

    std.log.info("\nPerformance Insights:", .{});
    std.log.info("- Stack operations are typically the fastest", .{});
    std.log.info("- Memory operations involve gas calculation overhead", .{});
    std.log.info("- Arithmetic operations have consistent performance", .{});
    std.log.info("- Each benchmark includes full EVM dispatch overhead", .{});
}

test "opcode benchmark infrastructure" {
    const test_allocator = std.testing.allocator;

    // Test that we can run a simple bytecode benchmark
    try benchmark_bytecode(test_allocator, &[_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x01, // PUSH1 1
        0x01, // ADD
        0x00, // STOP
    });
}
