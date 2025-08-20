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
// 0x6D-0x7F: PUSH14 through PUSH32
// ============================

test "PUSH14 (0x6D): Push 14 bytes onto stack" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;

    const code = [_]u8{
        0x6D, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, // PUSH14
        0x6D, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // PUSH14 max
    };

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

    // Test first PUSH14
    var result = try evm.table.execute(frame.pc, interpreter, state, 0x6D);
    try testing.expectEqual(@as(usize, 15), result.bytes_consumed);
    const top1 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0x0102030405060708090A0B0C0D0E), top1);
    _ = try frame.stack.pop();
    frame.pc = 15;

    // Test second PUSH14 (max value)
    result = try evm.table.execute(frame.pc, interpreter, state, 0x6D);
    try testing.expectEqual(@as(usize, 15), result.bytes_consumed);
    const top2 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF), top2);
}

test "PUSH15 (0x6E): Push 15 bytes onto stack" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;

    const code = [_]u8{
        0x6E, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, // PUSH15
    };

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

    const result = try evm.table.execute(frame.pc, interpreter, state, 0x6E);
    try testing.expectEqual(@as(usize, 16), result.bytes_consumed);
    const top = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0x0102030405060708090A0B0C0D0E0F), top);
}

test "PUSH16 (0x6F): Push 16 bytes onto stack" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;

    const code = [_]u8{
        0x6F, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, // PUSH16
        0x6F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // PUSH16 max
    };

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

    // Test first PUSH16
    var result = try evm.table.execute(frame.pc, interpreter, state, 0x6F);
    try testing.expectEqual(@as(usize, 17), result.bytes_consumed);
    const top1 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0x0102030405060708090A0B0C0D0E0F10), top1);
    _ = try frame.stack.pop();
    frame.pc = 17;

    // Test second PUSH16 (max value)
    result = try evm.table.execute(frame.pc, interpreter, state, 0x6F);
    try testing.expectEqual(@as(usize, 17), result.bytes_consumed);
    const top2 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF), top2);
}

test "PUSH17-PUSH19: Various sizes" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;

    // Create code with PUSH17, PUSH18, PUSH19
    var code: [60]u8 = undefined;
    var idx: usize = 0;

    // PUSH17
    code[idx] = 0x70;
    for (1..18) |_| {
        code[idx + i] = @intCast(i);
    }
    idx += 18;

    // PUSH18
    code[idx] = 0x71;
    for (1..19) |_| {
        code[idx + i] = @intCast(i);
    }
    idx += 19;

    // PUSH19
    code[idx] = 0x72;
    for (1..20) |_| {
        code[idx + i] = @intCast(i);
    }

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

    // Test PUSH17
    var result = try evm.table.execute(frame.pc, interpreter, state, 0x70);
    try testing.expectEqual(@as(usize, 18), result.bytes_consumed);
    const top1 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0x0102030405060708090A0B0C0D0E0F1011), top1);
    _ = try frame.stack.pop();
    frame.pc = 18;

    // Test PUSH18
    result = try evm.table.execute(frame.pc, interpreter, state, 0x71);
    try testing.expectEqual(@as(usize, 19), result.bytes_consumed);
    const top2 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0x0102030405060708090A0B0C0D0E0F101112), top2);
    _ = try frame.stack.pop();
    frame.pc = 37;

    // Test PUSH19
    result = try evm.table.execute(frame.pc, interpreter, state, 0x72);
    try testing.expectEqual(@as(usize, 20), result.bytes_consumed);
    const top3 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0x0102030405060708090A0B0C0D0E0F10111213), top3);
}

test "PUSH20-PUSH24: Various sizes" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;

    // Create large code buffer
    var code: [150]u8 = undefined;
    var idx: usize = 0;

    // PUSH20 (0x73) - 20 bytes is common for addresses
    code[idx] = 0x73;
    for (1..21) |_| {
        code[idx + i] = @intCast(i);
    }
    idx += 21;

    // PUSH21 (0x74)
    code[idx] = 0x74;
    for (1..22) |_| {
        code[idx + i] = @intCast(i);
    }
    idx += 22;

    // PUSH22 (0x75)
    code[idx] = 0x75;
    for (1..23) |_| {
        code[idx + i] = @intCast(i);
    }
    idx += 23;

    // PUSH23 (0x76)
    code[idx] = 0x76;
    for (1..24) |_| {
        code[idx + i] = @intCast(i);
    }
    idx += 24;

    // PUSH24 (0x77)
    code[idx] = 0x77;
    for (1..25) |_| {
        code[idx + i] = @intCast(i);
    }

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

    // Test PUSH20
    var result = try evm.table.execute(frame.pc, interpreter, state, 0x73);
    try testing.expectEqual(@as(usize, 21), result.bytes_consumed);
    const top1 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0x0102030405060708090A0B0C0D0E0F1011121314), top1);
    _ = try frame.stack.pop();
    frame.pc = 21;

    // Test PUSH21
    result = try evm.table.execute(frame.pc, interpreter, state, 0x74);
    try testing.expectEqual(@as(usize, 22), result.bytes_consumed);
    const top2 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0x0102030405060708090A0B0C0D0E0F101112131415), top2);
    _ = try frame.stack.pop();
    frame.pc = 43;

    // Test PUSH22
    result = try evm.table.execute(frame.pc, interpreter, state, 0x75);
    try testing.expectEqual(@as(usize, 23), result.bytes_consumed);
    const top3 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0x0102030405060708090A0B0C0D0E0F10111213141516), top3);
    _ = try frame.stack.pop();
    frame.pc = 66;

    // Test PUSH23
    result = try evm.table.execute(frame.pc, interpreter, state, 0x76);
    try testing.expectEqual(@as(usize, 24), result.bytes_consumed);
    const top4 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0x0102030405060708090A0B0C0D0E0F1011121314151617), top4);
    _ = try frame.stack.pop();
    frame.pc = 90;

    // Test PUSH24
    result = try evm.table.execute(frame.pc, interpreter, state, 0x77);
    try testing.expectEqual(@as(usize, 25), result.bytes_consumed);
    const top5 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0x0102030405060708090A0B0C0D0E0F101112131415161718), top5);
}

test "PUSH25-PUSH31: Various sizes" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;

    // Test a few more sizes
    var code: [100]u8 = undefined;
    var idx: usize = 0;

    // PUSH25 (0x78)
    code[idx] = 0x78;
    for (1..26) |_| {
        code[idx + i] = @intCast(i % 256);
    }
    idx += 26;

    // PUSH30 (0x7D)
    code[idx] = 0x7D;
    for (1..31) |_| {
        code[idx + i] = @intCast(i % 256);
    }
    idx += 31;

    // PUSH31 (0x7E)
    code[idx] = 0x7E;
    for (1..32) |_| {
        code[idx + i] = @intCast(i % 256);
    }

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

    // Test PUSH25
    var result = try evm.table.execute(frame.pc, interpreter, state, 0x78);
    try testing.expectEqual(@as(usize, 26), result.bytes_consumed);
    const expected25: u256 = 0x0102030405060708090A0B0C0D0E0F10111213141516171819;
    const top1 = try frame.stack.peek_n(0);
    try testing.expectEqual(expected25, top1);
    _ = try frame.stack.pop();
    frame.pc = 26;

    // Test PUSH30
    result = try evm.table.execute(frame.pc, interpreter, state, 0x7D);
    try testing.expectEqual(@as(usize, 31), result.bytes_consumed);
    const expected30: u256 = 0x0102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E;
    const top2 = try frame.stack.peek_n(0);
    try testing.expectEqual(expected30, top2);
    _ = try frame.stack.pop();
    frame.pc = 57;

    // Test PUSH31
    result = try evm.table.execute(frame.pc, interpreter, state, 0x7E);
    try testing.expectEqual(@as(usize, 32), result.bytes_consumed);
    const expected31: u256 = 0x0102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F;
    const top3 = try frame.stack.peek_n(0);
    try testing.expectEqual(expected31, top3);
}

test "PUSH32 (0x7F): Push full 32 bytes onto stack" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;

    const code = [_]u8{
        // PUSH32 with all bytes different
        0x7F,
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
        0x06,
        0x07,
        0x08,
        0x09,
        0x0A,
        0x0B,
        0x0C,
        0x0D,
        0x0E,
        0x0F,
        0x10,
        0x11,
        0x12,
        0x13,
        0x14,
        0x15,
        0x16,
        0x17,
        0x18,
        0x19,
        0x1A,
        0x1B,
        0x1C,
        0x1D,
        0x1E,
        0x1F,
        0x20,
        // PUSH32 with max value
        0x7F,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        // PUSH32 with zero
        0x7F,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
    };

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

    // Test first PUSH32
    var result = try evm.table.execute(frame.pc, interpreter, state, 0x7F);
    try testing.expectEqual(@as(usize, 33), result.bytes_consumed);
    const expected: u256 = 0x0102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20;
    const top1 = try frame.stack.peek_n(0);
    try testing.expectEqual(expected, top1);
    _ = try frame.stack.pop();
    frame.pc = 33;

    // Test PUSH32 with max value
    result = try evm.table.execute(frame.pc, interpreter, state, 0x7F);
    try testing.expectEqual(@as(usize, 33), result.bytes_consumed);
    const max_u256: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    const top2 = try frame.stack.peek_n(0);
    try testing.expectEqual(max_u256, top2);
    _ = try frame.stack.pop();
    frame.pc = 66;

    // Test PUSH32 with zero
    result = try evm.table.execute(frame.pc, interpreter, state, 0x7F);
    try testing.expectEqual(@as(usize, 33), result.bytes_consumed);
    const top3 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0), top3);
}

// ============================
// Gas consumption tests
// ============================

test "PUSH14-PUSH32: Gas consumption" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;

    // Create bytecode with various PUSH operations
    var code: [500]u8 = undefined;
    var idx: usize = 0;

    // Add PUSH14 through PUSH32
    for (0x6D..0x80) |opcode| {
        code[idx] = @intCast(opcode);
        idx += 1;
        const bytes_to_push = opcode - 0x60 + 1;
        for (0..bytes_to_push) |_| {
            code[idx] = 0x00;
            idx += 1;
        }
    }

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

    var pc: usize = 0;
    for (0x6D..0x80) |opcode| {
        frame.pc = pc;
        frame.stack.clear();

        const gas_before = frame.gas_remaining;
        const result = try evm.table.execute(frame.pc, interpreter, state, @intCast(opcode));

        // All PUSH operations cost 3 gas (GasFastestStep)
        const gas_used = gas_before - frame.gas_remaining;
        try testing.expectEqual(@as(u64, 3), gas_used);

        // Check bytes consumed
        const expected_bytes = (opcode - 0x60 + 1) + 1; // data bytes + opcode byte
        try testing.expectEqual(expected_bytes, result.bytes_consumed);

        pc += expected_bytes;
    }
}

// ============================
// Edge cases and special scenarios
// ============================

test "PUSH operations: Truncated data at end of code" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;

    // Test PUSH32 with only 10 bytes of data available
    const code = [_]u8{
        0x7F, // PUSH32
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
        0x06,
        0x07,
        0x08,
        0x09,
        0x0A,
        // Missing 22 bytes - should be padded with zeros
    };

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

    const result = try evm.table.execute(frame.pc, interpreter, state, 0x7F);
    try testing.expectEqual(@as(usize, 33), result.bytes_consumed);

    // Should be 0x0102030405060708090A followed by 22 zeros
    const expected: u256 = 0x0102030405060708090A00000000000000000000000000000000000000000000;
    const top = try frame.stack.peek_n(0);
    try testing.expectEqual(expected, top);
}

test "PUSH20: Address pushing pattern" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;

    // PUSH20 is commonly used for Ethereum addresses
    const code = [_]u8{
        0x73, // PUSH20
        // A typical Ethereum address (20 bytes)
        0xDE,
        0xAD,
        0xBE,
        0xEF,
        0xCA,
        0xFE,
        0xBA,
        0xBE,
        0x12,
        0x34,
        0x56,
        0x78,
        0x9A,
        0xBC,
        0xDE,
        0xF0,
        0x11,
        0x22,
        0x33,
        0x44,
    };

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

    const result = try evm.table.execute(frame.pc, interpreter, state, 0x73);
    try testing.expectEqual(@as(usize, 21), result.bytes_consumed);

    const expected_address: u256 = 0xDEADBEEFCAFEBABE123456789ABCDEF011223344;
    const top = try frame.stack.peek_n(0);
    try testing.expectEqual(expected_address, top);
}

test "PUSH32: Hash value pattern" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;

    // PUSH32 is commonly used for hash values (32 bytes)
    const code = [_]u8{
        0x7F, // PUSH32
        // A typical hash pattern (32 bytes)
        0xAB,
        0xCD,
        0xEF,
        0x01,
        0x23,
        0x45,
        0x67,
        0x89,
        0x9A,
        0xBC,
        0xDE,
        0xF0,
        0x12,
        0x34,
        0x56,
        0x78,
        0x87,
        0x65,
        0x43,
        0x21,
        0x0F,
        0xED,
        0xCB,
        0xA9,
        0x89,
        0x67,
        0x45,
        0x23,
        0x01,
        0xEF,
        0xCD,
        0xAB,
    };

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

    const result = try evm.table.execute(frame.pc, interpreter, state, 0x7F);
    try testing.expectEqual(@as(usize, 33), result.bytes_consumed);

    // This is the actual 256-bit value that would be pushed
    const expected_hash: u256 = 0xABCDEF01234567899ABCDEF012345678876543210FEDCBA98967452301EFCDAB;
    const top = try frame.stack.peek_n(0);
    try testing.expectEqual(expected_hash, top);
}

test "Large PUSH operations with stack near limit" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;

    const code = [_]u8{
        0x7F, // PUSH32
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
    };

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

    // Fill stack to near capacity (1023 items)
    for (0..1023) |_| {
        try frame.stack.append(@as(u256, @intCast(i)));
    }

    // One more PUSH32 should succeed (reaching limit of 1024)
    const result = try evm.table.execute(frame.pc, interpreter, state, 0x7F);
    try testing.expectEqual(@as(usize, 33), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 1024), frame.stack.size);

    // Clear one item to test overflow
    _ = try frame.stack.pop();

    // Fill to exactly 1024
    try frame.stack.append(0);

    // Next PUSH should fail with stack overflow
    frame.pc = 0;
    const overflow_result = evm.table.execute(frame.pc, interpreter, state, 0x7F);
    try testing.expectError(ExecutionError.Error.StackOverflow, overflow_result);
}

test "PUSH operations sequence verification" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;

    // Create sequence: PUSH14, PUSH20, PUSH32
    const code = [_]u8{
        // PUSH14 - small value
        0x6D, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        // PUSH20 - address-like
        0x73, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
        // PUSH32 - full value
        0x7F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
    };

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

    // Execute PUSH14
    var result = try evm.table.execute(frame.pc, interpreter, state, 0x6D);
    try testing.expectEqual(@as(usize, 15), result.bytes_consumed);
    const top1 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 1), top1);
    frame.pc = 15;

    // Execute PUSH20
    result = try evm.table.execute(frame.pc, interpreter, state, 0x73);
    try testing.expectEqual(@as(usize, 21), result.bytes_consumed);
    const top2_0 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 2), top2_0);
    const top2_1 = try frame.stack.peek_n(1);
    try testing.expectEqual(@as(u256, 1), top2_1);
    frame.pc = 36;

    // Execute PUSH32
    result = try evm.table.execute(frame.pc, interpreter, state, 0x7F);
    try testing.expectEqual(@as(usize, 33), result.bytes_consumed);
    const top3_0 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 3), top3_0);
    const top3_1 = try frame.stack.peek_n(1);
    try testing.expectEqual(@as(u256, 2), top3_1);
    const top3_2 = try frame.stack.peek_n(2);
    try testing.expectEqual(@as(u256, 1), top3_2);

    try testing.expectEqual(@as(usize, 3), frame.stack.size);
}
