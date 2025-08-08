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
// LT (0x10) - Comprehensive Tests
// ============================
test "LT: Comprehensive edge cases" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test cases with specific bit patterns
    const test_cases = [_]struct {
        a: u256,
        b: u256,
        expected: u256,
        desc: []const u8,
    }{
        // Basic cases
        .{ .a = 0, .b = 0, .expected = 0, .desc = "0 < 0 = false" },
        .{ .a = 0, .b = 1, .expected = 1, .desc = "0 < 1 = true" },
        .{ .a = 1, .b = 0, .expected = 0, .desc = "1 < 0 = false" },
        .{ .a = 1, .b = 1, .expected = 0, .desc = "1 < 1 = false" },

        // Powers of 2
        .{ .a = 1, .b = 2, .expected = 1, .desc = "1 < 2 = true" },
        .{ .a = 2, .b = 4, .expected = 1, .desc = "2 < 4 = true" },
        .{ .a = @as(u256, 1) << 127, .b = @as(u256, 1) << 128, .expected = 1, .desc = "2^127 < 2^128" },
        .{ .a = @as(u256, 1) << 255, .b = std.math.maxInt(u256), .expected = 1, .desc = "2^255 < MAX" },

        // Max value cases
        .{ .a = std.math.maxInt(u256), .b = std.math.maxInt(u256), .expected = 0, .desc = "MAX < MAX = false" },
        .{ .a = std.math.maxInt(u256) - 1, .b = std.math.maxInt(u256), .expected = 1, .desc = "MAX-1 < MAX = true" },
        .{ .a = std.math.maxInt(u256), .b = 0, .expected = 0, .desc = "MAX < 0 = false" },

        // Interesting bit patterns
        .{ .a = 0x5555555555555555, .b = 0xAAAAAAAAAAAAAAAA, .expected = 1, .desc = "alternating 01 < alternating 10" },
        .{ .a = 0xFFFFFFFF00000000, .b = 0xFFFFFFFF00000001, .expected = 1, .desc = "high bits same, low different" },

        // Adjacent values
        .{ .a = 999999, .b = 1000000, .expected = 1, .desc = "999999 < 1000000" },
        .{ .a = @as(u256, 1) << 64, .b = (@as(u256, 1) << 64) + 1, .expected = 1, .desc = "2^64 < 2^64+1" },
    };

    for (test_cases) |tc| {
        frame.stack.clear();
        try frame.stack.append(tc.b);
        try frame.stack.append(tc.a);
        _ = try evm.table.execute(0, interpreter, state, 0x10);
        const result = try frame.stack.pop();
        try testing.expectEqual(tc.expected, result);
    }
}

// ============================
// GT (0x11) - Comprehensive Tests
// ============================
test "GT: Comprehensive edge cases" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    const test_cases = [_]struct {
        a: u256,
        b: u256,
        expected: u256,
        desc: []const u8,
    }{
        // Basic cases
        .{ .a = 0, .b = 0, .expected = 0, .desc = "0 > 0 = false" },
        .{ .a = 1, .b = 0, .expected = 1, .desc = "1 > 0 = true" },
        .{ .a = 0, .b = 1, .expected = 0, .desc = "0 > 1 = false" },

        // Large numbers
        .{ .a = std.math.maxInt(u256), .b = std.math.maxInt(u256) - 1, .expected = 1, .desc = "MAX > MAX-1" },
        .{ .a = @as(u256, 1) << 200, .b = @as(u256, 1) << 199, .expected = 1, .desc = "2^200 > 2^199" },

        // Relationship to LT (a > b iff b < a)
        .{ .a = 100, .b = 50, .expected = 1, .desc = "100 > 50" },
        .{ .a = 50, .b = 100, .expected = 0, .desc = "50 > 100 = false" },
    };

    for (test_cases) |tc| {
        frame.stack.clear();
        try frame.stack.append(tc.b);
        try frame.stack.append(tc.a);
        _ = try evm.table.execute(0, interpreter, state, 0x11);
        const result = try frame.stack.pop();
        try testing.expectEqual(tc.expected, result);
    }
}

// ============================
// SLT (0x12) - Comprehensive Tests
// ============================
test "SLT: Comprehensive signed comparison cases" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Helper to convert signed to two's complement u256
    const to_twos_complement = struct {
        fn convert(val: i256) u256 {
            return @as(u256, @bitCast(val));
        }
    }.convert;

    const test_cases = [_]struct {
        a: u256,
        b: u256,
        expected: u256,
        desc: []const u8,
    }{
        // Zero comparisons
        .{ .a = 0, .b = 0, .expected = 0, .desc = "0 < 0 = false" },
        .{ .a = 0, .b = 1, .expected = 1, .desc = "0 < 1 = true" },
        .{ .a = 0, .b = to_twos_complement(-1), .expected = 0, .desc = "0 < -1 = false" },

        // Positive vs Positive
        .{ .a = 1, .b = 2, .expected = 1, .desc = "1 < 2 = true" },
        .{ .a = 1000, .b = 999, .expected = 0, .desc = "1000 < 999 = false" },

        // Negative vs Negative
        .{ .a = to_twos_complement(-1), .b = to_twos_complement(-1), .expected = 0, .desc = "-1 < -1 = false" },
        .{ .a = to_twos_complement(-2), .b = to_twos_complement(-1), .expected = 1, .desc = "-2 < -1 = true" },
        .{ .a = to_twos_complement(-100), .b = to_twos_complement(-50), .expected = 1, .desc = "-100 < -50 = true" },

        // Positive vs Negative
        .{ .a = 1, .b = to_twos_complement(-1), .expected = 0, .desc = "1 < -1 = false" },
        .{ .a = to_twos_complement(-1), .b = 1, .expected = 1, .desc = "-1 < 1 = true" },

        // Boundary cases
        .{ .a = @as(u256, 1) << 255, .b = (@as(u256, 1) << 255) - 1, .expected = 1, .desc = "MIN_I256 < MAX_I256" },
        .{ .a = (@as(u256, 1) << 255) - 1, .b = @as(u256, 1) << 255, .expected = 0, .desc = "MAX_I256 < MIN_I256 = false" },

        // Near-boundary values
        .{ .a = to_twos_complement(-(@as(i256, 1) << 254)), .b = to_twos_complement(-(@as(i256, 1) << 253)), .expected = 1, .desc = "-2^254 < -2^253" },

        // Special patterns
        .{ .a = 0x7FFFFFFFFFFFFFFF, .b = 0x8000000000000000, .expected = 0, .desc = "positive < negative pattern" },
    };

    for (test_cases) |tc| {
        frame.stack.clear();
        try frame.stack.append(tc.b);
        try frame.stack.append(tc.a);
        _ = try evm.table.execute(0, interpreter, state, 0x12);
        const result = try frame.stack.pop();
        try testing.expectEqual(tc.expected, result);
    }
}

// ============================
// SGT (0x13) - Comprehensive Tests
// ============================
test "SGT: Comprehensive signed greater than cases" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    const to_twos_complement = struct {
        fn convert(val: i256) u256 {
            return @as(u256, @bitCast(val));
        }
    }.convert;

    const test_cases = [_]struct {
        a: u256,
        b: u256,
        expected: u256,
        desc: []const u8,
    }{
        // Basic signed comparisons
        .{ .a = 1, .b = 0, .expected = 1, .desc = "1 > 0 = true" },
        .{ .a = 0, .b = to_twos_complement(-1), .expected = 1, .desc = "0 > -1 = true" },
        .{ .a = to_twos_complement(-1), .b = to_twos_complement(-2), .expected = 1, .desc = "-1 > -2 = true" },

        // Cross-sign comparisons
        .{ .a = (@as(u256, 1) << 255) - 1, .b = @as(u256, 1) << 255, .expected = 1, .desc = "MAX_I256 > MIN_I256" },

        // Edge cases with large magnitudes
        .{ .a = to_twos_complement(-(@as(i256, 1) << 200)), .b = to_twos_complement(-(@as(i256, 1) << 201)), .expected = 1, .desc = "-2^200 > -2^201" },
    };

    for (test_cases) |tc| {
        frame.stack.clear();
        try frame.stack.append(tc.b);
        try frame.stack.append(tc.a);
        _ = try evm.table.execute(0, interpreter, state, 0x13);
        const result = try frame.stack.pop();
        try testing.expectEqual(tc.expected, result);
    }
}

// ============================
// EQ (0x14) - Comprehensive Tests
// ============================
test "EQ: Comprehensive equality cases" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    const test_cases = [_]struct {
        a: u256,
        b: u256,
        expected: u256,
        desc: []const u8,
    }{
        // Identity cases
        .{ .a = 0, .b = 0, .expected = 1, .desc = "0 == 0" },
        .{ .a = 1, .b = 1, .expected = 1, .desc = "1 == 1" },
        .{ .a = std.math.maxInt(u256), .b = std.math.maxInt(u256), .expected = 1, .desc = "MAX == MAX" },

        // Non-equal cases
        .{ .a = 0, .b = 1, .expected = 0, .desc = "0 != 1" },
        .{ .a = 1, .b = 0, .expected = 0, .desc = "1 != 0" },

        // Powers of 2
        .{ .a = @as(u256, 1) << 100, .b = @as(u256, 1) << 100, .expected = 1, .desc = "2^100 == 2^100" },
        .{ .a = @as(u256, 1) << 100, .b = @as(u256, 1) << 101, .expected = 0, .desc = "2^100 != 2^101" },

        // Bit patterns
        .{ .a = 0xDEADBEEF, .b = 0xDEADBEEF, .expected = 1, .desc = "same pattern" },
        .{ .a = 0xDEADBEEF, .b = 0xDEADBEE0, .expected = 0, .desc = "one bit different" },

        // Large numbers differing by 1
        .{ .a = (@as(u256, 1) << 200) - 1, .b = @as(u256, 1) << 200, .expected = 0, .desc = "2^200-1 != 2^200" },
    };

    for (test_cases) |tc| {
        frame.stack.clear();
        try frame.stack.append(tc.b);
        try frame.stack.append(tc.a);
        _ = try evm.table.execute(0, interpreter, state, 0x14);
        const result = try frame.stack.pop();
        try testing.expectEqual(tc.expected, result);
    }
}

// ============================
// ISZERO (0x15) - Comprehensive Tests
// ============================
test "ISZERO: Comprehensive zero detection cases" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    const test_cases = [_]struct {
        value: u256,
        expected: u256,
        desc: []const u8,
    }{
        // Zero cases
        .{ .value = 0, .expected = 1, .desc = "0 is zero" },
        .{ .value = 0x0, .expected = 1, .desc = "0x0 is zero" },
        .{ .value = 0b0, .expected = 1, .desc = "0b0 is zero" },

        // Non-zero cases
        .{ .value = 1, .expected = 0, .desc = "1 is not zero" },
        .{ .value = std.math.maxInt(u256), .expected = 0, .desc = "MAX is not zero" },
        .{ .value = @as(u256, 1) << 255, .expected = 0, .desc = "MSB set is not zero" },

        // Small non-zero values
        .{ .value = 0x1, .expected = 0, .desc = "0x1 is not zero" },
        .{ .value = 0xFF, .expected = 0, .desc = "0xFF is not zero" },

        // Powers of 2
        .{ .value = @as(u256, 1) << 0, .expected = 0, .desc = "2^0 = 1 is not zero" },
        .{ .value = @as(u256, 1) << 128, .expected = 0, .desc = "2^128 is not zero" },

        // Special patterns
        .{ .value = 0x8000000000000000, .expected = 0, .desc = "single bit set is not zero" },
        .{ .value = 0xFFFFFFFFFFFFFFFF, .expected = 0, .desc = "low 64 bits set is not zero" },
    };

    for (test_cases) |tc| {
        frame.stack.clear();
        try frame.stack.append(tc.value);
        _ = try evm.table.execute(0, interpreter, state, 0x15);
        const result = try frame.stack.pop();
        try testing.expectEqual(tc.expected, result);
    }
}

// ============================
// AND (0x16) - Comprehensive Tests
// ============================
test "AND: Comprehensive bitwise AND cases" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    const test_cases = [_]struct {
        a: u256,
        b: u256,
        expected: u256,
        desc: []const u8,
    }{
        // Identity and annihilator
        .{ .a = 0xFF, .b = 0, .expected = 0, .desc = "x AND 0 = 0" },
        .{ .a = 0xFF, .b = std.math.maxInt(u256), .expected = 0xFF, .desc = "x AND MAX = x" },

        // Basic operations
        .{ .a = 0b1100, .b = 0b1010, .expected = 0b1000, .desc = "1100 AND 1010 = 1000" },
        .{ .a = 0xFF00, .b = 0x0FF0, .expected = 0x0F00, .desc = "FF00 AND 0FF0 = 0F00" },

        // Masking operations
        .{ .a = 0xDEADBEEF, .b = 0xFFFF0000, .expected = 0xDEAD0000, .desc = "high 16 bits mask" },
        .{ .a = 0xDEADBEEF, .b = 0x0000FFFF, .expected = 0x0000BEEF, .desc = "low 16 bits mask" },

        // Large numbers
        .{ .a = (@as(u256, 0xFF) << 248) | 0xFF, .b = (@as(u256, 0xF0) << 248) | 0x0F, .expected = (@as(u256, 0xF0) << 248) | 0x0F, .desc = "high and low byte operations" },

        // Clearing bits
        .{ .a = std.math.maxInt(u256), .b = ~@as(u256, 1), .expected = std.math.maxInt(u256) - 1, .desc = "clear LSB" },
        .{ .a = std.math.maxInt(u256), .b = ~(@as(u256, 1) << 255), .expected = (@as(u256, 1) << 255) - 1, .desc = "clear MSB" },

        // Self AND
        .{ .a = 0xABCDEF, .b = 0xABCDEF, .expected = 0xABCDEF, .desc = "x AND x = x" },
    };

    for (test_cases) |tc| {
        frame.stack.clear();
        try frame.stack.append(tc.b);
        try frame.stack.append(tc.a);
        _ = try evm.table.execute(0, interpreter, state, 0x16);
        const result = try frame.stack.pop();
        try testing.expectEqual(tc.expected, result);
    }
}

// ============================
// OR (0x17) - Comprehensive Tests
// ============================
test "OR: Comprehensive bitwise OR cases" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    const test_cases = [_]struct {
        a: u256,
        b: u256,
        expected: u256,
        desc: []const u8,
    }{
        // Identity and dominator
        .{ .a = 0xFF, .b = 0, .expected = 0xFF, .desc = "x OR 0 = x" },
        .{ .a = 0xFF, .b = std.math.maxInt(u256), .expected = std.math.maxInt(u256), .desc = "x OR MAX = MAX" },

        // Basic operations
        .{ .a = 0b1100, .b = 0b1010, .expected = 0b1110, .desc = "1100 OR 1010 = 1110" },
        .{ .a = 0xFF00, .b = 0x00FF, .expected = 0xFFFF, .desc = "FF00 OR 00FF = FFFF" },

        // Setting bits
        .{ .a = 0, .b = @as(u256, 1) << 100, .expected = @as(u256, 1) << 100, .desc = "set bit 100" },
        .{ .a = 0xF0F0, .b = 0x0F0F, .expected = 0xFFFF, .desc = "complementary patterns" },

        // Large numbers
        .{ .a = @as(u256, 1) << 255, .b = 1, .expected = (@as(u256, 1) << 255) | 1, .desc = "MSB OR LSB" },

        // Self OR
        .{ .a = 0xABCDEF, .b = 0xABCDEF, .expected = 0xABCDEF, .desc = "x OR x = x" },

        // Building patterns
        .{ .a = 0x00FF00FF, .b = 0xFF00FF00, .expected = 0xFFFFFFFF, .desc = "alternating bytes" },
    };

    for (test_cases) |tc| {
        frame.stack.clear();
        try frame.stack.append(tc.b);
        try frame.stack.append(tc.a);
        _ = try evm.table.execute(0, interpreter, state, 0x17);
        const result = try frame.stack.pop();
        try testing.expectEqual(tc.expected, result);
    }
}

// ============================
// XOR (0x18) - Comprehensive Tests
// ============================
test "XOR: Comprehensive bitwise XOR cases" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    const test_cases = [_]struct {
        a: u256,
        b: u256,
        expected: u256,
        desc: []const u8,
    }{
        // XOR properties
        .{ .a = 0xFF, .b = 0, .expected = 0xFF, .desc = "x XOR 0 = x" },
        .{ .a = 0xFF, .b = 0xFF, .expected = 0, .desc = "x XOR x = 0" },
        .{ .a = 0xFF, .b = std.math.maxInt(u256), .expected = std.math.maxInt(u256) ^ 0xFF, .desc = "x XOR MAX = ~x (for low bits)" },

        // Basic operations
        .{ .a = 0b1100, .b = 0b1010, .expected = 0b0110, .desc = "1100 XOR 1010 = 0110" },

        // Toggle operations
        .{ .a = 0xFF00, .b = 0xFFFF, .expected = 0x00FF, .desc = "toggle high byte" },
        .{ .a = 0xAAAA, .b = 0xFFFF, .expected = 0x5555, .desc = "flip alternating bits" },

        // Bit difference detection
        .{ .a = 0x1234, .b = 0x1235, .expected = 0x0001, .desc = "detect single bit difference" },
        .{ .a = 0xFF00FF00, .b = 0x00FF00FF, .expected = 0xFFFFFFFF, .desc = "all bits different" },

        // Large numbers
        .{ .a = (@as(u256, 1) << 200) - 1, .b = (@as(u256, 1) << 200), .expected = ((@as(u256, 1) << 201) - 1), .desc = "XOR with adjacent powers" },

        // Double XOR (encryption/decryption pattern)
        .{ .a = 0xDEADBEEF, .b = 0x12345678, .expected = 0xDEADBEEF ^ 0x12345678, .desc = "data XOR key" },
    };

    for (test_cases) |tc| {
        frame.stack.clear();
        try frame.stack.append(tc.b);
        try frame.stack.append(tc.a);
        _ = try evm.table.execute(0, interpreter, state, 0x18);
        const result = try frame.stack.pop();
        try testing.expectEqual(tc.expected, result);
    }

    // Test XOR encryption/decryption property
    frame.stack.clear();
    const data: u256 = 0xDEADBEEF;
    const key: u256 = 0x12345678;

    // Encrypt
    try frame.stack.append(key);
    try frame.stack.append(data);
    _ = try evm.table.execute(0, interpreter, state, 0x18);
    const encrypted = try frame.stack.pop();

    // Decrypt
    try frame.stack.append(key);
    try frame.stack.append(encrypted);
    _ = try evm.table.execute(0, interpreter, state, 0x18);
    const decrypted = try frame.stack.pop();

    try testing.expectEqual(data, decrypted);
}

// ============================
// NOT (0x19) - Comprehensive Tests
// ============================
test "NOT: Comprehensive bitwise NOT cases" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    const test_cases = [_]struct {
        value: u256,
        expected: u256,
        desc: []const u8,
    }{
        // Basic cases
        .{ .value = 0, .expected = std.math.maxInt(u256), .desc = "NOT 0 = MAX" },
        .{ .value = std.math.maxInt(u256), .expected = 0, .desc = "NOT MAX = 0" },

        // Single bit patterns
        .{ .value = 1, .expected = std.math.maxInt(u256) - 1, .desc = "NOT 1" },
        .{ .value = @as(u256, 1) << 255, .expected = (@as(u256, 1) << 255) - 1, .desc = "NOT MSB" },

        // Byte patterns
        .{ .value = 0xFF, .expected = std.math.maxInt(u256) - 0xFF, .desc = "NOT 0xFF" },
        .{ .value = 0xFF00, .expected = std.math.maxInt(u256) - 0xFF00, .desc = "NOT 0xFF00" },

        // Alternating patterns
        .{ .value = 0x5555555555555555, .expected = 0xAAAAAAAAAAAAAAAA | (std.math.maxInt(u256) ^ 0xFFFFFFFFFFFFFFFF), .desc = "NOT alternating 01" },

        // Powers of 2 minus 1
        .{ .value = (@as(u256, 1) << 64) - 1, .expected = std.math.maxInt(u256) - ((@as(u256, 1) << 64) - 1), .desc = "NOT (2^64 - 1)" },

        // Double NOT property test
        .{ .value = 0xDEADBEEFCAFEBABE, .expected = ~@as(u256, 0xDEADBEEFCAFEBABE), .desc = "NOT pattern" },
    };

    for (test_cases) |tc| {
        frame.stack.clear();
        try frame.stack.append(tc.value);
        _ = try evm.table.execute(0, interpreter, state, 0x19);
        const result = try frame.stack.pop();
        try testing.expectEqual(tc.expected, result);
    }

    // Test double NOT returns original
    frame.stack.clear();
    const original: u256 = 0x123456789ABCDEF0;
    try frame.stack.append(original);
    _ = try evm.table.execute(0, interpreter, state, 0x19); // NOT
    _ = try evm.table.execute(0, interpreter, state, 0x19); // NOT again
    const result = try frame.stack.pop();
    try testing.expectEqual(original, result);
}

// ============================
// BYTE (0x1A) - Comprehensive Tests
// ============================
test "BYTE: Comprehensive byte extraction cases" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Create a value with known bytes at each position
    var test_value: u256 = 0;
    var i: u8 = 0;
    while (i < 32) : (i += 1) {
        test_value = (test_value << 8) | (i + 1); // Byte 0 = 1, Byte 1 = 2, etc.
    }

    // Test extracting each byte
    i = 0;
    while (i < 32) : (i += 1) {
        frame.stack.clear();
        try frame.stack.append(test_value);
        try frame.stack.append(i);
        _ = try evm.table.execute(0, interpreter, state, 0x1A);
        const result = try frame.stack.pop();
        try testing.expectEqual(@as(u256, i + 1), result);
    }

    // Test out of bounds
    const out_of_bounds_cases = [_]u256{ 32, 33, 100, 1000, std.math.maxInt(u256) };
    for (out_of_bounds_cases) |idx| {
        frame.stack.clear();
        try frame.stack.append(test_value);
        try frame.stack.append(idx);
        _ = try evm.table.execute(0, interpreter, state, 0x1A);
        const result = try frame.stack.pop();
        try testing.expectEqual(@as(u256, 0), result);
    }

    // Test with specific patterns
    const pattern_tests = [_]struct {
        value: u256,
        index: u256,
        expected: u256,
        desc: []const u8,
    }{
        .{ .value = 0xFF << (31 * 8), .index = 0, .expected = 0xFF, .desc = "MSB = 0xFF" },
        .{ .value = 0xAB, .index = 31, .expected = 0xAB, .desc = "LSB = 0xAB" },
        .{ .value = 0xDEADBEEF, .index = 28, .expected = 0xDE, .desc = "Extract 0xDE from 0xDEADBEEF" },
        .{ .value = 0xDEADBEEF, .index = 29, .expected = 0xAD, .desc = "Extract 0xAD from 0xDEADBEEF" },
        .{ .value = 0xDEADBEEF, .index = 30, .expected = 0xBE, .desc = "Extract 0xBE from 0xDEADBEEF" },
        .{ .value = 0xDEADBEEF, .index = 31, .expected = 0xEF, .desc = "Extract 0xEF from 0xDEADBEEF" },
        .{ .value = 0, .index = 15, .expected = 0, .desc = "Extract from zero" },
    };

    for (pattern_tests) |tc| {
        frame.stack.clear();
        try frame.stack.append(tc.value);
        try frame.stack.append(tc.index);
        _ = try evm.table.execute(0, interpreter, state, 0x1A);
        const result = try frame.stack.pop();
        try testing.expectEqual(tc.expected, result);
    }
}

// ============================
// Combined Operations Tests
// ============================
test "Combined: Complex bitwise and comparison operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Test: (a AND b) == (a OR b) only when a == b
    const test_values = [_]u256{ 0, 1, 0xFF, 0xDEADBEEF, std.math.maxInt(u256) };

    for (test_values) |val| {
        frame.stack.clear();

        // Calculate a AND a
        try frame.stack.append(val);
        try frame.stack.append(val);
        _ = try evm.table.execute(0, interpreter, state, 0x16);
        const and_result = try frame.stack.pop();

        // Calculate a OR a
        try frame.stack.append(val);
        try frame.stack.append(val);
        _ = try evm.table.execute(0, interpreter, state, 0x17);
        const or_result = try frame.stack.pop();

        // They should be equal
        try testing.expectEqual(and_result, or_result);
        try testing.expectEqual(and_result, val);
    }

    // Test: Comparison results can be used as masks
    frame.stack.clear();

    // Create a comparison result (5 < 10) = 1
    try frame.stack.append(10);
    try frame.stack.append(5);
    _ = try evm.table.execute(0, interpreter, state, 0x10); // LT

    // Use it as a mask with AND
    try frame.stack.append(0xFFFFFFFF);
    _ = try evm.table.execute(0, interpreter, state, 0x16); // AND
    const masked_result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), masked_result); // 0xFFFFFFFF AND 1 = 1

    // Test: Building conditional values using comparisons
    frame.stack.clear();

    // Test that comparison results (0 or 1) can be used for conditional logic
    // Case 1: true comparison
    try frame.stack.append(10);
    try frame.stack.append(5);
    _ = try evm.table.execute(0, interpreter, state, 0x10); // LT = 1
    const true_result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), true_result);

    // Case 2: false comparison
    try frame.stack.append(5);
    try frame.stack.append(10);
    _ = try evm.table.execute(0, interpreter, state, 0x10); // LT = 0
    const false_result = try frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), false_result);
}

// ============================
// Performance Stress Tests
// ============================
test "Performance: Rapid successive operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Perform 100 mixed operations
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        frame.stack.clear();

        // Push some values
        try frame.stack.append(i * 3);
        try frame.stack.append(i * 2);
        try frame.stack.append(i + 1);
        try frame.stack.append(i);

        // Do various operations
        _ = try evm.table.execute(0, interpreter, state, 0x10); // LT
        _ = try evm.table.execute(0, interpreter, state, 0x16); // AND
        _ = try evm.table.execute(0, interpreter, state, 0x19); // NOT

        // Verify stack has one result
        try testing.expectEqual(@as(usize, 1), frame.stack.size);
        _ = try frame.stack.pop();
    }
}
