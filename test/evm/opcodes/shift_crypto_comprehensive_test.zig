const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const Contract = Evm.Contract;
const Frame = Evm.Frame;
const MemoryDatabase = Evm.MemoryDatabase;
const ExecutionError = Evm.ExecutionError;

// ============================
// SHL (0x1B) - Comprehensive Tests
// ============================
test "SHL: Comprehensive shift left edge cases" {
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    const test_cases = [_]struct {
        value: u256,
        shift: u256,
        expected: u256,
        desc: []const u8,
    }{
        // Basic cases
        .{ .value = 1, .shift = 0, .expected = 1, .desc = "1 << 0 = 1" },
        .{ .value = 1, .shift = 1, .expected = 2, .desc = "1 << 1 = 2" },
        .{ .value = 1, .shift = 8, .expected = 256, .desc = "1 << 8 = 256" },

        // Byte boundaries
        .{ .value = 0xFF, .shift = 8, .expected = 0xFF00, .desc = "0xFF << 8 = 0xFF00" },
        .{ .value = 0xFF, .shift = 16, .expected = 0xFF0000, .desc = "0xFF << 16" },
        .{ .value = 0xFF, .shift = 248, .expected = @as(u256, 0xFF) << 248, .desc = "0xFF << 248" },

        // Edge cases near 256-bit boundary
        .{ .value = 1, .shift = 254, .expected = @as(u256, 1) << 254, .desc = "1 << 254" },
        .{ .value = 1, .shift = 255, .expected = @as(u256, 1) << 255, .desc = "1 << 255 (MSB)" },
        .{ .value = 3, .shift = 254, .expected = @as(u256, 3) << 254, .desc = "3 << 254" },

        // Shift >= 256 (result is 0)
        .{ .value = 1, .shift = 256, .expected = 0, .desc = "1 << 256 = 0" },
        .{ .value = std.math.maxInt(u256), .shift = 256, .expected = 0, .desc = "MAX << 256 = 0" },
        .{ .value = 0xDEADBEEF, .shift = 300, .expected = 0, .desc = "value << 300 = 0" },
        .{ .value = 1, .shift = std.math.maxInt(u256), .expected = 0, .desc = "1 << MAX = 0" },

        // Zero value
        .{ .value = 0, .shift = 0, .expected = 0, .desc = "0 << 0 = 0" },
        .{ .value = 0, .shift = 100, .expected = 0, .desc = "0 << 100 = 0" },
        .{ .value = 0, .shift = 256, .expected = 0, .desc = "0 << 256 = 0" },

        // Overflow cases (bits shifted out)
        .{ .value = 0xFF, .shift = 250, .expected = (@as(u256, 0xFF) << 250), .desc = "0xFF << 250 (partial overflow)" },
        .{ .value = std.math.maxInt(u256), .shift = 1, .expected = std.math.maxInt(u256) - 1, .desc = "MAX << 1 (MSB lost, LSB becomes 0)" },
        .{ .value = (@as(u256, 1) << 255) | 1, .shift = 1, .expected = 2, .desc = "MSB|LSB << 1 = 2" },

        // Pattern preservation
        .{ .value = 0x123456789ABCDEF0, .shift = 4, .expected = 0x123456789ABCDEF0 << 4, .desc = "pattern << 4" },
        .{ .value = 0xF0F0F0F0, .shift = 4, .expected = 0xF0F0F0F00, .desc = "alternating << 4" },
    };

    for (test_cases) |tc| {
        frame.stack.clear();
        try frame.stack.append(tc.value); // value to shift (stays on stack, gets replaced)
        try frame.stack.append(tc.shift); // shift amount (gets popped)
        _ = try evm.table.execute(0, interpreter, state, 0x1B);
        const result = try frame.stack.peek_n(0);
        try testing.expectEqual(tc.expected, result);
        _ = try frame.stack.pop();
    }
}

// ============================
// SHR (0x1C) - Comprehensive Tests
// ============================
test "SHR: Comprehensive logical shift right edge cases" {
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    const test_cases = [_]struct {
        value: u256,
        shift: u256,
        expected: u256,
        desc: []const u8,
    }{
        // Basic cases
        .{ .value = 2, .shift = 1, .expected = 1, .desc = "2 >> 1 = 1" },
        .{ .value = 256, .shift = 8, .expected = 1, .desc = "256 >> 8 = 1" },
        .{ .value = 0xFF00, .shift = 8, .expected = 0xFF, .desc = "0xFF00 >> 8 = 0xFF" },

        // MSB handling (logical shift - zeros fill from left)
        .{ .value = @as(u256, 1) << 255, .shift = 1, .expected = @as(u256, 1) << 254, .desc = "MSB >> 1" },
        .{ .value = std.math.maxInt(u256), .shift = 1, .expected = std.math.maxInt(u256) >> 1, .desc = "MAX >> 1" },
        .{ .value = std.math.maxInt(u256), .shift = 255, .expected = 1, .desc = "MAX >> 255 = 1" },

        // Shift by 0
        .{ .value = 0xABCD, .shift = 0, .expected = 0xABCD, .desc = "value >> 0 = value" },

        // Shift >= 256
        .{ .value = std.math.maxInt(u256), .shift = 256, .expected = 0, .desc = "MAX >> 256 = 0" },
        .{ .value = 1, .shift = 256, .expected = 0, .desc = "1 >> 256 = 0" },
        .{ .value = 0xDEADBEEF, .shift = 1000, .expected = 0, .desc = "value >> 1000 = 0" },

        // Zero value
        .{ .value = 0, .shift = 0, .expected = 0, .desc = "0 >> 0 = 0" },
        .{ .value = 0, .shift = 100, .expected = 0, .desc = "0 >> 100 = 0" },

        // Byte extraction patterns
        .{ .value = 0xFF000000, .shift = 24, .expected = 0xFF, .desc = "extract high byte" },
        .{ .value = 0x123456789ABCDEF0, .shift = 32, .expected = 0x12345678, .desc = "extract high word" },

        // Complete shifts
        .{ .value = 1, .shift = 1, .expected = 0, .desc = "1 >> 1 = 0" },
        .{ .value = 0xFF, .shift = 8, .expected = 0, .desc = "0xFF >> 8 = 0" },
    };

    for (test_cases) |tc| {
        frame.stack.clear();
        try frame.stack.append(tc.value); // value to shift (stays on stack, gets replaced)
        try frame.stack.append(tc.shift); // shift amount (gets popped)
        _ = try evm.table.execute(0, interpreter, state, 0x1C);
        const result = try frame.stack.peek_n(0);
        try testing.expectEqual(tc.expected, result);
        _ = try frame.stack.pop();
    }
}

// ============================
// SAR (0x1D) - Comprehensive Tests
// ============================
test "SAR: Comprehensive arithmetic shift right edge cases" {
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    const test_cases = [_]struct {
        value: u256,
        shift: u256,
        expected: u256,
        desc: []const u8,
    }{
        // Positive numbers (same as SHR)
        .{ .value = 256, .shift = 8, .expected = 1, .desc = "positive: 256 >> 8 = 1" },
        .{ .value = 0x7FFFFFFFFFFFFFFF, .shift = 4, .expected = 0x7FFFFFFFFFFFFFFF >> 4, .desc = "positive large >> 4" },

        // Negative numbers (MSB = 1, sign extension)
        .{ .value = @as(u256, 1) << 255, .shift = 1, .expected = (@as(u256, 1) << 255) | (@as(u256, 1) << 254), .desc = "MIN >> 1 (sign extend)" },
        .{ .value = std.math.maxInt(u256), .shift = 1, .expected = std.math.maxInt(u256), .desc = "-1 >> 1 = -1" },
        .{ .value = std.math.maxInt(u256), .shift = 100, .expected = std.math.maxInt(u256), .desc = "-1 >> 100 = -1" },
        .{ .value = std.math.maxInt(u256), .shift = 255, .expected = std.math.maxInt(u256), .desc = "-1 >> 255 = -1" },

        // Negative with pattern
        .{ .value = std.math.maxInt(u256) - 0xFF, .shift = 8, .expected = std.math.maxInt(u256), .desc = "negative pattern >> 8" },

        // Shift >= 256
        .{ .value = 100, .shift = 256, .expected = 0, .desc = "positive >> 256 = 0" },
        .{ .value = 0, .shift = 256, .expected = 0, .desc = "0 >> 256 = 0" },
        .{ .value = @as(u256, 1) << 255, .shift = 256, .expected = std.math.maxInt(u256), .desc = "negative >> 256 = -1" },
        .{ .value = std.math.maxInt(u256), .shift = 300, .expected = std.math.maxInt(u256), .desc = "-1 >> 300 = -1" },
        .{ .value = std.math.maxInt(u256), .shift = std.math.maxInt(u256), .expected = std.math.maxInt(u256), .desc = "-1 >> MAX = -1" },

        // Boundary between positive and negative
        .{ .value = (@as(u256, 1) << 255) - 1, .shift = 1, .expected = ((@as(u256, 1) << 255) - 1) >> 1, .desc = "MAX_POSITIVE >> 1" },
        .{ .value = @as(u256, 1) << 255, .shift = 255, .expected = std.math.maxInt(u256), .desc = "MIN_NEGATIVE >> 255 = -1" },

        // Zero shifts
        .{ .value = std.math.maxInt(u256), .shift = 0, .expected = std.math.maxInt(u256), .desc = "-1 >> 0 = -1" },
        .{ .value = 42, .shift = 0, .expected = 42, .desc = "42 >> 0 = 42" },
    };

    for (test_cases) |tc| {
        frame.stack.clear();
        try frame.stack.append(tc.value); // value to shift (stays on stack, gets replaced)
        try frame.stack.append(tc.shift); // shift amount (gets popped)
        _ = try evm.table.execute(0, interpreter, state, 0x1D);
        const result = try frame.stack.peek_n(0);
        try testing.expectEqual(tc.expected, result);
        _ = try frame.stack.pop();
    }
}

// ============================
// KECCAK256 (0x20) - Comprehensive Tests
// ============================
test "KECCAK256: Comprehensive hash edge cases" {
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Known hash values
    const known_hashes = [_]struct {
        data: []const u8,
        offset: usize,
        expected_hash: u256,
        desc: []const u8,
    }{
        .{ .data = "", .offset = 0, .expected_hash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470, .desc = "empty string" },
        .{ .data = "a", .offset = 100, .expected_hash = 0x3ac225168df54212a25c1c01fd35bebfea408fdac2e31ddd6f80a4bbf9a5f1cb, .desc = "single 'a'" },
        .{ .data = "abc", .offset = 200, .expected_hash = 0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45, .desc = "'abc'" },
        .{ .data = "message digest", .offset = 300, .expected_hash = 0x856ab8a3ad0f6168a4d0ba8d77487243f3655db6fc5b0e1669bc05b1287e0147, .desc = "'message digest'" },
    };

    for (known_hashes) |kh| {
        frame.stack.clear();

        // Write data to memory
        if (kh.data.len > 0) {
            for (kh.data, 0..) |byte, i| {
                try frame.memory.set_data(kh.offset + i, &[_]u8{byte});
            }
        }

        // Hash it (size pushed first, offset on top for first pop)
        try frame.stack.append(kh.data.len); // size (will be popped 2nd)
        try frame.stack.append(kh.offset); // offset (will be popped 1st)
        _ = try evm.table.execute(0, interpreter, state, 0x20);
        const result = try frame.stack.peek_n(0);
        try testing.expectEqual(kh.expected_hash, result);
        _ = try frame.stack.pop();
    }

    // Test 2: Different data lengths
    const test_lengths = [_]usize{ 1, 31, 32, 33, 63, 64, 65, 127, 128, 255, 256, 1023, 1024 };

    for (test_lengths) |length| {
        frame.stack.clear();

        // Fill memory with pattern
        for (0..length) |i| {
            try frame.memory.set_data(i, &[_]u8{@as(u8, @intCast(i & 0xFF))});
        }

        try frame.stack.append(length); // size (will be popped 2nd)
        try frame.stack.append(0); // offset (will be popped 1st)
        _ = try evm.table.execute(0, interpreter, state, 0x20);

        // Verify we got a hash (non-zero)
        const hash = try frame.stack.pop();
        try testing.expect(hash != 0);
    }

    // Test 3: Same data, different offsets should give same hash
    frame.stack.clear();
    const test_data = "test data for offset comparison";

    // Write at offset 0
    for (test_data, 0..) |byte, i| {
        try frame.memory.set_data(0 + i, &[_]u8{byte});
    }
    try frame.stack.append(test_data.len); // size (will be popped 2nd)
    try frame.stack.append(0); // offset (will be popped 1st)
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const hash1 = try frame.stack.pop();

    // Write at offset 1000
    for (test_data, 0..) |byte, i| {
        try frame.memory.set_data(1000 + i, &[_]u8{byte});
    }
    try frame.stack.append(test_data.len); // size (will be popped 2nd)
    try frame.stack.append(1000); // offset (will be popped 1st)
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const hash2 = try frame.stack.pop();

    try testing.expectEqual(hash1, hash2);
}

test "KECCAK256: Gas consumption patterns" {
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test gas consumption for different sizes
    const test_cases = [_]struct {
        size: usize,
        offset: usize,
        expected_word_gas: u64,
        desc: []const u8,
    }{
        .{ .size = 0, .offset = 0, .expected_word_gas = 0, .desc = "empty data" },
        .{ .size = 1, .offset = 0, .expected_word_gas = 6, .desc = "1 byte = 1 word" },
        .{ .size = 31, .offset = 0, .expected_word_gas = 6, .desc = "31 bytes = 1 word" },
        .{ .size = 32, .offset = 0, .expected_word_gas = 6, .desc = "32 bytes = 1 word" },
        .{ .size = 33, .offset = 0, .expected_word_gas = 12, .desc = "33 bytes = 2 words" },
        .{ .size = 64, .offset = 0, .expected_word_gas = 12, .desc = "64 bytes = 2 words" },
        .{ .size = 96, .offset = 0, .expected_word_gas = 18, .desc = "96 bytes = 3 words" },
        .{ .size = 256, .offset = 0, .expected_word_gas = 48, .desc = "256 bytes = 8 words" },
    };

    for (test_cases) |tc| {
        frame.stack.clear();

        // Pre-expand memory to isolate hash gas cost
        if (tc.offset + tc.size > 0) {
            _ = try frame.memory.ensure_context_capacity(tc.offset + tc.size);
        }

        const gas_before = frame.gas_remaining;
        try frame.stack.append(tc.size); // size (will be popped 2nd)
        try frame.stack.append(tc.offset); // offset (will be popped 1st)
        _ = try evm.table.execute(0, interpreter, state, 0x20);
        const gas_after = frame.gas_remaining;

        const gas_used = gas_before - gas_after;
        // Gas should be 30 (base) + word_gas
        try testing.expectEqual(30 + tc.expected_word_gas, gas_used);
        _ = try frame.stack.pop();
    }
}

test "KECCAK256: Memory expansion edge cases" {
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test 1: Hash requiring memory expansion
    const large_offset = 10000;
    const size = 32;

    try frame.stack.append(size); // size (will be popped 2nd)
    try frame.stack.append(large_offset); // offset (will be popped 1st)
    _ = try evm.table.execute(0, interpreter, state, 0x20);

    // Memory should have expanded
    try testing.expect(frame.memory.size() >= large_offset + size);
    _ = try frame.stack.pop();

    // Test 2: Offset + size overflow
    frame.stack.clear();
    const overflow_offset = std.math.maxInt(u256) - 10;
    const overflow_size = 20;

    try frame.stack.append(overflow_size); // size (will be popped 2nd)
    try frame.stack.append(overflow_offset); // offset (will be popped 1st)
    try testing.expectError(ExecutionError.Error.OutOfOffset, evm.table.execute(0, interpreter, state, 0x20));

    // Test 3: Size too large for available gas
    frame.stack.clear();
    frame.gas_remaining = 100; // Very limited gas
    const huge_size = 100000; // Would require lots of gas

    try frame.stack.append(huge_size); // size (will be popped 2nd)
    try frame.stack.append(0); // offset (will be popped 1st)
    try testing.expectError(ExecutionError.Error.OutOfGas, evm.table.execute(0, interpreter, state, 0x20));
}

// ============================
// Combined Shift Tests
// ============================
test "Shifts: Combined operations and properties" {
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test: (x << n) >> n = x for n < 256 (if no overflow)
    const test_values = [_]u256{ 1, 42, 0xFF, 0x1234, 0xDEADBEEF };
    const test_shifts = [_]u8{ 1, 8, 16, 32, 64, 128 };

    for (test_values) |val| {
        for (test_shifts) |shift| {
            frame.stack.clear();

            // Only test if value won't overflow
            if (@clz(val) >= shift) {
                // Shift left
                try frame.stack.append(val); // value (stays on stack, gets replaced)
                try frame.stack.append(shift); // shift amount (gets popped)
                _ = try evm.table.execute(0, interpreter, state, 0x1B);
                const shifted_left = try frame.stack.pop();

                // Shift right
                try frame.stack.append(shifted_left); // value (stays on stack, gets replaced)
                try frame.stack.append(shift); // shift amount (gets popped)
                _ = try evm.table.execute(0, interpreter, state, 0x1C);
                const result = try frame.stack.pop();

                try testing.expectEqual(val, result);
            }
        }
    }

    // Test: SAR preserves sign for negative numbers
    frame.stack.clear();

    // Create a negative number with pattern
    const negative_val = std.math.maxInt(u256) - 0xDEADBEEF;

    // SAR by 4
    try frame.stack.append(negative_val); // value (stays on stack, gets replaced)
    try frame.stack.append(4); // shift amount (gets popped)
    _ = try evm.table.execute(0, interpreter, state, 0x1D);
    const sar_result = try frame.stack.pop();

    // Check MSB is still 1 (negative)
    try testing.expect((sar_result >> 255) == 1);

    // Test: Shift by amount stored in memory (via hash)
    frame.stack.clear();

    // Store shift amount (8) in memory at offset 0
    try frame.memory.set_data(0, &[_]u8{8});

    // Hash it to get a deterministic value
    try frame.stack.append(0); // offset
    try frame.stack.append(1); // size
    _ = try evm.table.execute(0, interpreter, state, 0x20);
    const hash_of_8 = try frame.stack.pop();

    // Use lower bits as shift amount (should be non-zero)
    const shift_from_hash = hash_of_8 & 0xFF;
    try testing.expect(shift_from_hash != 0);

    // Perform shift with this amount
    try frame.stack.append(0xFF00); // value (stays on stack, gets replaced)
    try frame.stack.append(shift_from_hash); // shift amount (gets popped)
    _ = try evm.table.execute(0, interpreter, state, 0x1C);
    const shifted_by_hash = try frame.stack.pop();

    // Just verify we got a result, since the exact value depends on the hash
    try testing.expect(shifted_by_hash <= 0xFF00);
}

// ============================
// Error Cases for All Opcodes
// ============================
test "Shift and Crypto: Stack underflow errors" {
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test all shift opcodes with empty stack
    const shift_opcodes = [_]u8{ 0x1B, 0x1C, 0x1D }; // SHL, SHR, SAR

    for (shift_opcodes) |opcode| {
        frame.stack.clear();
        try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(0, interpreter, state, opcode));

        // With only one item
        try frame.stack.append(42);
        try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(0, interpreter, state, opcode));
        frame.stack.clear();
    }

    // Test KECCAK256 with insufficient stack
    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(0, interpreter, state, 0x20));

    try frame.stack.append(100);
    try testing.expectError(ExecutionError.Error.StackUnderflow, evm.table.execute(0, interpreter, state, 0x20));
}

// ============================
// Performance and Stress Tests
// ============================
test "Performance: Rapid shift operations" {
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Perform many shift operations in sequence
    var value: u256 = 0xDEADBEEFCAFEBABE;

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        frame.stack.clear();

        // Shift left by i % 8
        const shift_amount = i % 8;
        try frame.stack.append(value); // value (stays on stack, gets replaced)
        try frame.stack.append(shift_amount); // shift amount (gets popped)
        _ = try evm.table.execute(0, interpreter, state, 0x1B);
        value = try frame.stack.pop();

        // Shift right by (i + 1) % 8
        const shift_right = (i + 1) % 8;
        try frame.stack.append(value); // value (stays on stack, gets replaced)
        try frame.stack.append(shift_right); // shift amount (gets popped)
        _ = try evm.table.execute(0, interpreter, state, 0x1C);
        value = try frame.stack.pop();

        // SAR by i % 4
        const sar_amount = i % 4;
        try frame.stack.append(value); // value (stays on stack, gets replaced)
        try frame.stack.append(sar_amount); // shift amount (gets popped)
        _ = try evm.table.execute(0, interpreter, state, 0x1D);
        value = try frame.stack.pop();
    }

    // Value should have changed
    try testing.expect(value != 0xDEADBEEFCAFEBABE);
}

test "KECCAK256: Hash collision resistance" {
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

    // Initialize stack for tests that directly use frame.stack
    frame.stack.ensureInitialized();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Hash different inputs and verify they produce different outputs
    var hashes = std.AutoHashMap(u256, usize).init(allocator);
    defer hashes.deinit();

    // Test sequential values
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        frame.stack.clear();

        // Write i to memory
        try frame.memory.set_data(0, &[_]u8{@as(u8, @intCast(i & 0xFF))});
        try frame.memory.set_data(1, &[_]u8{@as(u8, @intCast((i >> 8) & 0xFF))});
        try frame.memory.set_data(2, &[_]u8{@as(u8, @intCast((i >> 16) & 0xFF))});
        try frame.memory.set_data(3, &[_]u8{@as(u8, @intCast((i >> 24) & 0xFF))});

        // Hash 4 bytes
        try frame.stack.append(4); // size (will be popped 2nd)
        try frame.stack.append(0); // offset (will be popped 1st)
        _ = try evm.table.execute(0, interpreter, state, 0x20);
        const hash = try frame.stack.pop();

        // Check for collisions
        if (hashes.get(hash)) |existing| {
            // Collision found
            _ = existing;
            try testing.expect(false);
        }

        try hashes.put(hash, i);
    }

    // All hashes should be unique
    try testing.expectEqual(@as(usize, 100), hashes.count());
}
