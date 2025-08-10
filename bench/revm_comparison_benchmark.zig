/// Benchmarks comparing Guillotine EVM to revm performance
///
/// This module provides side-by-side performance comparisons between our native
/// Zig EVM implementation and the Rust-based revm. Tests cover various scenarios
/// from simple arithmetic operations to complex contract executions.
const std = @import("std");
const Allocator = std.mem.Allocator;
const timing = @import("timing.zig");
const BenchmarkSuite = timing.BenchmarkSuite;
const BenchmarkConfig = timing.BenchmarkConfig;

// Guillotine EVM imports
const evm = @import("evm");
const Vm = evm.Evm;
const Frame = evm.Frame;
const Contract = evm.Contract;
const MemoryDatabase = evm.MemoryDatabase;
const primitives = @import("primitives");
const Address = primitives.Address;

// revm imports (conditional)
const has_revm = @hasDecl(@import("root"), "revm");
const revm = if (has_revm) @import("revm") else undefined;
const Revm = if (has_revm) revm.Revm else undefined;
const RevmSettings = if (has_revm) revm.RevmSettings else undefined;

/// Result structure for comparison benchmarks
const ComparisonResult = struct {
    guillotine_ns: u64,
    revm_ns: u64,
    ratio: f64, // guillotine_ns / revm_ns (< 1.0 means Guillotine is faster)
};

/// Helper to create and setup Guillotine EVM
fn setupGuillotineEvm(allocator: Allocator) !struct { vm: *Vm, memory_db: *MemoryDatabase } {
    var memory_db = try allocator.create(MemoryDatabase);
    errdefer allocator.destroy(memory_db);

    memory_db.* = MemoryDatabase.init(allocator);
    errdefer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const vm = try allocator.create(Vm);
    errdefer allocator.destroy(vm);

    vm.* = try Vm.init(allocator, db_interface, null, null);

    return .{ .vm = vm, .memory_db = memory_db };
}

/// Helper to create and setup revm
fn setupRevm(allocator: Allocator) !Revm {
    const settings = RevmSettings{};
    return try Revm.init(allocator, settings);
}

/// Benchmark simple transfer on Guillotine
fn benchmarkGuillotineTransfer(allocator: Allocator, from: Address, to: Address, value: u256) !u64 {
    var setup = try setupGuillotineEvm(allocator);
    defer {
        setup.vm.deinit();
        allocator.destroy(setup.vm);
        setup.memory_db.deinit();
        allocator.destroy(setup.memory_db);
    }

    // Set balance for sender
    try setup.vm.state.set_balance(from, value * 2);

    // Create transfer contract (empty bytecode for simple transfer)
    var contract = try Contract.init(allocator, &.{}, .{ .address = to });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, setup.vm, 21000, contract, from, &.{});
    defer frame.deinit();
    frame.value = value;

    const start = std.time.nanoTimestamp();
    const result = try setup.vm.interpret(&frame);
    const end = std.time.nanoTimestamp();

    std.mem.doNotOptimizeAway(result.gas_used);
    return @intCast(end - start);
}

/// Benchmark simple transfer on revm
fn benchmarkRevmTransfer(allocator: Allocator, from: Address, to: Address, value: u256) !u64 {
    var vm = try setupRevm(allocator);
    defer vm.deinit();

    // Set balance for sender
    try vm.setBalance(from, value * 2);

    const start = std.time.nanoTimestamp();
    var result = try vm.call(from, to, value, &.{}, 21000);
    defer result.deinit();
    const end = std.time.nanoTimestamp();

    std.mem.doNotOptimizeAway(result.gasUsed);
    return @intCast(end - start);
}

/// Benchmark contract execution on Guillotine
fn benchmarkGuillotineContract(allocator: Allocator, bytecode: []const u8) !u64 {
    var setup = try setupGuillotineEvm(allocator);
    defer {
        setup.vm.deinit();
        allocator.destroy(setup.vm);
        setup.memory_db.deinit();
        allocator.destroy(setup.memory_db);
    }

    const caller = Address.from_u256(0x1000);
    try setup.vm.state.set_balance(caller, 1000000);

    var contract = try Contract.init(allocator, bytecode, .{ .address = Address.from_u256(0x2000) });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, setup.vm, 100000, contract, caller, &.{});
    defer frame.deinit();

    const start = std.time.nanoTimestamp();
    const result = try setup.vm.interpret(&frame);
    const end = std.time.nanoTimestamp();

    std.mem.doNotOptimizeAway(result.gas_used);
    return @intCast(end - start);
}

/// Benchmark contract execution on revm
fn benchmarkRevmContract(allocator: Allocator, bytecode: []const u8) !u64 {
    var vm = try setupRevm(allocator);
    defer vm.deinit();

    const caller = Address.from_u256(0x1000);
    const contract_addr = Address.from_u256(0x2000);

    try vm.setBalance(caller, 1000000);
    try vm.setCode(contract_addr, bytecode);

    const start = std.time.nanoTimestamp();
    var result = try vm.call(caller, contract_addr, 0, &.{}, 100000);
    defer result.deinit();
    const end = std.time.nanoTimestamp();

    std.mem.doNotOptimizeAway(result.gasUsed);
    return @intCast(end - start);
}

/// Run comparison benchmark for a specific scenario
fn runComparison(_: Allocator, name: []const u8, iterations: u32, guillotine_fn: anytype, revm_fn: anytype) !ComparisonResult {
    std.debug.print("\n--- {} ---\n", .{name});

    // Warmup runs
    const warmup = iterations / 10;
    var i: u32 = 0;
    while (i < warmup) : (i += 1) {
        _ = try guillotine_fn();
        _ = try revm_fn();
    }

    // Actual benchmark runs
    var guillotine_total: u64 = 0;
    var revm_total: u64 = 0;

    i = 0;
    while (i < iterations) : (i += 1) {
        guillotine_total += try guillotine_fn();
        revm_total += try revm_fn();
    }

    const guillotine_avg = guillotine_total / iterations;
    const revm_avg = revm_total / iterations;
    const ratio = @as(f64, @floatFromInt(guillotine_avg)) / @as(f64, @floatFromInt(revm_avg));

    std.debug.print("Guillotine: {} ns/op\n", .{guillotine_avg});
    std.debug.print("revm:       {} ns/op\n", .{revm_avg});
    std.debug.print("Ratio:      {d:.2}x ", .{ratio});

    if (ratio < 1.0) {
        std.debug.print("(Guillotine is {d:.1}% faster)\n", .{(1.0 - ratio) * 100});
    } else {
        std.debug.print("(revm is {d:.1}% faster)\n", .{(ratio - 1.0) * 100});
    }

    return ComparisonResult{
        .guillotine_ns = guillotine_avg,
        .revm_ns = revm_avg,
        .ratio = ratio,
    };
}

/// Main benchmark runner for all comparison tests
pub fn runRevmComparisonBenchmarks(allocator: Allocator) !void {
    std.debug.print("\n=== Checking revm availability ===\n", .{});
    std.debug.print("has_revm = {}\n", .{has_revm});

    if (!has_revm) {
        std.debug.print("\n=== revm comparison benchmarks skipped (revm not available) ===\n", .{});
        return;
    }

    std.debug.print("\n=== Guillotine vs revm Performance Comparison ===\n", .{});

    const from = Address.from_u256(0x1111);
    const to = Address.from_u256(0x2222);

    // Simple transfer benchmark
    _ = try runComparison(
        allocator,
        "Simple ETH Transfer",
        1000,
        struct {
            fn run() !u64 {
                return try benchmarkGuillotineTransfer(allocator, from, to, 1000);
            }
        }.run,
        struct {
            fn run() !u64 {
                return try benchmarkRevmTransfer(allocator, from, to, 1000);
            }
        }.run,
    );

    // Arithmetic operations benchmark
    const arithmetic_bytecode = &[_]u8{
        // Multiple arithmetic operations
        0x60, 0x2A, // PUSH1 42
        0x60, 0x64, // PUSH1 100
        0x01, // ADD
        0x60, 0x02, // PUSH1 2
        0x02, // MUL
        0x60, 0x0A, // PUSH1 10
        0x04, // DIV
        0x60, 0x05, // PUSH1 5
        0x03, // SUB
        0x00, // STOP
    };

    _ = try runComparison(
        allocator,
        "Arithmetic Operations",
        1000,
        struct {
            fn run() !u64 {
                return try benchmarkGuillotineContract(allocator, arithmetic_bytecode);
            }
        }.run,
        struct {
            fn run() !u64 {
                return try benchmarkRevmContract(allocator, arithmetic_bytecode);
            }
        }.run,
    );

    // Memory operations benchmark
    const memory_bytecode = &[_]u8{
        // Store and load from memory
        0x60, 0xFF, // PUSH1 0xFF
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0
        0x51, // MLOAD
        0x60, 0x20, // PUSH1 32
        0x51, // MLOAD
        0x01, // ADD
        0x00, // STOP
    };

    _ = try runComparison(
        allocator,
        "Memory Operations",
        1000,
        struct {
            fn run() !u64 {
                return try benchmarkGuillotineContract(allocator, memory_bytecode);
            }
        }.run,
        struct {
            fn run() !u64 {
                return try benchmarkRevmContract(allocator, memory_bytecode);
            }
        }.run,
    );

    // Storage operations benchmark
    const storage_bytecode = &[_]u8{
        // Store and load from storage
        0x60, 0xFF, // PUSH1 0xFF
        0x60, 0x00, // PUSH1 0
        0x55, // SSTORE
        0x60, 0x00, // PUSH1 0
        0x54, // SLOAD
        0x00, // STOP
    };

    _ = try runComparison(
        allocator,
        "Storage Operations",
        500,
        struct {
            fn run() !u64 {
                return try benchmarkGuillotineContract(allocator, storage_bytecode);
            }
        }.run,
        struct {
            fn run() !u64 {
                return try benchmarkRevmContract(allocator, storage_bytecode);
            }
        }.run,
    );

    // Complex computation benchmark (simplified Fibonacci)
    const complex_bytecode = &[_]u8{
        // Calculate Fibonacci(10)
        0x60, 0x01, // PUSH1 1 (a)
        0x60, 0x01, // PUSH1 1 (b)
        0x60, 0x0A, // PUSH1 10 (n)

        // Loop start
        0x5b, // JUMPDEST
        0x80, // DUP1 (n)
        0x60, 0x01, // PUSH1 1
        0x11, // GT
        0x61, 0x00, 0x1E, // PUSH2 0x001E (jump to end if n <= 1)
        0x57, // JUMPI

        // Fibonacci step
        0x82, // DUP3 (a)
        0x82, // DUP3 (b)
        0x01, // ADD (a + b)
        0x91, // SWAP2 (new b)
        0x50, // POP (remove old a)
        0x90, // SWAP1 (adjust stack)

        // Decrement counter
        0x60, 0x01, // PUSH1 1
        0x03, // SUB

        // Jump back to loop
        0x60, 0x06, // PUSH1 6 (JUMPDEST position)
        0x56, // JUMP

        // End
        0x5b, // JUMPDEST (0x1E)
        0x50, // POP (remove counter)
        0x50, // POP (remove a)
        0x00, // STOP (result in b)
    };

    _ = try runComparison(
        allocator,
        "Complex Computation (Fibonacci)",
        500,
        struct {
            fn run() !u64 {
                return try benchmarkGuillotineContract(allocator, complex_bytecode);
            }
        }.run,
        struct {
            fn run() !u64 {
                return try benchmarkRevmContract(allocator, complex_bytecode);
            }
        }.run,
    );

    std.debug.print("\n=== Comparison Benchmarks Complete ===\n", .{});
}

test "revm comparison benchmarks" {
    if (!has_revm) {
        return; // Skip test if revm not available
    }
    const allocator = std.testing.allocator;
    try runRevmComparisonBenchmarks(allocator);
}
