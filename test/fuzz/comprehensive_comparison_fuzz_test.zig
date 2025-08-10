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

// Comprehensive LT (Less Than) operation fuzz testing
test "fuzz_lt_unsigned_comparison_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);
    
    const test_cases = [_]struct { a: u256, b: u256, expected: u256 }{ 
        // Basic cases
        .{ .a = 5, .b = 10, .expected = 1 }, // 5 < 10 = true
        .{ .a = 10, .b = 5, .expected = 0 }, // 10 < 5 = false
        .{ .a = 5, .b = 5, .expected = 0 }, // 5 < 5 = false
        
        // Zero cases
        .{ .a = 0, .b = 1, .expected = 1 }, // 0 < 1 = true
        .{ .a = 1, .b = 0, .expected = 0 }, // 1 < 0 = false
        .{ .a = 0, .b = 0, .expected = 0 }, // 0 < 0 = false
        
        // Maximum value edge cases
        .{ .a = std.math.maxInt(u256), .b = std.math.maxInt(u256), .expected = 0 }, // max < max = false
        .{ .a = std.math.maxInt(u256) - 1, .b = std.math.maxInt(u256), .expected = 1 }, // (max-1) < max = true
        .{ .a = std.math.maxInt(u256), .b = std.math.maxInt(u256) - 1, .expected = 0 }, // max < (max-1) = false
        .{ .a = 0, .b = std.math.maxInt(u256), .expected = 1 }, // 0 < max = true
        .{ .a = std.math.maxInt(u256), .b = 0, .expected = 0 }, // max < 0 = false
        
        // Power of 2 boundaries
        .{ .a = (1 << 128) - 1, .b = 1 << 128, .expected = 1 }, // Just below vs at power of 2
        .{ .a = 1 << 128, .b = (1 << 128) - 1, .expected = 0 }, // At vs just below power of 2
        .{ .a = 1 << 255, .b = (1 << 255) + 1, .expected = 1 }, // High bit edge case
        
        // Large number comparisons
        .{ .a = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .b = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF1, .expected = 1 },
        .{ .a = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF1, .b = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .expected = 0 },
    };
    
    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        try ctx.frame.stack.append(case.a);
        try ctx.frame.stack.append(case.b);
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = *evm.Operation.State = @ptrCast(&ctx.frame);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x10); // LT
        
        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive GT (Greater Than) operation fuzz testing
test "fuzz_gt_unsigned_comparison_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);
    
    const test_cases = [_]struct { a: u256, b: u256, expected: u256 }{
        // Basic cases
        .{ .a = 10, .b = 5, .expected = 1 }, // 10 > 5 = true
        .{ .a = 5, .b = 10, .expected = 0 }, // 5 > 10 = false
        .{ .a = 5, .b = 5, .expected = 0 }, // 5 > 5 = false
        
        // Zero cases
        .{ .a = 1, .b = 0, .expected = 1 }, // 1 > 0 = true
        .{ .a = 0, .b = 1, .expected = 0 }, // 0 > 1 = false
        .{ .a = 0, .b = 0, .expected = 0 }, // 0 > 0 = false
        
        // Maximum value edge cases
        .{ .a = std.math.maxInt(u256), .b = std.math.maxInt(u256), .expected = 0 }, // max > max = false
        .{ .a = std.math.maxInt(u256), .b = std.math.maxInt(u256) - 1, .expected = 1 }, // max > (max-1) = true
        .{ .a = std.math.maxInt(u256) - 1, .b = std.math.maxInt(u256), .expected = 0 }, // (max-1) > max = false
        .{ .a = std.math.maxInt(u256), .b = 0, .expected = 1 }, // max > 0 = true
        .{ .a = 0, .b = std.math.maxInt(u256), .expected = 0 }, // 0 > max = false
        
        // Power of 2 boundaries
        .{ .a = 1 << 128, .b = (1 << 128) - 1, .expected = 1 }, // At vs just below power of 2
        .{ .a = (1 << 128) - 1, .b = 1 << 128, .expected = 0 }, // Just below vs at power of 2
        .{ .a = (1 << 255) + 1, .b = 1 << 255, .expected = 1 }, // High bit edge case
        
        // Large number comparisons
        .{ .a = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF1, .b = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .expected = 1 },
        .{ .a = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .b = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF1, .expected = 0 },
    };
    
    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        try ctx.frame.stack.append(case.a);
        try ctx.frame.stack.append(case.b);
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = *evm.Operation.State = @ptrCast(&ctx.frame);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x11); // GT
        
        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive SLT (Signed Less Than) operation fuzz testing
test "fuzz_slt_signed_comparison_edge_cases" {
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
        // Basic positive comparisons
        .{ .a = toU256(5), .b = toU256(10), .expected = 1 }, // 5 < 10 = true
        .{ .a = toU256(10), .b = toU256(5), .expected = 0 }, // 10 < 5 = false
        .{ .a = toU256(5), .b = toU256(5), .expected = 0 }, // 5 < 5 = false
        
        // Basic negative comparisons
        .{ .a = toU256(-10), .b = toU256(-5), .expected = 1 }, // -10 < -5 = true
        .{ .a = toU256(-5), .b = toU256(-10), .expected = 0 }, // -5 < -10 = false
        .{ .a = toU256(-5), .b = toU256(-5), .expected = 0 }, // -5 < -5 = false
        
        // Mixed sign comparisons
        .{ .a = toU256(-1), .b = toU256(1), .expected = 1 }, // -1 < 1 = true
        .{ .a = toU256(1), .b = toU256(-1), .expected = 0 }, // 1 < -1 = false
        .{ .a = toU256(-100), .b = toU256(1), .expected = 1 }, // -100 < 1 = true
        .{ .a = toU256(100), .b = toU256(-1), .expected = 0 }, // 100 < -1 = false
        
        // Zero comparisons
        .{ .a = toU256(0), .b = toU256(1), .expected = 1 }, // 0 < 1 = true
        .{ .a = toU256(0), .b = toU256(-1), .expected = 0 }, // 0 < -1 = false
        .{ .a = toU256(1), .b = toU256(0), .expected = 0 }, // 1 < 0 = false
        .{ .a = toU256(-1), .b = toU256(0), .expected = 1 }, // -1 < 0 = true
        .{ .a = toU256(0), .b = toU256(0), .expected = 0 }, // 0 < 0 = false
        
        // Edge cases with extreme values
        .{ .a = toU256(std.math.minInt(i256)), .b = toU256(std.math.maxInt(i256)), .expected = 1 }, // min < max = true
        .{ .a = toU256(std.math.maxInt(i256)), .b = toU256(std.math.minInt(i256)), .expected = 0 }, // max < min = false
        .{ .a = toU256(std.math.minInt(i256)), .b = toU256(-1), .expected = 1 }, // min < -1 = true
        .{ .a = toU256(std.math.maxInt(i256)), .b = toU256(1), .expected = 0 }, // max < 1 = false
        
        // Boundary cases around zero
        .{ .a = toU256(-1), .b = toU256(0), .expected = 1 }, // -1 < 0 = true
        .{ .a = toU256(0), .b = toU256(1), .expected = 1 }, // 0 < 1 = true
        .{ .a = toU256(1), .b = toU256(0), .expected = 0 }, // 1 < 0 = false
        .{ .a = toU256(0), .b = toU256(-1), .expected = 0 }, // 0 < -1 = false
    };
    
    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        try ctx.frame.stack.append(case.a);
        try ctx.frame.stack.append(case.b);
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = *evm.Operation.State = @ptrCast(&ctx.frame);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x12); // SLT
        
        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive SGT (Signed Greater Than) operation fuzz testing
test "fuzz_sgt_signed_greater_than_edge_cases" {
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
        // Basic positive comparisons
        .{ .a = toU256(10), .b = toU256(5), .expected = 1 }, // 10 > 5 = true
        .{ .a = toU256(5), .b = toU256(10), .expected = 0 }, // 5 > 10 = false
        .{ .a = toU256(5), .b = toU256(5), .expected = 0 }, // 5 > 5 = false
        
        // Basic negative comparisons
        .{ .a = toU256(-5), .b = toU256(-10), .expected = 1 }, // -5 > -10 = true
        .{ .a = toU256(-10), .b = toU256(-5), .expected = 0 }, // -10 > -5 = false
        .{ .a = toU256(-5), .b = toU256(-5), .expected = 0 }, // -5 > -5 = false
        
        // Mixed sign comparisons
        .{ .a = toU256(1), .b = toU256(-1), .expected = 1 }, // 1 > -1 = true
        .{ .a = toU256(-1), .b = toU256(1), .expected = 0 }, // -1 > 1 = false
        .{ .a = toU256(1), .b = toU256(-100), .expected = 1 }, // 1 > -100 = true
        .{ .a = toU256(-1), .b = toU256(100), .expected = 0 }, // -1 > 100 = false
        
        // Zero comparisons
        .{ .a = toU256(1), .b = toU256(0), .expected = 1 }, // 1 > 0 = true
        .{ .a = toU256(-1), .b = toU256(0), .expected = 0 }, // -1 > 0 = false
        .{ .a = toU256(0), .b = toU256(1), .expected = 0 }, // 0 > 1 = false
        .{ .a = toU256(0), .b = toU256(-1), .expected = 1 }, // 0 > -1 = true
        .{ .a = toU256(0), .b = toU256(0), .expected = 0 }, // 0 > 0 = false
        
        // Edge cases with extreme values
        .{ .a = toU256(std.math.maxInt(i256)), .b = toU256(std.math.minInt(i256)), .expected = 1 }, // max > min = true
        .{ .a = toU256(std.math.minInt(i256)), .b = toU256(std.math.maxInt(i256)), .expected = 0 }, // min > max = false
        .{ .a = toU256(-1), .b = toU256(std.math.minInt(i256)), .expected = 1 }, // -1 > min = true
        .{ .a = toU256(1), .b = toU256(std.math.maxInt(i256)), .expected = 0 }, // 1 > max = false
        
        // Boundary cases around zero
        .{ .a = toU256(0), .b = toU256(-1), .expected = 1 }, // 0 > -1 = true
        .{ .a = toU256(1), .b = toU256(0), .expected = 1 }, // 1 > 0 = true
        .{ .a = toU256(0), .b = toU256(1), .expected = 0 }, // 0 > 1 = false
        .{ .a = toU256(-1), .b = toU256(0), .expected = 0 }, // -1 > 0 = false
    };
    
    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        try ctx.frame.stack.append(case.a);
        try ctx.frame.stack.append(case.b);
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = *evm.Operation.State = @ptrCast(&ctx.frame);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x13); // SGT
        
        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive EQ (Equality) operation fuzz testing
test "fuzz_eq_equality_comparison_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);
    
    const test_cases = [_]struct { a: u256, b: u256, expected: u256 }{
        // Basic equality cases
        .{ .a = 0, .b = 0, .expected = 1 }, // 0 == 0 = true
        .{ .a = 1, .b = 1, .expected = 1 }, // 1 == 1 = true
        .{ .a = 100, .b = 100, .expected = 1 }, // 100 == 100 = true
        
        // Basic inequality cases
        .{ .a = 0, .b = 1, .expected = 0 }, // 0 == 1 = false
        .{ .a = 1, .b = 0, .expected = 0 }, // 1 == 0 = false
        .{ .a = 100, .b = 101, .expected = 0 }, // 100 == 101 = false
        
        // Maximum value cases
        .{ .a = std.math.maxInt(u256), .b = std.math.maxInt(u256), .expected = 1 }, // max == max = true
        .{ .a = std.math.maxInt(u256), .b = std.math.maxInt(u256) - 1, .expected = 0 }, // max == (max-1) = false
        .{ .a = std.math.maxInt(u256) - 1, .b = std.math.maxInt(u256), .expected = 0 }, // (max-1) == max = false
        .{ .a = 0, .b = std.math.maxInt(u256), .expected = 0 }, // 0 == max = false
        .{ .a = std.math.maxInt(u256), .b = 0, .expected = 0 }, // max == 0 = false
        
        // Power of 2 cases
        .{ .a = 1 << 128, .b = 1 << 128, .expected = 1 }, // 2^128 == 2^128 = true
        .{ .a = 1 << 128, .b = (1 << 128) + 1, .expected = 0 }, // 2^128 == (2^128+1) = false
        .{ .a = 1 << 255, .b = 1 << 255, .expected = 1 }, // 2^255 == 2^255 = true
        .{ .a = 1 << 255, .b = (1 << 255) + 1, .expected = 0 }, // 2^255 == (2^255+1) = false
        
        // Large number equality
        .{ .a = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .b = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .expected = 1 },
        .{ .a = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .b = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF1, .expected = 0 },
        
        // Single bit differences
        .{ .a = 0x1, .b = 0x3, .expected = 0 }, // 1 == 3 = false (differ by bit 1)
        .{ .a = 0xF, .b = 0x7, .expected = 0 }, // 15 == 7 = false (differ by bit 3)
        .{ .a = 1 << 100, .b = 1 << 101, .expected = 0 }, // Single high bit difference
        
        // Near-maximum values
        .{ .a = std.math.maxInt(u256) - 1000, .b = std.math.maxInt(u256) - 1000, .expected = 1 },
        .{ .a = std.math.maxInt(u256) - 1000, .b = std.math.maxInt(u256) - 999, .expected = 0 },
    };
    
    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        try ctx.frame.stack.append(case.a);
        try ctx.frame.stack.append(case.b);
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = *evm.Operation.State = @ptrCast(&ctx.frame);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x14); // EQ
        
        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive ISZERO operation fuzz testing
test "fuzz_iszero_zero_check_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);
    
    const test_cases = [_]struct { a: u256, expected: u256 }{
        // Zero cases (should return 1)
        .{ .a = 0, .expected = 1 }, // 0 is zero = true
        
        // Non-zero cases (should return 0)
        .{ .a = 1, .expected = 0 }, // 1 is not zero = false
        .{ .a = 2, .expected = 0 }, // 2 is not zero = false
        .{ .a = 100, .expected = 0 }, // 100 is not zero = false
        .{ .a = std.math.maxInt(u256), .expected = 0 }, // max is not zero = false
        .{ .a = std.math.maxInt(u256) - 1, .expected = 0 }, // (max-1) is not zero = false
        
        // Power of 2 cases
        .{ .a = 1, .expected = 0 }, // 2^0 is not zero = false
        .{ .a = 2, .expected = 0 }, // 2^1 is not zero = false
        .{ .a = 4, .expected = 0 }, // 2^2 is not zero = false
        .{ .a = 1 << 128, .expected = 0 }, // 2^128 is not zero = false
        .{ .a = 1 << 255, .expected = 0 }, // 2^255 is not zero = false
        
        // Single bit set cases
        .{ .a = 1 << 0, .expected = 0 }, // Bit 0 set
        .{ .a = 1 << 1, .expected = 0 }, // Bit 1 set
        .{ .a = 1 << 7, .expected = 0 }, // Bit 7 set
        .{ .a = 1 << 31, .expected = 0 }, // Bit 31 set
        .{ .a = 1 << 63, .expected = 0 }, // Bit 63 set
        .{ .a = 1 << 127, .expected = 0 }, // Bit 127 set
        .{ .a = 1 << 255, .expected = 0 }, // Bit 255 set (highest bit)
        
        // All bits set patterns
        .{ .a = 0xFF, .expected = 0 }, // 8 bits set
        .{ .a = 0xFFFF, .expected = 0 }, // 16 bits set
        .{ .a = 0xFFFFFFFF, .expected = 0 }, // 32 bits set
        .{ .a = 0xFFFFFFFFFFFFFFFF, .expected = 0 }, // 64 bits set
        
        // Large specific values
        .{ .a = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .expected = 0 },
        .{ .a = 0xFEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210, .expected = 0 },
        
        // Near-zero values
        .{ .a = 1, .expected = 0 }, // Smallest positive
        .{ .a = std.math.maxInt(u256), .expected = 0 }, // Largest value
    };
    
    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        try ctx.frame.stack.append(case.a);
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = *evm.Operation.State = @ptrCast(&ctx.frame);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x15); // ISZERO
        
        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Random comparison operations stress test
test "fuzz_comparison_random_stress_test" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);
    
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();
    
    // Test many random combinations to catch edge cases
    for (0..1000) |_| {
        const a = random.int(u256);
        const b = random.int(u256);
        
        // Test LT
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }
            
            try ctx.frame.stack.append(a);
            try ctx.frame.stack.append(b);
            
            var interpreter = evm.Operation.Interpreter = &ctx.vm;
            var state = *evm.Operation.State = @ptrCast(&ctx.frame);
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x10); // LT
            
            const result = try ctx.frame.stack.pop();
            const expected: u256 = if (a < b) 1 else 0;
            try testing.expectEqual(expected, result);
        }
        
        // Test GT
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }
            
            try ctx.frame.stack.append(a);
            try ctx.frame.stack.append(b);
            
            var interpreter = evm.Operation.Interpreter = &ctx.vm;
            var state = *evm.Operation.State = @ptrCast(&ctx.frame);
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x11); // GT
            
            const result = try ctx.frame.stack.pop();
            const expected: u256 = if (a > b) 1 else 0;
            try testing.expectEqual(expected, result);
        }
        
        // Test EQ
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }
            
            try ctx.frame.stack.append(a);
            try ctx.frame.stack.append(b);
            
            var interpreter = evm.Operation.Interpreter = &ctx.vm;
            var state = *evm.Operation.State = @ptrCast(&ctx.frame);
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x14); // EQ
            
            const result = try ctx.frame.stack.pop();
            const expected: u256 = if (a == b) 1 else 0;
            try testing.expectEqual(expected, result);
        }
        
        // Test ISZERO on first value
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }
            
            try ctx.frame.stack.append(a);
            
            var interpreter = evm.Operation.Interpreter = &ctx.vm;
            var state = *evm.Operation.State = @ptrCast(&ctx.frame);
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x15); // ISZERO
            
            const result = try ctx.frame.stack.pop();
            const expected: u256 = if (a == 0) 1 else 0;
            try testing.expectEqual(expected, result);
        }
    }
}