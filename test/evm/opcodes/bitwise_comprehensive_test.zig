const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const Contract = Evm.Contract;
const Frame = Evm.Frame;
const Context = Evm.Context;
const MemoryDatabase = Evm.MemoryDatabase;
const ExecutionError = Evm.ExecutionError;

// ============================
// 0x16: AND opcode
// ============================

test "AND (0x16): Basic bitwise AND" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    const code = [_]u8{0x16}; // AND
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

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
    defer frame.deinit();

    // Test: 0xFF00 & 0x0FF0 = 0x0F00
    try frame.stack_push(0xFF00);
    try frame.stack_push(0x0FF0);

    const interpreter: *@TypeOf(evm) = &evm;
    const state: *Frame = &frame;

    const result = try evm.table.execute(interpreter, state, 0x16);
    try testing.expectEqual(@as(usize, 1), result.bytes_consumed);

    const value = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0x0F00), value);
}

test "AND: All zeros" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x16},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
    defer frame.deinit();

    // Test: 0xFFFF & 0x0000 = 0x0000
    try frame.stack_push(0xFFFF);
    try frame.stack_push(0x0000);

    const interpreter: *@TypeOf(evm) = &evm;
    const state: *Frame = &frame;

    _ = try evm.table.execute(interpreter, state, 0x16);

    const value = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0), value);
}

test "AND: All ones" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x16},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
    defer frame.deinit();

    // Test: MAX & MAX = MAX
    const max = std.math.maxInt(u256);
    try frame.stack_push(max);
    try frame.stack_push(max);

    const interpreter: *@TypeOf(evm) = &evm;
    const state: *Frame = &frame;

    _ = try evm.table.execute(interpreter, state, 0x16);

    const value = try frame.stack_pop();
    try testing.expectEqual(max, value);
}

test "AND: Masking operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x16},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
    defer frame.deinit();

    // Test: Extract lower byte with mask
    try frame.stack_push(0x123456);
    try frame.stack_push(0xFF);

    const interpreter: *@TypeOf(evm) = &evm;
    const state: *Frame = &frame;

    _ = try evm.table.execute(interpreter, state, 0x16);

    const value = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0x56), value);
}

// ============================
// 0x17: OR opcode
// ============================

test "OR (0x17): Basic bitwise OR" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x17},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
    defer frame.deinit();

    // Test: 0xF000 | 0x00F0 = 0xF0F0
    try frame.stack_push(0xF000);
    try frame.stack_push(0x00F0);

    const interpreter: *@TypeOf(evm) = &evm;
    const state: *Frame = &frame;

    _ = try evm.table.execute(interpreter, state, 0x17);

    const value = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0xF0F0), value);
}

test "OR: With zero" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x17},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
    defer frame.deinit();

    // Test: 0x1234 | 0x0000 = 0x1234
    try frame.stack_push(0x1234);
    try frame.stack_push(0x0000);

    const interpreter: *@TypeOf(evm) = &evm;
    const state: *Frame = &frame;

    _ = try evm.table.execute(interpreter, state, 0x17);

    const value = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0x1234), value);
}

test "OR: Setting bits" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x17},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
    defer frame.deinit();

    // Test: Set specific bits
    try frame.stack_push(0x1000);
    try frame.stack_push(0x0200);

    const interpreter: *@TypeOf(evm) = &evm;
    const state: *Frame = &frame;

    _ = try evm.table.execute(interpreter, state, 0x17);

    const value = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0x1200), value);
}

// ============================
// 0x18: XOR opcode
// ============================

test "XOR (0x18): Basic bitwise XOR" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x18},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
    defer frame.deinit();

    // Test: 0xFF00 ^ 0x0FF0 = 0xF0F0
    try frame.stack_push(0xFF00);
    try frame.stack_push(0x0FF0);

    const interpreter: *@TypeOf(evm) = &evm;
    const state: *Frame = &frame;

    _ = try evm.table.execute(interpreter, state, 0x18);

    const value = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0xF0F0), value);
}

test "XOR: Self XOR equals zero" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x18},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
    defer frame.deinit();

    // Test: X ^ X = 0
    try frame.stack_push(0x123456);
    try frame.stack_push(0x123456);

    const interpreter: *@TypeOf(evm) = &evm;
    const state: *Frame = &frame;

    _ = try evm.table.execute(interpreter, state, 0x18);

    const value = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0), value);
}

test "XOR: Toggle bits" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x18},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
    defer frame.deinit();

    // Test: Toggle specific bits
    try frame.stack_push(0b1010);
    try frame.stack_push(0b1100);

    const interpreter: *@TypeOf(evm) = &evm;
    const state: *Frame = &frame;

    _ = try evm.table.execute(interpreter, state, 0x18);

    const value = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0b0110), value);
}

// ============================
// 0x19: NOT opcode
// ============================

test "NOT (0x19): Basic bitwise NOT" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x19},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
    defer frame.deinit();

    // Test: NOT 0 = MAX
    try frame.stack_push(0);

    const interpreter: *@TypeOf(evm) = &evm;
    const state: *Frame = &frame;

    _ = try evm.table.execute(interpreter, state, 0x19);

    const value = try frame.stack_pop();
    try testing.expectEqual(std.math.maxInt(u256), value);
}

test "NOT: Invert all bits" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x19},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
    defer frame.deinit();

    // Test: NOT MAX = 0
    try frame.stack_push(std.math.maxInt(u256));

    const interpreter: *@TypeOf(evm) = &evm;
    const state: *Frame = &frame;

    _ = try evm.table.execute(interpreter, state, 0x19);

    const value = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0), value);
}

test "NOT: Double NOT returns original" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{ 0x19, 0x19 },
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
    defer frame.deinit();

    // Test: NOT(NOT(X)) = X
    const original = 0x123456789ABCDEF;
    try frame.stack_push(original);

    const interpreter: *@TypeOf(evm) = &evm;
    const state: *Frame = &frame;

    // First NOT
    frame.pc = 0;
    _ = try evm.table.execute(interpreter, state, 0x19);

    // Second NOT
    frame.pc = 1;
    _ = try evm.table.execute(interpreter, state, 0x19);

    const value = try frame.stack_pop();
    try testing.expectEqual(@as(u256, original), value);
}

// ============================
// 0x1A: BYTE opcode
// ============================

test "BYTE (0x1A): Extract first byte" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x1A},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
    defer frame.deinit();

    // Test: Extract byte 0 (most significant) from 0x123456...
    try frame.stack_push(0x1234567890ABCDEF); // value (pushed first, popped second)
    try frame.stack_push(0); // byte index (pushed last, popped first)

    const interpreter: *@TypeOf(evm) = &evm;
    const state: *Frame = &frame;

    _ = try evm.table.execute(interpreter, state, 0x1A);

    const value = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0), value); // Most significant byte is 0
}

test "BYTE: Extract last byte" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x1A},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
    defer frame.deinit();

    // Test: Extract byte 31 (least significant) from value
    try frame.stack_push(0x1234567890ABCDEF); // value (pushed first, popped second)
    try frame.stack_push(31); // byte index (pushed last, popped first)

    const interpreter: *@TypeOf(evm) = &evm;
    const state: *Frame = &frame;

    _ = try evm.table.execute(interpreter, state, 0x1A);

    const value = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0xEF), value);
}

test "BYTE: Out of bounds returns zero" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x1A},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
    defer frame.deinit();

    // Test: Byte index >= 32 returns 0
    try frame.stack_push(0xFFFFFFFFFFFFFFFF); // value (pushed first, popped second)
    try frame.stack_push(32); // byte index (out of bounds) (pushed last, popped first)

    const interpreter: *@TypeOf(evm) = &evm;
    const state: *Frame = &frame;

    _ = try evm.table.execute(interpreter, state, 0x1A);

    const value = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0), value);
}

test "BYTE: Extract from full u256" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x1A},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
    defer frame.deinit();

    // Create a value with known byte pattern
    // Bytes 24-31: 0x0102030405060708
    const test_value = @as(u256, 0x0102030405060708);

    // Test extracting byte 24 (should be 0x01)
    try frame.stack_push(test_value); // value (pushed first, popped second)
    try frame.stack_push(24); // byte index (pushed last, popped first)

    const interpreter: *@TypeOf(evm) = &evm;
    const state: *Frame = &frame;

    _ = try evm.table.execute(interpreter, state, 0x1A);

    const value = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 0x01), value);
}

// ============================
// Gas consumption tests
// ============================

test "Bitwise opcodes: Gas consumption" {
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
            .opcode = 0x16,
            .expected_gas = 3,
            .setup = struct { // AND
                fn setup(frame: *Frame) !void {
                    try frame.stack_push(0xFF);
                    try frame.stack_push(0x0F);
                }
            }.setup,
        },
        .{
            .opcode = 0x17,
            .expected_gas = 3,
            .setup = struct { // OR
                fn setup(frame: *Frame) !void {
                    try frame.stack_push(0xFF);
                    try frame.stack_push(0x0F);
                }
            }.setup,
        },
        .{
            .opcode = 0x18,
            .expected_gas = 3,
            .setup = struct { // XOR
                fn setup(frame: *Frame) !void {
                    try frame.stack_push(0xFF);
                    try frame.stack_push(0x0F);
                }
            }.setup,
        },
        .{
            .opcode = 0x19,
            .expected_gas = 3,
            .setup = struct { // NOT
                fn setup(frame: *Frame) !void {
                    try frame.stack_push(0xFF);
                }
            }.setup,
        },
        .{
            .opcode = 0x1A,
            .expected_gas = 3,
            .setup = struct { // BYTE
                fn setup(frame: *Frame) !void {
                    try frame.stack_push(0);
                    try frame.stack_push(0xFF);
                }
            }.setup,
        },
    };

    for (test_cases) |tc| {
        const caller: Address.Address = [_]u8{0x11} ** 20;
        const contract_addr: Address.Address = [_]u8{0x33} ** 20;
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

        const context = Context.init();
        var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
        defer frame.deinit();

        try tc.setup(&frame);

        const gas_before = frame.gas_remaining;
        const interpreter: *@TypeOf(evm) = &evm;
        const state: *Frame = &frame;

        _ = try evm.table.execute(interpreter, state, tc.opcode);
        const gas_used = gas_before - frame.gas_remaining;

        try testing.expectEqual(tc.expected_gas, gas_used);
    }
}

// ============================
// Stack underflow tests
// ============================

test "Bitwise opcodes: Stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const binary_ops = [_]u8{ 0x16, 0x17, 0x18, 0x1A }; // AND, OR, XOR, BYTE
    const unary_ops = [_]u8{0x19}; // NOT

    // Test binary operations with insufficient stack
    for (binary_ops) |opcode| {
        const caller: Address.Address = [_]u8{0x11} ** 20;
        const contract_addr: Address.Address = [_]u8{0x33} ** 20;
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

        const context = Context.init();
        var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
        defer frame.deinit();

        const interpreter: *@TypeOf(evm) = &evm;
        const state: *Frame = &frame;

        // Empty stack
        const result = evm.table.execute(interpreter, state, opcode);
        try testing.expectError(ExecutionError.Error.StackUnderflow, result);

        // Only one item (need two)
        try frame.stack_push(10);
        const result2 = evm.table.execute(interpreter, state, opcode);
        try testing.expectError(ExecutionError.Error.StackUnderflow, result2);
    }

    // Test unary operations with empty stack
    for (unary_ops) |opcode| {
        const caller: Address.Address = [_]u8{0x11} ** 20;
        const contract_addr: Address.Address = [_]u8{0x33} ** 20;
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

        const context = Context.init();
        var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
        defer frame.deinit();

        const interpreter: *@TypeOf(evm) = &evm;
        const state: *Frame = &frame;

        // Empty stack
        const result = evm.table.execute(interpreter, state, opcode);
        try testing.expectError(ExecutionError.Error.StackUnderflow, result);
    }
}

// ============================
// Edge case tests
// ============================

test "Bitwise operations: Large values" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x16}, // AND
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
    defer frame.deinit();

    // Test with maximum values
    const max = std.math.maxInt(u256);
    const half_max = max >> 1;

    try frame.stack_push(max);
    try frame.stack_push(half_max);

    const interpreter: *@TypeOf(evm) = &evm;
    const state: *Frame = &frame;

    _ = try evm.table.execute(interpreter, state, 0x16);

    const value = try frame.stack_pop();
    try testing.expectEqual(half_max, value);
}

test "BYTE: Byte extraction patterns" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);

    var evm = try builder.build();
    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{0x1A},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const context = Context.init();
    var frame = try Frame.init(allocator, &evm, 1000, &contract, caller, &.{}, context);
    defer frame.deinit();

    // Create a value with distinct byte pattern
    // Each byte has value equal to its position (31-i)
    var test_value: u256 = 0;
    var i: u8 = 0;
    while (i < 32) : (i += 1) {
        test_value = (test_value << 8) | @as(u256, 31 - i);
    }

    // Test extracting byte 28 (should be 3)
    try frame.stack_push(test_value); // value (pushed first, popped second)
    try frame.stack_push(28); // byte index (pushed last, popped first)

    const interpreter: *@TypeOf(evm) = &evm;
    const state: *Frame = &frame;

    _ = try evm.table.execute(interpreter, state, 0x1A);

    const value = try frame.stack_pop();
    try testing.expectEqual(@as(u256, 3), value);
}
