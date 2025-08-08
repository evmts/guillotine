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

test "Bitwise: AND basic operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    // Test 1: Simple AND
    try frame.stack.append(0xFF00);
    try frame.stack.append(0xF0F0);
    _ = try evm.table.execute(0, interpreter, state, 0x16);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0xF000), result1);

    // Test 2: AND with zero
    frame.stack.clear();
    try frame.stack.append(0);
    try frame.stack.append(0xFFFF);
    _ = try evm.table.execute(0, interpreter, state, 0x16);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result2);

    // Test 3: AND with all ones
    frame.stack.clear();
    const max_u256 = std.math.maxInt(u256);
    try frame.stack.append(max_u256);
    try frame.stack.append(0x12345678);
    _ = try evm.table.execute(0, interpreter, state, 0x16);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0x12345678), result3);

    // Test gas consumption
    frame.stack.clear();
    frame.gas_remaining = 1000;
    try frame.stack.append(0xFF00);
    try frame.stack.append(0xF0F0);
    _ = try evm.table.execute(0, interpreter, state, 0x16);
    const gas_used = 1000 - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 3), gas_used); // GasFastestStep = 3
}

test "Bitwise: OR basic operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    // Test 1: Simple OR
    try frame.stack.append(0xFF00);
    try frame.stack.append(0x00FF);
    _ = try evm.table.execute(0, interpreter, state, 0x17);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0xFFFF), result1);

    // Test 2: OR with zero
    frame.stack.clear();
    try frame.stack.append(0);
    try frame.stack.append(0xABCD);
    _ = try evm.table.execute(0, interpreter, state, 0x17);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0xABCD), result2);

    // Test 3: OR with all ones
    frame.stack.clear();
    const max_u256 = std.math.maxInt(u256);
    try frame.stack.append(max_u256);
    try frame.stack.append(0x12345678);
    _ = try evm.table.execute(0, interpreter, state, 0x17);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, max_u256), result3);
}

test "Bitwise: XOR basic operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    // Test 1: Simple XOR
    try frame.stack.append(0xFF00);
    try frame.stack.append(0xF0F0);
    _ = try evm.table.execute(0, interpreter, state, 0x18);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0x0FF0), result1);

    // Test 2: XOR with itself (should be zero)
    frame.stack.clear();
    try frame.stack.append(0xABCD);
    try frame.stack.append(0xABCD);
    _ = try evm.table.execute(0, interpreter, state, 0x18);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result2);

    // Test 3: XOR with zero (identity)
    frame.stack.clear();
    try frame.stack.append(0);
    try frame.stack.append(0x1234);
    _ = try evm.table.execute(0, interpreter, state, 0x18);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0x1234), result3);
}

test "Bitwise: NOT basic operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    // Test 1: NOT of zero
    try frame.stack.append(0);
    _ = try evm.table.execute(0, interpreter, state, 0x19);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, std.math.maxInt(u256)), result1);

    // Test 2: NOT of all ones
    frame.stack.clear();
    try frame.stack.append(std.math.maxInt(u256));
    _ = try evm.table.execute(0, interpreter, state, 0x19);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result2);

    // Test 3: NOT of pattern
    frame.stack.clear();
    try frame.stack.append(0xFFFF0000FFFF0000);
    _ = try evm.table.execute(0, interpreter, state, 0x19);
    const expected = std.math.maxInt(u256) ^ 0xFFFF0000FFFF0000;
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, expected), result3);
}

test "Bitwise: BYTE extraction operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    // Test 1: Extract first byte (most significant)
    const test_value = 0xABCDEF1234567890;
    try frame.stack.append(test_value);
    try frame.stack.append(0);
    _ = try evm.table.execute(0, interpreter, state, 0x1A);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result1); // Byte 0 is 0x00 in a 256-bit number

    // Test 2: Extract last byte (least significant)
    frame.stack.clear();
    try frame.stack.append(test_value);
    try frame.stack.append(31);
    _ = try evm.table.execute(0, interpreter, state, 0x1A);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0x90), result2);

    // Test 3: Out of bounds index
    frame.stack.clear();
    try frame.stack.append(test_value);
    try frame.stack.append(32);
    _ = try evm.table.execute(0, interpreter, state, 0x1A);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result3); // Should return 0

    // Test 4: Extract from byte 24
    frame.stack.clear();
    try frame.stack.append(test_value);
    try frame.stack.append(24);
    _ = try evm.table.execute(0, interpreter, state, 0x1A);
    const result4 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0xAB), result4); // Byte 24 is where 0xAB is located
}

test "Bitwise: SHL (shift left) operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    // Test 1: Simple left shift
    try frame.stack.append(0xFF);
    try frame.stack.append(8);
    _ = try evm.table.execute(0, interpreter, state, 0x1B);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0xFF00), result1);

    // Test 2: Shift by zero
    frame.stack.clear();
    try frame.stack.append(0x1234);
    try frame.stack.append(0);
    _ = try evm.table.execute(0, interpreter, state, 0x1B);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0x1234), result2);

    // Test 3: Shift by >= 256 (should return 0)
    frame.stack.clear();
    try frame.stack.append(0xFFFF);
    try frame.stack.append(256);
    _ = try evm.table.execute(0, interpreter, state, 0x1B);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result3);

    // Test 4: Large shift
    frame.stack.clear();
    try frame.stack.append(1);
    try frame.stack.append(255);
    _ = try evm.table.execute(0, interpreter, state, 0x1B);
    const expected = @as(u256, 1) << 255;
    const result4 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, expected), result4);
}

test "Bitwise: SHR (logical shift right) operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    // Test 1: Simple right shift
    try frame.stack.append(0xFF00);
    try frame.stack.append(8);
    _ = try evm.table.execute(0, interpreter, state, 0x1C);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0xFF), result1);

    // Test 2: Shift by zero
    frame.stack.clear();
    try frame.stack.append(0x1234);
    try frame.stack.append(0);
    _ = try evm.table.execute(0, interpreter, state, 0x1C);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0x1234), result2);

    // Test 3: Shift by >= 256 (should return 0)
    frame.stack.clear();
    try frame.stack.append(0xFFFF);
    try frame.stack.append(256);
    _ = try evm.table.execute(0, interpreter, state, 0x1C);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result3);
}

test "Bitwise: SAR (arithmetic shift right) operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    // Test 1: SAR with positive number (same as logical shift)
    try frame.stack.append(0xFF00);
    try frame.stack.append(8);
    _ = try evm.table.execute(0, interpreter, state, 0x1D);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0xFF), result1);

    // Test 2: SAR with negative number (sign bit = 1)
    frame.stack.clear();
    const negative = @as(u256, 1) << 255 | 0xFF00; // Set sign bit
    try frame.stack.append(negative);
    try frame.stack.append(8);
    _ = try evm.table.execute(0, interpreter, state, 0x1D);
    // Should fill with 1s from left
    const expected = ((@as(u256, 0xFF) << 248) | (negative >> 8));
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, expected), result2);

    // Test 3: SAR by >= 256 with negative number (should return all 1s)
    frame.stack.clear();
    try frame.stack.append(negative);
    try frame.stack.append(256);
    _ = try evm.table.execute(0, interpreter, state, 0x1D);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, std.math.maxInt(u256)), result3);

    // Test 4: SAR by >= 256 with positive number (should return 0)
    frame.stack.clear();
    try frame.stack.append(0x7FFF);
    try frame.stack.append(256);
    _ = try evm.table.execute(0, interpreter, state, 0x1D);
    const result4 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result4);
}

test "Bitwise: Stack underflow errors" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    // Test AND with empty stack
    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(0, interpreter, state, 0x16));

    // Test NOT with empty stack
    frame.stack.clear();
    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(0, interpreter, state, 0x19));

    // Test BYTE with only one item
    frame.stack.clear();
    try frame.stack.append(42);
    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(0, interpreter, state, 0x1A));
}

test "Bitwise: Gas consumption" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    // All bitwise operations cost 3 gas (GasFastestStep)
    const operations = [_]struct {
        name: []const u8,
        opcode: u8,
        stack_items: u8,
    }{
        .{ .name = "AND", .opcode = 0x16, .stack_items = 2 },
        .{ .name = "OR", .opcode = 0x17, .stack_items = 2 },
        .{ .name = "XOR", .opcode = 0x18, .stack_items = 2 },
        .{ .name = "NOT", .opcode = 0x19, .stack_items = 1 },
        .{ .name = "BYTE", .opcode = 0x1A, .stack_items = 2 },
        .{ .name = "SHL", .opcode = 0x1B, .stack_items = 2 },
        .{ .name = "SHR", .opcode = 0x1C, .stack_items = 2 },
        .{ .name = "SAR", .opcode = 0x1D, .stack_items = 2 },
    };

    inline for (operations) |op_info| {
        frame.stack.clear();
        frame.gas_remaining = 1000;

        // Push required stack items
        var i: u8 = 0;
        while (i < op_info.stack_items) : (i += 1) {
            try frame.stack.append(0x42);
        }

        _ = try evm.table.execute(0, interpreter, state, op_info.opcode);
        const gas_used = 1000 - frame.gas_remaining;
        try testing.expectEqual(@as(u64, 3), gas_used); // GasFastestStep = 3
    }
}
