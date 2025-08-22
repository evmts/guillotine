const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const testing = std.testing;

test "fuzz_control_pc_operations" {
    const allocator = testing.allocator;
    
    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();
    
    var vm = try evm.Evm.init(allocator, db.to_database_interface());
    defer vm.deinit();
    
    const test_code = [_]u8{0x01};
    var contract = evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        &test_code,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    var builder = evm.Frame.builder(allocator);
    var frame = try builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(1000000)
        .withCaller(primitives.Address.ZERO)
        .build();
    defer frame.deinit(allocator);
    
    // Test PC operation
    var interpreter = evm.Operation.Interpreter = &vm;
    var state = evm.Operation.State = &frame;
    _ = try vm.table.execute(42, interpreter, state, 0x58); // PC opcode
    
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 42), result);
}

test "fuzz_control_gas_operations" {
    const allocator = testing.allocator;
    
    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();
    
    var vm = try evm.Evm.init(allocator, db.to_database_interface());
    defer vm.deinit();
    
    const test_code = [_]u8{0x01};
    var contract = evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        &test_code,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    var builder = evm.Frame.builder(allocator);
    var frame = try builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(1000000)
        .withCaller(primitives.Address.ZERO)
        .build();
    defer frame.deinit(allocator);
    
    const initial_gas = frame.gas_remaining;
    
    // Test GAS operation
    var interpreter = evm.Operation.Interpreter = &vm;
    var state = evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x5A); // GAS opcode
    
    const result = try frame.stack.pop();
    try testing.expect(result <= initial_gas);
}

test "fuzz_control_jumpdest_operations" {
    const allocator = testing.allocator;
    
    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();
    
    var vm = try evm.Evm.init(allocator, db.to_database_interface());
    defer vm.deinit();
    
    const test_code = [_]u8{0x01};
    var contract = evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        &test_code,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    var builder = evm.Frame.builder(allocator);
    var frame = try builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(1000000)
        .withCaller(primitives.Address.ZERO)
        .build();
    defer frame.deinit(allocator);
    
    // Test JUMPDEST operation (should be a no-op)
    const initial_stack_size = frame.stack.size;
    
    var interpreter = evm.Operation.Interpreter = &vm;
    var state = evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x5B); // JUMPDEST opcode
    
    // Stack size should be unchanged
    try testing.expectEqual(initial_stack_size, frame.stack.size);
}