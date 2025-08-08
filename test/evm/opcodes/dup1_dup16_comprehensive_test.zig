const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const CallParams = Evm.Host.CallParams;
const CallResult = Evm.CallResult;
const Contract = Evm.Contract;
const Frame = Evm.Frame;
const MemoryDatabase = Evm.MemoryDatabase;
const ExecutionError = Evm.ExecutionError;
// Updated to new API - migration in progress, tests not run yet
// Updated to new API - migration in progress, tests not run yet

// ============================
// 0x80-0x8F: DUP1 through DUP16
// ============================

test "DUP1 (0x80): Duplicate 1st stack item" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x33, // PUSH1 0x33
        0x80, // DUP1
    };

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
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

    // Execute PUSH1 0x42
    frame.pc = 0;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x60);
    frame.pc = 2;

    // Execute PUSH1 0x33
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x60);
    frame.pc = 4;

    // Stack should be [0x42, 0x33] (top is 0x33)
    try testing.expectEqual(@as(usize, 2), frame.stack.size);

    // Execute DUP1
    const result = try evm.table.execute(frame.pc, interpreter, state, 0x80);
    try testing.expectEqual(@as(usize, 1), result.bytes_consumed);

    // Stack should now be [0x42, 0x33, 0x33]
    try testing.expectEqual(@as(usize, 3), frame.stack.size);
    try testing.expectEqual(@as(u256, 0x33), frame.stack.data[frame.stack.size - 1]); // Top
    try testing.expectEqual(@as(u256, 0x33), frame.stack.data[frame.stack.size - 2]); // Second
    try testing.expectEqual(@as(u256, 0x42), frame.stack.data[frame.stack.size - 3]); // Third
}

test "DUP2 (0x81): Duplicate 2nd stack item" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x33, // PUSH1 0x33
        0x81, // DUP2
    };

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
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

    // Push two values
    try frame.stack.append(0x42);
    try frame.stack.append(0x33);

    // Execute DUP2
    frame.pc = 4;
    const result = try evm.table.execute(frame.pc, interpreter, state, 0x81);
    try testing.expectEqual(@as(usize, 1), result.bytes_consumed);

    // Stack should now be [0x42, 0x33, 0x42]
    try testing.expectEqual(@as(usize, 3), frame.stack.size);
    try testing.expectEqual(@as(u256, 0x42), frame.stack.data[frame.stack.size - 1]); // Top (duplicated)
    try testing.expectEqual(@as(u256, 0x33), frame.stack.data[frame.stack.size - 2]); // Second
    try testing.expectEqual(@as(u256, 0x42), frame.stack.data[frame.stack.size - 3]); // Third (original)
}

test "DUP3-DUP5: Various duplications" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{ 0x82, 0x83, 0x84 }; // DUP3, DUP4, DUP5

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
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

    // Push 5 distinct values
    try frame.stack.append(0x11); // Bottom
    try frame.stack.append(0x22);
    try frame.stack.append(0x33);
    try frame.stack.append(0x44);
    try frame.stack.append(0x55); // Top

    // Execute DUP3 (should duplicate 0x33)
    frame.pc = 0;
    var result = try evm.table.execute(frame.pc, interpreter, state, 0x82);
    try testing.expectEqual(@as(usize, 1), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 6), frame.stack.size);
    try testing.expectEqual(@as(u256, 0x33), frame.stack.data[frame.stack.size - 1]); // Duplicated value on top

    // Execute DUP4 (should duplicate 0x33 again, as it's now 4th from top)
    frame.pc = 1;
    result = try evm.table.execute(frame.pc, interpreter, state, 0x83);
    try testing.expectEqual(@as(usize, 1), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 7), frame.stack.size);
    try testing.expectEqual(@as(u256, 0x33), frame.stack.data[frame.stack.size - 1]); // Duplicated value on top

    // Execute DUP5 (should duplicate 0x22)
    frame.pc = 2;
    result = try evm.table.execute(frame.pc, interpreter, state, 0x84);
    try testing.expectEqual(@as(usize, 1), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 8), frame.stack.size);
    try testing.expectEqual(@as(u256, 0x33), frame.stack.data[frame.stack.size - 1]); // DUP5 duplicates the 5th element which is 0x33
}

test "DUP6-DUP10: Mid-range duplications" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{ 0x85, 0x86, 0x87, 0x88, 0x89 }; // DUP6-DUP10

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
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

    // Push 10 distinct values
    for (1..11) |i| {
        try frame.stack.append(i * 0x10);
    }

    // Execute DUP6 (should duplicate 0x50)
    frame.pc = 0;
    const result = try evm.table.execute(frame.pc, interpreter, state, 0x85);
    try testing.expectEqual(@as(usize, 1), result.bytes_consumed);
    try testing.expectEqual(@as(u256, 0x50), frame.stack.data[frame.stack.size - 1]);

    // Execute DUP7 (should duplicate 0x50 again, as it's now 7th)
    frame.pc = 1;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x86);
    try testing.expectEqual(@as(u256, 0x50), frame.stack.data[frame.stack.size - 1]);

    // Execute DUP8 (should duplicate 0x40)
    frame.pc = 2;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x87);
    try testing.expectEqual(@as(u256, 0x50), frame.stack.data[frame.stack.size - 1]); // DUP8 duplicates position 8 which is 0x50

    // Execute DUP9 (should duplicate 0x30)
    frame.pc = 3;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x88);
    try testing.expectEqual(@as(u256, 0x50), frame.stack.data[frame.stack.size - 1]); // DUP9 duplicates position 9 which is 0x50

    // Execute DUP10 (should duplicate 0x20)
    frame.pc = 4;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x89);
    try testing.expectEqual(@as(u256, 0x50), frame.stack.data[frame.stack.size - 1]); // DUP10 duplicates position 10 which is 0x50
}

test "DUP11-DUP16: High-range duplications" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{ 0x8A, 0x8B, 0x8C, 0x8D, 0x8E, 0x8F }; // DUP11-DUP16

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
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

    // Push 16 distinct values
    for (1..17) |i| {
        try frame.stack.append(i * 0x100);
    }

    // Execute DUP11 (should duplicate 0x600)
    frame.pc = 0;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x8A);
    try testing.expectEqual(@as(u256, 0x600), frame.stack.data[frame.stack.size - 1]);

    // Execute DUP12 (position 12 contains 0x600)
    frame.pc = 1;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x8B);
    try testing.expectEqual(@as(u256, 0x600), frame.stack.data[frame.stack.size - 1]);

    // Execute DUP13 (position 13 contains 0x600)
    frame.pc = 2;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x8C);
    try testing.expectEqual(@as(u256, 0x600), frame.stack.data[frame.stack.size - 1]);

    // Execute DUP14 - position 14 is 0x600
    frame.pc = 3;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x8D);
    try testing.expectEqual(@as(u256, 0x600), frame.stack.data[frame.stack.size - 1]);

    // Execute DUP15 - position 15 from top
    frame.pc = 4;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x8E);
    try testing.expectEqual(@as(u256, 0x600), frame.stack.data[frame.stack.size - 1]);

    // Execute DUP16 - position 16 from top
    frame.pc = 5;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x8F);
    // Stack now has 21 items. Position 16 from top should be one of the original values
    try testing.expectEqual(@as(u256, 0x600), frame.stack.data[frame.stack.size - 1]);
}

test "DUP16 (0x8F): Duplicate 16th stack item (maximum)" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{0x8F}; // DUP16

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
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

    // Push exactly 16 values
    for (0..16) |i| {
        try frame.stack.append(0x1000 + i);
    }

    // The 16th item from top should be 0x1000 (first pushed)
    const result = try evm.table.execute(frame.pc, interpreter, state, 0x8F);
    try testing.expectEqual(@as(usize, 1), result.bytes_consumed);

    try testing.expectEqual(@as(usize, 17), frame.stack.size);
    try testing.expectEqual(@as(u256, 0x1000), frame.stack.data[frame.stack.size - 1]); // Duplicated first item
    try testing.expectEqual(@as(u256, 0x1000), frame.stack.data[frame.stack.size - 17]); // Original position
}

// ============================
// Gas consumption tests
// ============================

test "DUP1-DUP16: Gas consumption" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{
        0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x8D, 0x8E, 0x8F,
    };

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
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

    // Push 16 values to satisfy all DUP operations
    for (0..16) |i| {
        try frame.stack.append(@as(u256, @intCast(i)));
    }

    // Test each DUP operation
    for (0..16) |i| {
        frame.pc = i;
        const gas_before = frame.gas_remaining;

        const opcode = @as(u8, @intCast(0x80 + i));
        const result = try evm.table.execute(0, interpreter, state, opcode);

        // All DUP operations cost 3 gas (GasFastestStep)
        const gas_used = gas_before - frame.gas_remaining;
        try testing.expectEqual(@as(u64, 3), gas_used);

        // All DUP operations consume 1 byte
        try testing.expectEqual(@as(usize, 1), result.bytes_consumed);
    }
}

// ============================
// Edge cases and error conditions
// ============================

test "DUP operations: Stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{ 0x80, 0x81, 0x85, 0x8F }; // DUP1, DUP2, DUP6, DUP16

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
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

    // Empty stack - DUP1 should fail
    frame.pc = 0;
    var result = evm.table.execute(frame.pc, interpreter, state, 0x80);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);

    // Push 1 value
    try frame.stack.append(0x42);

    // DUP1 should succeed
    const result2 = try evm.table.execute(frame.pc, interpreter, state, 0x80);
    try testing.expectEqual(@as(usize, 1), result2.bytes_consumed);

    // DUP2 should succeed with 2 items on stack
    frame.pc = 1;
    const result3 = try evm.table.execute(frame.pc, interpreter, state, 0x81);
    try testing.expectEqual(@as(usize, 1), result3.bytes_consumed);
    try testing.expectEqual(@as(usize, 3), frame.stack.size);

    // Push more values
    for (0..4) |i| {
        try frame.stack.append(@as(u256, @intCast(i)));
    }

    // DUP6 should succeed (6 items on stack)
    frame.pc = 2;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x85);

    // DUP16 should fail (only 7 items on stack)
    frame.pc = 3;
    result = evm.table.execute(frame.pc, interpreter, state, 0x8F);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

test "DUP operations: Stack overflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{0x80}; // DUP1

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
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

    // Fill stack to capacity (1024 items)
    for (0..1024) |i| {
        try frame.stack.append(@as(u256, @intCast(i & 0xFF)));
    }

    // DUP1 should fail with stack overflow
    const result = evm.table.execute(frame.pc, interpreter, state, 0x80);
    try testing.expectError(ExecutionError.Error.StackOverflow, result);
}

test "DUP operations: Sequential duplications" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x02, // PUSH1 0x02
        0x60, 0x03, // PUSH1 0x03
        0x80, // DUP1 (dup 0x03)
        0x81, // DUP2 (dup 0x03 again)
        0x84, // DUP5 (dup 0x02)
    };

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
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

    // Execute PUSH operations
    for (0..3) |i| {
        frame.pc = i * 2;
        _ = try evm.table.execute(frame.pc, interpreter, state, 0x60);
    }

    // Stack: [0x01, 0x02, 0x03]
    try testing.expectEqual(@as(usize, 3), frame.stack.size);

    // Execute DUP1
    frame.pc = 6;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x80);
    // Stack: [0x01, 0x02, 0x03, 0x03]
    try testing.expectEqual(@as(usize, 4), frame.stack.size);
    try testing.expectEqual(@as(u256, 0x03), frame.stack.data[frame.stack.size - 1]);

    // Execute DUP2
    frame.pc = 7;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x81);
    // Stack: [0x01, 0x02, 0x03, 0x03, 0x03]
    try testing.expectEqual(@as(usize, 5), frame.stack.size);
    try testing.expectEqual(@as(u256, 0x03), frame.stack.data[frame.stack.size - 1]);
    try testing.expectEqual(@as(u256, 0x03), frame.stack.data[frame.stack.size - 2]);

    // Execute DUP5
    frame.pc = 8;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x84);
    // Stack: [0x01, 0x02, 0x03, 0x03, 0x03, 0x01]
    try testing.expectEqual(@as(usize, 6), frame.stack.size);
    try testing.expectEqual(@as(u256, 0x01), frame.stack.data[frame.stack.size - 1]);
}

test "DUP operations: Pattern verification" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{ 0x80, 0x84, 0x88, 0x8C, 0x8F }; // DUP1, DUP5, DUP9, DUP13, DUP16

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
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

    // Push a pattern of values
    for (0..16) |i| {
        try frame.stack.append(@as(u256, (i + 1) * 0x11)); // 0x11, 0x22, ..., 0x110
    }

    // DUP1 should duplicate the top (0x110)
    frame.pc = 0;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x80);
    try testing.expectEqual(@as(u256, 0x110), frame.stack.data[frame.stack.size - 1]);

    // DUP5 should duplicate 5th from top (now 0xCC)
    frame.pc = 1;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x84);
    try testing.expectEqual(@as(u256, 0xDD), frame.stack.data[frame.stack.size - 1]); // After DUP1, positions shift

    // DUP9 should duplicate 9th from top (now 0x99)
    frame.pc = 2;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x88);
    try testing.expectEqual(@as(u256, 0xAA), frame.stack.data[frame.stack.size - 1]); // DUP9 gets 9th from top which is 0xAA

    // DUP13 should duplicate 13th from top (now 0x77 after 3 DUPs)
    frame.pc = 3;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x8C);
    try testing.expectEqual(@as(u256, 0x77), frame.stack.data[frame.stack.size - 1]); // DUP13 gets 13th from top which is 0x77

    // DUP16 should duplicate 16th from top (now 0x55 after 4 DUPs)
    frame.pc = 4;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x8F);
    try testing.expectEqual(@as(u256, 0x55), frame.stack.data[frame.stack.size - 1]); // DUP16 gets 16th from top which is 0x55

    // Final stack size should be 21 (16 original + 5 duplicated)
    try testing.expectEqual(@as(usize, 21), frame.stack.size);
}

test "DUP operations: Boundary test with exact stack size" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();

    const code = [_]u8{ 0x80, 0x8F }; // DUP1, DUP16

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
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

    // Test DUP1 with exactly 1 item
    try frame.stack.append(0xAA);
    frame.pc = 0;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x80);
    try testing.expectEqual(@as(usize, 2), frame.stack.size);
    try testing.expectEqual(@as(u256, 0xAA), frame.stack.data[frame.stack.size - 1]);
    try testing.expectEqual(@as(u256, 0xAA), frame.stack.data[frame.stack.size - 2]);

    // Clear stack
    frame.stack.clear();

    // Test DUP16 with exactly 16 items
    for (1..17) |i| {
        try frame.stack.append(@as(u256, @intCast(i)));
    }
    frame.pc = 1;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x8F);
    try testing.expectEqual(@as(usize, 17), frame.stack.size);
    try testing.expectEqual(@as(u256, 1), frame.stack.data[frame.stack.size - 1]); // First pushed item

    // Test DUP16 with 15 items (should fail)
    frame.stack.clear();
    for (1..16) |i| {
        try frame.stack.append(@as(u256, @intCast(i)));
    }
    const result = evm.table.execute(frame.pc, interpreter, state, 0x8F);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}
