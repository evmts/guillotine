const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const testing = std.testing;

test "fuzz_comparison_lt_operations" {
    const allocator = testing.allocator;
    
    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();
    
    var vm = try evm.Evm.init(allocator, db.to_database_interface());
    defer vm.deinit(allocator);
    
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
    
    var builder = evm.Frame.builder();
    var frame = try builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(1000000)
        .withCaller(.{})
        .build();
    defer frame.deinit(allocator);
    
    // Test LT operation: 5 < 10
    try frame.stack.append(5);  // a
    try frame.stack.append(10); // b
    
    var interpreter = evm.Operation.Interpreter = &vm;
    var state = evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x10);
    
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result); // true
}

test "fuzz_comparison_eq_operations" {
    const allocator = testing.allocator;
    
    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();
    
    var vm = try evm.Evm.init(allocator, db.to_database_interface());
    defer vm.deinit(allocator);
    
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
    
    var builder = evm.Frame.builder();
    var frame = try builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(1000000)
        .withCaller(.{})
        .build();
    defer frame.deinit(allocator);
    
    // Test EQ operation: 42 == 42
    try frame.stack.append(42); // b
    try frame.stack.append(42); // a
    
    var interpreter = evm.Operation.Interpreter = &vm;
    var state = evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x14);
    
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result); // true
}

test "fuzz_comparison_iszero_operations" {
    const allocator = testing.allocator;
    
    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();
    
    var vm = try evm.Evm.init(allocator, db.to_database_interface());
    defer vm.deinit(allocator);
    
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
    
    var builder = evm.Frame.builder();
    var frame = try builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(1000000)
        .withCaller(.{})
        .build();
    defer frame.deinit(allocator);
    
    // Test ISZERO operation with zero
    try frame.stack.append(0);
    
    var interpreter = evm.Operation.Interpreter = &vm;
    var state = evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x15);
    
    const result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result); // true
    
    // Test ISZERO operation with non-zero
    try frame.stack.append(42);
    _ = try vm.table.execute(0, interpreter, state, 0x15);
    
    const result2 = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result2); // false
}