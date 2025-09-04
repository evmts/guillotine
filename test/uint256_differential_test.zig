const std = @import("std");
const testing = std.testing;
const primitives = @import("../src/primitives/uint.zig");

// Type aliases for clarity
const U256 = primitives.Uint(256, 4);

/// Differential testing framework that compares our uint256 implementation
/// against native u256 operations to ensure correctness
pub const DifferentialTester = struct {
    const Self = @This();
    
    rng: std.rand.DefaultPrng,
    
    pub fn init(seed: u64) Self {
        return Self{
            .rng = std.rand.DefaultPrng.init(seed),
        };
    }
    
    /// Generate random U256 value for testing
    pub fn randomU256(self: *Self) U256 {
        var limbs: [4]u64 = undefined;
        for (0..4) |i| {
            limbs[i] = self.rng.random().int(u64);
        }
        return U256.from_limbs(limbs);
    }
    
    /// Generate random native u256 value for testing
    pub fn randomNativeU256(self: *Self) u256 {
        const bytes = self.rng.random().bytes([32]u8);
        return std.mem.readInt(u256, &bytes, .little);
    }
    
    /// Compare U256 result with native u256 result
    pub fn compareResults(our_result: U256, native_result: u256) !void {
        const our_native = our_result.to_u256() orelse {
            return error.ConversionFailed;
        };
        try testing.expectEqual(native_result, our_native);
    }
    
    /// Test addition operations
    pub fn testAddition(self: *Self, a: U256, b: U256) !void {
        const a_native = a.to_u256() orelse return error.ConversionFailed;
        const b_native = b.to_u256() orelse return error.ConversionFailed;
        
        // Test wrapping addition
        const our_result = a.wrapping_add(b);
        const native_result = a_native +% b_native;
        try Self.compareResults(our_result, native_result);
        
        // Test overflowing addition
        const overflow_result = a.overflowing_add(b);
        const expected_overflow = @addWithOverflow(a_native, b_native);
        try Self.compareResults(overflow_result.result, expected_overflow[0]);
        try testing.expectEqual(expected_overflow[1] != 0, overflow_result.overflow);
    }
    
    /// Test subtraction operations
    pub fn testSubtraction(self: *Self, a: U256, b: U256) !void {
        const a_native = a.to_u256() orelse return error.ConversionFailed;
        const b_native = b.to_u256() orelse return error.ConversionFailed;
        
        // Test wrapping subtraction
        const our_result = a.wrapping_sub(b);
        const native_result = a_native -% b_native;
        try Self.compareResults(our_result, native_result);
        
        // Test overflowing subtraction
        const overflow_result = a.overflowing_sub(b);
        const expected_overflow = @subWithOverflow(a_native, b_native);
        try Self.compareResults(overflow_result.result, expected_overflow[0]);
        try testing.expectEqual(expected_overflow[1] != 0, overflow_result.overflow);
    }
    
    /// Test multiplication operations
    pub fn testMultiplication(self: *Self, a: U256, b: U256) !void {
        const a_native = a.to_u256() orelse return error.ConversionFailed;
        const b_native = b.to_u256() orelse return error.ConversionFailed;
        
        // Test wrapping multiplication
        const our_result = a.wrapping_mul(b);
        const native_result = a_native *% b_native;
        try Self.compareResults(our_result, native_result);
        
        // Test overflowing multiplication
        const overflow_result = a.overflowing_mul(b);
        const expected_overflow = @mulWithOverflow(a_native, b_native);
        try Self.compareResults(overflow_result.result, expected_overflow[0]);
        try testing.expectEqual(expected_overflow[1] != 0, overflow_result.overflow);
    }
    
    /// Test division operations (when divisor is non-zero)
    pub fn testDivision(self: *Self, a: U256, b: U256) !void {
        if (b.is_zero()) return; // Skip division by zero
        
        const a_native = a.to_u256() orelse return error.ConversionFailed;
        const b_native = b.to_u256() orelse return error.ConversionFailed;
        
        // Test division
        const our_div = a.wrapping_div(b);
        const native_div = a_native / b_native;
        try Self.compareResults(our_div, native_div);
        
        // Test remainder/modulo
        const our_rem = a.wrapping_rem(b);
        const native_rem = a_native % b_native;
        try Self.compareResults(our_rem, native_rem);
        
        // Property: a = (a/b)*b + (a%b)
        const reconstructed = our_div.wrapping_mul(b).wrapping_add(our_rem);
        try testing.expect(reconstructed.eq(a));
    }
    
    /// Test bitwise operations
    pub fn testBitwise(self: *Self, a: U256, b: U256) !void {
        const a_native = a.to_u256() orelse return error.ConversionFailed;
        const b_native = b.to_u256() orelse return error.ConversionFailed;
        
        // Test AND
        const our_and = a.bit_and(b);
        const native_and = a_native & b_native;
        try Self.compareResults(our_and, native_and);
        
        // Test OR
        const our_or = a.bit_or(b);
        const native_or = a_native | b_native;
        try Self.compareResults(our_or, native_or);
        
        // Test XOR
        const our_xor = a.bit_xor(b);
        const native_xor = a_native ^ b_native;
        try Self.compareResults(our_xor, native_xor);
        
        // Test NOT
        const our_not = a.bit_not();
        const native_not = ~a_native;
        try Self.compareResults(our_not, native_not);
    }
    
    /// Test shift operations
    pub fn testShifts(self: *Self, a: U256, shift_amount: u8) !void {
        const a_native = a.to_u256() orelse return error.ConversionFailed;
        
        // Limit shift amount to avoid undefined behavior
        const safe_shift: u32 = shift_amount % 256;
        
        // Test left shift
        const our_shl = a.wrapping_shl(safe_shift);
        const native_shl = if (safe_shift < 256) a_native << @intCast(safe_shift) else 0;
        try Self.compareResults(our_shl, native_shl);
        
        // Test right shift
        const our_shr = a.wrapping_shr(safe_shift);
        const native_shr = a_native >> @intCast(safe_shift);
        try Self.compareResults(our_shr, native_shr);
    }
    
    /// Test comparison operations
    pub fn testComparisons(self: *Self, a: U256, b: U256) !void {
        const a_native = a.to_u256() orelse return error.ConversionFailed;
        const b_native = b.to_u256() orelse return error.ConversionFailed;
        
        // Test equality
        try testing.expectEqual(a_native == b_native, a.eq(b));
        
        // Test less than
        try testing.expectEqual(a_native < b_native, a.lt(b));
        
        // Test greater than
        try testing.expectEqual(a_native > b_native, a.gt(b));
        
        // Test comparison function
        const cmp_expected = std.math.order(a_native, b_native);
        try testing.expectEqual(cmp_expected, a.cmp(b));
    }
    
    /// Comprehensive test of all operations
    pub fn testAllOperations(self: *Self, a: U256, b: U256, shift: u8) !void {
        try self.testAddition(a, b);
        try self.testSubtraction(a, b);
        try self.testMultiplication(a, b);
        try self.testDivision(a, b);
        try self.testBitwise(a, b);
        try self.testShifts(a, shift);
        try self.testComparisons(a, b);
    }
};

// Property-based testing utilities
pub const PropertyTester = struct {
    /// Test mathematical properties like commutativity, associativity, etc.
    pub fn testCommutativeAdd(a: U256, b: U256) !void {
        const result1 = a.wrapping_add(b);
        const result2 = b.wrapping_add(a);
        try testing.expect(result1.eq(result2));
    }
    
    pub fn testCommutativeMul(a: U256, b: U256) !void {
        const result1 = a.wrapping_mul(b);
        const result2 = b.wrapping_mul(a);
        try testing.expect(result1.eq(result2));
    }
    
    pub fn testCommutativeBitAnd(a: U256, b: U256) !void {
        const result1 = a.bit_and(b);
        const result2 = b.bit_and(a);
        try testing.expect(result1.eq(result2));
    }
    
    pub fn testCommutativeBitOr(a: U256, b: U256) !void {
        const result1 = a.bit_or(b);
        const result2 = b.bit_or(a);
        try testing.expect(result1.eq(result2));
    }
    
    pub fn testCommutativeBitXor(a: U256, b: U256) !void {
        const result1 = a.bit_xor(b);
        const result2 = b.bit_xor(a);
        try testing.expect(result1.eq(result2));
    }
    
    pub fn testAssociativeAdd(a: U256, b: U256, c: U256) !void {
        const result1 = a.wrapping_add(b).wrapping_add(c);
        const result2 = a.wrapping_add(b.wrapping_add(c));
        try testing.expect(result1.eq(result2));
    }
    
    pub fn testAssociativeMul(a: U256, b: U256, c: U256) !void {
        const result1 = a.wrapping_mul(b).wrapping_mul(c);
        const result2 = a.wrapping_mul(b.wrapping_mul(c));
        try testing.expect(result1.eq(result2));
    }
    
    pub fn testIdentityAdd(a: U256) !void {
        const result1 = a.wrapping_add(U256.ZERO);
        const result2 = U256.ZERO.wrapping_add(a);
        try testing.expect(result1.eq(a));
        try testing.expect(result2.eq(a));
    }
    
    pub fn testIdentityMul(a: U256) !void {
        const result1 = a.wrapping_mul(U256.ONE);
        const result2 = U256.ONE.wrapping_mul(a);
        try testing.expect(result1.eq(a));
        try testing.expect(result2.eq(a));
    }
};

/// Test edge cases and boundary conditions
test "differential testing: edge cases" {
    var tester = DifferentialTester.init(42);
    
    // Test boundary values
    const zero = U256.ZERO;
    const one = U256.ONE;
    const max = U256.MAX;
    
    try tester.testAllOperations(zero, one, 0);
    try tester.testAllOperations(one, max, 1);
    try tester.testAllOperations(max, zero, 255);
    
    // Test powers of 2
    const power_of_2 = U256.from_u64(1).shl(64);
    try tester.testAllOperations(power_of_2, one, 64);
    
    // Test values near boundaries
    const near_max = max.wrapping_sub(one);
    try tester.testAllOperations(near_max, one, 128);
}

/// Comprehensive fuzzing test
test "differential testing: fuzzing against native u256" {
    var tester = DifferentialTester.init(std.crypto.random.int(u64));
    
    // Run comprehensive test with random values
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const a = tester.randomU256();
        const b = tester.randomU256();
        const shift = @intCast(tester.rng.random().int(u8));
        
        try tester.testAllOperations(a, b, shift);
    }
}

/// Test mathematical properties
test "differential testing: mathematical properties" {
    var tester = DifferentialTester.init(123);
    
    // Test commutativity
    for (0..100) |_| {
        const a = tester.randomU256();
        const b = tester.randomU256();
        try PropertyTester.testCommutativeAdd(a, b);
        try PropertyTester.testCommutativeMul(a, b);
        try PropertyTester.testCommutativeBitAnd(a, b);
        try PropertyTester.testCommutativeBitOr(a, b);
        try PropertyTester.testCommutativeBitXor(a, b);
    }
    
    // Test associativity
    for (0..50) |_| {
        const a = tester.randomU256();
        const b = tester.randomU256();
        const c = tester.randomU256();
        try PropertyTester.testAssociativeAdd(a, b, c);
        try PropertyTester.testAssociativeMul(a, b, c);
    }
    
    // Test identity properties
    for (0..50) |_| {
        const a = tester.randomU256();
        try PropertyTester.testIdentityAdd(a);
        try PropertyTester.testIdentityMul(a);
    }
}

/// Test bit manipulation operations
test "differential testing: bit operations comprehensive" {
    var tester = DifferentialTester.init(456);
    
    for (0..200) |_| {
        const a = tester.randomU256();
        
        // Test bit counting functions if available
        if (@hasDecl(U256, "count_ones")) {
            const a_native = a.to_u256() orelse continue;
            try testing.expectEqual(@popCount(a_native), a.count_ones());
        }
        
        if (@hasDecl(U256, "leading_zeros")) {
            const a_native = a.to_u256() orelse continue;
            try testing.expectEqual(@clz(a_native), a.leading_zeros());
        }
        
        if (@hasDecl(U256, "trailing_zeros")) {
            const a_native = a.to_u256() orelse continue;
            try testing.expectEqual(@ctz(a_native), a.trailing_zeros());
        }
    }
}

/// Test conversion functions thoroughly
test "differential testing: conversions" {
    var tester = DifferentialTester.init(789);
    
    // Test round-trip conversions
    for (0..500) |_| {
        const native_val = tester.randomNativeU256();
        const uint_val = U256.from_u256(native_val);
        const back_to_native = uint_val.to_u256() orelse {
            return error.ConversionFailed;
        };
        try testing.expectEqual(native_val, back_to_native);
    }
    
    // Test u64 conversions
    for (0..100) |_| {
        const u64_val = tester.rng.random().int(u64);
        const uint_val = U256.from_u64(u64_val);
        
        if (@hasDecl(U256, "to_u64")) {
            const back_to_u64 = uint_val.to_u64();
            if (back_to_u64) |val| {
                try testing.expectEqual(u64_val, val);
            }
        }
    }
}