const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const Address = @import("Address").Address;
const configureEvm = Evm.configureEvm;

test "constructor REVERT should fail deployment, not deploy revert data" {
    const allocator = testing.allocator;
    
    // Minimal bytecode that just REVERTs with some data
    // PUSH1 0x04  ; push 4 bytes of data
    // PUSH1 0x00  ; push offset 0
    // PUSH1 0x00  ; push offset 0 in memory  
    // CODECOPY    ; copy 4 bytes from code to memory
    // PUSH1 0x04  ; push size 4
    // PUSH1 0x00  ; push offset 0
    // REVERT      ; revert with 4 bytes from memory
    const revert_bytecode = "\x60\x04\x60\x00\x60\x00\x39\x60\x04\x60\x00\xfd";
    
    // Create EVM
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = comptime Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var vm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer vm.deinit();

    const caller = Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Try to deploy contract that REVERTs
    const create_result = try vm.create_contract(
        caller,
        0,
        revert_bytecode,
        1_000_000
    );
    defer if (create_result.output) |output| allocator.free(output);

    // The deployment should FAIL because constructor reverted
    try testing.expect(!create_result.success);
    
    // The contract should NOT be deployed
    const code = vm.state.get_code(create_result.address);
    try testing.expectEqual(@as(usize, 0), code.len);
}

test "constructor that returns empty code should deploy empty contract" {
    const allocator = testing.allocator;
    
    // Bytecode that STOPs (returns empty runtime code)
    // STOP
    const stop_bytecode = "\x00";
    
    // Create EVM
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = comptime Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var vm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer vm.deinit();

    const caller = Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Deploy contract that STOPs
    const create_result = try vm.create_contract(
        caller,
        0,
        stop_bytecode,
        1_000_000
    );
    defer if (create_result.output) |output| allocator.free(output);

    // The deployment should succeed
    try testing.expect(create_result.success);
    
    // But the contract should have empty code
    const code = vm.state.get_code(create_result.address);
    try testing.expectEqual(@as(usize, 0), code.len);
}

test "constructor that returns runtime code should deploy that code" {
    const allocator = testing.allocator;
    
    // Bytecode that returns some runtime code
    // PUSH1 0x01  ; push 1 byte to return
    // PUSH1 0x00  ; push offset 0  
    // PUSH1 0x00  ; push dest offset 0 in memory
    // CODECOPY    ; copy 1 byte from code to memory
    // PUSH1 0x01  ; push size 1
    // PUSH1 0x00  ; push offset 0
    // RETURN      ; return 1 byte from memory (which will be 0x60, the PUSH1 opcode)
    const return_bytecode = "\x60\x01\x60\x00\x60\x00\x39\x60\x01\x60\x00\xf3";
    
    // Create EVM
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = comptime Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var vm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer vm.deinit();

    const caller = Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Deploy contract
    const create_result = try vm.create_contract(
        caller,
        0,
        return_bytecode,
        1_000_000
    );
    defer if (create_result.output) |output| allocator.free(output);

    // The deployment should succeed
    try testing.expect(create_result.success);
    
    // The deployed code should be the single byte we returned (0x60)
    const code = vm.state.get_code(create_result.address);
    try testing.expectEqual(@as(usize, 1), code.len);
    try testing.expectEqual(@as(u8, 0x60), code[0]);
}