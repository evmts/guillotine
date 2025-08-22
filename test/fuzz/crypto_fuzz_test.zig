const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const testing = std.testing;

// Debug logging disabled for clean output
// test {
//     std.testing.log_level = .warn;
// }

test "fuzz_crypto_keccak256_empty" {
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
    
    // Test KECCAK256 of empty data: stack order [size, offset] where offset is on top
    try frame.stack.append(0); // size
    try frame.stack.append(0); // offset
    
    var interpreter = evm.Operation.Interpreter = &vm;
    var state = evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x20);
    
    const result = try frame.stack.pop();
    // keccak256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
    const expected_empty_hash: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    try testing.expectEqual(expected_empty_hash, result);
}

test "fuzz_crypto_keccak256_basic" {
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
    
    // Set up test data in memory
    const test_data = "Hello, World!";
    try frame.memory.set_data(0, test_data);
    
    // Test KECCAK256 of test data: stack order [size, offset] where offset is on top
    try frame.stack.append(test_data.len); // size
    try frame.stack.append(0); // offset
    
    var interpreter = evm.Operation.Interpreter = &vm;
    var state = evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x20);
    
    const result = try frame.stack.pop();
    
    // Verify by computing expected hash
    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(test_data, &expected_hash, .{});
    const expected_hash_u256 = std.mem.readInt(u256, &expected_hash, .big);
    
    try testing.expectEqual(expected_hash_u256, result);
}

test "fuzz_crypto_keccak256_edge_cases" {
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
    
    // Test with single byte
    try frame.memory.set_data(0, &[_]u8{0x42});
    
    // Test KECCAK256 of single byte: stack order [size, offset] where offset is on top  
    try frame.stack.append(1); // size
    try frame.stack.append(0); // offset
    
    var interpreter = evm.Operation.Interpreter = &vm;
    var state = evm.Operation.State = &frame;
    _ = try vm.table.execute(0, interpreter, state, 0x20);
    
    const result = try frame.stack.pop();
    
    // Verify single byte hash
    var expected_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&[_]u8{0x42}, &expected_hash, .{});
    const expected_hash_u256 = std.mem.readInt(u256, &expected_hash, .big);
    
    try testing.expectEqual(expected_hash_u256, result);
}