const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const testing = std.testing;

test "fuzz_bitwise_and_operations" {
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
        .withCaller(primitives.Address.ZERO)
        .build();
    defer frame.deinit();

    // Test AND operation
    try frame.stack.append(0xF0F0F0F0F0F0F0F0);
    try frame.stack.append(0x0F0F0F0F0F0F0F0F);

    var interpreter: evm.Operation.Interpreter = &vm;
    var state: evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x16);

    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

test "fuzz_bitwise_or_operations" {
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
        .withCaller(primitives.Address.ZERO)
        .build();
    defer frame.deinit();

    // Test OR operation
    try frame.stack.append(0xF0F0F0F0F0F0F0F0);
    try frame.stack.append(0x0F0F0F0F0F0F0F0F);

    var interpreter: evm.Operation.Interpreter = &vm;
    var state: evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x17);

    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0xFFFFFFFFFFFFFFFF), result);
}

test "fuzz_bitwise_xor_operations" {
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
        .withCaller(primitives.Address.ZERO)
        .build();
    defer frame.deinit();

    // Test XOR operation
    try frame.stack.append(0xAAAAAAAAAAAAAAAA);
    try frame.stack.append(0x5555555555555555);

    var interpreter: evm.Operation.Interpreter = &vm;
    var state: evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x18);

    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0xFFFFFFFFFFFFFFFF), result);
}

test "fuzz_bitwise_not_operations" {
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
        .withCaller(primitives.Address.ZERO)
        .build();
    defer frame.deinit();

    // Test NOT operation
    try frame.stack.append(0);

    var interpreter: evm.Operation.Interpreter = &vm;
    var state: evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x19);

    const result = try frame.stack.pop();
    try testing.expectEqual(std.math.maxInt(u256), result);
}
