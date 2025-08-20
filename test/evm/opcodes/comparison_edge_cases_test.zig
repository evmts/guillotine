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

test "Comparison: EQ edge case - operand order shouldn't matter" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, null);
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
    defer frame.deinit(allocator);

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test that EQ(a,b) == EQ(b,a)
    const val_a: u256 = 0x123456789;
    const val_b: u256 = 0xABCDEF;

    // First order: a, b
    try frame.stack.append(val_b);
    try frame.stack.append(val_a);
    _ = try evm.table.execute(0, interpreter, state, 0x14);
    const result1 = try frame.stack.pop();

    // Second order: b, a
    try frame.stack.append(val_a);
    try frame.stack.append(val_b);
    _ = try evm.table.execute(0, interpreter, state, 0x14);
    const result2 = try frame.stack.pop();

    // Both should give the same result
    try testing.expectEqual(result1, result2);
}

test "Comparison: Signed comparisons with boundary values" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, null);
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
    defer frame.deinit(allocator);

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test MIN_I256 < -1
    const min_i256 = @as(u256, 1) << 255; // 0x80000...0 (most negative)
    const neg_one = std.math.maxInt(u256); // 0xFFFF...F (-1 in two's complement)

    try frame.stack.append(neg_one);
    try frame.stack.append(min_i256);
    _ = try evm.table.execute(0, interpreter, state, 0x12); // SLT
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result); // MIN_I256 < -1 is true

    // Test -1 > MIN_I256
    frame.stack.clear();
    try frame.stack.append(min_i256);
    try frame.stack.append(neg_one);
    _ = try evm.table.execute(0, interpreter, state, 0x13); // SGT
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result2); // -1 > MIN_I256 is true
}

test "Comparison: Gas edge case - ensure gas is consumed before operation" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, null);
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        2,
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
        .withGas(2) // Only 2 gas
        .build();
    defer frame.deinit(allocator);

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push values for LT operation
    try frame.stack.append(10);
    try frame.stack.append(5);

    // Should fail with OutOfGas since we need 3 gas for comparison
    try testing.expectError(ExecutionError.Error.OutOfGas, evm.table.execute(0, interpreter, state, 0x10));
}

test "Bitwise: XOR properties verification" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, null);
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
    defer frame.deinit(allocator);

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test: a XOR a = 0 (already tested, but let's verify with edge values)
    const max_u256 = std.math.maxInt(u256);
    try frame.stack.append(max_u256);
    try frame.stack.append(max_u256);
    _ = try evm.table.execute(0, interpreter, state, 0x18);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result1);

    // Test: a XOR 0 = a (identity)
    frame.stack.clear();
    const test_val: u256 = 0x123456789ABCDEF;
    try frame.stack.append(0);
    try frame.stack.append(test_val);
    _ = try evm.table.execute(0, interpreter, state, 0x18);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(test_val, result2);

    // Test: a XOR ~a = MAX_U256 (all ones)
    frame.stack.clear();
    try frame.stack.append(~test_val);
    try frame.stack.append(test_val);
    _ = try evm.table.execute(0, interpreter, state, 0x18);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(max_u256, result3);
}

test "Bitwise: AND/OR De Morgan's laws" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, null);
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
    defer frame.deinit(allocator);

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test: ~(a AND b) = (~a OR ~b)
    const a: u256 = 0xF0F0F0F0;
    const b: u256 = 0xFF00FF00;

    // Calculate ~(a AND b)
    try frame.stack.append(b);
    try frame.stack.append(a);
    _ = try evm.table.execute(0, interpreter, state, 0x16); // AND
    _ = try evm.table.execute(0, interpreter, state, 0x19); // NOT
    const left_side = try frame.stack.pop();

    // Calculate (~a OR ~b)
    try frame.stack.append(a);
    _ = try evm.table.execute(0, interpreter, state, 0x19); // NOT
    const not_a = try frame.stack.pop();

    try frame.stack.append(b);
    _ = try evm.table.execute(0, interpreter, state, 0x19); // NOT
    const not_b = try frame.stack.pop();

    try frame.stack.append(not_b);
    try frame.stack.append(not_a);
    _ = try evm.table.execute(0, interpreter, state, 0x17); // OR
    const right_side = try frame.stack.pop();

    // They should be equal
    try testing.expectEqual(left_side, right_side);
}

test "Comparison: Chained comparisons behavior" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, null);
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

    // Test: (5 < 10) AND (10 < 15) = 1 AND 1 = 1
    try frame.stack.append(10);
    try frame.stack.append(5);
    _ = try evm.table.execute(0, interpreter, state, 0x10); // LT

    try frame.stack.append(15);
    try frame.stack.append(10);
    _ = try evm.table.execute(0, interpreter, state, 0x10); // LT

    _ = try evm.table.execute(0, interpreter, state, 0x16); // AND
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result); // Both comparisons true
}

test "ISZERO: Various representations of zero" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, null);
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

    // Test multiple ways to represent zero
    const zero_values = [_]u256{
        0,
        0x0,
        @as(u256, 0),
        0b0,
        0o0,
    };

    for (zero_values) |zero_val| {
        frame.stack.clear();
        try frame.stack.append(zero_val);
        _ = try evm.table.execute(0, interpreter, state, 0x15);
        const result = try frame.stack.pop();
        try testing.expectEqual(@as(u256, 1), result);
    }
}

test "Bitwise: Shift operations with large values" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, null);
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

    // Test SHL with max value
    const max_u256 = std.math.maxInt(u256);
    try frame.stack.append(max_u256);
    try frame.stack.append(1);
    _ = try evm.table.execute(0, interpreter, state, 0x1B); // SHL
    const expected_shl = max_u256 << 1; // Should lose the MSB
    const result1 = try frame.stack.pop();
    try testing.expectEqual(expected_shl, result1);

    // Test SHR with 1
    frame.stack.clear();
    try frame.stack.append(1);
    try frame.stack.append(1);
    _ = try evm.table.execute(0, interpreter, state, 0x1C); // SHR
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result2); // 1 >> 1 = 0

    // Test SAR with all ones (negative)
    frame.stack.clear();
    try frame.stack.append(max_u256);
    try frame.stack.append(1);
    _ = try evm.table.execute(0, interpreter, state, 0x1D); // SAR
    const result3 = try frame.stack.pop();
    try testing.expectEqual(max_u256, result3); // Sign extension keeps it all ones
}

test "Comparison: Stack behavior with multiple operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, null);
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

    // Start with multiple values on stack
    try frame.stack.append(100);
    try frame.stack.append(200);
    try frame.stack.append(5);
    try frame.stack.append(10); // Bottom to top: 100, 200, 5, 10

    // LT: pops 10, 5, pushes (5 < 10) = 1
    _ = try evm.table.execute(0, interpreter, state, 0x10);
    try testing.expectEqual(@as(usize, 3), frame.stack.size); // 100, 200, 1

    // GT: pops 1, 200, pushes (200 > 1) = 1
    _ = try evm.table.execute(0, interpreter, state, 0x11);
    try testing.expectEqual(@as(usize, 2), frame.stack.size); // 100, 1

    // EQ: pops 1, 100, pushes (100 == 1) = 0
    _ = try evm.table.execute(0, interpreter, state, 0x14);
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
    try testing.expectEqual(@as(usize, 0), frame.stack.size);
}
