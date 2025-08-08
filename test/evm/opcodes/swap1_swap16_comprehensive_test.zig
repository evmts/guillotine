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
// 0x90-0x9F: SWAP1 through SWAP16
// ============================

test "SWAP1 (0x90): Swap top two stack items" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x02, // PUSH1 0x02
        0x90, // SWAP1
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

    // Execute PUSH1 0x01
    frame.pc = 0;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x60);
    frame.pc = 2;

    // Execute PUSH1 0x02
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x60);
    frame.pc = 4;

    // Stack should be [0x01, 0x02] (top is 0x02)
    try testing.expectEqual(@as(usize, 2), frame.stack.size);
    try testing.expectEqual(@as(u256, 0x02), frame.stack.data[frame.stack.size - 1]);
    try testing.expectEqual(@as(u256, 0x01), frame.stack.data[frame.stack.size - 2]);

    // Execute SWAP1
    const result = try evm.table.execute(0, interpreter, state, 0x90);
    try testing.expectEqual(@as(usize, 1), result.bytes_consumed);

    // Stack should now be [0x02, 0x01] (swapped)
    try testing.expectEqual(@as(usize, 2), frame.stack.size);
    try testing.expectEqual(@as(u256, 0x01), frame.stack.data[frame.stack.size - 1]); // Top
    try testing.expectEqual(@as(u256, 0x02), frame.stack.data[frame.stack.size - 2]); // Bottom
}

test "SWAP2 (0x91): Swap 1st and 3rd stack items" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{0x91}; // SWAP2

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

    // Push three values
    try frame.stack.append(0x11); // Bottom
    try frame.stack.append(0x22); // Middle
    try frame.stack.append(0x33); // Top

    // Execute SWAP2
    const result = try evm.table.execute(0, interpreter, state, 0x91);
    try testing.expectEqual(@as(usize, 1), result.bytes_consumed);

    // Stack should now be [0x33, 0x22, 0x11] -> [0x11, 0x22, 0x33]
    try testing.expectEqual(@as(usize, 3), frame.stack.size);
    try testing.expectEqual(@as(u256, 0x11), frame.stack.data[frame.stack.size - 1]); // Top (was bottom)
    try testing.expectEqual(@as(u256, 0x22), frame.stack.data[frame.stack.size - 2]); // Middle (unchanged)
    try testing.expectEqual(@as(u256, 0x33), frame.stack.data[frame.stack.size - 3]); // Bottom (was top)
}

test "SWAP3-SWAP5: Various swaps" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{ 0x92, 0x93, 0x94 }; // SWAP3, SWAP4, SWAP5

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

    // Push 6 distinct values
    for (1..7) |i| {
        try frame.stack.append(i * 0x10); // 0x10, 0x20, ..., 0x60
    }

    // Execute SWAP3 (swap top with 4th)
    frame.pc = 0;
    var result = try evm.table.execute(0, interpreter, state, 0x92);
    try testing.expectEqual(@as(usize, 1), result.bytes_consumed);
    // Stack was: [0x10, 0x20, 0x30, 0x40, 0x50, 0x60]
    // SWAP3 swaps top (0x60) with 4th from top (0x30)
    // Now: [0x10, 0x20, 0x60, 0x40, 0x50, 0x30]
    try testing.expectEqual(@as(u256, 0x30), frame.stack.data[frame.stack.size - 1]);
    try testing.expectEqual(@as(u256, 0x60), frame.stack.data[frame.stack.size - 4]);

    // Execute SWAP4 (swap new top with 5th)
    frame.pc = 1;
    // Before SWAP4
    result = try evm.table.execute(0, interpreter, state, 0x93);
    try testing.expectEqual(@as(usize, 1), result.bytes_consumed);
    // After SWAP4
    // Stack was: [0x10, 0x20, 0x60, 0x40, 0x50, 0x30]
    // SWAP4 swaps top (0x30) with 5th from top (0x20)
    // Now: [0x10, 0x30, 0x60, 0x40, 0x50, 0x20]
    try testing.expectEqual(@as(u256, 0x20), frame.stack.data[frame.stack.size - 1]);
    try testing.expectEqual(@as(u256, 0x30), frame.stack.data[frame.stack.size - 5]);

    // Execute SWAP5 (swap new top with 6th)
    frame.pc = 2;
    // Before SWAP5
    result = try evm.table.execute(0, interpreter, state, 0x94);
    try testing.expectEqual(@as(usize, 1), result.bytes_consumed);
    // After SWAP5
    // Stack was: [0x10, 0x30, 0x60, 0x40, 0x50, 0x20]
    // SWAP5 swaps top (0x20) with 6th from top (0x10)
    // Now: [0x20, 0x30, 0x60, 0x40, 0x50, 0x10]
    try testing.expectEqual(@as(u256, 0x10), frame.stack.data[frame.stack.size - 1]);
    try testing.expectEqual(@as(u256, 0x20), frame.stack.data[frame.stack.size - 6]);
}

test "SWAP6-SWAP10: Mid-range swaps" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{ 0x95, 0x96, 0x97, 0x98, 0x99 }; // SWAP6-SWAP10

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

    // Push 11 distinct values
    for (0..11) |i| {
        try frame.stack.append(0x100 + i); // 0x100, 0x101, ..., 0x10A
    }

    // Execute SWAP6
    frame.pc = 0;
    const result6 = try evm.table.execute(0, interpreter, state, 0x95);
    try testing.expectEqual(@as(usize, 1), result6.bytes_consumed);
    try testing.expectEqual(@as(u256, 0x104), frame.stack.data[frame.stack.size - 1]); // Was at position 6
    try testing.expectEqual(@as(u256, 0x10A), frame.stack.data[frame.stack.size - 7]); // Was at top

    // Execute SWAP7
    frame.pc = 1;
    _ = try evm.table.execute(0, interpreter, state, 0x96);
    try testing.expectEqual(@as(u256, 0x103), frame.stack.data[frame.stack.size - 1]); // Was at position 7

    // Execute SWAP8
    frame.pc = 2;
    _ = try evm.table.execute(0, interpreter, state, 0x97);
    try testing.expectEqual(@as(u256, 0x102), frame.stack.data[frame.stack.size - 1]); // Was at position 8

    // Execute SWAP9
    frame.pc = 3;
    _ = try evm.table.execute(0, interpreter, state, 0x98);
    try testing.expectEqual(@as(u256, 0x101), frame.stack.data[frame.stack.size - 1]); // Was at position 9

    // Execute SWAP10
    frame.pc = 4;
    _ = try evm.table.execute(0, interpreter, state, 0x99);
    try testing.expectEqual(@as(u256, 0x100), frame.stack.data[frame.stack.size - 1]); // Was at position 10 (bottom)
}

test "SWAP11-SWAP16: High-range swaps" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{ 0x9A, 0x9B, 0x9C, 0x9D, 0x9E, 0x9F }; // SWAP11-SWAP16

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

    // Push 17 distinct values (need 17 for SWAP16)
    for (0..17) |i| {
        try frame.stack.append(0x200 + i); // 0x200-0x210
    }

    // Execute SWAP11
    frame.pc = 0;
    _ = try evm.table.execute(0, interpreter, state, 0x9A);
    try testing.expectEqual(@as(u256, 0x205), frame.stack.data[frame.stack.size - 1]); // Was at position 11
    try testing.expectEqual(@as(u256, 0x210), frame.stack.data[frame.stack.size - 12]); // Was at top

    // Execute SWAP12
    frame.pc = 1;
    _ = try evm.table.execute(0, interpreter, state, 0x9B);
    try testing.expectEqual(@as(u256, 0x204), frame.stack.data[frame.stack.size - 1]); // Was at position 12

    // Execute SWAP13
    frame.pc = 2;
    _ = try evm.table.execute(0, interpreter, state, 0x9C);
    try testing.expectEqual(@as(u256, 0x203), frame.stack.data[frame.stack.size - 1]); // Was at position 13

    // Execute SWAP14
    frame.pc = 3;
    _ = try evm.table.execute(0, interpreter, state, 0x9D);
    try testing.expectEqual(@as(u256, 0x202), frame.stack.data[frame.stack.size - 1]); // Was at position 14

    // Execute SWAP15
    frame.pc = 4;
    _ = try evm.table.execute(0, interpreter, state, 0x9E);
    try testing.expectEqual(@as(u256, 0x201), frame.stack.data[frame.stack.size - 1]); // Was at position 15

    // Execute SWAP16
    frame.pc = 5;
    _ = try evm.table.execute(0, interpreter, state, 0x9F);
    try testing.expectEqual(@as(u256, 0x200), frame.stack.data[frame.stack.size - 1]); // Was at position 16 (bottom)
    try testing.expectEqual(@as(u256, 0x201), frame.stack.data[frame.stack.size - 17]); // Previous top value
}

test "SWAP16 (0x9F): Swap with 16th position (maximum)" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{0x9F}; // SWAP16

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

    // Push exactly 17 values (minimum for SWAP16)
    for (0..17) |i| {
        try frame.stack.append(0xA00 + i);
    }

    // Before SWAP16: top is 0xA10, 16th position is 0xA00
    try testing.expectEqual(@as(u256, 0xA10), frame.stack.data[frame.stack.size - 1]);
    try testing.expectEqual(@as(u256, 0xA00), frame.stack.data[frame.stack.size - 17]);

    const result = try evm.table.execute(0, interpreter, state, 0x9F);
    try testing.expectEqual(@as(usize, 1), result.bytes_consumed);

    // After SWAP16: positions should be swapped
    try testing.expectEqual(@as(u256, 0xA00), frame.stack.data[frame.stack.size - 1]);
    try testing.expectEqual(@as(u256, 0xA10), frame.stack.data[frame.stack.size - 17]);
}

// ============================
// Gas consumption tests
// ============================

test "SWAP1-SWAP16: Gas consumption" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{
        0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97,
        0x98, 0x99, 0x9A, 0x9B, 0x9C, 0x9D, 0x9E, 0x9F,
    };

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x33} ** 20;
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

    // Push 17 values to satisfy all SWAP operations
    for (0..17) |i| {
        try frame.stack.append(@as(u256, @intCast(i)));
    }

    // Test each SWAP operation
    for (0..16) |i| {
        frame.pc = i;
        const gas_before = frame.gas_remaining;

        const opcode = @as(u8, @intCast(0x90 + i));
        const result = try evm.table.execute(0, interpreter, state, opcode);

        // All SWAP operations cost 3 gas (GasFastestStep)
        const gas_used = gas_before - frame.gas_remaining;
        try testing.expectEqual(@as(u64, 3), gas_used);

        // All SWAP operations consume 1 byte
        try testing.expectEqual(@as(usize, 1), result.bytes_consumed);
    }
}

// ============================
// Edge cases and error conditions
// ============================

test "SWAP operations: Stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{ 0x90, 0x91, 0x95, 0x9F }; // SWAP1, SWAP2, SWAP6, SWAP16

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

    // Empty stack - SWAP1 should fail (needs 2 items)
    frame.pc = 0;
    var result = evm.table.execute(0, interpreter, state, 0x90);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);

    // Push 1 value
    try frame.stack.append(0x42);

    // SWAP1 still fails (needs 2 items)
    result = evm.table.execute(0, interpreter, state, 0x90);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);

    // Push another value
    try frame.stack.append(0x43);

    // SWAP1 should succeed now (2 items)
    _ = try evm.table.execute(0, interpreter, state, 0x90);

    // SWAP2 should fail (needs 3 items, only have 2)
    frame.pc = 1;
    result = evm.table.execute(0, interpreter, state, 0x91);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);

    // Push more values
    for (0..5) |i| {
        try frame.stack.append(@as(u256, @intCast(i)));
    }

    // SWAP6 should succeed (have 7 items, need 7)
    frame.pc = 2;
    _ = try evm.table.execute(0, interpreter, state, 0x95);

    // SWAP16 should fail (have 7 items, need 17)
    frame.pc = 3;
    result = evm.table.execute(0, interpreter, state, 0x9F);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

test "SWAP operations: Sequential swaps" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x02, // PUSH1 0x02
        0x60, 0x03, // PUSH1 0x03
        0x60, 0x04, // PUSH1 0x04
        0x90, // SWAP1
        0x91, // SWAP2
        0x90, // SWAP1
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

    // Execute PUSH operations
    for (0..4) |i| {
        frame.pc = i * 2;
        _ = try evm.table.execute(frame.pc, interpreter, state, 0x60);
    }

    // Stack: [0x01, 0x02, 0x03, 0x04]
    try testing.expectEqual(@as(usize, 4), frame.stack.size);

    // Execute first SWAP1
    frame.pc = 8;
    _ = try evm.table.execute(0, interpreter, state, 0x90);
    // Stack: [0x01, 0x02, 0x04, 0x03]
    try testing.expectEqual(@as(u256, 0x03), frame.stack.data[frame.stack.size - 1]);
    try testing.expectEqual(@as(u256, 0x04), frame.stack.data[frame.stack.size - 2]);

    // Execute SWAP2
    frame.pc = 9;
    _ = try evm.table.execute(0, interpreter, state, 0x91);
    // Stack: [0x01, 0x03, 0x04, 0x02]
    try testing.expectEqual(@as(u256, 0x02), frame.stack.data[frame.stack.size - 1]);
    try testing.expectEqual(@as(u256, 0x03), frame.stack.data[frame.stack.size - 3]);

    // Execute second SWAP1
    frame.pc = 10;
    _ = try evm.table.execute(0, interpreter, state, 0x90);
    // Stack: [0x01, 0x03, 0x02, 0x04]
    try testing.expectEqual(@as(u256, 0x04), frame.stack.data[frame.stack.size - 1]);
    try testing.expectEqual(@as(u256, 0x02), frame.stack.data[frame.stack.size - 2]);
}

test "SWAP operations: Pattern verification" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{ 0x90, 0x94, 0x98, 0x9C, 0x9F }; // SWAP1, SWAP5, SWAP9, SWAP13, SWAP16

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

    // Push a pattern of values (17 values for SWAP16)
    for (0..17) |i| {
        try frame.stack.append(0xFF00 + i); // 0xFF00-0xFF10
    }

    // Before any swaps, verify initial state
    try testing.expectEqual(@as(u256, 0xFF10), frame.stack.data[frame.stack.size - 1]); // Top
    try testing.expectEqual(@as(u256, 0xFF00), frame.stack.data[frame.stack.size - 17]); // Bottom

    // SWAP1: swap top (0xFF10) with second (0xFF0F)
    frame.pc = 0;
    _ = try evm.table.execute(0, interpreter, state, 0x90);
    try testing.expectEqual(@as(u256, 0xFF0F), frame.stack.data[frame.stack.size - 1]);
    try testing.expectEqual(@as(u256, 0xFF10), frame.stack.data[frame.stack.size - 2]);

    // SWAP5: swap new top (0xFF0F) with 6th position (0xFF0B)
    frame.pc = 1;
    _ = try evm.table.execute(0, interpreter, state, 0x94);
    try testing.expectEqual(@as(u256, 0xFF0B), frame.stack.data[frame.stack.size - 1]);
    try testing.expectEqual(@as(u256, 0xFF0F), frame.stack.data[frame.stack.size - 6]);

    // SWAP9: swap new top (0xFF0B) with 10th position (0xFF07)
    frame.pc = 2;
    _ = try evm.table.execute(0, interpreter, state, 0x98);
    try testing.expectEqual(@as(u256, 0xFF07), frame.stack.data[frame.stack.size - 1]);
    try testing.expectEqual(@as(u256, 0xFF0B), frame.stack.data[frame.stack.size - 10]);

    // SWAP13: swap new top (0xFF07) with 14th position (0xFF03)
    frame.pc = 3;
    _ = try evm.table.execute(0, interpreter, state, 0x9C);
    try testing.expectEqual(@as(u256, 0xFF03), frame.stack.data[frame.stack.size - 1]);
    try testing.expectEqual(@as(u256, 0xFF07), frame.stack.data[frame.stack.size - 14]);

    // SWAP16: swap new top (0xFF03) with 17th position (0xFF00)
    frame.pc = 4;
    _ = try evm.table.execute(0, interpreter, state, 0x9F);
    try testing.expectEqual(@as(u256, 0xFF00), frame.stack.data[frame.stack.size - 1]);
    try testing.expectEqual(@as(u256, 0xFF03), frame.stack.data[frame.stack.size - 17]);
}

test "SWAP operations: Boundary test with exact stack size" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{ 0x90, 0x9F }; // SWAP1, SWAP16

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

    // Test SWAP1 with exactly 2 items
    try frame.stack.append(0xAA);
    try frame.stack.append(0xBB);

    frame.pc = 0;
    _ = try evm.table.execute(0, interpreter, state, 0x90);
    try testing.expectEqual(@as(u256, 0xAA), frame.stack.data[frame.stack.size - 1]);
    try testing.expectEqual(@as(u256, 0xBB), frame.stack.data[frame.stack.size - 2]);

    // Clear stack
    frame.stack.clear();

    // Test SWAP16 with exactly 17 items
    for (1..18) |i| {
        try frame.stack.append(@as(u256, @intCast(i)));
    }

    frame.pc = 1;
    _ = try evm.table.execute(0, interpreter, state, 0x9F);
    try testing.expectEqual(@as(u256, 1), frame.stack.data[frame.stack.size - 1]); // Swapped with bottom
    try testing.expectEqual(@as(u256, 17), frame.stack.data[frame.stack.size - 17]); // Was top

    // Test SWAP16 with 16 items (should fail)
    frame.stack.clear();
    for (1..17) |i| {
        try frame.stack.append(@as(u256, @intCast(i)));
    }
    const result = evm.table.execute(0, interpreter, state, 0x9F);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

test "SWAP operations: No side effects" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    defer evm.deinit();

    const code = [_]u8{0x92}; // SWAP3

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

    // Push 5 values
    try frame.stack.append(0x11);
    try frame.stack.append(0x22);
    try frame.stack.append(0x33);
    try frame.stack.append(0x44);
    try frame.stack.append(0x55);

    // Execute SWAP3
    _ = try evm.table.execute(0, interpreter, state, 0x92);

    // Verify only positions 0 and 3 were swapped
    try testing.expectEqual(@as(u256, 0x22), frame.stack.data[frame.stack.size - 1]); // Was at position 3
    try testing.expectEqual(@as(u256, 0x44), frame.stack.data[frame.stack.size - 2]); // Unchanged
    try testing.expectEqual(@as(u256, 0x33), frame.stack.data[frame.stack.size - 3]); // Unchanged
    try testing.expectEqual(@as(u256, 0x55), frame.stack.data[frame.stack.size - 4]); // Was at position 0
    try testing.expectEqual(@as(u256, 0x11), frame.stack.data[frame.stack.size - 5]); // Unchanged

    // Stack size should remain the same
    try testing.expectEqual(@as(usize, 5), frame.stack.size);
}
