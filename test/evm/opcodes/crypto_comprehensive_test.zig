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

// ============================
// Cryptographic Instructions (0x20)
// KECCAK256 (SHA3)
// ============================

// ============================
// 0x20: KECCAK256 - Compute Keccak-256 hash of memory data
// Gas: 30 base + 6 per word + memory expansion
// Stack: [offset, size] -> [hash]
// ============================

test "KECCAK256 (0x20): Known test vectors" {
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

    // Test vector 1: Empty string
    // keccak256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
    try frame.stack.append(0); // offset
    try frame.stack.append(0); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const empty_hash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    const top1 = try frame.stack.peek_n(0);
    try testing.expectEqual(empty_hash, top1);
    frame.stack.clear();

    // Test vector 2: Single byte 0x01
    // keccak256(0x01) = 0x5fe7f977e71dba2ea1a68e21057beebb9be2ac30c6410aa38d4f3fbe41dcffd2
    try frame.memory.set_data(0, &[_]u8{0x01});
    try frame.stack.append(0); // offset
    try frame.stack.append(1); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const single_byte_hash = 0x5fe7f977e71dba2ea1a68e21057beebb9be2ac30c6410aa38d4f3fbe41dcffd2;
    const top2 = try frame.stack.peek_n(0);
    try testing.expectEqual(single_byte_hash, top2);
    frame.stack.clear();

    // Test vector 3: "abc" (0x616263)
    // keccak256("abc") = 0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45
    try frame.memory.set_data(0, &[_]u8{ 0x61, 0x62, 0x63 });
    try frame.stack.append(0); // offset
    try frame.stack.append(3); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const abc_hash = 0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45;
    const top3 = try frame.stack.peek_n(0);
    try testing.expectEqual(abc_hash, top3);
    frame.stack.clear();

    // Test vector 4: 32 bytes of zeros
    // keccak256(32 zero bytes) = 0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563
    var zero_bytes = [_]u8{0} ** 32;
    for (0..32) |i| {
        try frame.memory.set_data(i, &[_]u8{zero_bytes[i]});
    }
    try frame.stack.append(0); // offset
    try frame.stack.append(32); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const zero32_hash = 0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563;
    const top4 = try frame.stack.peek_n(0);
    try testing.expectEqual(zero32_hash, top4);
}

test "KECCAK256: Gas cost calculations" {
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

    // Test 1: Empty data (0 words)
    // Gas cost should be base cost (30) + 0 words * 6 = 30
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    const initial_gas = frame.gas_remaining;
    try frame.stack.append(0); // offset
    try frame.stack.append(0); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const gas_used_empty = initial_gas - frame.gas_remaining;
    // Empty data still charges base cost
    try testing.expectEqual(@as(u64, 30), gas_used_empty);
    frame.stack.clear();

    // Test 2: 1 byte (1 word)
    // Gas cost should be 30 + 1 * 6 = 36
    frame.gas_remaining = 1000;
    const initial_gas2 = frame.gas_remaining;
    try frame.memory.set_data(0, &[_]u8{0x01});
    try frame.stack.append(0); // offset
    try frame.stack.append(1); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const gas_used_1byte = initial_gas2 - frame.gas_remaining;
    try testing.expect(gas_used_1byte >= 36); // At least 36, may include memory expansion
    frame.stack.clear();

    // Test 3: 32 bytes (1 word)
    // Gas cost should be 30 + 1 * 6 = 36
    frame.gas_remaining = 1000;
    const initial_gas3 = frame.gas_remaining;
    for (0..32) |i| {
        try frame.memory.set_data(i, &[_]u8{@intCast(i)});
    }
    try frame.stack.append(0); // offset
    try frame.stack.append(32); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const gas_used_32bytes = initial_gas3 - frame.gas_remaining;
    try testing.expect(gas_used_32bytes >= 36);
    frame.stack.clear();

    // Test 4: 64 bytes (2 words)
    // Gas cost should be 30 + 2 * 6 = 42
    frame.gas_remaining = 1000;
    const initial_gas4 = frame.gas_remaining;
    for (0..64) |i| {
        try frame.memory.set_data(i, &[_]u8{@intCast(i & 0xFF)});
    }
    try frame.stack.append(0); // offset
    try frame.stack.append(64); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const gas_used_64bytes = initial_gas4 - frame.gas_remaining;
    try testing.expect(gas_used_64bytes >= 42);
    try testing.expect(gas_used_64bytes > gas_used_32bytes); // Should cost more

    // Test 5: Large data (256 bytes = 8 words)
    // Gas cost should be 30 + 8 * 6 = 78 (plus memory expansion)
    frame.stack.clear();
    frame.gas_remaining = 1000;
    const initial_gas5 = frame.gas_remaining;
    for (0..256) |i| {
        try frame.memory.set_data(i, &[_]u8{@intCast(i & 0xFF)});
    }
    try frame.stack.append(0); // offset
    try frame.stack.append(256); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const gas_used_256bytes = initial_gas5 - frame.gas_remaining;
    try testing.expect(gas_used_256bytes >= 78);
    try testing.expect(gas_used_256bytes > gas_used_64bytes);
}

test "KECCAK256: Memory operations" {
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

    // Test 1: Hash data at non-zero offset
    const pattern = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    for (pattern, 0..) |byte, i| {
        try frame.memory.set_data(100 + i, &[_]u8{byte});
    }
    try frame.stack.append(100); // offset
    try frame.stack.append(4); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const offset_hash = try frame.stack.peek_n(0);
    try testing.expect(offset_hash != 0);
    frame.stack.clear();

    // Test 2: Same data at offset 0 should produce same hash
    for (pattern, 0..) |byte, i| {
        try frame.memory.set_data(i, &[_]u8{byte});
    }
    try frame.stack.append(0); // offset
    try frame.stack.append(4); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const zero_offset_hash = try frame.stack.peek_n(0);
    try testing.expectEqual(offset_hash, zero_offset_hash);
    frame.stack.clear();

    // Test 3: Memory expansion
    const large_offset = 1000;
    const size = 64;
    try frame.stack.append(large_offset); // offset
    try frame.stack.append(size); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    // Should not error, memory should expand to accommodate
    const expansion_hash = try frame.stack.peek_n(0);
    try testing.expect(expansion_hash != 0);
    frame.stack.clear();

    // Test 4: Zero-size hash at large offset should not fail
    try frame.stack.append(large_offset); // offset
    try frame.stack.append(0); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const empty_at_offset = try frame.stack.peek_n(0);
    const empty_hash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
    try testing.expectEqual(@as(u256, empty_hash), empty_at_offset);
}

test "KECCAK256: Variable input sizes" {
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

    // Set up test data pattern
    for (0..1024) |i| {
        try frame.memory.set_data(i, &[_]u8{@intCast(i & 0xFF)});
    }

    var previous_hash: u256 = 0;

    // Test various sizes to ensure each produces a different hash
    const test_sizes = [_]u256{ 1, 2, 3, 4, 5, 8, 16, 31, 32, 33, 63, 64, 65, 127, 128, 255, 256, 511, 512, 1023 };

    for (test_sizes) |size| {
        try frame.stack.append(0); // offset
        try frame.stack.append(size); // size
        _ = try evm.table.execute(0, interpreter, state, 0x20);
        const current_hash = try frame.stack.peek_n(0);

        // Each different input size should produce a different hash
        if (previous_hash != 0) {
            try testing.expect(current_hash != previous_hash);
        }
        previous_hash = current_hash;
        frame.stack.clear();
    }
}

test "KECCAK256: Hash consistency" {
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

    // Test: Same input should always produce same hash
    const test_data = [_]u8{ 0x48, 0x65, 0x6c, 0x6c, 0x6f }; // "Hello"
    for (test_data, 0..) |byte, i| {
        try frame.memory.set_data(i, &[_]u8{byte});
    }

    // Hash it multiple times
    var first_hash: u256 = 0;
    for (0..5) |iteration| {
        try frame.stack.append(0); // offset
        try frame.stack.append(test_data.len); // size
        _ = try evm.table.execute(0, interpreter, state, 0x20);
        const current_hash = try frame.stack.peek_n(0);

        if (iteration == 0) {
            first_hash = current_hash;
        } else {
            try testing.expectEqual(first_hash, current_hash);
        }
        frame.stack.clear();
    }

    // Test: Different input should produce different hash
    try frame.memory.set_data(4, &[_]u8{0x6F}); // Change "Hello" to "Helloo"
    try frame.stack.append(0); // offset
    try frame.stack.append(test_data.len); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const different_hash = try frame.stack.peek_n(0);
    try testing.expect(different_hash != first_hash);
}

test "KECCAK256: Edge cases and limits" {
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
        100000,
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
        .withGas(100000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Maximum reasonable size that doesn't exceed memory limits
    const large_size = 8192; // 256 words
    try frame.stack.append(0); // offset
    try frame.stack.append(large_size); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const large_hash = try frame.stack.peek_n(0);
    try testing.expect(large_hash != 0);
    frame.stack.clear();

    // Test 2: Zero offset with non-zero size
    try frame.stack.append(0); // offset
    try frame.stack.append(32); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const zero_offset_result = try frame.stack.peek_n(0);
    try testing.expect(zero_offset_result != 0);
    frame.stack.clear();

    // Test 3: Word boundary alignment (31 bytes vs 32 bytes)
    // 31 bytes should use 1 word, 33 bytes should use 2 words
    for (0..33) |i| {
        try frame.memory.set_data(i, &[_]u8{0xAA});
    }

    const gas_before_31 = frame.gas_remaining;
    try frame.stack.append(0); // offset
    try frame.stack.append(31); // size = 31 bytes = 1 word
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const gas_after_31 = frame.gas_remaining;
    const gas_used_31 = gas_before_31 - gas_after_31;
    frame.stack.clear();

    const gas_before_33 = frame.gas_remaining;
    try frame.stack.append(0); // offset
    try frame.stack.append(33); // size = 33 bytes = 2 words
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const gas_after_33 = frame.gas_remaining;
    const gas_used_33 = gas_before_33 - gas_after_33;

    // 33 bytes should cost more than 31 bytes due to additional word
    try testing.expect(gas_used_33 >= gas_used_31 + 6); // At least 6 more gas for extra word
}

test "KECCAK256: Error conditions" {
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

    // Test 1: Stack underflow - no arguments
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(0, interpreter, state, 0x20));

    // Test 2: Stack underflow - only one argument
    try frame.stack.append(32);
    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(0, interpreter, state, 0x20));
    frame.stack.clear();

    // Test 3: Out of gas - insufficient gas for large hash
    frame.gas_remaining = 30; // Only enough for base cost, not word cost
    const large_size = 1000; // Would require 30 + ceil(1000/32) * 6 = 30 + 32 * 6 = 222 gas
    try frame.stack.append(0); // offset
    try frame.stack.append(large_size); // size
    try testing.expectError(ExecutionError.Error.OutOfGas, evm.table.execute(0, interpreter, state, 0x20));
    frame.stack.clear();

    // Test 4: Invalid offset - extremely large offset that would overflow
    frame.gas_remaining = 10000;
    const huge_offset = std.math.maxInt(u256);
    try frame.stack.append(huge_offset); // offset
    try frame.stack.append(1); // size
    try testing.expectError(ExecutionError.Error.OutOfOffset, evm.table.execute(0, interpreter, state, 0x20));
    frame.stack.clear();

    // Test 5: Size overflow - offset + size overflows
    const large_offset = std.math.maxInt(u256) - 10;
    const size_that_overflows = 20;
    try frame.stack.append(large_offset); // offset
    try frame.stack.append(size_that_overflows); // size
    try testing.expectError(ExecutionError.Error.OutOfOffset, evm.table.execute(0, interpreter, state, 0x20));
}

test "KECCAK256: Stack behavior" {
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

    // Set up initial stack state
    try frame.stack.append(0x12345678); // [bottom]
    try frame.stack.append(0xABCDEF); //
    try frame.stack.append(0x0); // offset
    try frame.stack.append(0x55); // size [top]

    // Stack before: [0x12345678, 0xABCDEF, 0x0, 0x55] (size and offset are on top)
    try testing.expectEqual(@as(usize, 4), frame.stack.size);

    // Execute KECCAK256
    _ = try evm.table.execute(0, interpreter, state, 0x20);

    // Stack after: [0x12345678, 0xABCDEF, hash_result] (consumed 2, produced 1)
    try testing.expectEqual(@as(usize, 3), frame.stack.size);

    // Bottom values should remain unchanged
    const bottom1 = try frame.stack.peek_n(2);
    try testing.expectEqual(@as(u256, 0x12345678), bottom1);
    const bottom2 = try frame.stack.peek_n(1);
    try testing.expectEqual(@as(u256, 0xABCDEF), bottom2);

    // Top value should be the hash result
    const hash_result = try frame.stack.peek_n(0);
    try testing.expect(hash_result != 0); // Hash should be non-zero
    try testing.expect(hash_result != 0x55); // Should not be the old value
}

test "KECCAK256: Memory access patterns" {
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

    // Test 1: Reading across memory boundaries
    // Write data that spans multiple 32-byte words
    const test_pattern = "This is a test string that spans multiple memory words and should produce a consistent hash";
    for (test_pattern, 0..) |char, i| {
        try frame.memory.set_data(i, &[_]u8{char});
    }

    try frame.stack.append(0); // offset
    try frame.stack.append(test_pattern.len); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const pattern_hash = try frame.stack.peek_n(0);
    try testing.expect(pattern_hash != 0);
    frame.stack.clear();

    // Test 2: Reading with gaps in initialized memory
    // Initialize only every other byte
    for (0..64) |i| {
        if (i % 2 == 0) {
            try frame.memory.set_data(100 + i, &[_]u8{@intCast(i)});
        }
        // Odd positions remain 0 (default)
    }

    try frame.stack.append(100); // offset
    try frame.stack.append(64); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const gap_hash = try frame.stack.peek_n(0);
    try testing.expect(gap_hash != 0);
    try testing.expect(gap_hash != pattern_hash);
}
