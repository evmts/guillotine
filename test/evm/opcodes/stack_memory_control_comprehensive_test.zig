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
// 0x4F-0x58 Stack, Memory, Storage, and Control Flow
// ============================

test "POP (0x50): Remove top stack item" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

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

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Pop single value
    try frame.stack.append(42);
    try testing.expectEqual(@as(usize, 1), frame.stack.size);

    _ = try evm.table.execute(0, interpreter, state, 0x50);
    try testing.expectEqual(@as(usize, 0), frame.stack.size);

    // Test 2: Pop multiple values in sequence
    try frame.stack.append(10);
    try frame.stack.append(20);
    try frame.stack.append(30);
    try testing.expectEqual(@as(usize, 3), frame.stack.size);

    _ = try evm.table.execute(0, interpreter, state, 0x50);
    try testing.expectEqual(@as(usize, 2), frame.stack.size);

    _ = try evm.table.execute(0, interpreter, state, 0x50);
    try testing.expectEqual(@as(usize, 1), frame.stack.size);

    _ = try evm.table.execute(0, interpreter, state, 0x50);
    try testing.expectEqual(@as(usize, 0), frame.stack.size);

    // Test 3: Pop from empty stack should fail
    const result = evm.table.execute(0, interpreter, state, 0x50);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

test "MLOAD (0x51): Load word from memory" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

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

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Load from uninitialized memory (should return 0)
    try frame.stack.append(0); // offset
    _ = try evm.table.execute(0, interpreter, state, 0x51);
    try testing.expectEqual(@as(u256, 0), frame.stack.data[frame.stack.size - 1]);
    _ = try frame.stack.pop();

    // Test 2: Store and load a value
    const test_value: u256 = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
    try frame.memory.set_u256(32, test_value);

    try frame.stack.append(32); // offset
    _ = try evm.table.execute(0, interpreter, state, 0x51);
    try testing.expectEqual(test_value, frame.stack.data[frame.stack.size - 1]);
    _ = try frame.stack.pop();

    // Test 3: Load from offset with partial overlap
    try frame.stack.append(16); // offset
    _ = try evm.table.execute(0, interpreter, state, 0x51);
    const result = try frame.stack.pop();
    // Should load 16 bytes of zeros followed by first 16 bytes of test_value
    const expected = test_value >> 128;
    try testing.expectEqual(expected, result);
}

test "MSTORE (0x52): Store 32 bytes to memory" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

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

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Store at offset 0
    const value1: u256 = 0xdeadbeefcafebabe;
    try frame.stack.append(value1); // value (will be popped 2nd)
    try frame.stack.append(0); // offset (will be popped 1st)
    _ = try evm.table.execute(0, interpreter, state, 0x52);

    // Verify the value was stored
    const stored1 = try frame.memory.get_u256(0);
    try testing.expectEqual(value1, stored1);

    // Test 2: Store at offset 32
    const value2: u256 = 0x1234567890abcdef;
    try frame.stack.append(value2); // value (will be popped 2nd)
    try frame.stack.append(32); // offset (will be popped 1st)
    _ = try evm.table.execute(0, interpreter, state, 0x52);

    const stored2 = try frame.memory.get_u256(32);
    try testing.expectEqual(value2, stored2);

    // Test 3: Store with memory expansion
    const value3: u256 = 0xffffffffffffffff;
    try frame.stack.append(value3); // value (will be popped 2nd)
    try frame.stack.append(1024); // offset (will be popped 1st)
    const gas_before = frame.gas_remaining;
    _ = try evm.table.execute(0, interpreter, state, 0x52);

    // Should have consumed gas for memory expansion
    try testing.expect(frame.gas_remaining < gas_before);

    const stored3 = try frame.memory.get_u256(1024);
    try testing.expectEqual(value3, stored3);
}

test "MSTORE8 (0x53): Store single byte to memory" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

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

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Store single byte
    try frame.stack.append(0xAB); // value (will be popped 2nd)
    try frame.stack.append(0); // offset (will be popped 1st)
    _ = try evm.table.execute(0, interpreter, state, 0x53);

    const byte1 = try frame.memory.get_byte(0);
    try testing.expectEqual(@as(u8, 0xAB), byte1);

    // Test 2: Store only lowest byte of larger value
    try frame.stack.append(0x123456789ABCDEF0); // value (will be popped 2nd)
    try frame.stack.append(1); // offset (will be popped 1st)
    _ = try evm.table.execute(0, interpreter, state, 0x53);

    const byte2 = try frame.memory.get_byte(1);
    try testing.expectEqual(@as(u8, 0xF0), byte2); // Only lowest byte

    // Test 3: Store at various offsets
    const test_bytes = [_]struct { value: u256, offset: u256, expected: u8 }{
        .{ .value = 0xFF, .offset = 10, .expected = 0xFF },
        .{ .value = 0x100, .offset = 11, .expected = 0x00 }, // Only lowest byte (0x00)
        .{ .value = 0x42, .offset = 12, .expected = 0x42 },
    };

    for (test_bytes) |tb| {
        try frame.stack.append(tb.value); // value (will be popped 2nd)
        try frame.stack.append(tb.offset); // offset (will be popped 1st)
        _ = try evm.table.execute(0, interpreter, state, 0x53);

        const stored = try frame.memory.get_byte(@intCast(tb.offset));
        try testing.expectEqual(tb.expected, stored);
    }
}

test "SLOAD (0x54): Load from storage" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

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

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(50000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Load from empty slot (should return 0)
    try frame.stack.append(42); // slot
    _ = try evm.table.execute(0, interpreter, state, 0x54);
    try testing.expectEqual(@as(u256, 0), frame.stack.data[frame.stack.size - 1]);
    _ = try frame.stack.pop();

    // Test 2: Load from populated slot
    const slot: u256 = 100;
    const value: u256 = 0xdeadbeef;
    // Set storage value directly in the state
    try evm.state.set_storage(contract.address, slot, value);

    try frame.stack.append(slot);
    _ = try evm.table.execute(0, interpreter, state, 0x54);
    try testing.expectEqual(value, frame.stack.data[frame.stack.size - 1]);
    _ = try frame.stack.pop();

    // Test 3: Load multiple different slots
    const test_slots = [_]struct { slot: u256, value: u256 }{
        .{ .slot = 0, .value = 1 },
        .{ .slot = 1, .value = 1000 },
        .{ .slot = std.math.maxInt(u256), .value = 42 },
    };

    for (test_slots, 0..) |ts, i| {
        _ = i;
        // Set storage value directly in the state
        try evm.state.set_storage(contract.address, ts.slot, ts.value);
        try frame.stack.append(ts.slot);
        _ = try evm.table.execute(0, interpreter, state, 0x54);
        const stack_value = try frame.stack.peek();
        _ = stack_value;
        try testing.expectEqual(ts.value, frame.stack.data[frame.stack.size - 1]);
        _ = try frame.stack.pop();
    }
}

test "SSTORE (0x55): Store to storage" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

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

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(30000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Store to empty slot
    const slot1: u256 = 10;
    const value1: u256 = 12345;
    try frame.stack.append(value1); // value (will be popped 1st)
    try frame.stack.append(slot1); // slot (will be popped 2nd)
    _ = try evm.table.execute(0, interpreter, state, 0x55);

    // Verify storage was updated
    // Get storage value from state
    const stored1 = evm.state.get_storage(contract.address, slot1);
    try testing.expectEqual(value1, stored1);

    // Test 2: Update existing slot
    const value2: u256 = 67890;
    try frame.stack.append(value2); // value (will be popped 1st)
    try frame.stack.append(slot1); // slot (will be popped 2nd)
    _ = try evm.table.execute(0, interpreter, state, 0x55);

    const stored2 = evm.state.get_storage(contract.address, slot1);
    try testing.expectEqual(value2, stored2);

    // Test 3: Clear slot (set to 0)
    try frame.stack.append(0); // value (will be popped 1st)
    try frame.stack.append(slot1); // slot (will be popped 2nd)
    _ = try evm.table.execute(0, interpreter, state, 0x55);

    const stored3 = evm.state.get_storage(contract.address, slot1);
    try testing.expectEqual(@as(u256, 0), stored3);
}

test "JUMP (0x56): Unconditional jump" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    // Create bytecode with JUMPDEST
    const code = [_]u8{
        0x60, 0x04, // PUSH1 4
        0x56, // JUMP
        0x00, // STOP (should be skipped)
        0x5B, // JUMPDEST at position 4
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

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Valid jump
    try frame.stack.append(4); // Jump to JUMPDEST at position 4
    _ = try evm.table.execute(0, interpreter, state, 0x56);
    try testing.expectEqual(@as(usize, 4), frame.pc);

    // Test 2: Invalid jump (not a JUMPDEST)
    frame.pc = 0;
    try frame.stack.append(3); // Position 3 is not a JUMPDEST
    const result = evm.table.execute(0, interpreter, state, 0x56);
    try testing.expectError(ExecutionError.Error.InvalidJump, result);

    // Test 3: Jump out of bounds
    frame.pc = 0;
    try frame.stack.append(100); // Beyond code length
    const result2 = evm.table.execute(0, interpreter, state, 0x56);
    try testing.expectError(ExecutionError.Error.InvalidJump, result2);
}

test "JUMPI (0x57): Conditional jump" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    // Create bytecode with JUMPDEST
    const code = [_]u8{
        0x60, 0x08, // PUSH1 8
        0x60, 0x01, // PUSH1 1
        0x57, // JUMPI
        0x60, 0xFF, // PUSH1 0xFF (should be skipped)
        0x00, // STOP
        0x5B, // JUMPDEST at position 8
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

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Jump with non-zero condition
    try frame.stack.append(1); // condition (will be popped 1st)
    try frame.stack.append(8); // dest (will be popped 2nd)
    _ = try evm.table.execute(0, interpreter, state, 0x57);
    try testing.expectEqual(@as(usize, 8), frame.pc);

    // Test 2: No jump with zero condition
    frame.pc = 0;
    try frame.stack.append(0); // condition (zero) (will be popped 1st)
    try frame.stack.append(8); // dest (will be popped 2nd)
    const pc_before = frame.pc;
    _ = try evm.table.execute(0, interpreter, state, 0x57);
    try testing.expectEqual(pc_before, frame.pc); // PC unchanged

    // Test 3: Jump with large non-zero condition
    frame.pc = 0;
    try frame.stack.append(std.math.maxInt(u256)); // large condition (will be popped 1st)
    try frame.stack.append(8); // dest (will be popped 2nd)
    _ = try evm.table.execute(0, interpreter, state, 0x57);
    try testing.expectEqual(@as(usize, 8), frame.pc);

    // Test 4: Invalid jump destination with non-zero condition
    frame.pc = 0;
    try frame.stack.append(1); // non-zero condition (will be popped 1st)
    try frame.stack.append(3); // invalid dest (will be popped 2nd)
    const result = evm.table.execute(0, interpreter, state, 0x57);
    try testing.expectError(ExecutionError.Error.InvalidJump, result);
}

test "PC (0x58): Get program counter" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{ 0x58, 0x58, 0x58 }, // PC, PC, PC
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: PC at position 0
    frame.pc = 0;
    _ = try evm.table.execute(0, interpreter, state, 0x58);
    try testing.expectEqual(@as(u256, 0), frame.stack.data[frame.stack.size - 1]);
    _ = try frame.stack.pop();

    // Test 2: PC at position 1
    frame.pc = 1;
    _ = try evm.table.execute(1, interpreter, state, 0x58);
    try testing.expectEqual(@as(u256, 1), frame.stack.data[frame.stack.size - 1]);
    _ = try frame.stack.pop();

    // Test 3: PC at various positions
    const test_positions = [_]usize{ 0, 10, 100, 1000, 10000 };
    for (test_positions) |pos| {
        frame.pc = pos;
        _ = try evm.table.execute(pos, interpreter, state, 0x58);
        try testing.expectEqual(@as(u256, pos), frame.stack.data[frame.stack.size - 1]);
        _ = try frame.stack.pop();
    }
}

// ============================
// Gas consumption tests
// ============================

test "Stack, Memory, and Control opcodes: Gas consumption" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x5B}, // JUMPDEST for jump tests
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

    // Test POP gas
    frame.stack.clear();
    try frame.stack.append(42);
    var gas_before: u64 = 1000;
    frame.gas_remaining = gas_before;
    _ = try evm.table.execute(0, interpreter, state, 0x50);
    var gas_used = gas_before - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 2), gas_used);

    // Test MLOAD gas
    frame.stack.clear();
    try frame.stack.append(0);
    gas_before = 1000;
    frame.gas_remaining = gas_before;
    _ = try evm.table.execute(0, interpreter, state, 0x51);
    gas_used = gas_before - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 6), gas_used); // Base (3) + memory expansion (3)

    // Test MSTORE gas (with fresh memory to avoid interference from MLOAD)
    var frame_builder2 = Frame.builder(allocator);
    var frame2 = try frame_builder2
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame2.deinit();
    const state2: Evm.Operation.State = &frame2;

    try frame2.stack.append(42); // value
    try frame2.stack.append(0); // offset (on top)
    gas_before = frame2.gas_remaining;
    _ = try evm.table.execute(0, interpreter, state2, 0x52);
    gas_used = gas_before - frame2.gas_remaining;
    try testing.expectEqual(@as(u64, 6), gas_used); // Base (3) + memory expansion (3)

    // Test MSTORE8 gas (with fresh memory)
    var frame_builder3 = Frame.builder(allocator);
    var frame3 = try frame_builder3
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame3.deinit();
    const state3: Evm.Operation.State = &frame3;

    try frame3.stack.append(42); // value (will be popped 2nd)
    try frame3.stack.append(0); // offset (will be popped 1st)
    gas_before = frame3.gas_remaining;
    _ = try evm.table.execute(0, interpreter, state3, 0x53);
    gas_used = gas_before - frame3.gas_remaining;
    try testing.expectEqual(@as(u64, 6), gas_used); // Base (3) + memory expansion (3)

    // Test PC gas
    frame.stack.clear();
    gas_before = 1000;
    frame.gas_remaining = gas_before;
    _ = try evm.table.execute(0, interpreter, state, 0x58);
    gas_used = gas_before - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 2), gas_used);
}

test "SLOAD/SSTORE: EIP-2929 gas costs" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

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

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(50000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test SLOAD cold access
    const slot: u256 = 42;
    try frame.stack.append(slot);
    const gas_before_cold = frame.gas_remaining;
    _ = try evm.table.execute(0, interpreter, state, 0x54);
    const gas_cold = gas_before_cold - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 2100), gas_cold); // Cold SLOAD cost
    _ = try frame.stack.pop();

    // Test SLOAD warm access
    try frame.stack.append(slot);
    const gas_before_warm = frame.gas_remaining;
    _ = try evm.table.execute(0, interpreter, state, 0x54);
    const gas_warm = gas_before_warm - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 100), gas_warm); // Warm SLOAD cost
}

// ============================
// Edge cases and error conditions
// ============================

test "Invalid opcode 0x4F" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

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

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    const result = evm.table.execute(0, interpreter, state, 0x4F);
    try testing.expectError(ExecutionError.Error.InvalidOpcode, result);
    try testing.expectEqual(@as(u64, 0), frame.gas_remaining);
}

test "Memory operations: Large offset handling" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

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

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100)
        .build();
    defer frame.deinit(); // Limited gas

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // MSTORE with huge offset should run out of gas
    const huge_offset = std.math.maxInt(u256);
    try frame.stack.append(42);
    try frame.stack.append(huge_offset);
    const result = evm.table.execute(0, interpreter, state, 0x52);
    try testing.expectError(ExecutionError.Error.OutOfOffset, result);
}

test "Jump operations: Code analysis integration" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    // Complex bytecode with multiple JUMPDESTs
    const code = [_]u8{
        0x60, 0x09, // PUSH1 9
        0x56, // JUMP
        0x00, // STOP
        0x00, // STOP
        0x00, // STOP
        0x00, // STOP
        0x00, // STOP
        0x00, // STOP
        0x5B, // JUMPDEST at position 9
        0x60, 0x13, // PUSH1 19
        0x60, 0x01, // PUSH1 1
        0x57, // JUMPI
        0x00, // STOP
        0x00, // STOP
        0x00, // STOP
        0x00, // STOP
        0x5B, // JUMPDEST at position 19
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

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test chained jumps
    frame.pc = 0;

    // First JUMP to position 9
    try frame.stack.append(9);
    _ = try evm.table.execute(0, interpreter, state, 0x56);
    try testing.expectEqual(@as(usize, 9), frame.pc);

    // Simulate execution at JUMPDEST, then JUMPI to position 19
    frame.pc = 11; // After PUSH1 19
    // JUMPI expects: destination on top, then condition
    // Stack: [condition, destination] with destination on top (popped second)
    try frame.stack.append(1); // condition (will be popped 1st)
    try frame.stack.append(19); // dest (will be popped 2nd)
    _ = try evm.table.execute(0, interpreter, state, 0x57);
    try testing.expectEqual(@as(usize, 19), frame.pc);
}
