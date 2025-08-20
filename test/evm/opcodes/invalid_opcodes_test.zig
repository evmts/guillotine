const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const Contract = Evm.Contract;
const Frame = Evm.Frame;
const MemoryDatabase = Evm.MemoryDatabase;
const ExecutionError = Evm.ExecutionError;

// Test invalid opcodes in the 0x21-0x2F range
test "Invalid Opcodes: 0x21-0x24 should fail" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    // Create test addresses
    const contract_address: Address.Address = [_]u8{0x12} ** 20;
    const caller_address: Address.Address = [_]u8{0xab} ** 20;

    // Create contract
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    // Test each invalid opcode from 0x21 to 0x24
    const invalid_opcodes = [_]u8{ 0x21, 0x22, 0x23, 0x24 };

    for (invalid_opcodes) |opcode| {
        frame.stack.clear();
        frame.gas_remaining = 1000;

        // Push some dummy values on stack in case the opcode tries to pop
        try frame.stack.append(42);
        try frame.stack.append(100);

        // Execute opcode directly through jump table
        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &frame;
        const result = evm.table.execute(0, interpreter, state, opcode);

        // We expect an error (likely InvalidOpcode or similar)
        try testing.expectError(ExecutionError.Error.InvalidOpcode, result);

        // All gas should be consumed
        try testing.expectEqual(@as(u64, 0), frame.gas_remaining);
    }
}

// Test that all opcodes in the 0x21-0x2F range are invalid
test "Invalid Opcodes: Full 0x21-0x2F range" {
    const allocator = testing.allocator;

    // Create memory database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    // Create test addresses
    const contract_address: Address.Address = [_]u8{0x12} ** 20;
    const caller_address: Address.Address = [_]u8{0xab} ** 20;

    // Create contract
    var contract = Contract.init(
        caller_address,
        contract_address,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    // Test all opcodes from 0x21 to 0x2F
    var opcode: u8 = 0x21;
    while (opcode <= 0x2F) : (opcode += 1) {
        frame.stack.clear();
        frame.gas_remaining = 1000;

        // Push some dummy values
        try frame.stack.append(1);
        try frame.stack.append(2);
        try frame.stack.append(3);

        // Execute opcode directly through jump table
        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &frame;
        const result = evm.table.execute(0, interpreter, state, opcode);

        // All these should be invalid
        try testing.expectError(ExecutionError.Error.InvalidOpcode, result);

        // Verify gas consumption
        try testing.expectEqual(@as(u64, 0), frame.gas_remaining);
    }
}
