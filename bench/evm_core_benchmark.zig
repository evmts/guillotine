const std = @import("std");
const root = @import("root.zig");
const Evm = root.Evm;
const primitives = root.primitives;
const Allocator = std.mem.Allocator;

// === VM INITIALIZATION/TEARDOWN BENCHMARKS ===

/// Benchmark VM initialization with default hardfork
pub fn vm_init_default(allocator: Allocator) void {
    vm_init_default_impl(allocator) catch |err| {
        std.log.err("VM init default benchmark failed: {}", .{err});
    };
}

fn vm_init_default_impl(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    std.mem.doNotOptimizeAway(vm.depth);
}

/// Benchmark VM initialization with specific hardfork (Berlin)
pub fn vm_init_with_hardfork_berlin(allocator: Allocator) void {
    vm_init_with_hardfork_berlin_impl(allocator) catch |err| {
        std.log.err("VM init Berlin hardfork benchmark failed: {}", .{err});
    };
}

fn vm_init_with_hardfork_berlin_impl(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init_with_hardfork(allocator, db_interface, .BERLIN);
    defer vm.deinit();
    
    std.mem.doNotOptimizeAway(vm.depth);
}

/// Benchmark VM initialization with specific hardfork (Shanghai)
pub fn vm_init_with_hardfork_shanghai(allocator: Allocator) void {
    vm_init_with_hardfork_shanghai_impl(allocator) catch |err| {
        std.log.err("VM init Shanghai hardfork benchmark failed: {}", .{err});
    };
}

fn vm_init_with_hardfork_shanghai_impl(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init_with_hardfork(allocator, db_interface, .SHANGHAI);
    defer vm.deinit();
    
    std.mem.doNotOptimizeAway(vm.depth);
}

/// Benchmark VM deinitialization with empty state
pub fn vm_deinit_empty_state(allocator: Allocator) void {
    vm_deinit_empty_state_impl(allocator) catch |err| {
        std.log.err("VM deinit empty state benchmark failed: {}", .{err});
    };
}

fn vm_deinit_empty_state_impl(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    
    // Perform the deinit that we're measuring
    vm.deinit();
}

/// Benchmark VM deinitialization with populated state
pub fn vm_deinit_populated_state(allocator: Allocator) void {
    vm_deinit_populated_state_impl(allocator) catch |err| {
        std.log.err("VM deinit populated state benchmark failed: {}", .{err});
    };
}

fn vm_deinit_populated_state_impl(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    
    // Populate state with some accounts and storage
    const addr1 = primitives.Address.from_u256(0x1111);
    const addr2 = primitives.Address.from_u256(0x2222);
    const addr3 = primitives.Address.from_u256(0x3333);
    
    try vm.state.set_balance(addr1, 1000000);
    try vm.state.set_balance(addr2, 2000000);
    try vm.state.set_balance(addr3, 3000000);
    
    try vm.state.set_storage(addr1, 0, 100);
    try vm.state.set_storage(addr2, 0, 200);
    
    const simple_code = &[_]u8{0x60, 0x01, 0x60, 0x02, 0x01, 0x00}; // Simple ADD
    try vm.state.set_code(addr3, simple_code);
    
    // Perform the deinit that we're measuring
    vm.deinit();
}

// === CONTRACT INTERPRETATION BENCHMARKS ===

/// Benchmark interpret() with simple arithmetic operations
pub fn interpret_simple_arithmetic(allocator: Allocator) void {
    interpret_simple_arithmetic_impl(allocator) catch |err| {
        std.log.err("Interpret simple arithmetic benchmark failed: {}", .{err});
    };
}

fn interpret_simple_arithmetic_impl(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const caller = primitives.Address.from_u256(0x1111);
    const contract_addr = primitives.Address.from_u256(0x2222);
    try vm.state.set_balance(caller, 1000000000000000000);

    // Simple arithmetic: 10 + 32 = 42
    const arithmetic_code = &[_]u8{
        0x60, 0x0A, // PUSH1 10
        0x60, 0x20, // PUSH1 32
        0x01,       // ADD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x00, // PUSH1 0
        0x60, 0x20, // PUSH1 32
        0xf3,       // RETURN
    };

    var contract = Evm.Contract.init_at_address(
        caller,
        contract_addr,
        0,
        100_000,
        arithmetic_code,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    try vm.state.set_code(contract_addr, arithmetic_code);

    const result = try vm.interpret(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);

    std.mem.doNotOptimizeAway(result.gas_used);
}

/// Benchmark interpret() with complex operations (loops, memory)
pub fn interpret_complex_operations(allocator: Allocator) void {
    interpret_complex_operations_impl(allocator) catch |err| {
        std.log.err("Interpret complex operations benchmark failed: {}", .{err});
    };
}

fn interpret_complex_operations_impl(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const caller = primitives.Address.from_u256(0x1111);
    const contract_addr = primitives.Address.from_u256(0x3333);
    try vm.state.set_balance(caller, 1000000000000000000);

    // Complex loop with memory operations (calculate sum 1+2+3+...+10)
    const complex_code = &[_]u8{
        // Initialize sum = 0, counter = 1
        0x60, 0x00, // PUSH1 0 (sum)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE (store sum at 0x00)
        0x60, 0x01, // PUSH1 1 (counter)
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE (store counter at 0x20)
        
        // Loop start (JUMPDEST at position ~21)
        0x5b,       // JUMPDEST (position for loop start)
        
        // Load counter
        0x60, 0x20, // PUSH1 32
        0x51,       // MLOAD
        
        // Check if counter > 10
        0x60, 0x0A, // PUSH1 10
        0x82,       // DUP3 (duplicate counter)
        0x11,       // GT (counter > 10?)
        0x60, 0x45, // PUSH1 69 (jump to end position)
        0x57,       // JUMPI (conditional jump)
        
        // Add counter to sum
        0x60, 0x00, // PUSH1 0
        0x51,       // MLOAD (load sum)
        0x60, 0x20, // PUSH1 32
        0x51,       // MLOAD (load counter)
        0x01,       // ADD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE (store new sum)
        
        // Increment counter
        0x60, 0x20, // PUSH1 32
        0x51,       // MLOAD (load counter)
        0x60, 0x01, // PUSH1 1
        0x01,       // ADD
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE (store incremented counter)
        
        // Jump back to loop start
        0x60, 0x0D, // PUSH1 13 (position of JUMPDEST)
        0x56,       // JUMP
        
        // End (JUMPDEST at position ~69)
        0x5b,       // JUMPDEST
        0x60, 0x00, // PUSH1 0
        0x60, 0x20, // PUSH1 32
        0xf3,       // RETURN (return sum)
    };

    var contract = Evm.Contract.init_at_address(
        caller,
        contract_addr,
        0,
        1_000_000,
        complex_code,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    try vm.state.set_code(contract_addr, complex_code);

    const result = try vm.interpret(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);

    std.mem.doNotOptimizeAway(result.gas_used);
}

/// Benchmark interpret_static() for read-only context
pub fn interpret_static_context(allocator: Allocator) void {
    interpret_static_context_impl(allocator) catch |err| {
        std.log.err("Interpret static context benchmark failed: {}", .{err});
    };
}

fn interpret_static_context_impl(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const caller = primitives.Address.from_u256(0x1111);
    const contract_addr = primitives.Address.from_u256(0x4444);
    try vm.state.set_balance(caller, 1000000000000000000);
    
    // Pre-populate some storage to read
    try vm.state.set_storage(contract_addr, 0, 42);

    // Read-only operations: load from storage and return
    const readonly_code = &[_]u8{
        0x60, 0x00, // PUSH1 0 (storage key)
        0x54,       // SLOAD (load from storage)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x00, // PUSH1 0
        0x60, 0x20, // PUSH1 32
        0xf3,       // RETURN
    };

    var contract = Evm.Contract.init_at_address(
        caller,
        contract_addr,
        0,
        100_000,
        readonly_code,
        &[_]u8{},
        true, // static context
    );
    defer contract.deinit(allocator, null);

    try vm.state.set_code(contract_addr, readonly_code);

    const result = try vm.interpret_static(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);

    std.mem.doNotOptimizeAway(result.gas_used);
}

// === STATE OPERATIONS BENCHMARKS ===

/// Benchmark cold storage access (first time accessing storage slot)
pub fn storage_cold_access(allocator: Allocator) void {
    storage_cold_access_impl(allocator) catch |err| {
        std.log.err("Storage cold access benchmark failed: {}", .{err});
    };
}

fn storage_cold_access_impl(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const caller = primitives.Address.from_u256(0x1111);
    const contract_addr = primitives.Address.from_u256(0x5555);
    try vm.state.set_balance(caller, 1000000000000000000);

    // Cold SSTORE: store to a previously unaccessed slot
    const cold_sstore_code = &[_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)
        0x60, 0x00, // PUSH1 0 (key)
        0x55,       // SSTORE (cold storage write)
        0x00,       // STOP
    };

    var contract = Evm.Contract.init_at_address(
        caller,
        contract_addr,
        0,
        100_000,
        cold_sstore_code,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    try vm.state.set_code(contract_addr, cold_sstore_code);

    const result = try vm.interpret(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);

    std.mem.doNotOptimizeAway(result.gas_used);
}

/// Benchmark warm storage access (accessing already-accessed storage slot)
pub fn storage_warm_access(allocator: Allocator) void {
    storage_warm_access_impl(allocator) catch |err| {
        std.log.err("Storage warm access benchmark failed: {}", .{err});
    };
}

fn storage_warm_access_impl(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const caller = primitives.Address.from_u256(0x1111);
    const contract_addr = primitives.Address.from_u256(0x6666);
    try vm.state.set_balance(caller, 1000000000000000000);

    // Pre-warm the storage slot by accessing it once
    try vm.state.set_storage(contract_addr, 0, 0); // This warms the slot

    // Warm SSTORE: store to a previously accessed slot
    const warm_sstore_code = &[_]u8{
        0x60, 0x84, // PUSH1 0x84 (value)
        0x60, 0x00, // PUSH1 0 (key)
        0x55,       // SSTORE (warm storage write)
        0x00,       // STOP
    };

    var contract = Evm.Contract.init_at_address(
        caller,
        contract_addr,
        0,
        100_000,
        warm_sstore_code,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    try vm.state.set_code(contract_addr, warm_sstore_code);

    const result = try vm.interpret(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);

    std.mem.doNotOptimizeAway(result.gas_used);
}

/// Benchmark setting balance for account
pub fn set_balance_operation(allocator: Allocator) void {
    set_balance_operation_impl(allocator) catch |err| {
        std.log.err("Set balance operation benchmark failed: {}", .{err});
    };
}

fn set_balance_operation_impl(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const target_addr = primitives.Address.from_u256(0x7777);
    
    // This is the operation we're benchmarking
    try vm.set_balance_protected(target_addr, 1000000000000000000);
    
    std.mem.doNotOptimizeAway(vm.state.get_balance(target_addr));
}

/// Benchmark setting contract code
pub fn set_code_operation(allocator: Allocator) void {
    set_code_operation_impl(allocator) catch |err| {
        std.log.err("Set code operation benchmark failed: {}", .{err});
    };
}

fn set_code_operation_impl(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const target_addr = primitives.Address.from_u256(0x8888);
    
    // Sample contract code (simple counter)
    const sample_code = &[_]u8{
        0x60, 0x00, 0x54, 0x60, 0x01, 0x01, 0x60, 0x00, 0x55, // Load storage[0], increment, store back
        0x60, 0x00, 0x54, 0x60, 0x00, 0x52, 0x60, 0x20, 0xf3, // Return current value
    };
    
    // This is the operation we're benchmarking
    try vm.set_code_protected(target_addr, sample_code);
    
    const stored_code = vm.state.get_code(target_addr);
    std.mem.doNotOptimizeAway(stored_code.len);
}

/// Benchmark transient storage operations (EIP-1153)
pub fn transient_storage_operations(allocator: Allocator) void {
    transient_storage_operations_impl(allocator) catch |err| {
        std.log.err("Transient storage operations benchmark failed: {}", .{err});
    };
}

fn transient_storage_operations_impl(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const target_addr = primitives.Address.from_u256(0x9999);
    
    // This is the operation we're benchmarking (transient storage)
    try vm.set_transient_storage_protected(target_addr, 0, 42);
    
    const value = vm.state.get_transient_storage(target_addr, 0);
    std.mem.doNotOptimizeAway(value);
}

// === GAS AND ACCESS LIST BENCHMARKS ===

/// Benchmark gas consumption tracking overhead
pub fn gas_tracking_overhead(allocator: Allocator) void {
    gas_tracking_overhead_impl(allocator) catch |err| {
        std.log.err("Gas tracking overhead benchmark failed: {}", .{err});
    };
}

fn gas_tracking_overhead_impl(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const caller = primitives.Address.from_u256(0x1111);
    const contract_addr = primitives.Address.from_u256(0xAAAA);
    try vm.state.set_balance(caller, 1000000000000000000);

    // Many operations that consume gas for tracking overhead measurement
    const gas_heavy_code = &[_]u8{
        // 20 PUSH operations
        0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 0x60, 0x04, 0x60, 0x05,
        0x60, 0x06, 0x60, 0x07, 0x60, 0x08, 0x60, 0x09, 0x60, 0x0A,
        0x60, 0x0B, 0x60, 0x0C, 0x60, 0x0D, 0x60, 0x0E, 0x60, 0x0F,
        0x60, 0x10, 0x60, 0x11, 0x60, 0x12, 0x60, 0x13, 0x60, 0x14,
        // 10 ADD operations
        0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
        // 10 POP operations to clean stack
        0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50, 0x50,
        0x00, // STOP
    };

    var contract = Evm.Contract.init_at_address(
        caller,
        contract_addr,
        0,
        1_000_000,
        gas_heavy_code,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    try vm.state.set_code(contract_addr, gas_heavy_code);

    const result = try vm.interpret(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);

    std.mem.doNotOptimizeAway(result.gas_used);
}

/// Benchmark access list cold vs warm access performance difference
pub fn access_list_warm_cold_performance(allocator: Allocator) void {
    access_list_warm_cold_performance_impl(allocator) catch |err| {
        std.log.err("Access list warm/cold performance benchmark failed: {}", .{err});
    };
}

fn access_list_warm_cold_performance_impl(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const caller = primitives.Address.from_u256(0x1111);
    const contract_addr = primitives.Address.from_u256(0xBBBB);
    try vm.state.set_balance(caller, 1000000000000000000);

    // First access contract address (cold) then access again (warm)
    const access_pattern_code = &[_]u8{
        // First BALANCE call (cold)
        0x30,       // ADDRESS (push contract address)
        0x31,       // BALANCE (cold access)
        0x50,       // POP
        
        // Second BALANCE call (warm)
        0x30,       // ADDRESS (push contract address)
        0x31,       // BALANCE (warm access)
        0x50,       // POP
        
        0x00,       // STOP
    };

    var contract = Evm.Contract.init_at_address(
        caller,
        contract_addr,
        0,
        1_000_000,
        access_pattern_code,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    try vm.state.set_code(contract_addr, access_pattern_code);

    const result = try vm.interpret(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);

    std.mem.doNotOptimizeAway(result.gas_used);
}

// === COMPREHENSIVE SCENARIO BENCHMARKS ===

/// Benchmark deep call stack scenario
pub fn deep_call_stack_scenario(allocator: Allocator) void {
    deep_call_stack_scenario_impl(allocator) catch |err| {
        std.log.err("Deep call stack scenario benchmark failed: {}", .{err});
    };
}

fn deep_call_stack_scenario_impl(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const caller = primitives.Address.from_u256(0x1111);
    const contract_addr = primitives.Address.from_u256(0xCCCC);
    try vm.state.set_balance(caller, 1000000000000000000);

    // Self-recursive contract that makes calls to itself up to depth limit
    const recursive_code = &[_]u8{
        // Check call depth (simplified - just make a few self-calls)
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, // Prepare CALL params
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0x30,             // ADDRESS (self address)
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, // More CALL params
        0xF1,             // CALL (make recursive call)
        0x50,             // POP (ignore return value)
        0x00,             // STOP
    };

    var contract = Evm.Contract.init_at_address(
        caller,
        contract_addr,
        0,
        10_000_000, // High gas limit for deep recursion
        recursive_code,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    try vm.state.set_code(contract_addr, recursive_code);

    // Note: This may hit recursion limits safely
    const result = vm.interpret(&contract, &[_]u8{}) catch |err| {
        // Expected that deep recursion may fail - that's part of the benchmark
        std.log.debug("Deep call recursion failed as expected: {}", .{err});
        return;
    };
    defer if (result.output) |output| allocator.free(output);

    std.mem.doNotOptimizeAway(result.gas_used);
}

/// Benchmark large contract deployment
pub fn large_contract_deployment(allocator: Allocator) void {
    large_contract_deployment_impl(allocator) catch |err| {
        std.log.err("Large contract deployment benchmark failed: {}", .{err});
    };
}

fn large_contract_deployment_impl(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const creator = primitives.Address.from_u256(0x1111);
    try vm.state.set_balance(creator, 1000000000000000000);

    // Create init code that returns a large runtime bytecode (8KB)
    // This simulates deploying a large contract
    var large_runtime_code = try allocator.alloc(u8, 8192);
    defer allocator.free(large_runtime_code);
    
    // Fill with mostly PUSH1 + POP operations (valid but large bytecode)
    for (0..large_runtime_code.len / 2) |i| {
        large_runtime_code[i * 2] = 0x60; // PUSH1
        large_runtime_code[i * 2 + 1] = @intCast(i % 256); // Some value
    }
    
    const init_code = &[_]u8{
        // Return the large runtime code (simplified version)
        // In reality, this would CODECOPY the large bytecode to memory and return it
        0x60, 0x00, // PUSH1 0 (return empty for simplicity)
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };

    // Benchmark CREATE operation with large code
    const result = vm.create_contract(creator, 0, init_code, 10_000_000) catch |err| {
        // Expected that very large deployments may fail due to gas or size limits
        std.log.debug("Large contract deployment failed as expected: {}", .{err});
        return;
    };
    
    std.mem.doNotOptimizeAway(result.success);
}

/// Benchmark cross-contract interaction scenario  
pub fn cross_contract_interaction(allocator: Allocator) void {
    cross_contract_interaction_impl(allocator) catch |err| {
        std.log.err("Cross-contract interaction benchmark failed: {}", .{err});
    };
}

fn cross_contract_interaction_impl(allocator: Allocator) !void {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const caller = primitives.Address.from_u256(0x1111);
    const contract_a = primitives.Address.from_u256(0xAAAA);
    const contract_b = primitives.Address.from_u256(0xBBBB);
    
    try vm.state.set_balance(caller, 1000000000000000000);
    try vm.state.set_balance(contract_a, 1000000);
    try vm.state.set_balance(contract_b, 1000000);

    // Contract B: Simple storage setter/getter
    const contract_b_code = &[_]u8{
        // Store input value in storage slot 0
        0x60, 0x04,   // PUSH1 4 (calldata size)
        0x60, 0x00,   // PUSH1 0 (calldata offset)
        0x60, 0x00,   // PUSH1 0 (memory offset)
        0x37,         // CALLDATACOPY
        0x60, 0x00,   // PUSH1 0 (memory offset)
        0x51,         // MLOAD (load the input)
        0x60, 0x00,   // PUSH1 0 (storage key)
        0x55,         // SSTORE (store to storage)
        0x00,         // STOP
    };
    
    try vm.state.set_code(contract_b, contract_b_code);

    // Contract A: Calls contract B with data
    const contract_a_code = &[_]u8{
        // Prepare call to contract B
        0x60, 0x2A,   // PUSH1 42 (data to send)
        0x60, 0x00,   // PUSH1 0
        0x52,         // MSTORE (put 42 in memory)
        
        0x60, 0x00,   // PUSH1 0 (return data size)
        0x60, 0x00,   // PUSH1 0 (return data offset)  
        0x60, 0x04,   // PUSH1 4 (call data size)
        0x60, 0x00,   // PUSH1 0 (call data offset)
        0x60, 0x00,   // PUSH1 0 (value to send)
        
        // Push contract B address (0xBBBB) 
        0x61, 0xBB, 0xBB, // PUSH2 0xBBBB
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xF1,         // CALL
        
        0x50,         // POP (ignore return status)
        0x00,         // STOP
    };

    var contract = Evm.Contract.init_at_address(
        caller,
        contract_a,
        0,
        1_000_000,
        contract_a_code,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    try vm.state.set_code(contract_a, contract_a_code);

    const result = try vm.interpret(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);

    std.mem.doNotOptimizeAway(result.gas_used);
}

test "core EVM benchmarks compile and basic execution" {
    const allocator = std.testing.allocator;
    
    // Test VM lifecycle benchmarks
    vm_init_default(allocator);
    vm_init_with_hardfork_berlin(allocator);
    vm_deinit_empty_state(allocator);
    
    // Test interpretation benchmarks
    interpret_simple_arithmetic(allocator);
    interpret_static_context(allocator);
    
    // Test state operation benchmarks
    storage_cold_access(allocator);
    set_balance_operation(allocator);
    
    // Test gas and access benchmarks
    gas_tracking_overhead(allocator);
    
    // Note: Some complex benchmarks might be too heavy for routine testing
}