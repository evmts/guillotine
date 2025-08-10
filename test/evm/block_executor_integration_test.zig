const std = @import("std");
const evm = @import("evm");

test "interpret_block: simple arithmetic execution" {
    const allocator = std.testing.allocator;

    // Create bytecode: PUSH1 5, PUSH1 10, ADD, STOP
    const bytecode = &[_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x0A, // PUSH1 10
        0x01, // ADD
        0x00, // STOP
    };

    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Create contract
    var contract = try evm.Contract.init(
        allocator,
        bytecode,
        null,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        1000000, // gas
        false,
    );
    defer contract.deinit(allocator, null);

    // Execute using block-based interpretation
    const result = try vm.interpret_block(&contract, &.{}, false);
    defer if (result.output) |output| allocator.free(output);

    // Verify success
    try std.testing.expectEqual(evm.RunResult.Status.Success, result.status);
    try std.testing.expect(result.output == null);

    // Gas should be consumed
    try std.testing.expect(result.gas_used > 0);
}

test "interpret_block: contract with output" {
    const allocator = std.testing.allocator;

    // Create bytecode: PUSH1 0x42, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
    const bytecode = &[_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Create contract
    var contract = try evm.Contract.init(
        allocator,
        bytecode,
        null,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        1000000, // gas
        false,
    );
    defer contract.deinit(allocator, null);

    // Execute using block-based interpretation
    const result = try vm.interpret_block(&contract, &.{}, false);
    defer if (result.output) |output| allocator.free(output);

    // Verify success with output
    try std.testing.expectEqual(evm.RunResult.Status.Success, result.status);
    try std.testing.expect(result.output != null);
    try std.testing.expectEqual(@as(usize, 32), result.output.?.len);

    // Check the value (0x42 stored as 32-byte word)
    var expected = [_]u8{0} ** 32;
    expected[31] = 0x42;
    try std.testing.expectEqualSlices(u8, &expected, result.output.?);
}

test "interpret_block: fallback to regular interpret for jumps" {
    const allocator = std.testing.allocator;

    // Create bytecode with JUMP: PUSH1 0x08, JUMP, INVALID, JUMPDEST, STOP
    const bytecode = &[_]u8{
        0x60, 0x08, // PUSH1 0x08
        0x56, // JUMP
        0xFE, // INVALID (should be skipped)
        0xFE, // INVALID (should be skipped)
        0xFE, // INVALID (should be skipped)
        0x5B, // JUMPDEST (at position 8)
        0x00, // STOP
    };

    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Create contract
    var contract = try evm.Contract.init(
        allocator,
        bytecode,
        null,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        1000000, // gas
        false,
    );
    defer contract.deinit(allocator, null);

    // Execute using block-based interpretation (should fallback to regular)
    const result = try vm.interpret_block(&contract, &.{}, false);
    defer if (result.output) |output| allocator.free(output);

    // Should still succeed (via fallback)
    try std.testing.expectEqual(evm.RunResult.Status.Success, result.status);
}

test "interpret_block: comparison with regular interpret" {
    const allocator = std.testing.allocator;

    // Create a simple bytecode program
    const bytecode = &[_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x02, // MUL
        0x60, 0x02, // PUSH1 2
        0x01, // ADD
        0x00, // STOP
    };

    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // Create contract for regular interpretation
    var contract1 = try evm.Contract.init(
        allocator,
        bytecode,
        null,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        1000000, // gas
        false,
    );
    defer contract1.deinit(allocator, null);

    // Execute using regular interpretation
    const result1 = try vm.interpret(&contract1, &.{}, false);
    defer if (result1.output) |output| allocator.free(output);

    // Create contract for block interpretation
    var contract2 = try evm.Contract.init(
        allocator,
        bytecode,
        null,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        evm.primitives.Address.ZERO,
        1000000, // gas
        false,
    );
    defer contract2.deinit(allocator, null);

    // Execute using block-based interpretation
    const result2 = try vm.interpret_block(&contract2, &.{}, false);
    defer if (result2.output) |output| allocator.free(output);

    // Both should succeed with same results
    try std.testing.expectEqual(result1.status, result2.status);
    try std.testing.expectEqual(result1.gas_used, result2.gas_used);
}
