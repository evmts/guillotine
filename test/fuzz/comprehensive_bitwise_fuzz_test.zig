const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const testing = std.testing;

// Helper function to create a minimal EVM execution context
fn create_evm_context(allocator: std.mem.Allocator) !struct {
    db: evm.MemoryDatabase,
    vm: evm.Evm,
    contract: evm.Contract,
    frame: evm.Frame,
} {
    var db = evm.MemoryDatabase.init(allocator);
    const config = evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.Evm(config);
    var vm = try EvmType.init(allocator, db.to_database_interface(), null, 0, false, null);

    const test_code = [_]u8{0x01}; // Simple ADD opcode
    var contract = evm.Contract.init(primitives.Address.ZERO, primitives.Address.ZERO, 0, 1000000, &test_code, [_]u8{0} ** 32, &.{}, false);

    var frame = try evm.Frame.init(allocator, &contract);
    frame.gas_remaining = 1000000;

    return .{
        .db = db,
        .vm = vm,
        .contract = contract,
        .frame = frame,
    };
}

fn deinit_evm_context(ctx: anytype, allocator: std.mem.Allocator) void {
    ctx.frame.deinit();
    ctx.contract.deinit(allocator, null);
    ctx.vm.deinit();
    ctx.db.deinit();
}

// Comprehensive AND operation fuzz testing
test "fuzz_and_bitwise_and_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    const test_cases = [_]struct { a: u256, b: u256, expected: u256 }{
        // Basic cases
        .{ .a = 0, .b = 0, .expected = 0 },
        .{ .a = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, .b = 0, .expected = 0 },
        .{ .a = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, .b = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, .expected = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF },

        // Power of 2 masking
        .{ .a = 0xFF, .b = 0x0F, .expected = 0x0F },
        .{ .a = 0x123456789ABCDEF0, .b = 0xFFFFFFFFFFFFFFF, .expected = 0x123456789ABCDEF0 & 0xFFFFFFFFFFFFFFF },

        // Bit pattern tests
        .{ .a = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA, .b = 0x5555555555555555555555555555555555555555555555555555555555555555, .expected = 0 },
        .{ .a = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA, .b = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA, .expected = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA },

        // Random bit patterns
        .{ .a = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .b = 0x0FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA98765432, .expected = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0 & 0x0FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA98765432 },

        // Edge cases with single bits
        .{ .a = 1, .b = 1, .expected = 1 },
        .{ .a = 1, .b = 2, .expected = 0 },
        .{ .a = 1 << 255, .b = 1 << 255, .expected = 1 << 255 },
        .{ .a = 1 << 255, .b = 1 << 254, .expected = 0 },
    };

    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(case.a);
        try ctx.frame.stack.append(case.b);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: evm.Operation.State = &ctx.frame;
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x16); // AND

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive OR operation fuzz testing
test "fuzz_or_bitwise_or_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    const test_cases = [_]struct { a: u256, b: u256, expected: u256 }{
        // Basic cases
        .{ .a = 0, .b = 0, .expected = 0 },
        .{ .a = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, .b = 0, .expected = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF },
        .{ .a = 0, .b = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, .expected = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF },
        .{ .a = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, .b = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, .expected = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF },

        // Bit combining tests
        .{ .a = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA, .b = 0x5555555555555555555555555555555555555555555555555555555555555555, .expected = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF },
        .{ .a = 0x0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F, .b = 0xF0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0, .expected = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF },

        // Single bit tests
        .{ .a = 1, .b = 2, .expected = 3 },
        .{ .a = 1 << 255, .b = 1 << 254, .expected = (1 << 255) | (1 << 254) },
        .{ .a = 0x8000000000000000000000000000000000000000000000000000000000000000, .b = 0x1, .expected = 0x8000000000000000000000000000000000000000000000000000000000000001 },

        // Pattern combinations
        .{ .a = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .b = 0x0FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA98765432, .expected = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0 | 0x0FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA98765432 },
    };

    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(case.a);
        try ctx.frame.stack.append(case.b);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: evm.Operation.State = &ctx.frame;
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x17); // OR

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive XOR operation fuzz testing
test "fuzz_xor_bitwise_xor_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    const test_cases = [_]struct { a: u256, b: u256, expected: u256 }{
        // Basic cases
        .{ .a = 0, .b = 0, .expected = 0 },
        .{ .a = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, .b = 0, .expected = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF },
        .{ .a = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, .b = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, .expected = 0 },

        // Self XOR (should always be 0)
        .{ .a = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .b = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .expected = 0 },
        .{ .a = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA, .b = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA, .expected = 0 },

        // Bit flipping
        .{ .a = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA, .b = 0x5555555555555555555555555555555555555555555555555555555555555555, .expected = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF },
        .{ .a = 0x0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F, .b = 0xF0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0, .expected = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF },

        // Single bit XOR
        .{ .a = 1, .b = 1, .expected = 0 },
        .{ .a = 1, .b = 3, .expected = 2 },
        .{ .a = 1 << 255, .b = 1 << 255, .expected = 0 },
        .{ .a = 1 << 255, .b = 1 << 254, .expected = (1 << 255) | (1 << 254) },

        // XOR with all 1s (bit flip)
        .{ .a = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .b = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, .expected = ~@as(u256, 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0) },
    };

    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(case.a);
        try ctx.frame.stack.append(case.b);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: evm.Operation.State = &ctx.frame;
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x18); // XOR

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive NOT operation fuzz testing
test "fuzz_not_bitwise_not_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    const test_cases = [_]struct { a: u256, expected: u256 }{
        // Basic cases
        .{ .a = 0, .expected = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF },
        .{ .a = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, .expected = 0 },

        // Single bit cases
        .{ .a = 1, .expected = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE },
        .{ .a = 1 << 255, .expected = ~(@as(u256, 1) << 255) },

        // Pattern cases
        .{ .a = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA, .expected = 0x5555555555555555555555555555555555555555555555555555555555555555 },
        .{ .a = 0x5555555555555555555555555555555555555555555555555555555555555555, .expected = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA },
        .{ .a = 0x0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F, .expected = 0xF0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0 },

        // Double NOT should return original (a == ~~a)
        .{ .a = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .expected = ~@as(u256, 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0) },
    };

    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(case.a);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: evm.Operation.State = &ctx.frame;
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x19); // NOT

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive BYTE operation fuzz testing
test "fuzz_byte_byte_extraction_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    const test_cases = [_]struct { i: u256, val: u256, expected: u256 }{
        // Basic byte extraction
        .{ .i = 0, .val = 0xFF00000000000000000000000000000000000000000000000000000000000000, .expected = 0xFF },
        .{ .i = 1, .val = 0x00FF000000000000000000000000000000000000000000000000000000000000, .expected = 0xFF },
        .{ .i = 31, .val = 0x00000000000000000000000000000000000000000000000000000000000000FF, .expected = 0xFF },

        // Out of bounds (should return 0)
        .{ .i = 32, .val = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .expected = 0 },
        .{ .i = 100, .val = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .expected = 0 },
        .{ .i = std.math.maxInt(u256), .val = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .expected = 0 },

        // Zero value
        .{ .i = 0, .val = 0, .expected = 0 },
        .{ .i = 15, .val = 0, .expected = 0 },
        .{ .i = 31, .val = 0, .expected = 0 },

        // Max value
        .{ .i = 0, .val = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, .expected = 0xFF },
        .{ .i = 31, .val = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, .expected = 0xFF },

        // Pattern extraction
        .{ .i = 0, .val = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .expected = 0x12 },
        .{ .i = 1, .val = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .expected = 0x34 },
        .{ .i = 2, .val = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .expected = 0x56 },
        .{ .i = 31, .val = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .expected = 0xF0 },
    };

    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(case.i);
        try ctx.frame.stack.append(case.val);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: evm.Operation.State = &ctx.frame;
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x1A); // BYTE

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive SHL (Shift Left) operation fuzz testing
test "fuzz_shl_shift_left_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    const test_cases = [_]struct { shift: u256, value: u256, expected: u256 }{
        // Basic shifts
        .{ .shift = 0, .value = 0x123456789ABCDEF0, .expected = 0x123456789ABCDEF0 },
        .{ .shift = 1, .value = 0x123456789ABCDEF0, .expected = 0x2468ACF13579BDE0 },
        .{ .shift = 4, .value = 0x123456789ABCDEF0, .expected = 0x123456789ABCDEF00 },
        .{ .shift = 8, .value = 0x123456789ABCDEF0, .expected = 0x123456789ABCDEF000 },

        // Edge cases with zero
        .{ .shift = 0, .value = 0, .expected = 0 },
        .{ .shift = 100, .value = 0, .expected = 0 },
        .{ .shift = std.math.maxInt(u256), .value = 0, .expected = 0 },

        // Large shifts (should shift out all bits)
        .{ .shift = 256, .value = 0x123456789ABCDEF0, .expected = 0 },
        .{ .shift = 300, .value = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, .expected = 0 },
        .{ .shift = std.math.maxInt(u256), .value = 0x123456789ABCDEF0, .expected = 0 },

        // Boundary shifts
        .{ .shift = 255, .value = 1, .expected = 1 << 255 },
        .{ .shift = 256, .value = 1, .expected = 0 }, // Shifts out completely
        .{ .shift = 1, .value = 1 << 255, .expected = 0 }, // Overflow

        // Pattern shifts
        .{ .shift = 4, .value = 0x0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F, .expected = 0xF0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0 },
        .{ .shift = 128, .value = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, .expected = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000000000000000000000000000 },
    };

    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(case.shift);
        try ctx.frame.stack.append(case.value);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: evm.Operation.State = &ctx.frame;
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x1B); // SHL

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive SHR (Shift Right) operation fuzz testing
test "fuzz_shr_shift_right_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    const test_cases = [_]struct { shift: u256, value: u256, expected: u256 }{
        // Basic shifts
        .{ .shift = 0, .value = 0x123456789ABCDEF0, .expected = 0x123456789ABCDEF0 },
        .{ .shift = 1, .value = 0x123456789ABCDEF0, .expected = 0x091A2B3C4D5E6F78 },
        .{ .shift = 4, .value = 0x123456789ABCDEF0, .expected = 0x0123456789ABCDEF },
        .{ .shift = 8, .value = 0x123456789ABCDEF0, .expected = 0x00123456789ABCDE },

        // Edge cases with zero
        .{ .shift = 0, .value = 0, .expected = 0 },
        .{ .shift = 100, .value = 0, .expected = 0 },

        // Large shifts (should shift out all bits)
        .{ .shift = 256, .value = 0x123456789ABCDEF0, .expected = 0 },
        .{ .shift = 300, .value = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, .expected = 0 },
        .{ .shift = std.math.maxInt(u256), .value = 0x123456789ABCDEF0, .expected = 0 },

        // Boundary shifts
        .{ .shift = 255, .value = 1 << 255, .expected = 1 },
        .{ .shift = 256, .value = 1 << 255, .expected = 0 },
        .{ .shift = 1, .value = 1, .expected = 0 },

        // Pattern shifts
        .{ .shift = 4, .value = 0xF0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0, .expected = 0x0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F },
        .{ .shift = 128, .value = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000000000000000000000000000, .expected = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF },

        // Max value shifts
        .{ .shift = 1, .value = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, .expected = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF },
        .{ .shift = 8, .value = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, .expected = 0x00FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF },
    };

    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(case.shift);
        try ctx.frame.stack.append(case.value);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: evm.Operation.State = &ctx.frame;
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x1C); // SHR

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive SAR (Arithmetic Shift Right) operation fuzz testing
test "fuzz_sar_arithmetic_shift_right_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    // Helper to convert signed to u256 (two's complement)
    const toU256 = struct {
        fn call(val: i256) u256 {
            return @bitCast(val);
        }
    }.call;

    const test_cases = [_]struct { shift: u256, value: u256, expected: u256 }{
        // Positive number shifts (same as SHR)
        .{ .shift = 0, .value = 0x123456789ABCDEF0, .expected = 0x123456789ABCDEF0 },
        .{ .shift = 1, .value = 0x123456789ABCDEF0, .expected = 0x091A2B3C4D5E6F78 },
        .{ .shift = 4, .value = 0x123456789ABCDEF0, .expected = 0x0123456789ABCDEF },

        // Negative number shifts (sign extend)
        .{ .shift = 1, .value = toU256(-1), .expected = toU256(-1) }, // -1 >> 1 = -1
        .{ .shift = 1, .value = toU256(-2), .expected = toU256(-1) }, // -2 >> 1 = -1
        .{ .shift = 1, .value = toU256(-4), .expected = toU256(-2) }, // -4 >> 1 = -2
        .{ .shift = 2, .value = toU256(-4), .expected = toU256(-1) }, // -4 >> 2 = -1

        // Large negative shifts
        .{ .shift = 255, .value = toU256(-1), .expected = toU256(-1) },
        .{ .shift = 256, .value = toU256(-1), .expected = toU256(-1) }, // Should remain -1
        .{ .shift = 300, .value = toU256(-2), .expected = toU256(-1) },

        // Edge case: most negative value
        .{ .shift = 1, .value = toU256(std.math.minInt(i256)), .expected = toU256(std.math.minInt(i256) >> 1) },
        .{ .shift = 255, .value = toU256(std.math.minInt(i256)), .expected = toU256(-1) },

        // Zero shifts
        .{ .shift = 0, .value = toU256(-100), .expected = toU256(-100) },
        .{ .shift = 100, .value = 0, .expected = 0 },

        // Large shifts on negative numbers should result in -1
        .{ .shift = 256, .value = toU256(-12345), .expected = toU256(-1) },
        .{ .shift = std.math.maxInt(u256), .value = toU256(-1), .expected = toU256(-1) },
    };

    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(case.shift);
        try ctx.frame.stack.append(case.value);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: evm.Operation.State = &ctx.frame;
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x1D); // SAR

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Random bitwise operations stress test
test "fuzz_bitwise_random_stress_test" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Test many random combinations to catch edge cases
    for (0..500) |_| {
        const a = random.int(u256);
        const b = random.int(u256);
        const shift = random.intRangeAtMost(u256, 0, 300); // Test shifts beyond 256

        // Test AND
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }

            try ctx.frame.stack.append(a);
            try ctx.frame.stack.append(b);

            var interpreter: evm.Operation.Interpreter = &ctx.vm;
            var state: evm.Operation.State = &ctx.frame;
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x16); // AND

            const result = try ctx.frame.stack.pop();
            const expected = a & b;
            try testing.expectEqual(expected, result);
        }

        // Test OR
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }

            try ctx.frame.stack.append(a);
            try ctx.frame.stack.append(b);

            var interpreter: evm.Operation.Interpreter = &ctx.vm;
            var state: evm.Operation.State = &ctx.frame;
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x17); // OR

            const result = try ctx.frame.stack.pop();
            const expected = a | b;
            try testing.expectEqual(expected, result);
        }

        // Test XOR
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }

            try ctx.frame.stack.append(a);
            try ctx.frame.stack.append(b);

            var interpreter: evm.Operation.Interpreter = &ctx.vm;
            var state: evm.Operation.State = &ctx.frame;
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x18); // XOR

            const result = try ctx.frame.stack.pop();
            const expected = a ^ b;
            try testing.expectEqual(expected, result);
        }

        // Test SHL (shift left)
        if (shift < 256) {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }

            try ctx.frame.stack.append(shift);
            try ctx.frame.stack.append(a);

            var interpreter: evm.Operation.Interpreter = &ctx.vm;
            var state: evm.Operation.State = &ctx.frame;
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x1B); // SHL

            const result = try ctx.frame.stack.pop();
            const expected = if (shift >= 256) 0 else a << @intCast(shift);
            try testing.expectEqual(expected, result);
        }
    }
}
