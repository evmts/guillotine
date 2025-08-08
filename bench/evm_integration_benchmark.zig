//! EVM Module Integration and Error Handling Benchmarks
//! 
//! This file implements comprehensive benchmarks for Issue #49:
//! "Benchmark: EVM module integration and error handling (root.zig)"
//!
//! Covers:
//! 1. Module loading performance
//! 2. Integration scenarios (contract deployment, cross-contract calls)
//! 3. Error handling performance across different error types
//! 4. Component integration (VM + Frame + Stack + Memory coordination)
//!
//! The benchmarks focus on measuring the performance of components working
//! together rather than individual component performance.

const std = @import("std");
const Allocator = std.mem.Allocator;
const print = std.debug.print;
const Timer = std.time.Timer;

const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const AddressType = Address.Address;
const CallParams = Evm.Host.CallParams;
const CallResult = Evm.CallResult;
const timing = @import("timing.zig");

// Updated to new API - migration in progress, tests not run yet

// Test constants for benchmarking
const WARMUP_ITERATIONS = 10;
const BENCHMARK_ITERATIONS = 1000;
const MEMORY_OVERHEAD_SAMPLES = 100;

// Error types we'll benchmark
const ExecutionError = Evm.ExecutionError;
const ContractError = Evm.ContractError;
const MemoryError = Evm.MemoryError;
const StackError = Evm.StackError;

/// Complex contract bytecode for integration testing
/// This simulates a moderately complex smart contract with:
/// - Multiple functions
/// - Memory operations
/// - Storage operations
/// - Arithmetic operations
const COMPLEX_CONTRACT_BYTECODE = [_]u8{
    // Constructor: Store some initial values
    0x60, 0x80, // PUSH1 0x80 (initial memory size)
    0x60, 0x40, // PUSH1 0x40 
    0x52,       // MSTORE (set up memory)
    
    // Store value 42 at slot 0
    0x60, 0x2A, // PUSH1 42
    0x60, 0x00, // PUSH1 0
    0x55,       // SSTORE
    
    // Store value 100 at slot 1
    0x60, 0x64, // PUSH1 100
    0x60, 0x01, // PUSH1 1
    0x55,       // SSTORE
    
    // Load both values and add them
    0x60, 0x00, // PUSH1 0
    0x54,       // SLOAD (load 42)
    0x60, 0x01, // PUSH1 1
    0x54,       // SLOAD (load 100)
    0x01,       // ADD (42 + 100 = 142)
    
    // Store result in memory
    0x60, 0x20, // PUSH1 0x20
    0x52,       // MSTORE
    
    // Return the result
    0x60, 0x20, // PUSH1 0x20 (size)
    0x60, 0x20, // PUSH1 0x20 (offset)
    0xF3,       // RETURN
};

/// Simple contract that calls another contract
const CALLER_CONTRACT_BYTECODE = [_]u8{
    // Prepare call data
    0x60, 0x00, // PUSH1 0 (size)
    0x60, 0x00, // PUSH1 0 (offset) 
    0x60, 0x00, // PUSH1 0 (size)
    0x60, 0x00, // PUSH1 0 (offset)
    0x60, 0x00, // PUSH1 0 (value)
    0x73, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH20 (target address)
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    0x61, 0x27, 0x10, // PUSH2 10000 (gas)
    0xF1,       // CALL
    0x00,       // STOP
};

/// Contract that triggers various errors for error handling benchmarks
const ERROR_CONTRACT_BYTECODE = [_]u8{
    // Push too many values to trigger stack overflow
    0x60, 0x01, // PUSH1 1
    0x60, 0x02, // PUSH1 2
    0x60, 0x03, // PUSH1 3
    // ... (would continue to push many values)
    0x00,       // STOP
};

/// Benchmark result aggregation
const BenchmarkResult = struct {
    name: []const u8,
    iterations: u32,
    total_time_ns: u64,
    avg_time_ns: u64,
    min_time_ns: u64,
    max_time_ns: u64,
    memory_used: usize,
    
    pub fn format(self: BenchmarkResult, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{s}: avg={d}ns, min={d}ns, max={d}ns, mem={d}bytes", 
                        .{self.name, self.avg_time_ns, self.min_time_ns, self.max_time_ns, self.memory_used});
    }
};

/// Benchmark context for measuring performance
const BenchmarkContext = struct {
    allocator: Allocator,
    timer: Timer,
    results: std.ArrayList(BenchmarkResult),
    
    const Self = @This();
    
    pub fn init(allocator: Allocator) !Self {
        return Self{
            .allocator = allocator,
            .timer = try Timer.start(),
            .results = std.ArrayList(BenchmarkResult).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.results.deinit();
    }
    
    pub fn run_benchmark(self: *Self, name: []const u8, benchmark_fn: anytype, args: anytype) !void {
        var times = std.ArrayList(u64).init(self.allocator);
        defer times.deinit();
        
        var total_memory: usize = 0;
        
        // Warmup
        var i: u32 = 0;
        while (i < WARMUP_ITERATIONS) : (i += 1) {
            @call(.auto, benchmark_fn, args) catch {};
        }
        
        // Actual benchmark
        i = 0;
        while (i < BENCHMARK_ITERATIONS) : (i += 1) {
            const start_memory = self.get_memory_usage();
            
            self.timer.reset();
            @call(.auto, benchmark_fn, args) catch {};
            const elapsed = self.timer.read();
            
            const end_memory = self.get_memory_usage();
            total_memory += if (end_memory > start_memory) end_memory - start_memory else 0;
            
            try times.append(elapsed);
        }
        
        // Calculate statistics
        std.sort.heap(u64, times.items, {}, std.sort.asc(u64));
        const total_time = blk: {
            var sum: u64 = 0;
            for (times.items) |time| sum += time;
            break :blk sum;
        };
        
        const result = BenchmarkResult{
            .name = name,
            .iterations = BENCHMARK_ITERATIONS,
            .total_time_ns = total_time,
            .avg_time_ns = total_time / BENCHMARK_ITERATIONS,
            .min_time_ns = times.items[0],
            .max_time_ns = times.items[times.items.len - 1],
            .memory_used = total_memory / BENCHMARK_ITERATIONS,
        };
        
        try self.results.append(result);
        print("Benchmark completed: {}\n", .{result});
    }
    
    fn get_memory_usage(self: *Self) usize {
        // Simple memory usage estimation
        // In a real implementation, you might use more sophisticated memory tracking
        _ = self;
        return 0; // Placeholder - would need proper memory tracking
    }
    
    pub fn print_summary(self: *Self) void {
        print("\n=== EVM Integration Benchmark Summary ===\n", .{});
        for (self.results.items) |result| {
            print("{}\n", .{result});
        }
        print("==========================================\n\n", .{});
    }
};

/// Benchmark 1: Module Loading Performance
/// Tests the performance of importing and initializing EVM modules
fn benchmark_module_loading(allocator: Allocator) !void {
    // Initialize memory database
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    // Initialize VM
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // The initialization itself is what we're measuring
}

/// Benchmark 2: Contract Deployment Flow 
/// Measures end-to-end contract deployment performance
fn benchmark_contract_deployment(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Deploy contract
    const caller = Address.ZERO;
    const target = Address.ZERO;
    
    // Set contract code in state
    try vm.state.set_code(target, &COMPLEX_CONTRACT_BYTECODE);
    
    // Execute using new call API
    const call_params = CallParams{ .call = .{
        .caller = caller,
        .to = target,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    }};
    
    const result = try vm.call(call_params);
    if (result.output) |output| {
        allocator.free(output);
    }
}

/// Benchmark 3: Cross-Contract Call Integration
/// Tests performance of complex call scenarios with multiple frames
fn benchmark_cross_contract_calls(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Set up caller contract
    const caller_addr: AddressType = [_]u8{0x10} ** 20;
    const target_addr: AddressType = [_]u8{0x20} ** 20;
    
    // Set both contracts in state
    try vm.state.set_code(caller_addr, &CALLER_CONTRACT_BYTECODE);
    try vm.state.set_code(target_addr, &COMPLEX_CONTRACT_BYTECODE);
    
    // Create caller contract
    var caller_contract = Evm.Contract.init_at_address(
        Address.ZERO, 
        caller_addr, 
        0, // value
        1000000, // gas_limit
        &CALLER_CONTRACT_BYTECODE, 
        &[_]u8{}, // empty input
        false // not static
    );
    defer caller_contract.deinit(allocator, null);
    
    // Execute caller (which will call target)
    _ = try vm.interpret(&caller_contract, &[_]u8{});
}

/// Benchmark 4: Error Propagation Performance
/// Measures the cost of error handling throughout the EVM stack
fn benchmark_error_propagation(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    const target = Address.ZERO;
    
    var contract = Evm.Contract.init_at_address(
        Address.ZERO, 
        target, 
        0, // value
        100, // low gas limit to trigger error
        &COMPLEX_CONTRACT_BYTECODE, 
        &[_]u8{}, // empty input
        false // not static
    );
    defer contract.deinit(allocator, null);
    
    try vm.state.set_code(target, &COMPLEX_CONTRACT_BYTECODE);
    
    // This should fail due to insufficient gas, measuring error handling performance
    _ = vm.interpret(&contract, &[_]u8{}) catch {};
}

/// Benchmark 5: State Transitions with Journaling
/// Tests performance of state changes with rollback capability
fn benchmark_state_transitions(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    const addr = Address.ZERO;
    
    // Perform multiple state operations
    try vm.state.set_balance(addr, 1000);
    try vm.state.set_nonce(addr, 1);
    try vm.state.set_storage(addr, 0, 42);
    try vm.state.set_storage(addr, 1, 100);
    try vm.state.set_code(addr, &COMPLEX_CONTRACT_BYTECODE);
    
    // Create checkpoint
    const checkpoint = vm.state.journal.checkpoint();
    
    // Make more changes
    try vm.state.set_balance(addr, 2000);
    try vm.state.set_storage(addr, 2, 200);
    
    // Rollback to checkpoint
    vm.state.journal.rollback(checkpoint);
}

/// Benchmark 6: Component Integration Stress Test
/// Tests all components working together under load
fn benchmark_component_integration(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Execute the complex contract multiple times with different parameters
    const addresses = [_]Address{
        Address.fromBytes(&[_]u8{0x01} ** 20),
        Address.fromBytes(&[_]u8{0x02} ** 20),
        Address.fromBytes(&[_]u8{0x03} ** 20),
    };
    
    for (addresses) |addr| {
        try vm.state.set_code(addr, &COMPLEX_CONTRACT_BYTECODE);
        
        var contract = Evm.Contract.init_at_address(
            Address.ZERO, 
            addr, 
            100, // value
            1000000, // gas_limit
            &COMPLEX_CONTRACT_BYTECODE, 
            &[_]u8{}, // empty input
            false // not static
        );
        defer contract.deinit(allocator, null);
        
        _ = try vm.interpret(&contract, &[_]u8{});
    }
}

/// Benchmark 7: Memory Expansion Performance
/// Tests memory growth patterns and performance impact
fn benchmark_memory_expansion(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Contract that performs large memory operations
    const memory_test_bytecode = [_]u8{
        // Store data at offset 0x1000 (4KB)
        0x60, 0xFF,       // PUSH1 0xFF 
        0x61, 0x10, 0x00, // PUSH2 0x1000
        0x52,             // MSTORE
        
        // Store data at offset 0x2000 (8KB)  
        0x60, 0xAA,       // PUSH1 0xAA
        0x61, 0x20, 0x00, // PUSH2 0x2000
        0x52,             // MSTORE
        
        0x00,             // STOP
    };
    
    const target = Address.ZERO;
    try vm.state.set_code(target, &memory_test_bytecode);
    
    var contract = Evm.Contract.init_at_address(
        Address.ZERO, 
        target, 
        0, // value
        1000000, // gas_limit
        &memory_test_bytecode, 
        &[_]u8{}, // empty input
        false // not static
    );
    defer contract.deinit(allocator, null);
    
    _ = try vm.interpret(&contract, &[_]u8{});
}

/// Main benchmark runner
pub fn run_integration_benchmarks(allocator: Allocator) !void {
    print("\n=== Starting EVM Integration Benchmarks (Issue #49) ===\n\n", .{});
    
    var ctx = try BenchmarkContext.init(allocator);
    defer ctx.deinit();
    
    // Run all benchmarks
    print("1. Module Loading Performance...\n", .{});
    try ctx.run_benchmark("Module Loading", benchmark_module_loading, .{allocator});
    
    print("2. Contract Deployment Flow...\n", .{});
    try ctx.run_benchmark("Contract Deployment", benchmark_contract_deployment, .{allocator});
    
    print("3. Cross-Contract Call Integration...\n", .{});
    try ctx.run_benchmark("Cross-Contract Calls", benchmark_cross_contract_calls, .{allocator});
    
    print("4. Error Propagation Performance...\n", .{});
    try ctx.run_benchmark("Error Propagation", benchmark_error_propagation, .{allocator});
    
    print("5. State Transitions with Journaling...\n", .{});
    try ctx.run_benchmark("State Transitions", benchmark_state_transitions, .{allocator});
    
    print("6. Component Integration Stress Test...\n", .{});
    try ctx.run_benchmark("Component Integration", benchmark_component_integration, .{allocator});
    
    print("7. Memory Expansion Performance...\n", .{});
    try ctx.run_benchmark("Memory Expansion", benchmark_memory_expansion, .{allocator});
    
    // Print comprehensive summary
    ctx.print_summary();
    
    print("=== EVM Integration Benchmarks Complete ===\n\n", .{});
}

/// Specific error handling benchmarks
pub fn run_error_handling_benchmarks(allocator: Allocator) !void {
    print("\n=== Error Handling Performance Benchmarks ===\n\n", .{});
    
    var ctx = try BenchmarkContext.init(allocator);
    defer ctx.deinit();
    
    // Benchmark different error types
    try ctx.run_benchmark("Stack Overflow Error", benchmark_stack_overflow_error, .{allocator});
    try ctx.run_benchmark("Out of Gas Error", benchmark_out_of_gas_error, .{allocator});
    try ctx.run_benchmark("Invalid Opcode Error", benchmark_invalid_opcode_error, .{allocator});
    try ctx.run_benchmark("Memory Out of Bounds Error", benchmark_memory_bounds_error, .{allocator});
    
    ctx.print_summary();
    
    print("=== Error Handling Benchmarks Complete ===\n\n", .{});
}

/// Stack overflow error benchmark
fn benchmark_stack_overflow_error(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Bytecode that pushes many values to overflow the stack
    var overflow_bytecode = std.ArrayList(u8).init(allocator);
    defer overflow_bytecode.deinit();
    
    // Push enough values to exceed stack limit
    var i: u16 = 0;
    while (i < 1025) : (i += 1) { // EVM stack limit is 1024
        try overflow_bytecode.append(0x60); // PUSH1
        try overflow_bytecode.append(@intCast(i & 0xFF)); // value
    }
    try overflow_bytecode.append(0x00); // STOP
    
    const target = Address.ZERO;
    try vm.state.set_code(target, overflow_bytecode.items);
    
    var contract = Evm.Contract.init_at_address(
        Address.ZERO, 
        target, 
        0, // value
        1000000, // gas_limit
        overflow_bytecode.items, 
        &[_]u8{}, // empty input
        false // not static
    );
    defer contract.deinit(allocator, null);
    
    // This should fail with stack overflow
    _ = vm.interpret(&contract, &[_]u8{}) catch {};
}

/// Out of gas error benchmark
fn benchmark_out_of_gas_error(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    const target = Address.ZERO;
    try vm.state.set_code(target, &COMPLEX_CONTRACT_BYTECODE);
    
    var contract = Evm.Contract.init_at_address(
        Address.ZERO, 
        target, 
        0, // value
        10, // Very low gas limit
        &COMPLEX_CONTRACT_BYTECODE, 
        &[_]u8{}, // empty input
        false // not static
    );
    defer contract.deinit(allocator, null);
    
    // Should fail with out of gas
    _ = vm.interpret(&contract, &[_]u8{}) catch {};
}

/// Invalid opcode error benchmark  
fn benchmark_invalid_opcode_error(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Bytecode with invalid opcode
    const invalid_bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0xFF,       // Invalid opcode
        0x00,       // STOP
    };
    
    const target = Address.ZERO;
    try vm.state.set_code(target, &invalid_bytecode);
    
    var contract = Evm.Contract.init_at_address(
        Address.ZERO, 
        target, 
        0, // value
        1000000, // gas_limit
        &invalid_bytecode, 
        &[_]u8{}, // empty input
        false // not static
    );
    defer contract.deinit(allocator, null);
    
    // Should fail with invalid opcode
    _ = vm.interpret(&contract, &[_]u8{}) catch {};
}

/// Memory bounds error benchmark
fn benchmark_memory_bounds_error(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Bytecode that tries to access very large memory offset
    const bounds_test_bytecode = [_]u8{
        0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // PUSH32 (very large number)
              0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
              0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
              0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x51,       // MLOAD (try to load from huge offset)
        0x00,       // STOP
    };
    
    const target = Address.ZERO;
    try vm.state.set_code(target, &bounds_test_bytecode);
    
    var contract = Evm.Contract.init_at_address(
        Address.ZERO, 
        target, 
        0, // value
        1000000, // gas_limit
        &bounds_test_bytecode, 
        &[_]u8{}, // empty input
        false // not static
    );
    defer contract.deinit(allocator, null);
    
    // Should fail with memory bounds error
    _ = vm.interpret(&contract, &[_]u8{}) catch {};
}

// Tests to ensure compilation
test "EVM integration benchmarks compile" {
    const allocator = std.testing.allocator;
    
    // Test basic benchmark functions compile
    try benchmark_module_loading(allocator);
    
    // Test error handling benchmarks compile
    try benchmark_out_of_gas_error(allocator);
}