const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const Contract = Evm.Contract;
const Frame = Evm.Frame;
const MemoryDatabase = Evm.MemoryDatabase;
const ExecutionError = Evm.ExecutionError;

test "Comparison: LT (less than) operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface);
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

    // Test 1: LT with stack [5, 10] (10 on top)
    // LT computes: top < second-from-top = 10 < 5 = false
    try frame.stack.append(5);
    try frame.stack.append(10);
    _ = try evm.table.execute(0, interpreter, state, 0x10);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result1);

    // Test 2: LT with stack [10, 5] (5 on top)
    // LT computes: top < second-from-top = 5 < 10 = true
    frame.stack.clear();
    try frame.stack.append(10);
    try frame.stack.append(5);
    _ = try evm.table.execute(0, interpreter, state, 0x10);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result2);

    // Test 3: a == b (false)
    frame.stack.clear();
    try frame.stack.append(42);
    try frame.stack.append(42);
    _ = try evm.table.execute(0, interpreter, state, 0x10);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result3); // 42 < 42 = false

    // Test 4: Compare with zero
    frame.stack.clear();
    try frame.stack.append(0);
    try frame.stack.append(1);
    _ = try evm.table.execute(0, interpreter, state, 0x10);
    const result4 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result4); // 0 < 1 = true

    // Test 5: Compare with max value
    frame.stack.clear();
    const max_u256 = std.math.maxInt(u256);
    try frame.stack.append(max_u256 - 1);
    try frame.stack.append(max_u256);
    _ = try evm.table.execute(0, interpreter, state, 0x10);
    const result5 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result5); // (max-1) < max = true

    // Test gas consumption for a single operation
    frame.stack.clear();
    frame.gas_remaining = 1000;
    try frame.stack.append(1);
    try frame.stack.append(2);
    _ = try evm.table.execute(0, interpreter, state, 0x10);
    const gas_used = 1000 - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 3), gas_used); // GasFastestStep = 3
}

test "Comparison: GT (greater than) operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface);
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

    // Test 1: a > b (true)
    try frame.stack.append(10);
    try frame.stack.append(5);
    _ = try evm.table.execute(0, interpreter, state, 0x11);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result1); // 10 > 5 = true

    // Test 2: a < b (false)
    frame.stack.clear();
    try frame.stack.append(5);
    try frame.stack.append(10);
    _ = try evm.table.execute(0, interpreter, state, 0x11);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result2); // 5 > 10 = false

    // Test 3: a == b (false)
    frame.stack.clear();
    try frame.stack.append(42);
    try frame.stack.append(42);
    _ = try evm.table.execute(0, interpreter, state, 0x11);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result3); // 42 > 42 = false

    // Test 4: GT with stack [1, 0] (0 on top)
    // GT computes: top > second-from-top = 0 > 1 = false
    frame.stack.clear();
    try frame.stack.append(1);
    try frame.stack.append(0);
    _ = try evm.table.execute(0, interpreter, state, 0x11);
    const result4 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result4);

    // Test gas consumption for a single operation
    frame.stack.clear();
    frame.gas_remaining = 1000;
    try frame.stack.append(1);
    try frame.stack.append(2);
    _ = try evm.table.execute(0, interpreter, state, 0x11);
    const gas_used = 1000 - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 3), gas_used); // GasFastestStep = 3
}

test "Comparison: SLT (signed less than) operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface);
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

    // Test 1: SLT with stack [5, 10] (10 on top)
    // SLT computes: top < second-from-top (signed) = 10 < 5 = false
    try frame.stack.append(5);
    try frame.stack.append(10);
    _ = try evm.table.execute(0, interpreter, state, 0x12);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result1);

    // Test 2: SLT with stack [-1, 10] (10 on top)
    // SLT computes: top < second-from-top (signed) = 10 < -1 = false
    frame.stack.clear();
    const negative_one = std.math.maxInt(u256); // -1 in two's complement
    try frame.stack.append(negative_one);
    try frame.stack.append(10);
    _ = try evm.table.execute(0, interpreter, state, 0x12);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result2);

    // Test 3: SLT with stack [10, -1] (-1 on top)
    // SLT computes: top < second-from-top (signed) = -1 < 10 = true
    frame.stack.clear();
    try frame.stack.append(10);
    try frame.stack.append(negative_one);
    _ = try evm.table.execute(0, interpreter, state, 0x12);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result3);

    // Test 4: Both negative
    frame.stack.clear();
    const negative_two = std.math.maxInt(u256) - 1; // -2 in two's complement
    try frame.stack.append(negative_two);
    try frame.stack.append(negative_one);
    _ = try evm.table.execute(0, interpreter, state, 0x12);
    const result4 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result4); // -2 < -1 = true

    // Test 5: Most negative vs most positive
    frame.stack.clear();
    const most_negative = @as(u256, 1) << 255; // 0x80000...0
    const most_positive = (@as(u256, 1) << 255) - 1; // 0x7FFFF...F
    try frame.stack.append(most_negative);
    try frame.stack.append(most_positive);
    _ = try evm.table.execute(0, interpreter, state, 0x12);
    const result5 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result5); // most_negative < most_positive = true

    // Test gas consumption for a single operation
    frame.stack.clear();
    frame.gas_remaining = 1000;
    try frame.stack.append(1);
    try frame.stack.append(2);
    _ = try evm.table.execute(0, interpreter, state, 0x12);
    const gas_used = 1000 - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 3), gas_used); // GasFastestStep = 3
}

test "Comparison: SGT (signed greater than) operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface);
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

    // Test 1: SGT with stack [10, 5] (5 on top)
    // SGT computes: top > second-from-top (signed) = 5 > 10 = false
    try frame.stack.append(10);
    try frame.stack.append(5);
    _ = try evm.table.execute(0, interpreter, state, 0x13);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result1);

    // Test 2: SGT with stack [10, -1] (-1 on top)
    // SGT computes: top > second-from-top (signed) = -1 > 10 = false
    frame.stack.clear();
    const negative_one = std.math.maxInt(u256); // -1 in two's complement
    try frame.stack.append(10);
    try frame.stack.append(negative_one);
    _ = try evm.table.execute(0, interpreter, state, 0x13);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result2);

    // Test 3: SGT with stack [-1, 10] (10 on top)
    // SGT computes: top > second-from-top (signed) = 10 > -1 = true
    frame.stack.clear();
    try frame.stack.append(negative_one);
    try frame.stack.append(10);
    _ = try evm.table.execute(0, interpreter, state, 0x13);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result3);

    // Test 4: Both negative
    frame.stack.clear();
    const negative_two = std.math.maxInt(u256) - 1; // -2 in two's complement
    try frame.stack.append(negative_one);
    try frame.stack.append(negative_two);
    _ = try evm.table.execute(0, interpreter, state, 0x13);
    const result4 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result4); // -1 > -2 = true

    // Test gas consumption for a single operation
    frame.stack.clear();
    frame.gas_remaining = 1000;
    try frame.stack.append(1);
    try frame.stack.append(2);
    _ = try evm.table.execute(0, interpreter, state, 0x13);
    const gas_used = 1000 - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 3), gas_used); // GasFastestStep = 3
}

test "Comparison: EQ (equal) operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface);
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

    // Test 1: Equal values
    try frame.stack.append(42);
    try frame.stack.append(42);
    _ = try evm.table.execute(0, interpreter, state, 0x14);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result1); // 42 == 42 = true

    // Test 2: Different values
    frame.stack.clear();
    try frame.stack.append(42);
    try frame.stack.append(43);
    _ = try evm.table.execute(0, interpreter, state, 0x14);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result2); // 42 == 43 = false

    // Test 3: Zero equality
    frame.stack.clear();
    try frame.stack.append(0);
    try frame.stack.append(0);
    _ = try evm.table.execute(0, interpreter, state, 0x14);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result3); // 0 == 0 = true

    // Test 4: Max value equality
    frame.stack.clear();
    const max_u256 = std.math.maxInt(u256);
    try frame.stack.append(max_u256);
    try frame.stack.append(max_u256);
    _ = try evm.table.execute(0, interpreter, state, 0x14);
    const result4 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result4); // max == max = true

    // Test gas consumption for a single operation
    frame.stack.clear();
    frame.gas_remaining = 1000;
    try frame.stack.append(1);
    try frame.stack.append(2);
    _ = try evm.table.execute(0, interpreter, state, 0x14);
    const gas_used = 1000 - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 3), gas_used); // GasFastestStep = 3
}

test "Comparison: ISZERO operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface);
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

    // Test 1: Zero value
    try frame.stack.append(0);
    _ = try evm.table.execute(0, interpreter, state, 0x15);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result1); // 0 == 0 = true

    // Test 2: Non-zero value
    frame.stack.clear();
    try frame.stack.append(42);
    _ = try evm.table.execute(0, interpreter, state, 0x15);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result2); // 42 == 0 = false

    // Test 3: Small non-zero value
    frame.stack.clear();
    try frame.stack.append(1);
    _ = try evm.table.execute(0, interpreter, state, 0x15);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result3); // 1 == 0 = false

    // Test 4: Max value
    frame.stack.clear();
    try frame.stack.append(std.math.maxInt(u256));
    _ = try evm.table.execute(0, interpreter, state, 0x15);
    const result4 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result4); // max == 0 = false

    // Test gas consumption for a single operation
    frame.stack.clear();
    frame.gas_remaining = 1000;
    try frame.stack.append(0);
    _ = try evm.table.execute(0, interpreter, state, 0x15);
    const gas_used = 1000 - frame.gas_remaining;
    try testing.expectEqual(@as(u64, 3), gas_used); // GasFastestStep = 3
}

test "Comparison: Stack underflow errors" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface);
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

    // Test LT with empty stack
    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(0, interpreter, state, 0x10));

    // Test LT with only one item
    try frame.stack.append(42);
    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(0, interpreter, state, 0x10));

    // Test ISZERO with empty stack
    frame.stack.clear();
    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(0, interpreter, state, 0x15));
}

test "Comparison: Edge cases" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface);
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

    // Test signed comparison edge cases
    const sign_bit = @as(u256, 1) << 255;

    // Test: SLT with stack [most_negative, most_positive] (most_positive on top)
    // SLT computes: top < second-from-top (signed) = most_positive < most_negative = false
    try frame.stack.append(sign_bit);         // most negative (-2^255)
    try frame.stack.append(sign_bit - 1);     // most positive (2^255 - 1)
    _ = try evm.table.execute(0, interpreter, state, 0x12);
    const result1 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result1);

    // Test: Boundary between positive and negative
    frame.stack.clear();
    try frame.stack.append(sign_bit - 1);
    try frame.stack.append(sign_bit);
    _ = try evm.table.execute(0, interpreter, state, 0x12);
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result2); // most_positive < most_negative = false

    // Test: Equal signed values
    frame.stack.clear();
    try frame.stack.append(sign_bit);
    try frame.stack.append(sign_bit);
    _ = try evm.table.execute(0, interpreter, state, 0x13);
    const result3 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result3); // Equal values, so not greater
}

test "Comparison: Gas consumption verification" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface);
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

    // All comparison operations cost 3 gas (GasFastestStep)
    const operations = [_]struct {
        name: []const u8,
        opcode: u8,
        stack_items: u8,
    }{
        .{ .name = "LT", .opcode = 0x10, .stack_items = 2 },
        .{ .name = "GT", .opcode = 0x11, .stack_items = 2 },
        .{ .name = "SLT", .opcode = 0x12, .stack_items = 2 },
        .{ .name = "SGT", .opcode = 0x13, .stack_items = 2 },
        .{ .name = "EQ", .opcode = 0x14, .stack_items = 2 },
        .{ .name = "ISZERO", .opcode = 0x15, .stack_items = 1 },
    };

    inline for (operations) |op_info| {
        frame.stack.clear();
        frame.gas_remaining = 1000;

        // Push required stack items
        var i: u8 = 0;
        while (i < op_info.stack_items) : (i += 1) {
            try frame.stack.append(42);
        }

        _ = try evm.table.execute(0, interpreter, state, op_info.opcode);
        const gas_used = 1000 - frame.gas_remaining;
        try testing.expectEqual(@as(u64, 3), gas_used); // GasFastestStep = 3
    }
}
