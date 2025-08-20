const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const Contract = Evm.Contract;
const Frame = Evm.Frame;
const MemoryDatabase = Evm.MemoryDatabase;
const ExecutionError = Evm.ExecutionError;

// ============================
// 0x59-0x5B: MSIZE, GAS, JUMPDEST
// ============================

test "MSIZE (0x59): Get current memory size" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        10000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Initial memory size (should be 0)
    _ = try evm.table.execute(0, interpreter, state, 0x59);
    try testing.expectEqual(@as(u256, 0), frame.stack.data[frame.stack.size - 1]);
    _ = try frame.stack.pop();

    // Test 2: After storing 32 bytes
    try frame.stack.append(0xdeadbeef); // value
    try frame.stack.append(0); // offset
    _ = try evm.table.execute(0, interpreter, state, 0x52); // MSTORE

    _ = try evm.table.execute(0, interpreter, state, 0x59);
    try testing.expectEqual(@as(u256, 32), frame.stack.data[frame.stack.size - 1]); // One word
    _ = try frame.stack.pop();

    // Test 3: After storing at offset 32
    try frame.stack.append(0xcafebabe); // value
    try frame.stack.append(32); // offset
    _ = try evm.table.execute(0, interpreter, state, 0x52); // MSTORE

    _ = try evm.table.execute(0, interpreter, state, 0x59);
    try testing.expectEqual(@as(u256, 64), frame.stack.data[frame.stack.size - 1]); // Two words
    _ = try frame.stack.pop();

    // Test 4: After storing at offset 100 (should expand to word boundary)
    try frame.stack.append(0x12345678); // value
    try frame.stack.append(100); // offset
    _ = try evm.table.execute(0, interpreter, state, 0x52); // MSTORE

    _ = try evm.table.execute(0, interpreter, state, 0x59);
    // 100 + 32 = 132, rounded up to word boundary = 160 (5 words)
    try testing.expectEqual(@as(u256, 160), frame.stack.data[frame.stack.size - 1]);
    _ = try frame.stack.pop();

    // Test 5: After MSTORE8 (single byte)
    try frame.stack.append(0xFF); // value
    try frame.stack.append(200); // offset
    _ = try evm.table.execute(0, interpreter, state, 0x53); // MSTORE8

    _ = try evm.table.execute(0, interpreter, state, 0x59);
    // 200 + 1 = 201, rounded up to word boundary = 224 (7 words)
    try testing.expectEqual(@as(u256, 224), frame.stack.data[frame.stack.size - 1]);
}

test "GAS (0x5A): Get remaining gas" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Test with different initial gas amounts
    const test_cases = [_]u64{
        100,
        1000,
        10000,
        100000,
        1000000,
        std.math.maxInt(u64),
    };

    for (test_cases) |initial_gas| {
        var frame_builder = Frame.builder(allocator);
        var frame = try frame_builder
            .withVm(&evm)
            .withContract(&contract)
            .withGas(initial_gas)
            .build();
        defer frame.deinit();

        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &frame;

        // Execute GAS opcode
        _ = try evm.table.execute(0, interpreter, state, 0x5A);

        // The value pushed should be initial_gas minus the gas cost of GAS itself (2)
        const expected_gas = initial_gas - 2;
        try testing.expectEqual(@as(u256, expected_gas), frame.stack.data[frame.stack.size - 1]);
        _ = try frame.stack.pop();

        // Test 2: After consuming more gas
        const gas_before = frame.gas_remaining;

        // Execute some operations to consume gas
        try frame.stack.append(5); // Push value
        try frame.stack.append(10); // Push value
        _ = try evm.table.execute(0, interpreter, state, 0x01); // ADD (costs 3)
        _ = try frame.stack.pop();

        // Execute GAS again
        _ = try evm.table.execute(0, interpreter, state, 0x5A);

        // Should have consumed gas for ADD (3) and GAS (2)
        const expected_remaining = gas_before - 3 - 2;
        try testing.expectEqual(@as(u256, expected_remaining), frame.stack.data[frame.stack.size - 1]);
    }
}

test "JUMPDEST (0x5B): Mark valid jump destination" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    // Create bytecode with multiple JUMPDESTs
    const code = [_]u8{
        0x5B, // JUMPDEST at position 0
        0x60, 0x05, // PUSH1 5
        0x5B, // JUMPDEST at position 3
        0x60, 0x0A, // PUSH1 10
        0x5B, // JUMPDEST at position 6
        0x00, // STOP
    };

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        10000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Execute JUMPDEST - should be a no-op
    const stack_size_before = frame.stack.size;
    const gas_before = frame.gas_remaining;
    _ = try evm.table.execute(0, interpreter, state, 0x5B);

    // Stack should be unchanged
    try testing.expectEqual(stack_size_before, frame.stack.size);

    // Should consume only JUMPDEST gas (1)
    try testing.expectEqual(@as(u64, gas_before - 1), frame.gas_remaining);

    // Test 2: Verify jump destinations are valid
    try testing.expect(contract.valid_jumpdest(allocator, 0)); // Position 0
    try testing.expect(contract.valid_jumpdest(allocator, 3)); // Position 3
    try testing.expect(contract.valid_jumpdest(allocator, 6)); // Position 6

    // Test 3: Verify non-JUMPDEST positions are invalid
    try testing.expect(!contract.valid_jumpdest(allocator, 1)); // PUSH1 opcode
    try testing.expect(!contract.valid_jumpdest(allocator, 2)); // PUSH1 data
    try testing.expect(!contract.valid_jumpdest(allocator, 4)); // PUSH1 opcode
    try testing.expect(!contract.valid_jumpdest(allocator, 5)); // PUSH1 data
    try testing.expect(!contract.valid_jumpdest(allocator, 7)); // STOP

    // Test 4: Verify out of bounds positions are invalid
    try testing.expect(!contract.valid_jumpdest(allocator, 100));
    try testing.expect(!contract.valid_jumpdest(allocator, std.math.maxInt(u256)));
}

// ============================
// Gas consumption tests
// ============================

test "MSIZE, GAS, JUMPDEST: Gas consumption" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        10000,
        &[_]u8{0x5B}, // Include JUMPDEST
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    const opcodes = [_]struct {
        opcode: u8,
        name: []const u8,
        expected_gas: u64,
    }{
        .{ .opcode = 0x59, .name = "MSIZE", .expected_gas = 2 },
        .{ .opcode = 0x5A, .name = "GAS", .expected_gas = 2 },
        .{ .opcode = 0x5B, .name = "JUMPDEST", .expected_gas = 1 },
    };

    for (opcodes) |op| {
        frame.stack.clear();
        const gas_before = 1000;
        frame.gas_remaining = gas_before;

        _ = try evm.table.execute(0, interpreter, state, op.opcode);

        const gas_used = gas_before - frame.gas_remaining;
        try testing.expectEqual(op.expected_gas, gas_used);
    }
}

// ============================
// Edge cases and special scenarios
// ============================

test "MSIZE: Memory expansion scenarios" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        100000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test expansion via MLOAD
    try frame.stack.append(64); // offset
    _ = try evm.table.execute(0, interpreter, state, 0x51); // MLOAD
    _ = try frame.stack.pop();

    _ = try evm.table.execute(0, interpreter, state, 0x59); // MSIZE
    try testing.expectEqual(@as(u256, 96), frame.stack.data[frame.stack.size - 1]); // 64 + 32 = 96
    _ = try frame.stack.pop();

    // Test expansion via CALLDATACOPY
    frame.input = &[_]u8{ 0x01, 0x02, 0x03, 0x04 };
    try frame.stack.append(4); // size
    try frame.stack.append(0); // data_offset
    try frame.stack.append(200); // mem_offset
    _ = try evm.table.execute(0, interpreter, state, 0x37); // CALLDATACOPY

    _ = try evm.table.execute(0, interpreter, state, 0x59); // MSIZE
    try testing.expectEqual(@as(u256, 224), frame.stack.data[frame.stack.size - 1]); // 200 + 4 = 204, rounded to 224
}

test "GAS: Low gas scenarios" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Test with exactly enough gas for GAS opcode
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(2)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x5A);
    try testing.expectEqual(@as(u256, 0), frame.stack.data[frame.stack.size - 1]); // All gas consumed
    _ = try frame.stack.pop();

    // Test with not enough gas
    frame.gas_remaining = 1;
    const result = evm.table.execute(0, interpreter, state, 0x5A);
    try testing.expectError(ExecutionError.Error.OutOfGas, result);
}

test "JUMPDEST: Code analysis integration" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    // Complex bytecode with JUMPDEST in data section
    const code = [_]u8{
        0x60, 0x5B, // PUSH1 0x5B (pushes JUMPDEST opcode as data)
        0x60, 0x08, // PUSH1 8
        0x56, // JUMP
        0x5B, // This is actually a valid standalone JUMPDEST
        0x00, // STOP
        0x00, // Padding
        0x5B, // Real JUMPDEST at position 8
        0x60, 0x42, // PUSH1 0x42
        0x00, // STOP
    };

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    // Force code analysis

    // The JUMPDEST at position 5 SHOULD be valid (it's standalone, not PUSH data)
    try testing.expect(contract.valid_jumpdest(allocator, 5));

    // The JUMPDEST at position 8 should be valid
    try testing.expect(contract.valid_jumpdest(allocator, 8));

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Jump to valid JUMPDEST should succeed
    try frame.stack.append(8);
    _ = try evm.table.execute(0, interpreter, state, 0x56); // JUMP
    try testing.expectEqual(@as(usize, 8), frame.pc);

    // Jump to position 5 should also succeed (it's a valid JUMPDEST)
    frame.pc = 0;
    try frame.stack.append(5);
    _ = try evm.table.execute(0, interpreter, state, 0x56); // JUMP
    try testing.expectEqual(@as(usize, 5), frame.pc);
}

test "Stack operations: MSIZE and GAS push exactly one value" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        10000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    const opcodes = [_]u8{ 0x59, 0x5A }; // MSIZE, GAS

    for (opcodes) |opcode| {
        frame.stack.clear();
        const initial_stack_len = frame.stack.size;

        _ = try evm.table.execute(0, interpreter, state, opcode);

        // Check that exactly one value was pushed
        try testing.expectEqual(initial_stack_len + 1, frame.stack.size);
    }
}
