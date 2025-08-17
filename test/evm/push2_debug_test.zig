const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const Log = @import("evm").Log;

test {
    std.testing.log_level = .warn;
}

test "PUSH2 value interpretation" {
    const allocator = std.testing.allocator;

    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Test PUSH2 0x000f (should push 15)
    // Then JUMPI to that value
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1 (condition = true)
        0x61, 0x00, 0x0f, // PUSH2 0x000f (decimal 15)
        0x57, // JUMPI
        0x00, // STOP (position 6)
        0x00, // padding
        0x00, // padding
        0x00, // padding
        0x00, // padding
        0x00, // padding
        0x00, // padding
        0x00, // padding
        0x00, // padding
        0x5b, // JUMPDEST (position 15)
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    std.log.debug("Testing PUSH2 0x000f interpretation", .{});
    std.log.debug("Expecting jump to position 15 where JUMPDEST=0x{x}", .{bytecode[15]});

    const caller = primitives.Address.from_u256(0x1);
    try vm.state.set_balance(caller, 1000000);

    const create_result = try vm.create_contract(caller, 0, &bytecode, 10_000_000);

    std.log.debug("Create result: success={}", .{create_result.success});

    try std.testing.expect(create_result.success);

    // Check if we got the expected runtime code
    const deployed_code = vm.state.get_code(create_result.address);
    std.log.debug("Deployed code: {x}", .{deployed_code});
    try std.testing.expectEqual(@as(u8, 0x42), deployed_code[0]);
}

test "compare PUSH1 vs PUSH2 jump destinations" {
    const allocator = std.testing.allocator;

    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Test 1: PUSH1 0x05 (should jump to position 5)
    const bytecode1 = [_]u8{
        0x60, 0x01, // PUSH1 1 (condition)
        0x60, 0x05, // PUSH1 0x05
        0x57, // JUMPI (position 4)
        0x5b, // JUMPDEST (position 5)
        0x60, 0x11, // PUSH1 0x11 (result)
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const caller = primitives.Address.from_u256(0x1);
    try vm.state.set_balance(caller, 1000000);

    std.log.debug("\nTest 1: PUSH1 0x05", .{});
    const result1 = try vm.create_contract(caller, 0, &bytecode1, 10_000_000);
    try std.testing.expect(result1.success);

    const code1 = vm.state.get_code(result1.address);
    std.log.debug("Deployed code from PUSH1 test: {x}", .{code1});
    try std.testing.expectEqual(@as(u8, 0x11), code1[0]);

    // Test 2: PUSH2 0x0005 (should also jump to position 5)
    const bytecode2 = [_]u8{
        0x60, 0x01, // PUSH1 1 (condition)
        0x61, 0x00, 0x05, // PUSH2 0x0005
        0x57, // JUMPI (position 5)
        0x5b, // JUMPDEST (position 6)
        0x60, 0x22, // PUSH1 0x22 (result)
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    std.log.debug("\nTest 2: PUSH2 0x0005", .{});
    const result2 = try vm.create_contract(caller, 1, &bytecode2, 10_000_000);

    // This test expects failure because JUMPI at position 5 tries to jump to 5,
    // but JUMPDEST is at position 6
    try std.testing.expect(!result2.success);
}
