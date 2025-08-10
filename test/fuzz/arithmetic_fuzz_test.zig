const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const testing = std.testing;

test "fuzz_arithmetic_basic_operations" {
    const allocator = testing.allocator;

    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();

    const config = evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.Evm(config);
    var vm = try EvmType.init(allocator, db.to_database_interface(), null, 0, false, null);
    defer vm.deinit();

    const test_code = [_]u8{0x01};
    var contract = evm.Contract.init(primitives.Address.ZERO, primitives.Address.ZERO, 0, 1000000, &test_code, [_]u8{0} ** 32, &.{}, false);
    defer contract.deinit(allocator, null);

    var builder = evm.Frame.builder(allocator);
    var frame = try builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(1000000)
        .withCaller([_]u8{0x11} ** 20)
        .build();
    defer frame.deinit();

    // Test ADD operation
    try frame.stack.append(5);
    try frame.stack.append(10);

    var interpreter: evm.Operation.Interpreter = &vm;
    var state: evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x01);

    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 15), result);
}

test "fuzz_arithmetic_overflow_cases" {
    const allocator = testing.allocator;

    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();

    const config = evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.Evm(config);
    var vm = try EvmType.init(allocator, db.to_database_interface(), null, 0, false, null);
    defer vm.deinit();

    const test_code = [_]u8{0x01};
    var contract = evm.Contract.init(primitives.Address.ZERO, primitives.Address.ZERO, 0, 1000000, &test_code, [_]u8{0} ** 32, &.{}, false);
    defer contract.deinit(allocator, null);

    var builder = evm.Frame.builder(allocator);
    var frame = try builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(1000000)
        .withCaller([_]u8{0x11} ** 20)
        .build();
    defer frame.deinit();

    // Test ADD with max values (should wrap around)
    try frame.stack.append(std.math.maxInt(u256));
    try frame.stack.append(1);

    var interpreter: evm.Operation.Interpreter = &vm;
    var state: evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x01);

    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result); // Overflow wraps to 0
}

test "fuzz_arithmetic_division_by_zero" {
    const allocator = testing.allocator;

    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();

    const config = evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.Evm(config);
    var vm = try EvmType.init(allocator, db.to_database_interface(), null, 0, false, null);
    defer vm.deinit();

    const test_code = [_]u8{0x01};
    var contract = evm.Contract.init(primitives.Address.ZERO, primitives.Address.ZERO, 0, 1000000, &test_code, [_]u8{0} ** 32, &.{}, false);
    defer contract.deinit(allocator, null);

    var builder = evm.Frame.builder(allocator);
    var frame = try builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(1000000)
        .withCaller([_]u8{0x11} ** 20)
        .build();
    defer frame.deinit();

    // Test DIV by zero
    try frame.stack.append(0); // divisor
    try frame.stack.append(10); // dividend

    var interpreter: evm.Operation.Interpreter = &vm;
    var state: evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x04);

    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result); // Division by zero returns 0
}

test "fuzz_arithmetic_modulo_operations" {
    const allocator = testing.allocator;

    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();

    const config = evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.Evm(config);
    var vm = try EvmType.init(allocator, db.to_database_interface(), null, 0, false, null);
    defer vm.deinit();

    const test_code = [_]u8{0x01};
    var contract = evm.Contract.init(primitives.Address.ZERO, primitives.Address.ZERO, 0, 1000000, &test_code, [_]u8{0} ** 32, &.{}, false);
    defer contract.deinit(allocator, null);

    var builder = evm.Frame.builder(allocator);
    var frame = try builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(1000000)
        .withCaller([_]u8{0x11} ** 20)
        .build();
    defer frame.deinit();

    // Test MOD operation: 10 % 3 = 1
    try frame.stack.append(10); // dividend (a)
    try frame.stack.append(3); // modulus (b)

    var interpreter: evm.Operation.Interpreter = &vm;
    var state: evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x06);

    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result); // 10 % 3 = 1
}
