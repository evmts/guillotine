const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const Log = @import("evm").Log;

test {
    std.testing.log_level = .warn;
}

test "reproduce exact ERC20 deployment failure" {
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

    // Exact bytecode from ERC20 that's failing
    const bytecode = [_]u8{
        0x60, 0x80, // PUSH1 0x80
        0x60, 0x40, // PUSH1 0x40  
        0x52,       // MSTORE (position 4)
        0x34,       // CALLVALUE (position 5)
        0x80,       // DUP1 (position 6)
        0x15,       // ISZERO (position 7)
        0x61, 0x00, 0x0f, // PUSH2 0x000f (position 8-10)
        0x57,       // JUMPI (position 11)
        0x5f,       // PUSH0 (position 12)
        0x5f,       // PUSH0 (position 13)
        0xfd,       // REVERT (position 14)
        0x5b,       // JUMPDEST (position 15)
        0x50,       // POP (position 16)
        0x00,       // STOP (position 17)
    };

    std.log.debug("=== Deploying exact ERC20 bytecode ===", .{});
    
    // Since create value is 0, CALLVALUE will push 0
    // ISZERO(0) will push 1 
    // So JUMPI should jump to position 15
    
    const create_result = vm.create_contract(caller, 0, &bytecode, 10_000_000) catch |err| {
        std.log.debug("create_contract failed: {}", .{err});
        return err;
    };
    
    std.log.debug("Create result: success={}, address={}", .{ create_result.success, create_result.address });
    
    try std.testing.expect(create_result.success);
}

test "trace stack values before JUMPI" {
    const allocator = std.testing.allocator;

    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const caller = primitives.Address.from_u256(0x1);
    try vm.state.set_balance(caller, 1000000);

    // Simpler test to understand stack state
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (simulating CALLVALUE result)
        0x15,       // ISZERO (should push 1)
        0x60, 0x0f, // PUSH1 15 (destination)
        0x57,       // JUMPI
        0x00,       // STOP (position 6)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // padding
        0x5b,       // JUMPDEST (position 15)
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };

    std.log.debug("=== Testing simplified JUMPI ===", .{});
    
    const create_result = try vm.create_contract(caller, 0, &bytecode, 10_000_000);
    
    try std.testing.expect(create_result.success);
    
    const deployed_code = vm.state.get_code(create_result.address);
    try std.testing.expectEqual(@as(u8, 0x42), deployed_code[0]);
}