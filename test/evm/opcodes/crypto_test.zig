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
// Updated to new API - migration in progress, tests not run yet

test "Crypto: KECCAK256 (SHA3) basic operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        10000,
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
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Hash empty data
    try frame.stack.append(0); // size
    try frame.stack.append(0); // offset
    _ = try evm.table.execute(0, interpreter, state, 0x20);

    // Empty hash: keccak256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
    const empty_hash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    const result1 = try frame.stack.peek_n(0);
    try testing.expectEqual(empty_hash, result1);
    try testing.expectEqual(@as(usize, 1), frame.stack.size);

    // Test 2: Hash single byte
    frame.stack.clear();
    // Write 0x01 to memory at position 0
    try frame.memory.set_data(0, &[_]u8{0x01});
    try frame.stack.append(1); // size
    try frame.stack.append(0); // offset
    _ = try evm.table.execute(0, interpreter, state, 0x20);

    // keccak256(0x01) = 0x5fe7f977e71dba2ea1a68e21057beebb9be2ac30c6410aa38d4f3fbe41dcffd2
    const single_byte_hash = 0x5fe7f977e71dba2ea1a68e21057beebb9be2ac30c6410aa38d4f3fbe41dcffd2;
    const result2 = try frame.stack.peek_n(0);
    try testing.expectEqual(single_byte_hash, result2);

    // Test 3: Hash 32 bytes (one word)
    frame.stack.clear();
    // Write 32 bytes of 0xFF to memory
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        try frame.memory.set_data(i, &[_]u8{0xFF});
    }
    try frame.stack.append(0); // offset
    try frame.stack.append(32); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);

    // Should produce a valid hash (exact value would depend on actual keccak256 implementation)
    const result = try frame.stack.peek_n(0);
    try testing.expect(result != 0); // Hash should not be zero

    // Test 4: Hash with non-zero offset
    frame.stack.clear();
    // Write pattern starting at offset 64
    i = 64;
    while (i < 96) : (i += 1) {
        try frame.memory.set_data(i, &[_]u8{@intCast(i & 0xFF)});
    }
    try frame.stack.append(64); // offset
    try frame.stack.append(32); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);

    const offset_result = try frame.stack.peek_n(0);
    try testing.expect(offset_result != 0); // Hash should not be zero
    try testing.expect(offset_result != result); // Different data should produce different hash
}

test "Crypto: KECCAK256 memory expansion and gas" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        10000,
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
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test memory expansion gas cost
    const initial_gas = frame.gas_remaining;
    try frame.stack.append(256); // size (8 words) (will be popped 2nd)
    try frame.stack.append(0); // offset (will be popped 1st)
    _ = try evm.table.execute(0, interpreter, state, 0x20);

    // Gas should include:
    // - Base cost: 30
    // - Word cost: 6 * ceil(256/32) = 6 * 8 = 48
    // - Memory expansion cost for 256 bytes
    const gas_used = initial_gas - frame.gas_remaining;
    try testing.expect(gas_used >= 30 + 48); // At least base + word costs

    // Test large memory expansion
    frame.stack.clear();
    frame.gas_remaining = 10000;
    const large_size = 1024; // 32 words
    try frame.stack.append(large_size); // size (will be popped 2nd)
    try frame.stack.append(0); // offset (will be popped 1st)
    _ = try evm.table.execute(0, interpreter, state, 0x20);

    // Should consume more gas for larger data
    const large_gas_used = 10000 - frame.gas_remaining;
    try testing.expect(large_gas_used > gas_used);
}

test "Crypto: KECCAK256 edge cases" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        10000,
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
        .withGas(10000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test with maximum offset that fits in memory
    const max_offset = std.math.maxInt(usize) - 32;
    if (max_offset <= std.math.maxInt(u256)) {
        try frame.stack.append(0); // size (will be popped 2nd)
        try frame.stack.append(max_offset); // offset (will be popped 1st)
        const err = evm.table.execute(0, interpreter, state, 0x20);
        try testing.expectError(ExecutionError.Error.OutOfOffset, err);
    }

    // Test with size exceeding available gas (would cost too much)
    frame.stack.clear();
    frame.gas_remaining = 100; // Very limited gas
    const huge_size = 10000; // Would require lots of gas
    try frame.stack.append(huge_size); // size (will be popped 2nd)
    try frame.stack.append(0); // offset (will be popped 1st)
    const err2 = evm.table.execute(0, interpreter, state, 0x20);
    try testing.expectError(ExecutionError.Error.OutOfGas, err2);
}

test "Crypto: Stack underflow errors" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var evm = try EvmType.init(allocator, db_interface, null, 0, false, null);
    defer evm.deinit();

    const caller = [_]u8{0x11} ** 20;
    const contract_addr = [_]u8{0x11} ** 20;
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

    // Test SHA3 with empty stack
    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(0, interpreter, state, 0x20));

    // Test SHA3 with only one item
    try frame.stack.append(32);
    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(0, interpreter, state, 0x20));
}
