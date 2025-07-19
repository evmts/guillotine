/// Comprehensive benchmarks for Jump Table opcode dispatch performance
///
/// This module measures the performance of the EVM jump table dispatch mechanism,
/// which is a critical hot path in the EVM execution engine. The jump table provides
/// O(1) opcode lookup and dispatch, replacing traditional switch-based dispatch.
///
/// Key performance areas benchmarked:
/// 1. Opcode dispatch performance for different opcode categories
/// 2. Cache hit rates with 64-byte alignment
/// 3. Stack validation overhead
/// 4. Gas consumption checks
/// 5. Hardfork-specific jump table initialization
/// 6. Branch prediction accuracy for valid/invalid opcodes

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
const JumpTable = evm.JumpTable;
const Operation = evm.Operation;
const Hardfork = evm.Hardfork;
const ExecutionError = evm.ExecutionError;
const Address = @import("primitives").Address;

/// Measures the dispatch performance of the jump table
fn benchmarkJumpTableDispatch(allocator: Allocator, opcodes: []const u8, iterations: usize) !u64 {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = Contract.init(
        Address.ZERO, // caller
        Address.ZERO, // address
        0,            // value
        10000000,     // gas
        opcodes,      // code
        [_]u8{0} ** 32, // code_hash
        &.{},         // input
        false,        // is_static
    );
    
    var frame = try Frame.init(allocator, &contract);
    defer frame.deinit();
    frame.gas_remaining = 10000000;
    
    const start = std.time.nanoTimestamp();
    
    // Direct jump table dispatch benchmark
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var pc: usize = 0;
        while (pc < opcodes.len - 1) : (pc += 1) { // -1 to avoid STOP
            const opcode = opcodes[pc];
            _ = vm.table.execute(pc, interpreter_ptr, state_ptr, opcode) catch |err| {
                if (err == ExecutionError.Error.STOP) break;
                return err;
            };
        }
        
        // Reset frame for next iteration
        frame.stack.size = 0;
        frame.gas_remaining = 10000000;
    }
    
    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}

/// Benchmark hot path opcodes (most commonly used)
pub fn benchmarkHotPathOpcodes(allocator: Allocator) !BenchmarkSuite {
    var suite = BenchmarkSuite.init(allocator);
    
    // Use a global variable to pass allocator to the benchmark function
    const BenchmarkContext = struct {
        var bench_allocator: Allocator = undefined;
    };
    BenchmarkContext.bench_allocator = allocator;
    
    // Common arithmetic opcodes pattern
    const hot_opcodes = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x01,       // ADD
        0x60, 0x03, // PUSH1 3
        0x02,       // MUL
        0x60, 0x04, // PUSH1 4
        0x03,       // SUB
        0x80,       // DUP1
        0x81,       // DUP2
        0x90,       // SWAP1
        0x50,       // POP
        0x50,       // POP
        0x50,       // POP
        0x00,       // STOP
    };
    
    try suite.benchmark(BenchmarkConfig{
        .name = "jump_table_hot_path_dispatch",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, struct {
        fn run() void {
            const elapsed = benchmarkJumpTableDispatch(BenchmarkContext.bench_allocator, &hot_opcodes, 1000) catch unreachable;
            std.mem.doNotOptimizeAway(elapsed);
        }
    }.run);
    
    return suite;
}

/// Benchmark cold path opcodes (undefined/invalid)
pub fn benchmarkColdPathOpcodes(allocator: Allocator) !BenchmarkSuite {
    var suite = BenchmarkSuite.init(allocator);
    
    const BenchmarkContext = struct {
        var bench_allocator: Allocator = undefined;
    };
    BenchmarkContext.bench_allocator = allocator;
    
    // Mix of valid and invalid opcodes to stress branch prediction
    const cold_opcodes = [_]u8{
        0x60, 0x01, // PUSH1 1 (valid)
        0xfe,       // INVALID opcode
        0x60, 0x02, // PUSH1 2 (valid)
        0xef,       // Undefined opcode
        0x01,       // ADD (valid)
        0xfe,       // INVALID opcode
        0x00,       // STOP
    };
    
    try suite.benchmark(BenchmarkConfig{
        .name = "jump_table_cold_path_dispatch",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, struct {
        fn run() void {
            // This will fail on invalid opcodes, which is expected
            _ = benchmarkJumpTableDispatch(BenchmarkContext.bench_allocator, &cold_opcodes, 100) catch {};
        }
    }.run);
    
    return suite;
}

/// Benchmark jump table initialization for different hardforks
pub fn benchmarkJumpTableInitialization(allocator: Allocator) !BenchmarkSuite {
    var suite = BenchmarkSuite.init(allocator);
    
    // Benchmark Frontier (minimal opcodes)
    try suite.benchmark(BenchmarkConfig{
        .name = "jump_table_init_frontier",
        .iterations = 10000,
        .warmup_iterations = 1000,
    }, struct {
        fn run() void {
            const table = JumpTable.init_from_hardfork(.FRONTIER);
            std.mem.doNotOptimizeAway(table.table[0]);
        }
    }.run);
    
    // Benchmark Istanbul (more opcodes)
    try suite.benchmark(BenchmarkConfig{
        .name = "jump_table_init_istanbul",
        .iterations = 10000,
        .warmup_iterations = 1000,
    }, struct {
        fn run() void {
            const table = JumpTable.init_from_hardfork(.ISTANBUL);
            std.mem.doNotOptimizeAway(table.table[0]);
        }
    }.run);
    
    // Benchmark Cancun (latest, most opcodes)
    try suite.benchmark(BenchmarkConfig{
        .name = "jump_table_init_cancun",
        .iterations = 10000,
        .warmup_iterations = 1000,
    }, struct {
        fn run() void {
            const table = JumpTable.init_from_hardfork(.CANCUN);
            std.mem.doNotOptimizeAway(table.table[0]);
        }
    }.run);
    
    return suite;
}

/// Benchmark stack-heavy operations
pub fn benchmarkStackIntensiveOpcodes(allocator: Allocator) !BenchmarkSuite {
    var suite = BenchmarkSuite.init(allocator);
    
    const BenchmarkContext = struct {
        var bench_allocator: Allocator = undefined;
    };
    BenchmarkContext.bench_allocator = allocator;
    
    // Deep stack operations
    const stack_opcodes = [_]u8{
        // Push 16 values
        0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 0x60, 0x04,
        0x60, 0x05, 0x60, 0x06, 0x60, 0x07, 0x60, 0x08,
        0x60, 0x09, 0x60, 0x0a, 0x60, 0x0b, 0x60, 0x0c,
        0x60, 0x0d, 0x60, 0x0e, 0x60, 0x0f, 0x60, 0x10,
        // Deep DUP and SWAP operations
        0x8f,       // DUP16 (deepest dup)
        0x9f,       // SWAP16 (deepest swap)
        0x8e,       // DUP15
        0x9e,       // SWAP15
        // Clean up stack
        0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50,
        0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50,
        0x00,       // STOP
    };
    
    try suite.benchmark(BenchmarkConfig{
        .name = "jump_table_deep_stack_ops",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, struct {
        fn run() void {
            const elapsed = benchmarkJumpTableDispatch(BenchmarkContext.bench_allocator, &stack_opcodes, 500) catch unreachable;
            std.mem.doNotOptimizeAway(elapsed);
        }
    }.run);
    
    return suite;
}

/// Benchmark realistic contract execution patterns
pub fn benchmarkRealisticContract(allocator: Allocator) !BenchmarkSuite {
    var suite = BenchmarkSuite.init(allocator);
    
    const BenchmarkContext = struct {
        var bench_allocator: Allocator = undefined;
    };
    BenchmarkContext.bench_allocator = allocator;
    
    // Simulated ERC20 transfer pattern
    const erc20_pattern = [_]u8{
        // Load value
        0x60, 0x64,     // PUSH1 100
        0x80,           // DUP1
        // Check sender balance
        0x33,           // CALLER
        0x31,           // BALANCE
        0x81,           // DUP2
        0x10,           // LT
        0x60, 0x20,     // PUSH1 32
        0x57,           // JUMPI (would revert if insufficient)
        // Update balances
        0x33,           // CALLER
        0x31,           // BALANCE
        0x82,           // DUP3
        0x03,           // SUB
        0x60, 0x00,     // PUSH1 0
        0x52,           // MSTORE
        // Add to recipient
        0x60, 0x01,     // PUSH1 1 (simulated recipient)
        0x31,           // BALANCE
        0x82,           // DUP3
        0x01,           // ADD
        0x60, 0x20,     // PUSH1 32
        0x52,           // MSTORE
        // Emit event
        0x82,           // DUP3
        0x60, 0x00,     // PUSH1 0
        0x60, 0x40,     // PUSH1 64
        0xa1,           // LOG1
        0x50,           // POP
        0x00,           // STOP
    };
    
    try suite.benchmark(BenchmarkConfig{
        .name = "jump_table_erc20_pattern",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, struct {
        fn run() void {
            const elapsed = benchmarkJumpTableDispatch(BenchmarkContext.bench_allocator, &erc20_pattern, 200) catch unreachable;
            std.mem.doNotOptimizeAway(elapsed);
        }
    }.run);
    
    return suite;
}

/// Benchmark memory-intensive operations
pub fn benchmarkMemoryIntensiveOpcodes(allocator: Allocator) !BenchmarkSuite {
    var suite = BenchmarkSuite.init(allocator);
    
    const BenchmarkContext = struct {
        var bench_allocator: Allocator = undefined;
    };
    BenchmarkContext.bench_allocator = allocator;
    
    // Memory operations with dynamic gas
    const memory_opcodes = [_]u8{
        // Store values in memory
        0x60, 0xff,     // PUSH1 255
        0x60, 0x00,     // PUSH1 0
        0x52,           // MSTORE
        0x60, 0xaa,     // PUSH1 170
        0x60, 0x20,     // PUSH1 32
        0x52,           // MSTORE
        // Load from memory
        0x60, 0x00,     // PUSH1 0
        0x51,           // MLOAD
        0x60, 0x20,     // PUSH1 32
        0x51,           // MLOAD
        // Memory size
        0x59,           // MSIZE
        0x50,           // POP
        0x50,           // POP
        0x50,           // POP
        0x00,           // STOP
    };
    
    try suite.benchmark(BenchmarkConfig{
        .name = "jump_table_memory_ops",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, struct {
        fn run() void {
            const elapsed = benchmarkJumpTableDispatch(BenchmarkContext.bench_allocator, &memory_opcodes, 500) catch unreachable;
            std.mem.doNotOptimizeAway(elapsed);
        }
    }.run);
    
    return suite;
}

/// Direct operation lookup benchmark (without execution)
pub fn benchmarkOperationLookup(allocator: Allocator) !BenchmarkSuite {
    var suite = BenchmarkSuite.init(allocator);
    
    const BenchmarkContext = struct {
        var bench_table: JumpTable = undefined;
    };
    BenchmarkContext.bench_table = JumpTable.init_from_hardfork(.CANCUN);
    
    try suite.benchmark(BenchmarkConfig{
        .name = "jump_table_operation_lookup",
        .iterations = 100000,
        .warmup_iterations = 10000,
    }, struct {
        fn run() void {
            // Benchmark looking up various opcodes
            const op1 = BenchmarkContext.bench_table.get_operation(0x01); // ADD
            const op2 = BenchmarkContext.bench_table.get_operation(0x60); // PUSH1
            const op3 = BenchmarkContext.bench_table.get_operation(0x80); // DUP1
            const op4 = BenchmarkContext.bench_table.get_operation(0xfe); // INVALID
            const op5 = BenchmarkContext.bench_table.get_operation(0x00); // STOP
            
            std.mem.doNotOptimizeAway(op1);
            std.mem.doNotOptimizeAway(op2);
            std.mem.doNotOptimizeAway(op3);
            std.mem.doNotOptimizeAway(op4);
            std.mem.doNotOptimizeAway(op5);
        }
    }.run);
    
    return suite;
}

/// Run all jump table benchmarks
pub fn runJumpTableBenchmarks(allocator: Allocator) !void {
    std.log.info("\n=== Jump Table Dispatch Performance Benchmarks ===", .{});
    
    // Hot path dispatch
    std.log.info("\n--- Hot Path Opcode Dispatch ---", .{});
    var hot_suite = try benchmarkHotPathOpcodes(allocator);
    defer hot_suite.deinit();
    hot_suite.print_results();
    
    // Cold path dispatch
    std.log.info("\n--- Cold Path (Invalid Opcode) Dispatch ---", .{});
    var cold_suite = try benchmarkColdPathOpcodes(allocator);
    defer cold_suite.deinit();
    cold_suite.print_results();
    
    // Jump table initialization
    std.log.info("\n--- Jump Table Initialization ---", .{});
    var init_suite = try benchmarkJumpTableInitialization(allocator);
    defer init_suite.deinit();
    init_suite.print_results();
    
    // Stack-intensive operations
    std.log.info("\n--- Deep Stack Operations ---", .{});
    var stack_suite = try benchmarkStackIntensiveOpcodes(allocator);
    defer stack_suite.deinit();
    stack_suite.print_results();
    
    // Realistic contract patterns
    std.log.info("\n--- Realistic Contract Patterns ---", .{});
    var realistic_suite = try benchmarkRealisticContract(allocator);
    defer realistic_suite.deinit();
    realistic_suite.print_results();
    
    // Memory-intensive operations
    std.log.info("\n--- Memory-Intensive Operations ---", .{});
    var memory_suite = try benchmarkMemoryIntensiveOpcodes(allocator);
    defer memory_suite.deinit();
    memory_suite.print_results();
    
    // Direct operation lookup
    std.log.info("\n--- Direct Operation Lookup ---", .{});
    var lookup_suite = try benchmarkOperationLookup(allocator);
    defer lookup_suite.deinit();
    lookup_suite.print_results();
    
    std.log.info("\n=== Jump Table Benchmarks Complete ===", .{});
}

test "jump table benchmarks compile and run" {
    const allocator = std.testing.allocator;
    
    // Run a minimal benchmark to ensure everything works
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    const simple_bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x01,       // ADD
        0x00,       // STOP
    };
    
    var contract = Contract.init(
        Address.ZERO, // caller
        Address.ZERO, // address
        0,            // value
        100000,       // gas
        &simple_bytecode, // code
        [_]u8{0} ** 32, // code_hash
        &.{},         // input
        false,        // is_static
    );
    
    var frame = try Frame.init(allocator, &contract);
    defer frame.deinit();
    frame.gas_remaining = 100000;
    
    const result = try vm.interpret(&frame);
    try std.testing.expect(result.gas_used > 0);
}