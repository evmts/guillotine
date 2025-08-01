const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const Contract = Evm.Contract;
const Frame = Evm.Frame;
const MemoryDatabase = Evm.MemoryDatabase;
const ExecutionError = Evm.ExecutionError;
const EVMAllocator = Evm.EVMAllocator;

// ============================
// 0x00: STOP opcode
// ============================

test "STOP (0x00): Halt execution" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    const code = [_]u8{0x00}; // STOP
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Execute STOP
    const result = evm.table.execute(0, interpreter, state, 0x00);

    // Should return STOP error
    try testing.expectError(ExecutionError.Error.STOP, result);
}

// ============================
// 0x01: ADD opcode
// ============================

test "ADD (0x01): Basic addition" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    const code = [_]u8{0x01}; // ADD
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test basic addition: 5 + 10 = 15
    try frame.stack.append(5);
    try frame.stack.append(10);

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    const result = try evm.table.execute(0, interpreter, state, 0x01);
    try testing.expectEqual(@as(usize, 1), result.bytes_consumed);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 15), value);
}

test "ADD: Overflow wraps to zero" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x01},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test overflow: MAX + 1 = 0
    const max_u256 = std.math.maxInt(u256);
    try frame.stack.append(max_u256);
    try frame.stack.append(1);

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x01);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), value);
}

test "ADD: Large numbers" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x01},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test large number addition
    const large1 = std.math.maxInt(u256) / 2;
    const large2 = std.math.maxInt(u256) / 3;
    try frame.stack.append(large1);
    try frame.stack.append(large2);

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x01);

    const value = try frame.stack.pop();
    const expected = large1 +% large2; // Wrapping addition
    try testing.expectEqual(expected, value);
}

// ============================
// 0x02: MUL opcode
// ============================

test "MUL (0x02): Basic multiplication" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x02},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test basic multiplication: 5 * 10 = 50
    try frame.stack.append(5);
    try frame.stack.append(10);

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x02);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 50), value);
}

test "MUL: Multiplication by zero" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x02},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test multiplication by zero
    try frame.stack.append(1000);
    try frame.stack.append(0);

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x02);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), value);
}

test "MUL: Overflow behavior" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x02},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test overflow: (2^128) * (2^128) should wrap
    const half_max = @as(u256, 1) << 128;
    try frame.stack.append(half_max);
    try frame.stack.append(half_max);

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x02);

    const value = try frame.stack.pop();
    // Result should be 0 due to overflow (2^256 mod 2^256 = 0)
    try testing.expectEqual(@as(u256, 0), value);
}

// ============================
// 0x03: SUB opcode
// ============================

test "SUB (0x03): Basic subtraction" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x03},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test basic subtraction: 10 - 5 = 5
    // SUB calculates top - second, so we need [5, 10] with 10 on top
    try frame.stack.append(5);
    try frame.stack.append(10);

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x03);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 5), value);
}

test "SUB: Underflow wraps to max" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x03},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test underflow: 1 - 2 = MAX (wraps around)
    // SUB calculates top - second, so we need [2, 1] with 1 on top
    try frame.stack.append(2);
    try frame.stack.append(1);

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x03);

    const value = try frame.stack.pop();
    try testing.expectEqual(std.math.maxInt(u256), value);
}

// ============================
// 0x04: DIV opcode
// ============================

test "DIV (0x04): Basic division" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x04},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test basic division: 20 / 5 = 4
    // DIV pops dividend first, then divisor, so dividend must be on top
    try frame.stack.append(5); // divisor (bottom)
    try frame.stack.append(20); // dividend (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x04);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 4), value);
}

test "DIV: Division by zero returns zero" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x04},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test division by zero: 100 / 0 = 0
    // DIV pops dividend first, then divisor, so dividend must be on top
    try frame.stack.append(0); // divisor (bottom)
    try frame.stack.append(100); // dividend (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x04);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), value);
}

test "DIV: Integer division truncates" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x04},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test truncation: 7 / 3 = 2 (not 2.33...)
    // DIV pops dividend first, then divisor, so dividend must be on top
    try frame.stack.append(3); // divisor (bottom)
    try frame.stack.append(7); // dividend (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x04);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 2), value);
}

// ============================
// 0x05: SDIV opcode
// ============================

test "SDIV (0x05): Signed division positive" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x05},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test positive division: 20 / 5 = 4
    // SDIV pops dividend first, then divisor, so dividend must be on top
    try frame.stack.append(5); // divisor (bottom)
    try frame.stack.append(20); // dividend (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x05);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 4), value);
}

test "SDIV: Signed division negative" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x05},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test negative division: -20 / 5 = -4
    // In two's complement: -20 = MAX - 19
    // SDIV pops dividend first, then divisor, so dividend must be on top
    const neg_20 = std.math.maxInt(u256) - 19;
    try frame.stack.append(5); // divisor (bottom)
    try frame.stack.append(neg_20); // dividend (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x05);

    const value = try frame.stack.pop();
    const expected = std.math.maxInt(u256) - 3; // -4 in two's complement
    try testing.expectEqual(expected, value);
}

test "SDIV: Division by zero returns zero" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x05},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test division by zero
    // SDIV pops dividend first, then divisor, so dividend must be on top
    try frame.stack.append(0); // divisor (bottom)
    try frame.stack.append(100); // dividend (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x05);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), value);
}

test "SDIV: Edge case MIN / -1" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x05},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test MIN / -1 = MIN (special case)
    const min_i256 = @as(u256, 1) << 255; // -2^255 in two's complement
    const neg_1 = std.math.maxInt(u256); // -1 in two's complement
    // SDIV pops dividend first, then divisor, so dividend must be on top
    try frame.stack.append(neg_1); // divisor (bottom)
    try frame.stack.append(min_i256); // dividend (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x05);

    const value = try frame.stack.pop();
    try testing.expectEqual(min_i256, value);
}

// ============================
// 0x06: MOD opcode
// ============================

test "MOD (0x06): Basic modulo" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x06},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test basic modulo: 17 % 5 = 2
    // MOD pops dividend first, then divisor, so dividend must be on top
    try frame.stack.append(5); // divisor (bottom)
    try frame.stack.append(17); // dividend (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x06);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 2), value);
}

test "MOD: Modulo by zero returns zero" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x06},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test modulo by zero: 100 % 0 = 0
    // MOD pops dividend first, then divisor, so dividend must be on top
    try frame.stack.append(0); // divisor (bottom)
    try frame.stack.append(100); // dividend (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x06);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), value);
}

// ============================
// 0x07: SMOD opcode
// ============================

test "SMOD (0x07): Signed modulo positive" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x07},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test positive modulo: 17 % 5 = 2
    // SMOD pops dividend first, then divisor, so dividend must be on top
    try frame.stack.append(5); // divisor (bottom)
    try frame.stack.append(17); // dividend (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x07);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 2), value);
}

test "SMOD: Signed modulo negative" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x07},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test negative modulo: -17 % 5 = -2
    const neg_17 = std.math.maxInt(u256) - 16;
    // SMOD pops dividend first, then divisor, so dividend must be on top
    try frame.stack.append(5); // divisor (bottom)
    try frame.stack.append(neg_17); // dividend (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x07);

    const value = try frame.stack.pop();
    const expected = std.math.maxInt(u256) - 1; // -2 in two's complement
    try testing.expectEqual(expected, value);
}

// ============================
// 0x08: ADDMOD opcode
// ============================

test "ADDMOD (0x08): Basic modular addition" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x08},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test: (10 + 10) % 8 = 4
    // ADDMOD pops modulus first, then second addend, then first addend
    try frame.stack.append(8); // modulus (bottom)
    try frame.stack.append(10); // second addend (middle)
    try frame.stack.append(10); // first addend (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x08);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 4), value);
}

test "ADDMOD: Modulo zero returns zero" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x08},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test: (10 + 10) % 0 = 0
    // ADDMOD pops modulus first, then second addend, then first addend
    try frame.stack.append(0); // modulus (bottom)
    try frame.stack.append(10); // second addend (middle)
    try frame.stack.append(10); // first addend (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x08);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), value);
}

test "ADDMOD: No intermediate overflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x08},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test with values that would overflow u256
    const max = std.math.maxInt(u256);
    // ADDMOD pops modulus first, then second addend, then first addend
    try frame.stack.append(10); // modulus (bottom)
    try frame.stack.append(max); // second addend (middle)
    try frame.stack.append(max); // first addend (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x08);

    const value = try frame.stack.pop();
    // (MAX + MAX) % 10 = 4
    // MAX + MAX in u256 wraps to: 2^256 - 2 (since MAX = 2^256 - 1)
    // (2^256 - 2) % 10 = 4 (since 2^256 % 10 = 6)
    try testing.expectEqual(@as(u256, 4), value);
}

// ============================
// 0x09: MULMOD opcode
// ============================

test "MULMOD (0x09): Basic modular multiplication" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x09},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test: (10 * 10) % 8 = 4
    // MULMOD pops modulus first, then second factor, then first factor
    try frame.stack.append(8); // modulus (bottom)
    try frame.stack.append(10); // second factor (middle)
    try frame.stack.append(10); // first factor (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x09);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 4), value);
}

test "MULMOD: No intermediate overflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x09},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test with values that would overflow u256
    const large = @as(u256, 1) << 200;
    // MULMOD pops modulus first, then second factor, then first factor
    try frame.stack.append(100); // modulus (bottom)
    try frame.stack.append(large); // second factor (middle)
    try frame.stack.append(large); // first factor (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x09);

    const value = try frame.stack.pop();
    // Should compute correctly without overflow
    try testing.expect(value < 100);
}

// ============================
// 0x0A: EXP opcode
// ============================

test "EXP (0x0A): Basic exponentiation" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x0A},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test: 2^8 = 256
    // EXP pops base first, then exponent, so base must be on top
    try frame.stack.append(8); // exponent (bottom)
    try frame.stack.append(2); // base (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x0A);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 256), value);
}

test "EXP: Zero exponent" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x0A},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test: 100^0 = 1
    // EXP pops base first, then exponent, so base must be on top
    try frame.stack.append(0); // exponent (bottom)
    try frame.stack.append(100); // base (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x0A);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), value);
}

test "EXP: Zero base with non-zero exponent" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x0A},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test: 0^10 = 0
    // EXP pops base first, then exponent, so base must be on top
    try frame.stack.append(10); // exponent (bottom)
    try frame.stack.append(0); // base (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x0A);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), value);
}

test "EXP: Gas consumption scales with exponent size" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        10000,
        &[_]u8{0x0A},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test with large exponent
    // EXP pops base first, then exponent, so base must be on top
    try frame.stack.append(0x10000); // exponent (bottom)
    try frame.stack.append(2); // base (top)

    const gas_before = frame.gas_remaining;
    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x0A);
    const gas_used = gas_before - frame.gas_remaining;

    // EXP uses 10 + 50 * byte_size_of_exponent
    // 0x10000 = 65536, which is 3 bytes
    // Expected: 10 + 50 * 3 = 160
    try testing.expect(gas_used >= 160);
}

// ============================
// 0x0B: SIGNEXTEND opcode
// ============================

test "SIGNEXTEND (0x0B): Extend positive byte" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x0B},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test: sign extend 0x7F (positive) from byte 0
    // SIGNEXTEND pops byte_index first, then value, so byte_index must be on top
    try frame.stack.append(0x7F); // value (bottom)
    try frame.stack.append(0); // byte_index (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x0B);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0x7F), value);
}

test "SIGNEXTEND: Extend negative byte" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x0B},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test: sign extend 0xFF (negative) from byte 0
    // SIGNEXTEND pops byte_index first, then value, so byte_index must be on top
    try frame.stack.append(0xFF); // value (bottom)
    try frame.stack.append(0); // byte_index (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x0B);

    const value = try frame.stack.pop();
    // Should extend with 1s
    const expected = std.math.maxInt(u256); // All 1s
    try testing.expectEqual(expected, value);
}

test "SIGNEXTEND: Extend from higher byte position" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x0B},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test: sign extend 0x00FF from byte 1 (second byte)
    // SIGNEXTEND pops byte_index first, then value, so byte_index must be on top
    try frame.stack.append(0x00FF); // value (bottom)
    try frame.stack.append(1); // byte_index (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x0B);

    const value = try frame.stack.pop();
    // Since bit 15 is 0, it's positive, no extension
    try testing.expectEqual(@as(u256, 0x00FF), value);
}

test "SIGNEXTEND: Byte position >= 31 returns value unchanged" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x0B},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
    // Test: byte position >= 31 returns original value
    const test_value = 0x123456789ABCDEF;
    // SIGNEXTEND pops byte_index first, then value, so byte_index must be on top
    try frame.stack.append(test_value); // value (bottom)
    try frame.stack.append(31); // byte_index (top)

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    _ = try evm.table.execute(0, interpreter, state, 0x0B);

    const value = try frame.stack.pop();
    try testing.expectEqual(@as(u256, test_value), value);
}

// ============================
// Gas consumption tests
// ============================

test "Arithmetic opcodes: Gas consumption" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const test_cases = [_]struct {
        opcode: u8,
        expected_gas: u64,
        setup: *const fn (*Frame) anyerror!void,
    }{
        .{
            .opcode = 0x01,
            .expected_gas = 3,
            .setup = struct { // ADD
                fn setup(frame: *Frame) !void {
                    try frame.stack.append(5);
                    try frame.stack.append(10);
                }
            }.setup,
        },
        .{
            .opcode = 0x02,
            .expected_gas = 5,
            .setup = struct { // MUL
                fn setup(frame: *Frame) !void {
                    try frame.stack.append(5);
                    try frame.stack.append(10);
                }
            }.setup,
        },
        .{
            .opcode = 0x08,
            .expected_gas = 8,
            .setup = struct { // ADDMOD
                fn setup(frame: *Frame) !void {
                    // ADDMOD pops modulus first, then second addend, then first addend
                    try frame.stack.append(8); // modulus (bottom)
                    try frame.stack.append(10); // second addend (middle)
                    try frame.stack.append(10); // first addend (top)
                }
            }.setup,
        },
    };

    for (test_cases) |tc| {
        const caller = [_]u8{0x11} ** 20;
        const contract_addr = [_]u8{0x11} ** 20;
        var contract = Contract.init(
            caller,
            contract_addr,
            0,
            1000,
            &[_]u8{tc.opcode},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();
        try tc.setup(&frame);

        const gas_before = frame.gas_remaining;
        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &frame;

        _ = try evm.table.execute(0, interpreter, state, tc.opcode);
        const gas_used = gas_before - frame.gas_remaining;

        try testing.expectEqual(tc.expected_gas, gas_used);
    }
}

// ============================
// Stack underflow tests
// ============================

test "Arithmetic opcodes: Stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const binary_ops = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 }; // ADD, MUL, SUB, DIV, SDIV, MOD, SMOD
    const ternary_ops = [_]u8{ 0x08, 0x09 }; // ADDMOD, MULMOD

    // Test binary operations with empty stack
    for (binary_ops) |opcode| {
        const caller = [_]u8{0x11} ** 20;
        const contract_addr = [_]u8{0x11} ** 20;
        var contract = Contract.init(
            caller,
            contract_addr,
            0,
            1000,
            &[_]u8{opcode},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();

        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &frame;

        // Empty stack
        const result = evm.table.execute(0, interpreter, state, opcode);
        try testing.expectError(ExecutionError.Error.StackUnderflow, result);

        // Only one item
        try frame.stack.append(10);
        const result2 = evm.table.execute(0, interpreter, state, opcode);
        try testing.expectError(ExecutionError.Error.StackUnderflow, result2);
    }

    // Test ternary operations
    for (ternary_ops) |opcode| {
        const caller = [_]u8{0x11} ** 20;
        const contract_addr = [_]u8{0x11} ** 20;
        var contract = Contract.init(
            caller,
            contract_addr,
            0,
            1000,
            &[_]u8{opcode},
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();

        const interpreter: Evm.Operation.Interpreter = &evm;
        const state: Evm.Operation.State = &frame;

        // Only two items (need three)
        try frame.stack.append(10);
        try frame.stack.append(20);
        const result = evm.table.execute(0, interpreter, state, opcode);
        try testing.expectError(ExecutionError.Error.StackUnderflow, result);
    }
}

// ============================
// EVMAllocator test
// ============================

test "ADD with EVMAllocator: Using pre-allocated memory for EVM execution" {
    const backing_allocator = testing.allocator;

    // Create EVMAllocator with 4MB for testing (smaller than default 16MB)
    var evm_allocator = try EVMAllocator.init(backing_allocator, 4 * 1024 * 1024);
    defer evm_allocator.deinit();

    // Get the allocator interface for EVM use
    const allocator = evm_allocator.allocator();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    const code = [_]u8{0x01}; // ADD
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test basic addition
    try frame.stack.append(100);
    try frame.stack.append(200);
    _ = try evm.table.execute(0, interpreter, state, 0x01);
    try testing.expectEqual(@as(u256, 300), try frame.stack.pop());

    // Reset allocator and test reuse
    evm_allocator.reset();

    // Create new instances with reset allocator
    var memory_db2 = MemoryDatabase.init(allocator);
    defer memory_db2.deinit();

    const db_interface2 = memory_db2.to_database_interface();
    var builder2 = Evm.EvmBuilder.init(allocator, db_interface2);

    var evm2 = try builder2.build();
    defer evm2.deinit();

    var contract2 = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &code,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract2.deinit(allocator, null);

    var frame_builder2 = Frame.builder(allocator);
    var frame2 = try frame_builder2
        .withVm(&evm2)
        .withContract(&contract2)
        .withGas(1000)
        .build();
    defer frame2.deinit();

    frame2.stack.ensureInitialized();

    const interpreter2: Evm.Operation.Interpreter = &evm2;
    const state2: Evm.Operation.State = &frame2;

    // Test that reset allocator still works
    try frame2.stack.append(50);
    try frame2.stack.append(75);
    _ = try evm2.table.execute(0, interpreter2, state2, 0x01);
    try testing.expectEqual(@as(u256, 125), try frame2.stack.pop());
}
