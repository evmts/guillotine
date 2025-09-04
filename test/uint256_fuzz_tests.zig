const std = @import("std");
const testing = std.testing;
const primitives = @import("../src/primitives/uint.zig");

// Type aliases for clarity
const U256 = primitives.Uint(256, 4);

/// Comprehensive fuzzing test suite for uint256 operations
/// Generates random inputs and validates against native u256 operations

pub const FuzzTester = struct {
    const Self = @This();
    
    rng: std.rand.DefaultPrng,
    test_count: u32,
    
    pub fn init(seed: u64) Self {
        return Self{
            .rng = std.rand.DefaultPrng.init(seed),
            .test_count = 0,
        };
    }
    
    /// Generate random U256 with various patterns
    pub fn generateTestValue(self: *Self) U256 {
        const pattern = self.rng.random().int(u8) % 10;
        
        return switch (pattern) {
            0 => U256.ZERO,
            1 => U256.ONE,  
            2 => U256.MAX,
            3 => U256.from_u64(self.rng.random().int(u64)),
            4 => U256.from_limbs(.{
                self.rng.random().int(u64),
                0, 0, 0
            }),
            5 => U256.from_limbs(.{
                0,
                self.rng.random().int(u64),
                0, 0
            }),
            6 => U256.from_limbs(.{
                0, 0,
                self.rng.random().int(u64),
                0
            }),
            7 => U256.from_limbs(.{
                0, 0, 0,
                self.rng.random().int(u64)
            }),
            8 => U256.from_limbs(.{
                self.rng.random().int(u64),
                self.rng.random().int(u64),
                self.rng.random().int(u64),
                self.rng.random().int(u64)
            }),
            9 => blk: {
                // Power of 2 values
                const shift = self.rng.random().int(u8) % 256;
                break :blk U256.ONE.wrapping_shl(shift);
            },
            else => unreachable,
        };
    }
    
    /// Test all arithmetic operations against native u256
    pub fn fuzzArithmetic(self: *Self, iterations: u32) !void {
        for (0..iterations) |i| {
            const a = self.generateTestValue();
            const b = self.generateTestValue();
            
            // Only test if both values can be converted to native u256
            const a_native = a.to_u256() orelse continue;
            const b_native = b.to_u256() orelse continue;
            
            // Test addition
            const add_result = a.wrapping_add(b);
            const native_add = a_native +% b_native;
            const add_back = add_result.to_u256();
            if (add_back != null) {
                try testing.expectEqual(native_add, add_back.?);
            }
            
            // Test subtraction
            const sub_result = a.wrapping_sub(b);
            const native_sub = a_native -% b_native;
            const sub_back = sub_result.to_u256();
            if (sub_back != null) {
                try testing.expectEqual(native_sub, sub_back.?);
            }
            
            // Test multiplication
            const mul_result = a.wrapping_mul(b);
            const native_mul = a_native *% b_native;
            const mul_back = mul_result.to_u256();
            if (mul_back != null) {
                try testing.expectEqual(native_mul, mul_back.?);
            }
            
            // Test division (skip if b is zero)
            if (!b.is_zero()) {
                const div_result = a.wrapping_div(b);
                const native_div = a_native / b_native;
                const div_back = div_result.to_u256();
                if (div_back != null) {
                    try testing.expectEqual(native_div, div_back.?);
                }
                
                // Test remainder
                const rem_result = a.wrapping_rem(b);
                const native_rem = a_native % b_native;
                const rem_back = rem_result.to_u256();
                if (rem_back != null) {
                    try testing.expectEqual(native_rem, rem_back.?);
                }
            }
            
            if (i % 100 == 0) {
                std.debug.print("Fuzz arithmetic: {}/{}\n", .{ i, iterations });
            }
        }
    }
    
    /// Test all bitwise operations against native u256
    pub fn fuzzBitwise(self: *Self, iterations: u32) !void {
        for (0..iterations) |i| {
            const a = self.generateTestValue();
            const b = self.generateTestValue();
            
            const a_native = a.to_u256() orelse continue;
            const b_native = b.to_u256() orelse continue;
            
            // Test AND
            const and_result = a.bit_and(b);
            const native_and = a_native & b_native;
            if (and_result.to_u256()) |and_back| {
                try testing.expectEqual(native_and, and_back);
            }
            
            // Test OR
            const or_result = a.bit_or(b);
            const native_or = a_native | b_native;
            if (or_result.to_u256()) |or_back| {
                try testing.expectEqual(native_or, or_back);
            }
            
            // Test XOR
            const xor_result = a.bit_xor(b);
            const native_xor = a_native ^ b_native;
            if (xor_result.to_u256()) |xor_back| {
                try testing.expectEqual(native_xor, xor_back);
            }
            
            // Test NOT
            const not_result = a.bit_not();
            const native_not = ~a_native;
            if (not_result.to_u256()) |not_back| {
                try testing.expectEqual(native_not, not_back);
            }
            
            if (i % 100 == 0) {
                std.debug.print("Fuzz bitwise: {}/{}\n", .{ i, iterations });
            }
        }
    }
    
    /// Test shift operations against native u256
    pub fn fuzzShifts(self: *Self, iterations: u32) !void {
        for (0..iterations) |i| {
            const a = self.generateTestValue();
            const shift = self.rng.random().int(u8) % 128; // Limit to reasonable shift ranges
            
            const a_native = a.to_u256() orelse continue;
            
            // Test left shift
            const shl_result = a.wrapping_shl(shift);
            const native_shl = if (shift < 256) a_native << @intCast(shift) else 0;
            if (shl_result.to_u256()) |shl_back| {
                try testing.expectEqual(native_shl, shl_back);
            }
            
            // Test right shift
            const shr_result = a.wrapping_shr(shift);
            const native_shr = a_native >> @intCast(shift);
            if (shr_result.to_u256()) |shr_back| {
                try testing.expectEqual(native_shr, shr_back);
            }
            
            if (i % 100 == 0) {
                std.debug.print("Fuzz shifts: {}/{}\n", .{ i, iterations });
            }
        }
    }
    
    /// Test comparison operations
    pub fn fuzzComparisons(self: *Self, iterations: u32) !void {
        for (0..iterations) |i| {
            const a = self.generateTestValue();
            const b = self.generateTestValue();
            
            const a_native = a.to_u256() orelse continue;
            const b_native = b.to_u256() orelse continue;
            
            // Test all comparison operations
            try testing.expectEqual(a_native == b_native, a.eq(b));
            try testing.expectEqual(a_native < b_native, a.lt(b));
            try testing.expectEqual(a_native > b_native, a.gt(b));
            try testing.expectEqual(std.math.order(a_native, b_native), a.cmp(b));
            
            if (i % 100 == 0) {
                std.debug.print("Fuzz comparisons: {}/{}\n", .{ i, iterations });
            }
        }
    }
    
    /// Test mathematical properties with random values
    pub fn fuzzProperties(self: *Self, iterations: u32) !void {
        for (0..iterations) |i| {
            const a = self.generateTestValue();
            const b = self.generateTestValue();
            const c = self.generateTestValue();
            
            // Test commutativity
            try testing.expect(a.wrapping_add(b).eq(b.wrapping_add(a)));
            try testing.expect(a.wrapping_mul(b).eq(b.wrapping_mul(a)));
            try testing.expect(a.bit_and(b).eq(b.bit_and(a)));
            try testing.expect(a.bit_or(b).eq(b.bit_or(a)));
            try testing.expect(a.bit_xor(b).eq(b.bit_xor(a)));
            
            // Test associativity
            const add_assoc_1 = a.wrapping_add(b).wrapping_add(c);
            const add_assoc_2 = a.wrapping_add(b.wrapping_add(c));
            try testing.expect(add_assoc_1.eq(add_assoc_2));
            
            // Test identities
            try testing.expect(a.wrapping_add(U256.ZERO).eq(a));
            try testing.expect(a.wrapping_mul(U256.ONE).eq(a));
            try testing.expect(a.wrapping_mul(U256.ZERO).eq(U256.ZERO));
            
            // Test self operations
            try testing.expect(a.wrapping_sub(a).eq(U256.ZERO));
            try testing.expect(a.bit_xor(a).eq(U256.ZERO));
            
            if (!a.is_zero()) {
                try testing.expect(a.wrapping_div(a).eq(U256.ONE));
                try testing.expect(a.wrapping_rem(a).eq(U256.ZERO));
            }
            
            if (i % 100 == 0) {
                std.debug.print("Fuzz properties: {}/{}\n", .{ i, iterations });
            }
        }
    }
    
    /// Test overflow detection accuracy
    pub fn fuzzOverflows(self: *Self, iterations: u32) !void {
        for (0..iterations) |i| {
            const a = self.generateTestValue();
            const b = self.generateTestValue();
            
            const a_native = a.to_u256() orelse continue;
            const b_native = b.to_u256() orelse continue;
            
            // Test addition overflow detection
            const add_overflow = a.overflowing_add(b);
            const native_add_overflow = @addWithOverflow(a_native, b_native);
            try testing.expectEqual(native_add_overflow[1] != 0, add_overflow.overflow);
            if (add_overflow.result.to_u256()) |result_native| {
                try testing.expectEqual(native_add_overflow[0], result_native);
            }
            
            // Test subtraction overflow detection
            const sub_overflow = a.overflowing_sub(b);
            const native_sub_overflow = @subWithOverflow(a_native, b_native);
            try testing.expectEqual(native_sub_overflow[1] != 0, sub_overflow.overflow);
            if (sub_overflow.result.to_u256()) |result_native| {
                try testing.expectEqual(native_sub_overflow[0], result_native);
            }
            
            // Test multiplication overflow detection
            const mul_overflow = a.overflowing_mul(b);
            const native_mul_overflow = @mulWithOverflow(a_native, b_native);
            try testing.expectEqual(native_mul_overflow[1] != 0, mul_overflow.overflow);
            if (mul_overflow.result.to_u256()) |result_native| {
                try testing.expectEqual(native_mul_overflow[0], result_native);
            }
            
            if (i % 100 == 0) {
                std.debug.print("Fuzz overflows: {}/{}\n", .{ i, iterations });
            }
        }
    }
};

/// Comprehensive fuzzing test - arithmetic operations
test "fuzz: arithmetic operations vs native u256" {
    var tester = FuzzTester.init(std.crypto.random.int(u64));
    try tester.fuzzArithmetic(1000);
}

/// Comprehensive fuzzing test - bitwise operations  
test "fuzz: bitwise operations vs native u256" {
    var tester = FuzzTester.init(std.crypto.random.int(u64));
    try tester.fuzzBitwise(1000);
}

/// Comprehensive fuzzing test - shift operations
test "fuzz: shift operations vs native u256" {
    var tester = FuzzTester.init(std.crypto.random.int(u64));
    try tester.fuzzShifts(1000);
}

/// Comprehensive fuzzing test - comparison operations
test "fuzz: comparison operations vs native u256" {
    var tester = FuzzTester.init(std.crypto.random.int(u64));
    try tester.fuzzComparisons(1000);
}

/// Comprehensive fuzzing test - mathematical properties
test "fuzz: mathematical properties" {
    var tester = FuzzTester.init(std.crypto.random.int(u64));
    try tester.fuzzProperties(500);
}

/// Comprehensive fuzzing test - overflow detection
test "fuzz: overflow detection accuracy" {
    var tester = FuzzTester.init(std.crypto.random.int(u64));
    try tester.fuzzOverflows(500);
}

/// Long-running stress test
test "fuzz: extended stress test" {
    if (@import("builtin").mode != .ReleaseFast) return; // Only run in release mode
    
    var tester = FuzzTester.init(std.crypto.random.int(u64));
    
    // Run extended tests
    try tester.fuzzArithmetic(10000);
    try tester.fuzzBitwise(10000);
    try tester.fuzzShifts(10000);
    try tester.fuzzComparisons(10000);
    try tester.fuzzProperties(5000);
    try tester.fuzzOverflows(5000);
    
    std.debug.print("Extended fuzzing completed successfully!\n", .{});
}

/// Test specific edge case patterns that often reveal bugs
test "fuzz: edge case patterns" {
    var tester = FuzzTester.init(12345);
    
    // Test patterns that commonly cause issues
    const edge_patterns = [_]U256{
        U256.ZERO,
        U256.ONE,
        U256.MAX,
        U256.MAX.wrapping_sub(U256.ONE),
        U256.from_u64(1),
        U256.from_u64(2),
        U256.from_u64(0xFF),
        U256.from_u64(0x100),
        U256.from_u64(0xFFFF),
        U256.from_u64(0x10000),
        U256.from_u64(0xFFFFFFFF),
        U256.from_u64(0x100000000),
        U256.from_u64(0xFFFFFFFFFFFFFFFF),
        U256.from_limbs(.{ 0xFFFFFFFFFFFFFFFF, 0, 0, 0 }),
        U256.from_limbs(.{ 0, 1, 0, 0 }),
        U256.from_limbs(.{ 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0, 0 }),
        U256.from_limbs(.{ 0, 0, 1, 0 }),
        U256.from_limbs(.{ 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0 }),
        U256.from_limbs(.{ 0, 0, 0, 1 }),
    };
    
    // Test all combinations of edge patterns
    for (edge_patterns, 0..) |a, i| {
        for (edge_patterns, 0..) |b, j| {
            // Test with native comparison
            const a_native = a.to_u256();
            const b_native = b.to_u256();
            
            if (a_native != null and b_native != null) {
                const a_nat = a_native.?;
                const b_nat = b_native.?;
                
                // Test arithmetic
                const add = a.wrapping_add(b);
                const add_nat = a_nat +% b_nat;
                if (add.to_u256()) |add_back| {
                    try testing.expectEqual(add_nat, add_back);
                }
                
                const sub = a.wrapping_sub(b);
                const sub_nat = a_nat -% b_nat;
                if (sub.to_u256()) |sub_back| {
                    try testing.expectEqual(sub_nat, sub_back);
                }
                
                const mul = a.wrapping_mul(b);
                const mul_nat = a_nat *% b_nat;
                if (mul.to_u256()) |mul_back| {
                    try testing.expectEqual(mul_nat, mul_back);
                }
                
                // Test division (skip if b is zero)
                if (!b.is_zero()) {
                    const div = a.wrapping_div(b);
                    const div_nat = a_nat / b_nat;
                    if (div.to_u256()) |div_back| {
                        try testing.expectEqual(div_nat, div_back);
                    }
                }
                
                // Test comparisons
                try testing.expectEqual(a_nat == b_nat, a.eq(b));
                try testing.expectEqual(a_nat < b_nat, a.lt(b));
                try testing.expectEqual(a_nat > b_nat, a.gt(b));
            }
            
            std.debug.print("Edge case testing: {}/{} x {}/{}\n", .{ i + 1, edge_patterns.len, j + 1, edge_patterns.len });
        }
    }
}