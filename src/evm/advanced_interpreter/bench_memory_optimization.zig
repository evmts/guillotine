/// Benchmarks for memory optimization in advanced interpreter.
///
/// These benchmarks compare execution performance between:
/// 1. Standard memory operations with runtime expansion calculation
/// 2. Optimized memory operations with pre-calculated expansion costs

const std = @import("std");
const zbench = @import("zbench");
const Allocator = std.mem.Allocator;

const instruction_stream = @import("instruction_stream.zig");
const memory_expansion_analysis = @import("memory_expansion_analysis.zig");
const memory_optimized_ops = @import("memory_optimized_ops.zig");
const advanced_interpreter_integration = @import("advanced_interpreter_integration.zig");
const execute_advanced = @import("execute_advanced.zig");

const MemoryDatabase = @import("../state/memory_database.zig");
const Contract = @import("../frame/contract.zig");
const Frame = @import("../frame/frame.zig");
const CodeAnalysis = @import("../frame/code_analysis.zig");
const Vm = @import("../evm.zig");
const primitives = @import("primitives");

/// Benchmark contract: Heavy memory operations (array sorting)
fn create_memory_intensive_contract() []const u8 {
    // This simulates a simple bubble sort on 10 elements
    // Each iteration does multiple memory loads and stores
    const bytecode = [_]u8{
        // Initialize array with values 10, 9, 8, ..., 1
        0x60, 0x0A, 0x60, 0x00, 0x52, // array[0] = 10
        0x60, 0x09, 0x60, 0x20, 0x52, // array[1] = 9
        0x60, 0x08, 0x60, 0x40, 0x52, // array[2] = 8
        0x60, 0x07, 0x60, 0x60, 0x52, // array[3] = 7
        0x60, 0x06, 0x60, 0x80, 0x52, // array[4] = 6
        0x60, 0x05, 0x60, 0xA0, 0x52, // array[5] = 5
        0x60, 0x04, 0x60, 0xC0, 0x52, // array[6] = 4
        0x60, 0x03, 0x60, 0xE0, 0x52, // array[7] = 3
        0x60, 0x02, 0x61, 0x01, 0x00, 0x52, // array[8] = 2
        0x60, 0x01, 0x61, 0x01, 0x20, 0x52, // array[9] = 1
        
        // Bubble sort main loop (simplified)
        // For each pair of adjacent elements
        0x60, 0x00, // i = 0
        0x5B, // JUMPDEST (outer loop)
        0x60, 0x00, // j = 0
        0x5B, // JUMPDEST (inner loop)
        
        // Load array[j] and array[j+1]
        0x80, 0x60, 0x20, 0x02, 0x51, // DUP1, PUSH1 0x20, MUL, MLOAD
        0x81, 0x60, 0x20, 0x02, 0x60, 0x20, 0x01, 0x51, // array[j+1]
        
        // Compare and swap if needed
        0x80, 0x82, 0x10, // DUP1, DUP3, LT
        0x60, 0x50, 0x57, // PUSH1 skip_swap, JUMPI
        
        // Swap
        0x81, 0x82, // DUP2, DUP3
        0x83, 0x60, 0x20, 0x02, 0x52, // DUP4, PUSH1 0x20, MUL, MSTORE
        0x82, 0x60, 0x20, 0x02, 0x60, 0x20, 0x01, 0x52, // Store in j+1
        
        0x5B, // JUMPDEST (skip_swap)
        0x50, 0x50, // POP, POP
        
        // Increment j
        0x60, 0x01, 0x01, // PUSH1 1, ADD
        0x80, 0x60, 0x08, 0x10, // DUP1, PUSH1 8, LT
        0x60, 0x35, 0x57, // PUSH1 inner_loop, JUMPI
        
        0x50, // POP j
        // Increment i
        0x60, 0x01, 0x01, // PUSH1 1, ADD
        0x80, 0x60, 0x09, 0x10, // DUP1, PUSH1 9, LT
        0x60, 0x30, 0x57, // PUSH1 outer_loop, JUMPI
        
        0x50, // POP i
        0x00, // STOP
    };
    
    return &bytecode;
}

/// Benchmark contract: Memory table operations
fn create_memory_table_contract() []const u8 {
    // Simulates a lookup table with 32 entries
    // Each entry is 32 bytes, total 1KB of memory
    const bytecode = std.mem.sliceAsBytes(&[_]u8{
        // Initialize 32 table entries
        0x60, 0x00, // counter = 0
        0x5B, // JUMPDEST (loop)
        0x80, // DUP1 (counter)
        0x80, 0x60, 0x20, 0x02, // DUP1, PUSH1 32, MUL (offset)
        0x52, // MSTORE
        0x60, 0x01, 0x01, // PUSH1 1, ADD
        0x80, 0x60, 0x20, 0x10, // DUP1, PUSH1 32, LT
        0x60, 0x02, 0x57, // PUSH1 loop, JUMPI
        0x50, // POP
        
        // Perform 100 random lookups
        0x60, 0x00, // counter = 0
        0x5B, // JUMPDEST (lookup_loop)
        0x80, 0x60, 0x1F, 0x16, // DUP1, PUSH1 31, AND (mod 32)
        0x60, 0x20, 0x02, 0x51, // PUSH1 32, MUL, MLOAD
        0x50, // POP (discard result)
        0x60, 0x01, 0x01, // PUSH1 1, ADD
        0x80, 0x60, 0x64, 0x10, // DUP1, PUSH1 100, LT
        0x60, 0x13, 0x57, // PUSH1 lookup_loop, JUMPI
        0x50, // POP
        0x00, // STOP
    });
    
    return bytecode;
}

/// Setup VM and contract for benchmarking
fn setup_benchmark(allocator: Allocator, bytecode: []const u8) !struct {
    vm: *Vm,
    contract: Contract,
    memory_db: *MemoryDatabase,
} {
    var memory_db = try allocator.create(MemoryDatabase);
    memory_db.* = MemoryDatabase.init(allocator);
    
    const db_interface = memory_db.to_database_interface();
    var builder = @import("../evm_builder.zig").EvmBuilder.init(allocator, db_interface);
    var vm = try allocator.create(Vm);
    vm.* = try builder.build();
    
    var contract = Contract.init(
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        10000000, // 10M gas
        bytecode,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    contract.code_size = bytecode.len;
    
    return .{
        .vm = vm,
        .contract = contract,
        .memory_db = memory_db,
    };
}

fn cleanup_benchmark(allocator: Allocator, vm: *Vm, memory_db: *MemoryDatabase) void {
    vm.deinit();
    allocator.destroy(vm);
    memory_db.deinit();
    allocator.destroy(memory_db);
}

/// Benchmark standard execution without memory optimization
fn benchmark_standard_execution(allocator: Allocator, bench: *zbench.Benchmark) void {
    const bytecode = create_memory_intensive_contract();
    
    while (bench.next()) {
        var setup = setup_benchmark(allocator, bytecode) catch unreachable;
        defer cleanup_benchmark(allocator, setup.vm, setup.memory_db);
        
        // Analyze bytecode
        const analysis = CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode) catch unreachable;
        defer analysis.deinit(allocator);
        setup.contract.analysis = &analysis;
        
        // Generate standard instruction stream (no optimization)
        var stream = instruction_stream.generate_instruction_stream(
            allocator,
            bytecode,
            &analysis,
        ) catch unreachable;
        defer stream.deinit();
        
        // Create frame and execute
        var frame = Frame.init(allocator, &setup.contract) catch unreachable;
        defer frame.deinit();
        frame.gas_remaining = 10000000;
        
        bench.start();
        const result = execute_advanced.execute_advanced(setup.vm, &frame, &stream) catch unreachable;
        bench.end();
        
        // Ensure execution succeeded
        if (result.status != .Success) {
            std.debug.panic("Execution failed: {}\n", .{result.status});
        }
    }
}

/// Benchmark optimized execution with pre-calculated memory expansion
fn benchmark_optimized_execution(allocator: Allocator, bench: *zbench.Benchmark) void {
    const bytecode = create_memory_intensive_contract();
    
    while (bench.next()) {
        var setup = setup_benchmark(allocator, bytecode) catch unreachable;
        defer cleanup_benchmark(allocator, setup.vm, setup.memory_db);
        
        // Analyze bytecode
        const analysis = CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode) catch unreachable;
        defer analysis.deinit(allocator);
        setup.contract.analysis = &analysis;
        
        // Generate optimized instruction stream
        var stream = advanced_interpreter_integration.generate_optimized_instruction_stream(
            allocator,
            bytecode,
            &analysis,
        ) catch unreachable;
        defer stream.deinit();
        
        // Create frame and execute
        var frame = Frame.init(allocator, &setup.contract) catch unreachable;
        defer frame.deinit();
        frame.gas_remaining = 10000000;
        
        bench.start();
        const result = execute_advanced.execute_advanced(setup.vm, &frame, &stream) catch unreachable;
        bench.end();
        
        // Ensure execution succeeded
        if (result.status != .Success) {
            std.debug.panic("Execution failed: {}\n", .{result.status});
        }
    }
}

/// Benchmark memory table operations
fn benchmark_memory_table_standard(allocator: Allocator, bench: *zbench.Benchmark) void {
    const bytecode = create_memory_table_contract();
    
    while (bench.next()) {
        var setup = setup_benchmark(allocator, bytecode) catch unreachable;
        defer cleanup_benchmark(allocator, setup.vm, setup.memory_db);
        
        const analysis = CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode) catch unreachable;
        defer analysis.deinit(allocator);
        setup.contract.analysis = &analysis;
        
        var stream = instruction_stream.generate_instruction_stream(
            allocator,
            bytecode,
            &analysis,
        ) catch unreachable;
        defer stream.deinit();
        
        var frame = Frame.init(allocator, &setup.contract) catch unreachable;
        defer frame.deinit();
        frame.gas_remaining = 10000000;
        
        bench.start();
        _ = execute_advanced.execute_advanced(setup.vm, &frame, &stream) catch unreachable;
        bench.end();
    }
}

/// Benchmark memory table operations with optimization
fn benchmark_memory_table_optimized(allocator: Allocator, bench: *zbench.Benchmark) void {
    const bytecode = create_memory_table_contract();
    
    while (bench.next()) {
        var setup = setup_benchmark(allocator, bytecode) catch unreachable;
        defer cleanup_benchmark(allocator, setup.vm, setup.memory_db);
        
        const analysis = CodeAnalysis.analyze_bytecode_blocks(allocator, bytecode) catch unreachable;
        defer analysis.deinit(allocator);
        setup.contract.analysis = &analysis;
        
        var stream = advanced_interpreter_integration.generate_optimized_instruction_stream(
            allocator,
            bytecode,
            &analysis,
        ) catch unreachable;
        defer stream.deinit();
        
        var frame = Frame.init(allocator, &setup.contract) catch unreachable;
        defer frame.deinit();
        frame.gas_remaining = 10000000;
        
        bench.start();
        _ = execute_advanced.execute_advanced(setup.vm, &frame, &stream) catch unreachable;
        bench.end();
    }
}

/// Benchmark memory expansion cost calculation alone
fn benchmark_memory_expansion_calculation(allocator: Allocator, bench: *zbench.Benchmark) void {
    _ = allocator;
    var current_size: u64 = 0;
    
    while (bench.next()) {
        bench.start();
        
        // Simulate 100 memory expansions
        var i: usize = 0;
        while (i < 100) : (i += 1) {
            const new_size = current_size + 32;
            const cost = memory_expansion_analysis.calculate_memory_gas_cost(current_size, new_size);
            current_size = new_size;
            std.mem.doNotOptimizeAway(cost);
        }
        
        bench.end();
        
        current_size = 0; // Reset for next iteration
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var bench = zbench.Benchmark.init(allocator, .{
        .iterations = 1000,
        .max_iterations = 10000,
        .time_budget_ns = 2_000_000_000, // 2 seconds per benchmark
    });
    defer bench.deinit();
    
    std.debug.print("\n=== Advanced Interpreter Memory Optimization Benchmarks ===\n\n", .{});
    
    try bench.run("Memory Intensive - Standard", benchmark_standard_execution);
    try bench.run("Memory Intensive - Optimized", benchmark_optimized_execution);
    
    try bench.run("Memory Table - Standard", benchmark_memory_table_standard);
    try bench.run("Memory Table - Optimized", benchmark_memory_table_optimized);
    
    try bench.run("Memory Expansion Calculation", benchmark_memory_expansion_calculation);
    
    std.debug.print("\n=== Summary ===\n", .{});
    std.debug.print("The optimized versions should show significant performance improvements\n", .{});
    std.debug.print("for contracts with predictable memory access patterns.\n", .{});
}