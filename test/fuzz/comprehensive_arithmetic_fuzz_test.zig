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

// Comprehensive ADD operation fuzz testing
test "fuzz_add_extensive_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    const test_cases = [_]struct { a: u256, b: u256, expected: u256 }{
        // Basic cases
        .{ .a = 0, .b = 0, .expected = 0 },
        .{ .a = 1, .b = 1, .expected = 2 },
        .{ .a = 100, .b = 200, .expected = 300 },

        // Edge cases with maximum values
        .{ .a = std.math.maxInt(u256), .b = 0, .expected = std.math.maxInt(u256) },
        .{ .a = std.math.maxInt(u256), .b = 1, .expected = 0 }, // Overflow wraps
        .{ .a = std.math.maxInt(u256), .b = std.math.maxInt(u256), .expected = std.math.maxInt(u256) -% 1 },

        // Power of 2 boundaries
        .{ .a = (1 << 128) - 1, .b = 1, .expected = 1 << 128 },
        .{ .a = 1 << 255, .b = 1 << 255, .expected = 0 }, // Overflow

        // Random large values that might expose bugs
        .{ .a = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .b = 0x0FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA98765432, .expected = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0 +% 0x0FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA98765432 },
    };

    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        // Push operands
        try ctx.frame.stack.append(case.a);
        try ctx.frame.stack.append(case.b);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: *evm.Operation.State = @ptrCast(&ctx.frame);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x01); // ADD

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive MUL operation fuzz testing
test "fuzz_mul_comprehensive_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    const test_cases = [_]struct { a: u256, b: u256, expected: u256 }{
        // Basic cases
        .{ .a = 0, .b = 0, .expected = 0 },
        .{ .a = 1, .b = 1, .expected = 1 },
        .{ .a = 0, .b = std.math.maxInt(u256), .expected = 0 },
        .{ .a = 1, .b = std.math.maxInt(u256), .expected = std.math.maxInt(u256) },
        .{ .a = 2, .b = 3, .expected = 6 },
        .{ .a = 10, .b = 10, .expected = 100 },

        // Overflow cases
        .{ .a = std.math.maxInt(u128), .b = std.math.maxInt(u128), .expected = (@as(u256, std.math.maxInt(u128)) * std.math.maxInt(u128)) },
        .{ .a = std.math.maxInt(u256), .b = 2, .expected = std.math.maxInt(u256) -% 1 }, // Wrapping multiply

        // Large prime numbers (good for finding edge cases)
        .{ .a = 982451653, .b = 982451653, .expected = @as(u256, 982451653) * 982451653 },

        // Powers of 2
        .{ .a = 1 << 128, .b = 1 << 127, .expected = 1 << 255 },
        .{ .a = 1 << 128, .b = 1 << 128, .expected = 0 }, // Overflow wraps to 0
    };

    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(case.a);
        try ctx.frame.stack.append(case.b);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: *evm.Operation.State = @ptrCast(&ctx.frame);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x02); // MUL

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive SUB operation fuzz testing
test "fuzz_sub_underflow_and_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    const test_cases = [_]struct { a: u256, b: u256, expected: u256 }{
        // Basic cases
        .{ .a = 10, .b = 5, .expected = 5 },
        .{ .a = 0, .b = 0, .expected = 0 },
        .{ .a = std.math.maxInt(u256), .b = 1, .expected = std.math.maxInt(u256) - 1 },

        // Underflow cases (should wrap around)
        .{ .a = 0, .b = 1, .expected = std.math.maxInt(u256) }, // 0 - 1 wraps to max
        .{ .a = 5, .b = 10, .expected = 5 -% 10 }, // Wrapping subtraction
        .{ .a = 1, .b = std.math.maxInt(u256), .expected = 1 -% std.math.maxInt(u256) },

        // Edge cases with identical values
        .{ .a = std.math.maxInt(u256), .b = std.math.maxInt(u256), .expected = 0 },
        .{ .a = 12345678901234567890, .b = 12345678901234567890, .expected = 0 },
    };

    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(case.a);
        try ctx.frame.stack.append(case.b);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: *evm.Operation.State = @ptrCast(&ctx.frame);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x03); // SUB

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive DIV operation fuzz testing
test "fuzz_div_division_by_zero_and_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    const test_cases = [_]struct { a: u256, b: u256, expected: u256 }{
        // Division by zero cases (should return 0)
        .{ .a = 0, .b = 0, .expected = 0 },
        .{ .a = 1, .b = 0, .expected = 0 },
        .{ .a = std.math.maxInt(u256), .b = 0, .expected = 0 },

        // Normal division cases
        .{ .a = 10, .b = 2, .expected = 5 },
        .{ .a = 100, .b = 10, .expected = 10 },
        .{ .a = std.math.maxInt(u256), .b = 1, .expected = std.math.maxInt(u256) },
        .{ .a = std.math.maxInt(u256), .b = std.math.maxInt(u256), .expected = 1 },

        // Integer division (truncates)
        .{ .a = 7, .b = 3, .expected = 2 },
        .{ .a = 999999999999999999, .b = 1000000000000000000, .expected = 0 },

        // Large number divisions
        .{ .a = 1 << 255, .b = 1 << 128, .expected = 1 << 127 },
        .{ .a = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, .b = 0xFFFFFFFF, .expected = 0x100000001 },
    };

    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(case.a);
        try ctx.frame.stack.append(case.b);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: *evm.Operation.State = @ptrCast(&ctx.frame);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x04); // DIV

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive SDIV (signed division) operation fuzz testing
test "fuzz_sdiv_signed_division_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    // Helper to convert signed to u256 (two's complement)
    const toU256 = struct {
        fn call(val: i256) u256 {
            return @bitCast(val);
        }
    }.call;

    const test_cases = [_]struct { a: u256, b: u256, expected: u256 }{
        // Positive / positive
        .{ .a = toU256(10), .b = toU256(2), .expected = toU256(5) },
        .{ .a = toU256(100), .b = toU256(10), .expected = toU256(10) },

        // Negative / positive
        .{ .a = toU256(-10), .b = toU256(2), .expected = toU256(-5) },
        .{ .a = toU256(-100), .b = toU256(10), .expected = toU256(-10) },

        // Positive / negative
        .{ .a = toU256(10), .b = toU256(-2), .expected = toU256(-5) },
        .{ .a = toU256(100), .b = toU256(-10), .expected = toU256(-10) },

        // Negative / negative
        .{ .a = toU256(-10), .b = toU256(-2), .expected = toU256(5) },
        .{ .a = toU256(-100), .b = toU256(-10), .expected = toU256(10) },

        // Division by zero
        .{ .a = toU256(10), .b = toU256(0), .expected = toU256(0) },
        .{ .a = toU256(-10), .b = toU256(0), .expected = toU256(0) },

        // Edge case: most negative / -1 (overflow in signed arithmetic)
        .{ .a = toU256(std.math.minInt(i256)), .b = toU256(-1), .expected = toU256(std.math.minInt(i256)) }, // Should not overflow in EVM
    };

    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(case.a);
        try ctx.frame.stack.append(case.b);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: *evm.Operation.State = @ptrCast(&ctx.frame);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x05); // SDIV

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive MOD operation fuzz testing
test "fuzz_mod_modulo_by_zero_and_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    const test_cases = [_]struct { a: u256, b: u256, expected: u256 }{
        // Modulo by zero cases (should return 0)
        .{ .a = 0, .b = 0, .expected = 0 },
        .{ .a = 10, .b = 0, .expected = 0 },
        .{ .a = std.math.maxInt(u256), .b = 0, .expected = 0 },

        // Normal modulo cases
        .{ .a = 10, .b = 3, .expected = 1 },
        .{ .a = 100, .b = 7, .expected = 2 },
        .{ .a = 17, .b = 5, .expected = 2 },

        // Cases where a < b
        .{ .a = 5, .b = 10, .expected = 5 },
        .{ .a = 1, .b = std.math.maxInt(u256), .expected = 1 },

        // Cases where a == b
        .{ .a = 100, .b = 100, .expected = 0 },
        .{ .a = std.math.maxInt(u256), .b = std.math.maxInt(u256), .expected = 0 },

        // Power of 2 modulo (common optimization case)
        .{ .a = 0xFF, .b = 0x100, .expected = 0xFF },
        .{ .a = 0x1FF, .b = 0x100, .expected = 0xFF },
    };

    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(case.a);
        try ctx.frame.stack.append(case.b);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: *evm.Operation.State = @ptrCast(&ctx.frame);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x06); // MOD

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive ADDMOD operation fuzz testing
test "fuzz_addmod_modular_arithmetic_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    const test_cases = [_]struct { a: u256, b: u256, n: u256, expected: u256 }{
        // Basic cases
        .{ .a = 5, .b = 7, .n = 10, .expected = 2 }, // (5 + 7) % 10 = 2
        .{ .a = 8, .b = 9, .n = 13, .expected = 4 }, // (8 + 9) % 13 = 4

        // Modulo by zero (should return 0)
        .{ .a = 10, .b = 20, .n = 0, .expected = 0 },
        .{ .a = std.math.maxInt(u256), .b = std.math.maxInt(u256), .n = 0, .expected = 0 },

        // Cases where addition would overflow but modulo prevents it
        .{ .a = std.math.maxInt(u256), .b = std.math.maxInt(u256), .n = 100, .expected = 98 }, // (max + max) % 100
        .{ .a = std.math.maxInt(u256), .b = 1, .n = 5, .expected = 0 }, // Wrapping addition modulo 5

        // Large modulus cases
        .{ .a = 1000000000000000000, .b = 2000000000000000000, .n = 999999999999999999, .expected = 2000000000000000002 % 999999999999999999 },

        // Prime modulus (good for testing)
        .{ .a = 123456789, .b = 987654321, .n = 1000000007, .expected = (123456789 + 987654321) % 1000000007 },
    };

    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(case.a);
        try ctx.frame.stack.append(case.b);
        try ctx.frame.stack.append(case.n);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: *evm.Operation.State = @ptrCast(&ctx.frame);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x08); // ADDMOD

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive MULMOD operation fuzz testing
test "fuzz_mulmod_modular_multiplication_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    const test_cases = [_]struct { a: u256, b: u256, n: u256, expected: u256 }{
        // Basic cases
        .{ .a = 3, .b = 4, .n = 5, .expected = 2 }, // (3 * 4) % 5 = 2
        .{ .a = 7, .b = 8, .n = 10, .expected = 6 }, // (7 * 8) % 10 = 6

        // Modulo by zero (should return 0)
        .{ .a = 10, .b = 20, .n = 0, .expected = 0 },
        .{ .a = std.math.maxInt(u256), .b = std.math.maxInt(u256), .n = 0, .expected = 0 },

        // Cases where multiplication would overflow
        .{ .a = std.math.maxInt(u128), .b = std.math.maxInt(u128), .n = 1000000007, .expected = (@as(u256, std.math.maxInt(u128)) * std.math.maxInt(u128)) % 1000000007 },
        .{ .a = std.math.maxInt(u256), .b = 2, .n = 1000, .expected = 998 }, // Large number * 2 mod 1000

        // Zero cases
        .{ .a = 0, .b = 12345, .n = 67890, .expected = 0 },
        .{ .a = 12345, .b = 0, .n = 67890, .expected = 0 },

        // Identity cases
        .{ .a = 42, .b = 1, .n = 100, .expected = 42 },

        // Prime modulus
        .{ .a = 123456789, .b = 987654321, .n = 1000000007, .expected = (@as(u256, 123456789) * 987654321) % 1000000007 },
    };

    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(case.a);
        try ctx.frame.stack.append(case.b);
        try ctx.frame.stack.append(case.n);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: *evm.Operation.State = @ptrCast(&ctx.frame);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x09); // MULMOD

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive EXP operation fuzz testing
test "fuzz_exp_exponentiation_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    const test_cases = [_]struct { a: u256, b: u256, expected: u256 }{
        // Basic cases
        .{ .a = 2, .b = 3, .expected = 8 },
        .{ .a = 5, .b = 4, .expected = 625 },
        .{ .a = 10, .b = 2, .expected = 100 },

        // Zero exponent (anything^0 = 1)
        .{ .a = 0, .b = 0, .expected = 1 }, // 0^0 = 1 in EVM
        .{ .a = 123456789, .b = 0, .expected = 1 },
        .{ .a = std.math.maxInt(u256), .b = 0, .expected = 1 },

        // Base zero (0^anything = 0, except 0^0)
        .{ .a = 0, .b = 1, .expected = 0 },
        .{ .a = 0, .b = 100, .expected = 0 },
        .{ .a = 0, .b = std.math.maxInt(u256), .expected = 0 },

        // Exponent 1 (anything^1 = anything)
        .{ .a = 42, .b = 1, .expected = 42 },
        .{ .a = std.math.maxInt(u256), .b = 1, .expected = std.math.maxInt(u256) },

        // Powers of 2
        .{ .a = 2, .b = 8, .expected = 256 },
        .{ .a = 2, .b = 16, .expected = 65536 },
        .{ .a = 2, .b = 255, .expected = 1 << 255 },
        .{ .a = 2, .b = 256, .expected = 0 }, // Overflow wraps to 0

        // Overflow cases (very large exponents should overflow to 0 or unexpected values)
        .{ .a = 3, .b = 200, .expected = 0 }, // This will overflow and wrap
        .{ .a = 256, .b = 32, .expected = 0 }, // 256^32 overflows
    };

    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(case.a);
        try ctx.frame.stack.append(case.b);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: *evm.Operation.State = @ptrCast(&ctx.frame);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x0A); // EXP

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive SIGNEXTEND operation fuzz testing
test "fuzz_signextend_sign_extension_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    const test_cases = [_]struct { i: u256, x: u256, expected: u256 }{
        // Basic cases - extending from byte 0 (8-bit)
        .{ .i = 0, .x = 0x7F, .expected = 0x7F }, // Positive byte, no extension needed
        .{ .i = 0, .x = 0x80, .expected = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF80 }, // Negative byte, extend sign
        .{ .i = 0, .x = 0xFF, .expected = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF }, // All 1s byte

        // Extending from byte 1 (16-bit)
        .{ .i = 1, .x = 0x7FFF, .expected = 0x7FFF }, // Positive 16-bit
        .{ .i = 1, .x = 0x8000, .expected = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF8000 }, // Negative 16-bit

        // Extending from byte 2 (24-bit)
        .{ .i = 2, .x = 0x7FFFFF, .expected = 0x7FFFFF }, // Positive 24-bit
        .{ .i = 2, .x = 0x800000, .expected = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF800000 }, // Negative 24-bit

        // Edge case: i >= 31 (32 bytes) should return x unchanged
        .{ .i = 31, .x = 0x1234567890ABCDEF, .expected = 0x1234567890ABCDEF },
        .{ .i = 32, .x = 0x1234567890ABCDEF, .expected = 0x1234567890ABCDEF },
        .{ .i = 100, .x = 0x1234567890ABCDEF, .expected = 0x1234567890ABCDEF },
        .{ .i = std.math.maxInt(u256), .x = 0x1234567890ABCDEF, .expected = 0x1234567890ABCDEF },

        // Testing with already sign-extended values
        .{ .i = 3, .x = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF800000, .expected = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF800000 },

        // Zero value
        .{ .i = 0, .x = 0, .expected = 0 },
        .{ .i = 15, .x = 0, .expected = 0 },
    };

    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(case.i);
        try ctx.frame.stack.append(case.x);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: *evm.Operation.State = @ptrCast(&ctx.frame);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x0B); // SIGNEXTEND

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Random arithmetic operations stress test
test "fuzz_arithmetic_random_stress_test" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    // Test many random combinations to catch edge cases
    for (0..1000) |_| {
        const a = random.int(u256);
        const b = random.int(u256);
        const c = random.int(u256);

        // Test ADD
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }

            try ctx.frame.stack.append(a);
            try ctx.frame.stack.append(b);

            var interpreter: evm.Operation.Interpreter = &ctx.vm;
            var state: *evm.Operation.State = @ptrCast(&ctx.frame);
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x01); // ADD

            const result = try ctx.frame.stack.pop();
            const expected = a +% b; // Wrapping addition
            try testing.expectEqual(expected, result);
        }

        // Test MUL
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }

            try ctx.frame.stack.append(a);
            try ctx.frame.stack.append(b);

            var interpreter: evm.Operation.Interpreter = &ctx.vm;
            var state: *evm.Operation.State = @ptrCast(&ctx.frame);
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x02); // MUL

            const result = try ctx.frame.stack.pop();
            const expected = a *% b; // Wrapping multiplication
            try testing.expectEqual(expected, result);
        }

        // Test ADDMOD (only when c != 0)
        if (c != 0) {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }

            try ctx.frame.stack.append(a);
            try ctx.frame.stack.append(b);
            try ctx.frame.stack.append(c);

            var interpreter: evm.Operation.Interpreter = &ctx.vm;
            var state: *evm.Operation.State = @ptrCast(&ctx.frame);
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x08); // ADDMOD

            const result = try ctx.frame.stack.pop();
            const expected = (a +% b) % c;
            try testing.expectEqual(expected, result);
        }
    }
}
