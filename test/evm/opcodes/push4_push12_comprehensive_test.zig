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
// 0x63-0x6C: PUSH4 through PUSH12
// ============================

test "PUSH4 (0x63): Push 4 bytes onto stack" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;

    const code = [_]u8{
        0x63, 0x12, 0x34, 0x56, 0x78, // PUSH4 0x12345678
        0x63, 0xFF, 0xFF, 0xFF, 0xFF, // PUSH4 0xFFFFFFFF
        0x63, 0x00, 0x00, 0x00, 0x00, // PUSH4 0x00000000
        0x63, 0xDE, 0xAD, 0xBE, 0xEF, // PUSH4 0xDEADBEEF
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

    const expected_values = [_]u256{ 0x12345678, 0xFFFFFFFF, 0x00000000, 0xDEADBEEF };

    for (expected_values) |expected| {
        const pc = frame.pc;
        const result = try evm.table.execute(pc, interpreter, state, 0x63);

        // Check that 5 bytes were consumed (opcode + 4 data bytes)
        try testing.expectEqual(@as(usize, 5), result.bytes_consumed);
        frame.pc = pc + 5;

        const top = try frame.stack.peek_n(0);
        try testing.expectEqual(expected, top);
        _ = try frame.stack.pop();
    }
}

test "PUSH5 (0x64): Push 5 bytes onto stack" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;

    const code = [_]u8{
        0x64, 0x01, 0x23, 0x45, 0x67, 0x89, // PUSH5 0x0123456789
        0x64, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // PUSH5 0xFFFFFFFFFF
        0x64, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH5 0x0000000000
        0x64, 0xAB, 0xCD, 0xEF, 0x01, 0x23, // PUSH5 0xABCDEF0123
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

    const expected_values = [_]u256{ 0x0123456789, 0xFFFFFFFFFF, 0x0000000000, 0xABCDEF0123 };

    for (expected_values) |expected| {
        const pc = frame.pc;
        const result = try evm.table.execute(pc, interpreter, state, 0x64);

        // Check that 6 bytes were consumed (opcode + 5 data bytes)
        try testing.expectEqual(@as(usize, 6), result.bytes_consumed);
        frame.pc = pc + 6;

        const top = try frame.stack.peek_n(0);
        try testing.expectEqual(expected, top);
        _ = try frame.stack.pop();
    }
}

test "PUSH6 (0x65): Push 6 bytes onto stack" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;

    const code = [_]u8{
        0x65, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, // PUSH6 0x0123456789AB
        0x65, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // PUSH6 0xFFFFFFFFFFFF
        0x65, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH6 0x000000000000
        0x65, 0xCA, 0xFE, 0xBA, 0xBE, 0xDE, 0xAD, // PUSH6 0xCAFEBABEDEAD
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

    const expected_values = [_]u256{ 0x0123456789AB, 0xFFFFFFFFFFFF, 0x000000000000, 0xCAFEBABEDEAD };

    for (expected_values) |expected| {
        const pc = frame.pc;
        const result = try evm.table.execute(pc, interpreter, state, 0x65);

        // Check that 7 bytes were consumed (opcode + 6 data bytes)
        try testing.expectEqual(@as(usize, 7), result.bytes_consumed);
        frame.pc = pc + 7;

        const top = try frame.stack.peek_n(0);
        try testing.expectEqual(expected, top);
        _ = try frame.stack.pop();
    }
}

test "PUSH7 (0x66): Push 7 bytes onto stack" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;

    const code = [_]u8{
        0x66, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, // PUSH7 0x0123456789ABCD
        0x66, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // PUSH7 0xFFFFFFFFFFFFFF
        0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH7 0x00000000000000
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

    const expected_values = [_]u256{ 0x0123456789ABCD, 0xFFFFFFFFFFFFFF, 0x00000000000000 };

    for (expected_values) |expected| {
        const pc = frame.pc;
        const result = try evm.table.execute(pc, interpreter, state, 0x66);

        // Check that 8 bytes were consumed (opcode + 7 data bytes)
        try testing.expectEqual(@as(usize, 8), result.bytes_consumed);
        frame.pc = pc + 8;

        const top = try frame.stack.peek_n(0);
        try testing.expectEqual(expected, top);
        _ = try frame.stack.pop();
    }
}

test "PUSH8 (0x67): Push 8 bytes onto stack" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;

    const code = [_]u8{
        0x67, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, // PUSH8 0x0123456789ABCDEF
        0x67, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // PUSH8 0xFFFFFFFFFFFFFFFF
        0x67, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH8 0x0000000000000000
        0x67, 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE, // PUSH8 0xDEADBEEFCAFEBABE
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

    const expected_values = [_]u256{ 0x0123456789ABCDEF, 0xFFFFFFFFFFFFFFFF, 0x0000000000000000, 0xDEADBEEFCAFEBABE };

    for (expected_values) |expected| {
        const pc = frame.pc;
        const result = try evm.table.execute(pc, interpreter, state, 0x67);

        // Check that 9 bytes were consumed (opcode + 8 data bytes)
        try testing.expectEqual(@as(usize, 9), result.bytes_consumed);
        frame.pc = pc + 9;

        const top = try frame.stack.peek_n(0);
        try testing.expectEqual(expected, top);
        _ = try frame.stack.pop();
    }
}

test "PUSH9 (0x68): Push 9 bytes onto stack" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;

    const code = [_]u8{
        0x68, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, // PUSH9
        0x68, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // PUSH9 max
        0x68, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH9 zero
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

    const expected_values = [_]u256{
        0x010203040506070809,
        0xFFFFFFFFFFFFFFFFFF,
        0x000000000000000000,
    };

    for (expected_values) |expected| {
        const pc = frame.pc;
        const result = try evm.table.execute(pc, interpreter, state, 0x68);

        // Check that 10 bytes were consumed (opcode + 9 data bytes)
        try testing.expectEqual(@as(usize, 10), result.bytes_consumed);
        frame.pc = pc + 10;

        const top = try frame.stack.peek_n(0);
        try testing.expectEqual(expected, top);
        _ = try frame.stack.pop();
    }
}

test "PUSH10 (0x69): Push 10 bytes onto stack" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;

    const code = [_]u8{
        0x69, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, // PUSH10
        0x69, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // PUSH10 max
        0x69, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH10 zero
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

    const expected_values = [_]u256{
        0x0102030405060708090A,
        0xFFFFFFFFFFFFFFFFFFFF,
        0x00000000000000000000,
    };

    for (expected_values) |expected| {
        const pc = frame.pc;
        const result = try evm.table.execute(pc, interpreter, state, 0x69);

        // Check that 11 bytes were consumed (opcode + 10 data bytes)
        try testing.expectEqual(@as(usize, 11), result.bytes_consumed);
        frame.pc = pc + 11;

        const top = try frame.stack.peek_n(0);
        try testing.expectEqual(expected, top);
        _ = try frame.stack.pop();
    }
}

test "PUSH11 (0x6A): Push 11 bytes onto stack" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;

    const code = [_]u8{
        0x6A, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, // PUSH11
        0x6A, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // PUSH11 max
        0x6A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH11 zero
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

    const expected_values = [_]u256{
        0x0102030405060708090A0B,
        0xFFFFFFFFFFFFFFFFFFFFFF,
        0x00000000000000000000000,
    };

    for (expected_values) |expected| {
        const pc = frame.pc;
        const result = try evm.table.execute(pc, interpreter, state, 0x6A);

        // Check that 12 bytes were consumed (opcode + 11 data bytes)
        try testing.expectEqual(@as(usize, 12), result.bytes_consumed);
        frame.pc = pc + 12;

        const top = try frame.stack.peek_n(0);
        try testing.expectEqual(expected, top);
        _ = try frame.stack.pop();
    }
}

test "PUSH12 (0x6B): Push 12 bytes onto stack" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;

    const code = [_]u8{
        0x6B, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, // PUSH12
        0x6B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // PUSH12 max
        0x6B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH12 zero
        0x6B, 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE, 0x12, 0x34, 0x56, 0x78, // PUSH12 pattern
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

    const expected_values = [_]u256{
        0x0102030405060708090A0B0C,
        0xFFFFFFFFFFFFFFFFFFFFFFFF,
        0x000000000000000000000000,
        0xDEADBEEFCAFEBABE12345678,
    };

    for (expected_values) |expected| {
        const pc = frame.pc;
        const result = try evm.table.execute(pc, interpreter, state, 0x6B);

        // Check that 13 bytes were consumed (opcode + 12 data bytes)
        try testing.expectEqual(@as(usize, 13), result.bytes_consumed);
        frame.pc = pc + 13;

        const top = try frame.stack.peek_n(0);
        try testing.expectEqual(expected, top);
        _ = try frame.stack.pop();
    }
}

test "PUSH13 (0x6C): Push 13 bytes onto stack" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;

    // PUSH13 exists, so let's test it properly
    const code = [_]u8{
        0x6C, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, // PUSH13
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

    const result = try evm.table.execute(frame.pc, interpreter, state, 0x6C);

    // Check that 14 bytes were consumed (opcode + 13 data bytes)
    try testing.expectEqual(@as(usize, 14), result.bytes_consumed);

    const expected: u256 = 0x0102030405060708090A0B0C0D;
    const top = try frame.stack.peek_n(0);
    try testing.expectEqual(expected, top);
}

// ============================
// Gas consumption tests
// ============================

test "PUSH4-PUSH12: Gas consumption" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;

    // Create bytecode with various PUSH operations
    const code = [_]u8{
        0x63, 0x00, 0x00, 0x00, 0x00, // PUSH4
        0x64, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH5
        0x65, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH6
        0x66, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH7
        0x67, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH8
        0x68, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH9
        0x69, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH10
        0x6A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH11
        0x6B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH12
        0x6C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH13
    };

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

    const opcodes = [_]struct {
        opcode: u8,
        name: []const u8,
        bytes_consumed: usize,
    }{
        .{ .opcode = 0x63, .name = "PUSH4", .bytes_consumed = 5 },
        .{ .opcode = 0x64, .name = "PUSH5", .bytes_consumed = 6 },
        .{ .opcode = 0x65, .name = "PUSH6", .bytes_consumed = 7 },
        .{ .opcode = 0x66, .name = "PUSH7", .bytes_consumed = 8 },
        .{ .opcode = 0x67, .name = "PUSH8", .bytes_consumed = 9 },
        .{ .opcode = 0x68, .name = "PUSH9", .bytes_consumed = 10 },
        .{ .opcode = 0x69, .name = "PUSH10", .bytes_consumed = 11 },
        .{ .opcode = 0x6A, .name = "PUSH11", .bytes_consumed = 12 },
        .{ .opcode = 0x6B, .name = "PUSH12", .bytes_consumed = 13 },
        .{ .opcode = 0x6C, .name = "PUSH13", .bytes_consumed = 14 },
    };

    var pc: usize = 0;
    for (opcodes) |op| {
        frame.pc = pc;
        frame.stack.clear();

        const gas_before = frame.gas_remaining;
        const result = try evm.table.execute(frame.pc, interpreter, state, op.opcode);

        // All PUSH operations cost 3 gas (GasFastestStep)
        const gas_used = gas_before - frame.gas_remaining;
        try testing.expectEqual(@as(u64, 3), gas_used);

        // Check bytes consumed
        try testing.expectEqual(op.bytes_consumed, result.bytes_consumed);

        pc += op.bytes_consumed;
    }
}

// ============================
// Edge cases and special scenarios
// ============================

test "PUSH operations: Boundary conditions with truncated data" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;

    // Test PUSH operations with incomplete data at end of code
    const code = [_]u8{
        // Complete PUSH4
        0x63, 0x12, 0x34, 0x56, 0x78,
        // Incomplete PUSH8 (only 3 bytes of data)
        0x67, 0xAB, 0xCD, 0xEF,
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

    // First PUSH4 should work normally
    const result1 = try evm.table.execute(frame.pc, interpreter, state, 0x63);
    try testing.expectEqual(@as(usize, 5), result1.bytes_consumed);
    const top1 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0x12345678), top1);
    _ = try frame.stack.pop();
    frame.pc = 5;

    // Second PUSH8 should pad with zeros for missing bytes
    const result2 = try evm.table.execute(frame.pc, interpreter, state, 0x67);
    try testing.expectEqual(@as(usize, 9), result2.bytes_consumed);
    // Should be 0xABCDEF0000000000 (3 bytes followed by 5 zeros)
    const top2 = try frame.stack.peek_n(0);
    try testing.expectEqual(@as(u256, 0xABCDEF0000000000), top2);
}

test "PUSH operations: Sequential pushes filling stack" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;

    // Create code with many PUSH4 operations
    var code: [1024 * 5]u8 = undefined;
    for (0..1024) |_| {
        code[i * 5] = 0x63; // PUSH4
        code[i * 5 + 1] = @intCast((i >> 24) & 0xFF);
        code[i * 5 + 2] = @intCast((i >> 16) & 0xFF);
        code[i * 5 + 3] = @intCast((i >> 8) & 0xFF);
        code[i * 5 + 4] = @intCast(i & 0xFF);
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

    // Push 1023 values (leaving room for one more)
    for (0..1023) |_| {
        frame.pc = i * 5;
        const result = try evm.table.execute(frame.pc, interpreter, state, 0x63);
        try testing.expectEqual(@as(usize, 5), result.bytes_consumed);
    }

    try testing.expectEqual(@as(usize, 1023), frame.stack.size);

    // One more should succeed (reaching stack limit of 1024)
    frame.pc = 1023 * 5;
    _ = try evm.table.execute(frame.pc, interpreter, state, 0x63);
    try testing.expectEqual(@as(usize, 1024), frame.stack.size);

    // Next one should fail with stack overflow
    frame.pc = 1024 * 5;
    const overflow_result = evm.table.execute(frame.pc, interpreter, state, 0x63);
    try testing.expectError(ExecutionError.Error.StackOverflow, overflow_result);
}

test "PUSH operations: Verify big-endian byte order" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;

    // Test that bytes are interpreted in big-endian order
    const code = [_]u8{
        0x67, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, // PUSH8
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

    _ = try evm.table.execute(frame.pc, interpreter, state, 0x67);

    // Value should be 0x0102030405060708 (big-endian interpretation)
    const expected: u256 = (@as(u256, 0x01) << 56) |
        (@as(u256, 0x02) << 48) |
        (@as(u256, 0x03) << 40) |
        (@as(u256, 0x04) << 32) |
        (@as(u256, 0x05) << 24) |
        (@as(u256, 0x06) << 16) |
        (@as(u256, 0x07) << 8) |
        (@as(u256, 0x08));

    const top = try frame.stack.peek_n(0);
    try testing.expectEqual(expected, top);
}
