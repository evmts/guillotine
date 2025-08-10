const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const testing = std.testing;

test "fuzz_storage_sload_operations" {
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

    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(1000000)
        .build();
    defer frame.deinit();

    const slot: u256 = 0x123456789ABCDEF;

    // Test SLOAD operation (should return 0 for uninitialized storage)
    try frame.stack.append(slot);

    var interpreter: evm.Operation.Interpreter = &vm;
    var state: evm.Operation.State = &frame;
    _ = try config.opcodes.table.execute(0, interpreter, state, 0x54); // SLOAD opcode

    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

test "fuzz_storage_sstore_sload_roundtrip" {
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

    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(1000000)
        .build();
    defer frame.deinit();

    const slot: u256 = 0x123456789ABCDEF;
    const value: u256 = 0xFEDCBA9876543210;

    // Test SSTORE operation: stack order [value, slot] where slot is on top
    try frame.stack.append(value);
    try frame.stack.append(slot);

    var interpreter: evm.Operation.Interpreter = &vm;
    var state: evm.Operation.State = &frame;
    _ = try config.opcodes.table.execute(0, interpreter, state, 0x55); // SSTORE opcode

    // Now test SLOAD to retrieve the stored value
    try frame.stack.append(slot);
    _ = try config.opcodes.table.execute(0, interpreter, state, 0x54); // SLOAD opcode

    const result = try frame.stack.pop();
    try testing.expectEqual(value, result);
}

test "fuzz_storage_tload_operations" {
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

    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(1000000)
        .build();
    defer frame.deinit();

    const slot: u256 = 0x123456789ABCDEF;

    // Test TLOAD operation (should return 0 for uninitialized transient storage)
    try frame.stack.append(slot);

    var interpreter: evm.Operation.Interpreter = &vm;
    var state: evm.Operation.State = &frame;
    _ = try config.opcodes.table.execute(0, interpreter, state, 0x5C); // TLOAD opcode

    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result);
}

test "fuzz_storage_tstore_tload_roundtrip" {
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

    var frame_builder = evm.Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(1000000)
        .build();
    defer frame.deinit();

    const slot: u256 = 0x123456789ABCDEF;
    const value: u256 = 0xFEDCBA9876543210;

    // Test TSTORE operation: stack order [value, slot] where slot is on top
    try frame.stack.append(value);
    try frame.stack.append(slot);

    var interpreter: evm.Operation.Interpreter = &vm;
    var state: evm.Operation.State = &frame;
    _ = try config.opcodes.table.execute(0, interpreter, state, 0x5D); // TSTORE opcode

    // Now test TLOAD to retrieve the stored value
    try frame.stack.append(slot);
    _ = try config.opcodes.table.execute(0, interpreter, state, 0x5C); // TLOAD opcode

    const result = try frame.stack.pop();
    try testing.expectEqual(value, result);
}
