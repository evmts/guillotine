const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const Log = @import("evm").Log;

test {
    std.testing.log_level = .debug;
}

test "debug ERC20 contract deployment jumpdest issue" {
    const allocator = std.testing.allocator;

    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Caller with funds
    const caller = primitives.Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Minimal bytecode that reproduces the issue
    // 0x608060405234801561000f575f5ffd5b50... (from ERC20)
    // This has a JUMPI at position 20 that tries to jump to position 15 (0x0f)
    const bytecode = [_]u8{
        0x60, 0x80, // PUSH1 0x80
        0x60, 0x40, // PUSH1 0x40  
        0x52,       // MSTORE
        0x34,       // CALLVALUE (position 5)
        0x80,       // DUP1
        0x15,       // ISZERO
        0x61, 0x00, 0x0f, // PUSH2 0x000f (position 15)
        0x57,       // JUMPI
        0x5f,       // PUSH0 (position 12)
        0x5f,       // PUSH0
        0xfd,       // REVERT
        0x5b,       // JUMPDEST (position 15)
        0x50,       // POP
    };

    std.log.debug("Deploying contract with bytecode len={}", .{bytecode.len});
    std.log.debug("Expected jumpdest at position 15, opcode=0x{x}", .{bytecode[15]});
    
    // Try to deploy
    const create_result = vm.create_contract(caller, 0, &bytecode, 10_000_000) catch |err| {
        std.log.debug("create_contract failed with error: {}", .{err});
        return err;
    };
    
    std.log.debug("Create result: success={}, address={}", .{ create_result.success, create_result.address });
    
    try std.testing.expect(create_result.success);
}

test "minimal constructor with conditional revert" {
    const allocator = std.testing.allocator;

    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Caller with funds
    const caller = primitives.Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Even simpler bytecode to test JUMPI validation
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 0x01 (condition = true)
        0x60, 0x06, // PUSH1 0x06 (jump dest)
        0x57,       // JUMPI
        0x00,       // STOP (not reached)
        0x5b,       // JUMPDEST (position 6)
        0x60, 0x42, // PUSH1 0x42 (runtime code)
        0x60, 0x00, // PUSH1 0x00
        0x52,       // MSTORE
        0x60, 0x01, // PUSH1 0x01 (size)
        0x60, 0x00, // PUSH1 0x00 (offset)
        0xf3,       // RETURN
    };

    std.log.debug("Testing simple JUMPI with bytecode len={}", .{bytecode.len});
    
    const create_result = try vm.create_contract(caller, 0, &bytecode, 10_000_000);
    
    std.log.debug("Create result: success={}, address={}", .{ create_result.success, create_result.address });
    
    try std.testing.expect(create_result.success);
    
    // Check deployed code
    const deployed_code = vm.state.get_code(create_result.address);
    std.log.debug("Deployed code: {x}", .{deployed_code});
    try std.testing.expectEqual(@as(u8, 0x42), deployed_code[0]);
}