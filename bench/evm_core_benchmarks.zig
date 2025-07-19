const std = @import("std");
const root = @import("root.zig");
const Evm = root.Evm;
const primitives = root.primitives;
const Allocator = std.mem.Allocator;

const MemoryDatabase = Evm.MemoryDatabase;
const Address = primitives.Address;
const Contract = Evm.Contract;
const Hardfork = Evm.Hardfork;

// VM Initialization/Teardown Benchmarks

pub fn benchmark_vm_init_default(allocator: Allocator) void {
    benchmark_vm_init_default_impl(allocator) catch |err| {
        std.log.err("VM init default benchmark failed: {}", .{err});
    };
}

fn benchmark_vm_init_default_impl(allocator: Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    std.mem.doNotOptimizeAway(&vm);
}

pub fn benchmark_vm_init_london(allocator: Allocator) void {
    benchmark_vm_init_london_impl(allocator) catch |err| {
        std.log.err("VM init London benchmark failed: {}", .{err});
    };
}

fn benchmark_vm_init_london_impl(allocator: Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init_with_hardfork(allocator, db_interface, .LONDON);
    defer vm.deinit();
    
    std.mem.doNotOptimizeAway(&vm);
}

pub fn benchmark_vm_init_cancun(allocator: Allocator) void {
    benchmark_vm_init_cancun_impl(allocator) catch |err| {
        std.log.err("VM init Cancun benchmark failed: {}", .{err});
    };
}

fn benchmark_vm_init_cancun_impl(allocator: Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init_with_hardfork(allocator, db_interface, .CANCUN);
    defer vm.deinit();
    
    std.mem.doNotOptimizeAway(&vm);
}

// Contract Interpretation Benchmarks

pub fn benchmark_interpret_simple_opcodes(allocator: Allocator) void {
    benchmark_interpret_simple_opcodes_impl(allocator) catch |err| {
        std.log.err("Interpret simple opcodes benchmark failed: {}", .{err});
    };
}

fn benchmark_interpret_simple_opcodes_impl(allocator: Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1111);
    const contract_address = Address.from_u256(0x2222);
    try vm.state.set_balance(caller, 1000000000000000000);
    
    const bytecode = &[_]u8{
        0x60, 0x0A, // PUSH1 10
        0x60, 0x14, // PUSH1 20
        0x01,       // ADD
        0x60, 0x03, // PUSH1 3
        0x02,       // MUL
        0x60, 0x05, // PUSH1 5
        0x06,       // MOD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x00, // PUSH1 0
        0x60, 0x20, // PUSH1 32
        0xf3,       // RETURN
    };
    
    var contract = Contract.init_at_address(
        caller,
        contract_address,
        0,
        100000,
        bytecode,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);
    
    try vm.state.set_code(contract_address, bytecode);
    
    const result = try vm.interpret(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);
    
    std.mem.doNotOptimizeAway(result.gas_used);
}

pub fn benchmark_interpret_complex_opcodes(allocator: Allocator) void {
    benchmark_interpret_complex_opcodes_impl(allocator) catch |err| {
        std.log.err("Interpret complex opcodes benchmark failed: {}", .{err});
    };
}

fn benchmark_interpret_complex_opcodes_impl(allocator: Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1111);
    const contract_address = Address.from_u256(0x3333);
    try vm.state.set_balance(caller, 1000000000000000000);
    
    const bytecode = &[_]u8{
        0x60, 0xFF, // PUSH1 255
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE (storage write)
        0x60, 0x00, // PUSH1 0
        0x54,       // SLOAD (storage read)
        0x20,       // KECCAK256 prep - place on stack
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x20, // PUSH1 32 (length)
        0x20,       // KECCAK256
        0x60, 0x01, // PUSH1 1
        0x55,       // SSTORE
        0x60, 0x00, // PUSH1 0
        0x60, 0x20, // PUSH1 32
        0xf3,       // RETURN
    };
    
    var contract = Contract.init_at_address(
        caller,
        contract_address,
        0,
        1000000,
        bytecode,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);
    
    try vm.state.set_code(contract_address, bytecode);
    
    const result = try vm.interpret(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);
    
    std.mem.doNotOptimizeAway(result.gas_used);
}

// State Operations Benchmarks

pub fn benchmark_cold_storage_access(allocator: Allocator) void {
    benchmark_cold_storage_access_impl(allocator) catch |err| {
        std.log.err("Cold storage access benchmark failed: {}", .{err});
    };
}

fn benchmark_cold_storage_access_impl(allocator: Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1111);
    const contract_address = Address.from_u256(0x4444);
    try vm.state.set_balance(caller, 1000000000000000000);
    
    const bytecode = &[_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0 (cold slot)
        0x55,       // SSTORE
        0x60, 0x84, // PUSH1 0x84
        0x60, 0x01, // PUSH1 1 (cold slot)
        0x55,       // SSTORE
        0x60, 0xC6, // PUSH1 0xC6
        0x60, 0x02, // PUSH1 2 (cold slot)
        0x55,       // SSTORE
        0x60, 0x00, // PUSH1 0
        0x60, 0x20, // PUSH1 32
        0xf3,       // RETURN
    };
    
    var contract = Contract.init_at_address(
        caller,
        contract_address,
        0,
        1000000,
        bytecode,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);
    
    try vm.state.set_code(contract_address, bytecode);
    
    const result = try vm.interpret(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);
    
    std.mem.doNotOptimizeAway(result.gas_used);
}

pub fn benchmark_warm_storage_access(allocator: Allocator) void {
    benchmark_warm_storage_access_impl(allocator) catch |err| {
        std.log.err("Warm storage access benchmark failed: {}", .{err});
    };
}

fn benchmark_warm_storage_access_impl(allocator: Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1111);
    const contract_address = Address.from_u256(0x5555);
    try vm.state.set_balance(caller, 1000000000000000000);
    
    const bytecode = &[_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0 (slot 0)
        0x55,       // SSTORE (make warm)
        0x60, 0x00, // PUSH1 0
        0x54,       // SLOAD (warm access)
        0x60, 0x00, // PUSH1 0
        0x54,       // SLOAD (warm access again)
        0x60, 0x00, // PUSH1 0
        0x54,       // SLOAD (warm access again)
        0x60, 0x00, // PUSH1 0
        0x60, 0x20, // PUSH1 32
        0xf3,       // RETURN
    };
    
    var contract = Contract.init_at_address(
        caller,
        contract_address,
        0,
        1000000,
        bytecode,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);
    
    try vm.state.set_code(contract_address, bytecode);
    
    const result = try vm.interpret(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);
    
    std.mem.doNotOptimizeAway(result.gas_used);
}

pub fn benchmark_balance_operations(allocator: Allocator) void {
    benchmark_balance_operations_impl(allocator) catch |err| {
        std.log.err("Balance operations benchmark failed: {}", .{err});
    };
}

fn benchmark_balance_operations_impl(allocator: Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1111);
    const contract_address = Address.from_u256(0x6666);
    const target_address = Address.from_u256(0x7777);
    
    try vm.state.set_balance(caller, 1000000000000000000);
    try vm.state.set_balance(target_address, 500000000000000000);
    
    const bytecode = &[_]u8{
        0x73, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x77, 0x77, // PUSH20 target_address
        0x31,       // BALANCE
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x00, // PUSH1 0
        0x60, 0x20, // PUSH1 32
        0xf3,       // RETURN
    };
    
    var contract = Contract.init_at_address(
        caller,
        contract_address,
        0,
        100000,
        bytecode,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);
    
    try vm.state.set_code(contract_address, bytecode);
    
    const result = try vm.interpret(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);
    
    std.mem.doNotOptimizeAway(result.gas_used);
}

pub fn benchmark_code_operations(allocator: Allocator) void {
    benchmark_code_operations_impl(allocator) catch |err| {
        std.log.err("Code operations benchmark failed: {}", .{err});
    };
}

fn benchmark_code_operations_impl(allocator: Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1111);
    const contract_address = Address.from_u256(0x8888);
    const target_address = Address.from_u256(0x9999);
    
    try vm.state.set_balance(caller, 1000000000000000000);
    
    const target_code = &[_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0xf3 };
    try vm.state.set_code(target_address, target_code);
    
    const bytecode = &[_]u8{
        0x73, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x99, 0x99, // PUSH20 target_address
        0x3B,       // EXTCODESIZE
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x00, // PUSH1 0
        0x60, 0x20, // PUSH1 32
        0xf3,       // RETURN
    };
    
    var contract = Contract.init_at_address(
        caller,
        contract_address,
        0,
        100000,
        bytecode,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);
    
    try vm.state.set_code(contract_address, bytecode);
    
    const result = try vm.interpret(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);
    
    std.mem.doNotOptimizeAway(result.gas_used);
}

// Gas Consumption Benchmarks

pub fn benchmark_gas_metering_overhead(allocator: Allocator) void {
    benchmark_gas_metering_overhead_impl(allocator) catch |err| {
        std.log.err("Gas metering overhead benchmark failed: {}", .{err});
    };
}

fn benchmark_gas_metering_overhead_impl(allocator: Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1111);
    const contract_address = Address.from_u256(0xAAAA);
    try vm.state.set_balance(caller, 1000000000000000000);
    
    const bytecode = &[_]u8{
        0x5b, // JUMPDEST (loop start)
        0x60, 0x01, // PUSH1 1
        0x60, 0x01, // PUSH1 1
        0x01,       // ADD (gas cost: 3)
        0x50,       // POP (gas cost: 2)
        0x60, 0x01, // PUSH1 1
        0x60, 0x01, // PUSH1 1
        0x02,       // MUL (gas cost: 5)
        0x50,       // POP (gas cost: 2)
        0x60, 0x00, // PUSH1 0 (return)
        0x60, 0x20, // PUSH1 32
        0xf3,       // RETURN
    };
    
    var contract = Contract.init_at_address(
        caller,
        contract_address,
        0,
        100000,
        bytecode,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);
    
    try vm.state.set_code(contract_address, bytecode);
    
    const result = try vm.interpret(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);
    
    std.mem.doNotOptimizeAway(result.gas_used);
}

// Deep Call Stack Benchmark

pub fn benchmark_deep_call_stack(allocator: Allocator) void {
    benchmark_deep_call_stack_impl(allocator) catch |err| {
        std.log.err("Deep call stack benchmark failed: {}", .{err});
    };
}

fn benchmark_deep_call_stack_impl(allocator: Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1111);
    const contract_address = Address.from_u256(0xBBBB);
    try vm.state.set_balance(caller, 1000000000000000000);
    
    const recursive_bytecode = &[_]u8{
        0x30,       // ADDRESS
        0x60, 0x00, // PUSH1 0 (gas)
        0x80,       // DUP1 (address)
        0x60, 0x00, // PUSH1 0 (argsSize)
        0x60, 0x00, // PUSH1 0 (argsOffset)  
        0x60, 0x00, // PUSH1 0 (value)
        0x86,       // DUP7 (address again)
        0x61, 0x03, 0xE8, // PUSH2 1000 (gas)
        0xF1,       // CALL
        0x60, 0x00, // PUSH1 0
        0x60, 0x20, // PUSH1 32
        0xf3,       // RETURN
    };
    
    var contract = Contract.init_at_address(
        caller,
        contract_address,
        0,
        5000000,
        recursive_bytecode,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);
    
    try vm.state.set_code(contract_address, recursive_bytecode);
    
    const result = try vm.interpret(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);
    
    std.mem.doNotOptimizeAway(result.gas_used);
}

// Large Contract Deployment Benchmark

pub fn benchmark_large_contract_deployment(allocator: Allocator) void {
    benchmark_large_contract_deployment_impl(allocator) catch |err| {
        std.log.err("Large contract deployment benchmark failed: {}", .{err});
    };
}

fn benchmark_large_contract_deployment_impl(allocator: Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1111);
    const deployer_address = Address.from_u256(0xCCCC);
    try vm.state.set_balance(caller, 1000000000000000000);
    
    var large_runtime_code: [2048]u8 = undefined;
    @memset(large_runtime_code[0..1024], 0x60);
    @memset(large_runtime_code[1024..2047], 0x01);
    large_runtime_code[2047] = 0xf3;
    
    var deployment_bytecode: [100]u8 = undefined;
    var idx: usize = 0;
    
    deployment_bytecode[idx] = 0x61; idx += 1;
    deployment_bytecode[idx] = 0x08; idx += 1;
    deployment_bytecode[idx] = 0x00; idx += 1;
    deployment_bytecode[idx] = 0x60; idx += 1;
    deployment_bytecode[idx] = 0x00; idx += 1;
    deployment_bytecode[idx] = 0x60; idx += 1;
    deployment_bytecode[idx] = 0x00; idx += 1;
    deployment_bytecode[idx] = 0x39; idx += 1;
    deployment_bytecode[idx] = 0x61; idx += 1;
    deployment_bytecode[idx] = 0x08; idx += 1;
    deployment_bytecode[idx] = 0x00; idx += 1;
    deployment_bytecode[idx] = 0x60; idx += 1;
    deployment_bytecode[idx] = 0x00; idx += 1;
    deployment_bytecode[idx] = 0xf3; idx += 1;
    
    while (idx < deployment_bytecode.len) {
        deployment_bytecode[idx] = 0x00;
        idx += 1;
    }
    
    var contract = Contract.init_at_address(
        caller,
        deployer_address,
        0,
        10000000,
        &deployment_bytecode,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);
    
    try vm.state.set_code(deployer_address, &deployment_bytecode);
    
    const result = try vm.interpret(&contract, &[_]u8{});
    defer if (result.output) |output| allocator.free(output);
    
    std.mem.doNotOptimizeAway(result.gas_used);
}

test "evm core benchmarks compile and basic execution" {
    const allocator = std.testing.allocator;
    
    benchmark_vm_init_default(allocator);
    benchmark_vm_init_london(allocator);
    benchmark_vm_init_cancun(allocator);
    
    benchmark_interpret_simple_opcodes(allocator);
    benchmark_interpret_complex_opcodes(allocator);
    
    benchmark_cold_storage_access(allocator);
    benchmark_warm_storage_access(allocator);
    benchmark_balance_operations(allocator);
    benchmark_code_operations(allocator);
    
    benchmark_gas_metering_overhead(allocator);
    benchmark_deep_call_stack(allocator);
    benchmark_large_contract_deployment(allocator);
}