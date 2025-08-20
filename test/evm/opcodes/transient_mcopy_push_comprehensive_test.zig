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
// 0x5C-0x5E: TLOAD, TSTORE, MCOPY
// ============================

test "TLOAD (0x5C): Load from transient storage" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{ 0x5C, 0x5D }, // TLOAD, TSTORE opcodes
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

    // Test 1: Load from empty slot (should return 0)
    try frame.stack.append(42); // slot
    _ = try evm.table.execute(1, interpreter, state, 0x5C);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result1);

    // Test 2: Load after TSTORE
    const slot: u256 = 100;
    const value: u256 = 0xdeadbeef;
    try frame.stack.append(value); // value
    try frame.stack.append(slot); // slot (on top)
    _ = try evm.table.execute(0, interpreter, state, 0x5D); // TSTORE

    try frame.stack.append(slot);
    _ = try evm.table.execute(1, interpreter, state, 0x5C);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(value, result2);

    // Test 3: Multiple slots
    const test_slots = [_]struct { slot: u256, value: u256 }{
        .{ .slot = 0, .value = 1 },
        .{ .slot = 1, .value = 1000 },
        .{ .slot = std.math.maxInt(u256), .value = 42 },
    };

    for (test_slots) |ts| {
        try frame.stack.append(ts.value); // value
        try frame.stack.append(ts.slot); // slot (on top)
        _ = try evm.table.execute(0, interpreter, state, 0x5D); // TSTORE

        try frame.stack.append(ts.slot);
        _ = try evm.table.execute(1, interpreter, state, 0x5C);
        const result = try frame.stack.pop();
        try testing.expectEqual(ts.value, result);
    }
}

test "TSTORE (0x5D): Store to transient storage" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
    const bytecode = [_]u8{ 0x5D, 0x5C }; // TSTORE at 0, TLOAD at 1
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &bytecode,
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

    // Test 1: Store to empty slot
    const slot1: u256 = 10;
    const value1: u256 = 12345;
    try frame.stack.append(value1); // value
    try frame.stack.append(slot1); // slot (on top)
    _ = try evm.table.execute(0, interpreter, state, 0x5D);

    // Verify storage was updated via TLOAD
    try frame.stack.append(slot1);
    _ = try evm.table.execute(1, interpreter, state, 0x5C);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(value1, result1);

    // Test 2: Update existing slot
    const value2: u256 = 67890;
    try frame.stack.append(value2); // value
    try frame.stack.append(slot1); // slot (on top)
    _ = try evm.table.execute(0, interpreter, state, 0x5D);

    try frame.stack.append(slot1);
    _ = try evm.table.execute(1, interpreter, state, 0x5C);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(value2, result2);

    // Test 3: Clear slot (set to 0)
    try frame.stack.append(0); // value
    try frame.stack.append(slot1); // slot (on top)
    _ = try evm.table.execute(0, interpreter, state, 0x5D);

    try frame.stack.append(slot1);
    _ = try evm.table.execute(1, interpreter, state, 0x5C);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result3);

    // Test 4: TSTORE in static context should fail
    frame.is_static = true;
    try frame.stack.append(42); // value
    try frame.stack.append(1); // slot (on top)
    const result = evm.table.execute(frame.pc, interpreter, state, 0x5D);
    try testing.expectError(ExecutionError.Error.WriteProtection, result);
}

test "MCOPY (0x5E): Memory to memory copy" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{ 0x5E, 0x51, 0x52, 0x59 }, // MCOPY, MLOAD, MSTORE, MSIZE opcodes
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

    // Test 1: Simple copy without overlap
    // Store data at source location
    const test_data: u256 = 0xdeadbeefcafebabe1234567890abcdef;
    try frame.stack.append(test_data); // value
    try frame.stack.append(0); // offset
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x52); // MSTORE at 0

    // Copy 32 bytes from offset 0 to offset 64
    try frame.stack.append(32); // size
    try frame.stack.append(0); // src
    try frame.stack.append(64); // dest (on top)
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x5E);

    // Verify data was copied
    try frame.stack.append(64); // offset
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x51); // MLOAD
    const result1 = try frame.stack.pop();
    try testing.expectEqual(test_data, result1);

    // Test 2: Copy with forward overlap (dest > src)
    // Copy from offset 0 to offset 16 (partial overlap)
    try frame.stack.append(32); // size
    try frame.stack.append(0); // src
    try frame.stack.append(16); // dest (on top)
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x5E);

    // Test 3: Copy with backward overlap (dest < src)
    // First store different data at offset 32
    const test_data2: u256 = 0xfeedfacefeedfacefeedfacefeedface;
    try frame.stack.append(test_data2); // value
    try frame.stack.append(32); // offset
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x52); // MSTORE

    // Copy from offset 32 to offset 16 (backward overlap)
    try frame.stack.append(32); // size
    try frame.stack.append(32); // src
    try frame.stack.append(16); // dest (on top)
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x5E);

    // Test 4: Zero-size copy (should be no-op)
    const gas_before = frame.gas_remaining;
    try frame.stack.append(0); // size=0
    try frame.stack.append(200); // src
    try frame.stack.append(100); // dest (on top)
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x5E);
    // Should only consume base gas (3)
    try testing.expectEqual(@as(u64, gas_before - 3), frame.gas_remaining);

    // Test 5: Large copy
    try frame.stack.append(1000); // dest
    try frame.stack.append(0); // src
    try frame.stack.append(256); // size (on top)
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x5E);

    // Verify memory size expanded correctly
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x59); // MSIZE
    const msize = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1280), msize); // 1000 + 256 = 1256, rounded to 1280
}

// ============================
// 0x5F-0x62: PUSH0, PUSH1, PUSH2, PUSH3
// ============================

test "PUSH0 (0x5F): Push zero onto stack" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x5F}, // PUSH0 opcode
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(3000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Basic PUSH0
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x5F);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result1);

    // Test 2: Multiple PUSH0 operations
    for (0..5) |_| {
        _ = try evm.table.execute(frame.pc, interpreter, state, 0x5F);
    }
    try testing.expectEqual(@as(usize, 5), frame.stack.size);

    // All values should be 0
    for (0..5) |_| {
        const value = try frame.stack.pop();
        try testing.expectEqual(@as(u256, 0), value);
    }

    // Test 3: Stack overflow protection
    // Fill stack to near capacity
    for (0..1023) |_| {
        _ = try evm.table.execute(frame.pc, interpreter, state, 0x5F);
    }

    // One more should succeed (stack capacity is 1024)
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x5F);

    // Next one should fail
    const result = evm.table.execute(frame.pc, interpreter, state, 0x5F);
    try testing.expectError(ExecutionError.Error.StackOverflow, result);
}

test "PUSH1 (0x60): Push 1 byte onto stack" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const code = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0xFF, // PUSH1 0xFF
        0x60, 0x00, // PUSH1 0x00
        0x60, 0x7F, // PUSH1 0x7F
    };

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
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

    // Test pushing different byte values
    const expected_values = [_]u256{ 0x42, 0xFF, 0x00, 0x7F };

    for (expected_values) |expected| {
        const pc = frame.pc;
        const result = try evm.table.execute(pc, interpreter, state, 0x60);

        // Check that 2 bytes were consumed (opcode + data)
        try testing.expectEqual(@as(usize, 2), result.bytes_consumed);
        frame.pc = pc + 2;

        const value = try frame.stack.pop();
        try testing.expectEqual(expected, value);
    }
}

test "PUSH2 (0x61): Push 2 bytes onto stack" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const code = [_]u8{
        0x61, 0x12, 0x34, // PUSH2 0x1234
        0x61, 0xFF, 0xFF, // PUSH2 0xFFFF
        0x61, 0x00, 0x00, // PUSH2 0x0000
        0x61, 0xAB, 0xCD, // PUSH2 0xABCD
    };

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
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

    const expected_values = [_]u256{ 0x1234, 0xFFFF, 0x0000, 0xABCD };

    for (expected_values) |expected| {
        const pc = frame.pc;
        const result = try evm.table.execute(pc, interpreter, state, 0x61);

        // Check that 3 bytes were consumed (opcode + 2 data bytes)
        try testing.expectEqual(@as(usize, 3), result.bytes_consumed);
        frame.pc = pc + 3;

        const value = try frame.stack.pop();
        try testing.expectEqual(expected, value);
    }
}

test "PUSH3 (0x62): Push 3 bytes onto stack" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const code = [_]u8{
        0x62, 0x12, 0x34, 0x56, // PUSH3 0x123456
        0x62, 0xFF, 0xFF, 0xFF, // PUSH3 0xFFFFFF
        0x62, 0x00, 0x00, 0x00, // PUSH3 0x000000
        0x62, 0xAB, 0xCD, 0xEF, // PUSH3 0xABCDEF
    };

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
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

    const expected_values = [_]u256{ 0x123456, 0xFFFFFF, 0x000000, 0xABCDEF };

    for (expected_values) |expected| {
        const pc = frame.pc;
        const result = try evm.table.execute(pc, interpreter, state, 0x62);

        // Check that 4 bytes were consumed (opcode + 3 data bytes)
        try testing.expectEqual(@as(usize, 4), result.bytes_consumed);
        frame.pc = pc + 4;

        const value = try frame.stack.pop();
        try testing.expectEqual(expected, value);
    }
}

// ============================
// Gas consumption tests
// ============================

test "Transient storage and memory opcodes: Gas consumption" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const code = [_]u8{ 0x60, 0x42 }; // PUSH1 data for testing
    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
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
        .withGas(100000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test TLOAD gas
    frame.stack.clear();
    try frame.stack.append(42); // slot
    var gas_before = frame.gas_remaining;
    _ = try evm.table.execute(1, interpreter, state, 0x5C);
    var gas_used = gas_before - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 100), gas_used); // TLOAD costs 100
    _ = try frame.stack.pop();

    // Test TSTORE gas
    frame.stack.clear();
    try frame.stack.append(0xdead); // value (will be popped 1st)
    try frame.stack.append(42); // slot (will be popped 2nd)
    gas_before = frame.gas_remaining;
    _ = try evm.table.execute(0, interpreter, state, 0x5D);
    gas_used = gas_before - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 100), gas_used); // TSTORE costs 100

    // Test MCOPY gas (base cost only, no copy)
    frame.stack.clear();
    try frame.stack.append(0); // size=0
    try frame.stack.append(0); // src
    try frame.stack.append(100); // dest
    gas_before = frame.gas_remaining;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x5E);
    gas_used = gas_before - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 3), gas_used); // MCOPY base cost is 3

    // Test MCOPY with copy gas
    frame.stack.clear();
    try frame.stack.append(32); // size=32 (1 word)
    try frame.stack.append(0); // src
    try frame.stack.append(100); // dest
    gas_before = frame.gas_remaining;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x5E);
    gas_used = gas_before - frame.gas_remaining;
    // Base cost (3) + copy cost (3 * 1 word) + memory expansion
    try testing.expect(gas_used >= 6);

    // Test PUSH0 gas
    frame.stack.clear();
    gas_before = frame.gas_remaining;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x5F);
    gas_used = gas_before - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 2), gas_used); // PUSH0 costs 2

    // Test PUSH1 gas
    frame.stack.clear();
    frame.pc = 0;
    gas_before = frame.gas_remaining;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x60);
    gas_used = gas_before - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 3), gas_used); // PUSH1 costs 3
}

// ============================
// Edge cases and special scenarios
// ============================

test "MCOPY: Edge cases" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x5E}, // MCOPY opcode
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(100) // Limited gas
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test: MCOPY with huge size should run out of gas or fail with offset error
    try frame.stack.append(std.math.maxInt(u256)); // huge size
    try frame.stack.append(0); // src
    try frame.stack.append(0); // dest (on top)
    const result = evm.table.execute(0, interpreter, state, 0x5E);
    try testing.expectError(ExecutionError.Error.OutOfOffset, result);
}

test "Transient storage: Isolation between addresses" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr1 = [_]u8{0x33} ** 20;
    const contract_addr2 = [_]u8{0x11} ** 20;

    var contract1 = Contract.init(
        caller,
        contract_addr1,
        0,
        1000,
        &[_]u8{ 0x5C, 0x5D }, // TLOAD, TSTORE opcodes
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract1.deinit(allocator, null);

    var contract2 = Contract.init(
        caller,
        contract_addr2,
        0,
        1000,
        &[_]u8{ 0x5C, 0x5D }, // TLOAD, TSTORE opcodes
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract2.deinit(allocator, null);

    var frame_builder1 = Frame.builder(allocator);
    var frame1 = try frame_builder1
        .withVm(&evm)
        .withContract(&contract1)
        .withGas(10000)
        .build();
    defer frame1.deinit();

    var frame_builder2 = Frame.builder(allocator);
    var frame2 = try frame_builder2
        .withVm(&evm)
        .withContract(&contract2)
        .withGas(10000)
        .build();
    defer frame2.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state1: Evm.Operation.State = &frame1;
    const state2: Evm.Operation.State = &frame2;

    // Store value in contract1's transient storage
    const slot: u256 = 42;
    const value: u256 = 0xdeadbeef;
    try frame1.stack.append(value); // value (will be popped 1st)
    try frame1.stack.append(slot); // slot (will be popped 2nd)
    _ = try evm.table.execute(0, interpreter, state1, 0x5D); // TSTORE

    // Same slot in contract2 should still be 0
    try frame2.stack.append(slot);
    _ = try evm.table.execute(0, interpreter, state2, 0x5C); // TLOAD
    const result = try frame2.stack.pop();
    try testing.expectEqual(@as(u256, 0), result); // Should be 0, not value
}

test "PUSH operations: Boundary conditions" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    // Test PUSH with truncated data at end of code
    const code = [_]u8{
        0x60, 0x42, // Complete PUSH1
        0x61, 0x12, // Incomplete PUSH2 (missing 1 byte)
    };

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
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

    // First PUSH1 should work normally
    const result1 = try evm.table.execute(frame.pc, interpreter, state, 0x60);
    try testing.expectEqual(@as(usize, 2), result1.bytes_consumed);
    const value1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0x42), value1);
    frame.pc = 2;

    // Second PUSH2 should pad with zeros
    const result2 = try evm.table.execute(frame.pc, interpreter, state, 0x61);
    try testing.expectEqual(@as(usize, 3), result2.bytes_consumed);
    const value2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0x1200), value2); // 0x12 followed by 0x00
}
