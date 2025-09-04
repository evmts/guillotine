const std = @import("std");
const testing = std.testing;
const primitives = @import("../src/primitives/uint.zig");

// Type aliases for clarity
const U256 = primitives.Uint(256, 4);

/// Test cases inspired by holiman/uint256 comprehensive test suite
/// These tests focus on edge cases and boundary conditions that are critical for EVM operations

/// Test addition with various edge cases
test "holiman style: addition edge cases" {
    // Test adding zero
    try testing.expect(U256.ZERO.wrapping_add(U256.ZERO).eq(U256.ZERO));
    try testing.expect(U256.MAX.wrapping_add(U256.ZERO).eq(U256.MAX));
    try testing.expect(U256.ZERO.wrapping_add(U256.MAX).eq(U256.MAX));
    
    // Test adding one
    try testing.expect(U256.ZERO.wrapping_add(U256.ONE).eq(U256.ONE));
    try testing.expect(U256.ONE.wrapping_add(U256.ZERO).eq(U256.ONE));
    
    // Test overflow: MAX + 1 = 0 (wrapping)
    const max_plus_one = U256.MAX.wrapping_add(U256.ONE);
    try testing.expect(max_plus_one.eq(U256.ZERO));
    
    // Test overflow: MAX + MAX = MAX - 1 (wrapping)
    const max_plus_max = U256.MAX.wrapping_add(U256.MAX);
    const expected = U256.MAX.wrapping_sub(U256.ONE);
    try testing.expect(max_plus_max.eq(expected));
    
    // Test limb boundary cases
    const limb_boundary = U256.from_limbs(.{ 0xFFFFFFFFFFFFFFFF, 0, 0, 0 });
    const result = limb_boundary.wrapping_add(U256.ONE);
    const expected_result = U256.from_limbs(.{ 0, 1, 0, 0 });
    try testing.expect(result.eq(expected_result));
}

/// Test subtraction with various edge cases
test "holiman style: subtraction edge cases" {
    // Test subtracting zero
    try testing.expect(U256.ZERO.wrapping_sub(U256.ZERO).eq(U256.ZERO));
    try testing.expect(U256.MAX.wrapping_sub(U256.ZERO).eq(U256.MAX));
    
    // Test subtracting from zero (underflow)
    const zero_minus_one = U256.ZERO.wrapping_sub(U256.ONE);
    try testing.expect(zero_minus_one.eq(U256.MAX));
    
    // Test subtracting from one
    try testing.expect(U256.ONE.wrapping_sub(U256.ONE).eq(U256.ZERO));
    try testing.expect(U256.ONE.wrapping_sub(U256.ZERO).eq(U256.ONE));
    
    // Test limb boundary cases
    const limb_boundary = U256.from_limbs(.{ 0, 1, 0, 0 });
    const result = limb_boundary.wrapping_sub(U256.ONE);
    const expected_result = U256.from_limbs(.{ 0xFFFFFFFFFFFFFFFF, 0, 0, 0 });
    try testing.expect(result.eq(expected_result));
}

/// Test multiplication edge cases
test "holiman style: multiplication edge cases" {
    // Test multiplying by zero
    try testing.expect(U256.ZERO.wrapping_mul(U256.ZERO).eq(U256.ZERO));
    try testing.expect(U256.MAX.wrapping_mul(U256.ZERO).eq(U256.ZERO));
    try testing.expect(U256.ZERO.wrapping_mul(U256.MAX).eq(U256.ZERO));
    
    // Test multiplying by one
    try testing.expect(U256.ZERO.wrapping_mul(U256.ONE).eq(U256.ZERO));
    try testing.expect(U256.ONE.wrapping_mul(U256.ONE).eq(U256.ONE));
    try testing.expect(U256.MAX.wrapping_mul(U256.ONE).eq(U256.MAX));
    
    // Test powers of 2
    const val = U256.from_u64(0x12345678);
    const doubled = val.wrapping_mul(U256.from_u64(2));
    const shifted = val.wrapping_shl(1);
    try testing.expect(doubled.eq(shifted));
    
    // Test large multiplication that overflows
    const large = U256.from_limbs(.{ 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0, 0 });
    const result = large.wrapping_mul(U256.from_u64(2));
    const expected = U256.from_limbs(.{ 0xFFFFFFFFFFFFFFFE, 0xFFFFFFFFFFFFFFFF, 1, 0 });
    try testing.expect(result.eq(expected));
}

/// Test division and remainder edge cases
test "holiman style: division edge cases" {
    // Division by one
    try testing.expect(U256.ZERO.wrapping_div(U256.ONE).eq(U256.ZERO));
    try testing.expect(U256.ONE.wrapping_div(U256.ONE).eq(U256.ONE));
    try testing.expect(U256.MAX.wrapping_div(U256.ONE).eq(U256.MAX));
    
    // Self division
    const val = U256.from_u64(42);
    try testing.expect(val.wrapping_div(val).eq(U256.ONE));
    try testing.expect(val.wrapping_rem(val).eq(U256.ZERO));
    
    // Division by powers of 2
    const large_val = U256.from_limbs(.{ 0x1000, 0, 0, 0 });
    const div_by_2 = large_val.wrapping_div(U256.from_u64(2));
    const shr_by_1 = large_val.wrapping_shr(1);
    try testing.expect(div_by_2.eq(shr_by_1));
    
    // Remainder properties
    const dividend = U256.from_u64(17);
    const divisor = U256.from_u64(5);
    const quotient = dividend.wrapping_div(divisor);
    const remainder = dividend.wrapping_rem(divisor);
    const reconstructed = quotient.wrapping_mul(divisor).wrapping_add(remainder);
    try testing.expect(reconstructed.eq(dividend));
}

/// Test bitwise operations edge cases
test "holiman style: bitwise operations edge cases" {
    // AND operations
    try testing.expect(U256.ZERO.bit_and(U256.ZERO).eq(U256.ZERO));
    try testing.expect(U256.MAX.bit_and(U256.ZERO).eq(U256.ZERO));
    try testing.expect(U256.ZERO.bit_and(U256.MAX).eq(U256.ZERO));
    try testing.expect(U256.MAX.bit_and(U256.MAX).eq(U256.MAX));
    
    // OR operations
    try testing.expect(U256.ZERO.bit_or(U256.ZERO).eq(U256.ZERO));
    try testing.expect(U256.MAX.bit_or(U256.ZERO).eq(U256.MAX));
    try testing.expect(U256.ZERO.bit_or(U256.MAX).eq(U256.MAX));
    try testing.expect(U256.MAX.bit_or(U256.MAX).eq(U256.MAX));
    
    // XOR operations
    try testing.expect(U256.ZERO.bit_xor(U256.ZERO).eq(U256.ZERO));
    try testing.expect(U256.MAX.bit_xor(U256.ZERO).eq(U256.MAX));
    try testing.expect(U256.ZERO.bit_xor(U256.MAX).eq(U256.MAX));
    try testing.expect(U256.MAX.bit_xor(U256.MAX).eq(U256.ZERO));
    
    // NOT operation
    try testing.expect(U256.ZERO.bit_not().eq(U256.MAX));
    try testing.expect(U256.MAX.bit_not().eq(U256.ZERO));
    
    // De Morgan's laws
    const a = U256.from_u64(0xAAAAAAAAAAAAAAAA);
    const b = U256.from_u64(0x5555555555555555);
    
    // ~(a & b) == (~a) | (~b)
    const not_and = a.bit_and(b).bit_not();
    const not_a_or_not_b = a.bit_not().bit_or(b.bit_not());
    try testing.expect(not_and.eq(not_a_or_not_b));
    
    // ~(a | b) == (~a) & (~b)
    const not_or = a.bit_or(b).bit_not();
    const not_a_and_not_b = a.bit_not().bit_and(b.bit_not());
    try testing.expect(not_or.eq(not_a_and_not_b));
}

/// Test shift operations edge cases
test "holiman style: shift operations edge cases" {
    // Shifting by zero
    const val = U256.from_u64(0x12345678);
    try testing.expect(val.wrapping_shl(0).eq(val));
    try testing.expect(val.wrapping_shr(0).eq(val));
    
    // Shifting zero
    try testing.expect(U256.ZERO.wrapping_shl(1).eq(U256.ZERO));
    try testing.expect(U256.ZERO.wrapping_shr(1).eq(U256.ZERO));
    try testing.expect(U256.ZERO.wrapping_shl(255).eq(U256.ZERO));
    try testing.expect(U256.ZERO.wrapping_shr(255).eq(U256.ZERO));
    
    // Left shift by 1 == multiply by 2
    const small = U256.from_u64(100);
    try testing.expect(small.wrapping_shl(1).eq(small.wrapping_mul(U256.from_u64(2))));
    
    // Right shift by 1 == divide by 2 (for even numbers)
    const even = U256.from_u64(200);
    try testing.expect(even.wrapping_shr(1).eq(even.wrapping_div(U256.from_u64(2))));
    
    // Shift across limb boundaries
    const one_shifted_64 = U256.ONE.wrapping_shl(64);
    const expected_64 = U256.from_limbs(.{ 0, 1, 0, 0 });
    try testing.expect(one_shifted_64.eq(expected_64));
    
    const one_shifted_128 = U256.ONE.wrapping_shl(128);
    const expected_128 = U256.from_limbs(.{ 0, 0, 1, 0 });
    try testing.expect(one_shifted_128.eq(expected_128));
    
    const one_shifted_192 = U256.ONE.wrapping_shl(192);
    const expected_192 = U256.from_limbs(.{ 0, 0, 0, 1 });
    try testing.expect(one_shifted_192.eq(expected_192));
    
    // Large shifts result in zero
    try testing.expect(U256.ONE.wrapping_shl(256).eq(U256.ZERO));
    try testing.expect(U256.MAX.wrapping_shr(256).eq(U256.ZERO));
}

/// Test comparison operations edge cases
test "holiman style: comparison edge cases" {
    // Self comparison
    try testing.expect(U256.ZERO.eq(U256.ZERO));
    try testing.expect(U256.ONE.eq(U256.ONE));
    try testing.expect(U256.MAX.eq(U256.MAX));
    
    // Ordering
    try testing.expect(U256.ZERO.lt(U256.ONE));
    try testing.expect(U256.ONE.gt(U256.ZERO));
    try testing.expect(!U256.ZERO.gt(U256.ONE));
    try testing.expect(!U256.ONE.lt(U256.ZERO));
    
    // Adjacent values
    const val = U256.from_u64(100);
    const val_plus_one = val.wrapping_add(U256.ONE);
    try testing.expect(val.lt(val_plus_one));
    try testing.expect(val_plus_one.gt(val));
    
    // Limb boundary comparisons
    const low_limb_max = U256.from_limbs(.{ 0xFFFFFFFFFFFFFFFF, 0, 0, 0 });
    const next_limb_min = U256.from_limbs(.{ 0, 1, 0, 0 });
    try testing.expect(low_limb_max.lt(next_limb_min));
    try testing.expect(next_limb_min.gt(low_limb_max));
}

/// Test conversion edge cases  
test "holiman style: conversion edge cases" {
    // Round trip: u256 -> U256 -> u256
    const native_zero: u256 = 0;
    const native_one: u256 = 1;
    const native_max: u256 = std.math.maxInt(u256);
    
    try testing.expectEqual(native_zero, U256.from_u256(native_zero).to_u256().?);
    try testing.expectEqual(native_one, U256.from_u256(native_one).to_u256().?);
    try testing.expectEqual(native_max, U256.from_u256(native_max).to_u256().?);
    
    // u64 conversions
    const u64_max = std.math.maxInt(u64);
    const u256_from_u64_max = U256.from_u64(u64_max);
    const expected = U256.from_limbs(.{ u64_max, 0, 0, 0 });
    try testing.expect(u256_from_u64_max.eq(expected));
}

/// Test mathematical invariants and properties that should hold
test "holiman style: mathematical invariants" {
    const test_vals = [_]U256{
        U256.ZERO,
        U256.ONE,
        U256.from_u64(2),
        U256.from_u64(1000),
        U256.from_u64(0xFFFFFFFF),
        U256.from_u64(0x100000000),
        U256.from_limbs(.{ 0xFFFFFFFFFFFFFFFF, 0, 0, 0 }),
        U256.from_limbs(.{ 0, 1, 0, 0 }),
        U256.from_limbs(.{ 0, 0, 1, 0 }),
        U256.from_limbs(.{ 0, 0, 0, 1 }),
        U256.MAX.wrapping_sub(U256.ONE),
        U256.MAX,
    };
    
    for (test_vals) |a| {
        for (test_vals) |b| {
            if (b.is_zero()) continue; // Skip division by zero
            
            // Test a + 0 = a
            try testing.expect(a.wrapping_add(U256.ZERO).eq(a));
            
            // Test a * 1 = a
            try testing.expect(a.wrapping_mul(U256.ONE).eq(a));
            
            // Test a * 0 = 0
            try testing.expect(a.wrapping_mul(U256.ZERO).eq(U256.ZERO));
            
            // Test a - a = 0
            try testing.expect(a.wrapping_sub(a).eq(U256.ZERO));
            
            // Test a / a = 1 (when a != 0)
            if (!a.is_zero()) {
                try testing.expect(a.wrapping_div(a).eq(U256.ONE));
                try testing.expect(a.wrapping_rem(a).eq(U256.ZERO));
            }
            
            // Test commutativity: a + b = b + a
            try testing.expect(a.wrapping_add(b).eq(b.wrapping_add(a)));
            try testing.expect(a.wrapping_mul(b).eq(b.wrapping_mul(a)));
            
            // Test (a / b) * b + (a % b) = a
            const quotient = a.wrapping_div(b);
            const remainder = a.wrapping_rem(b);
            const reconstructed = quotient.wrapping_mul(b).wrapping_add(remainder);
            try testing.expect(reconstructed.eq(a));
            
            // Test bitwise operations
            try testing.expect(a.bit_and(a).eq(a));
            try testing.expect(a.bit_or(a).eq(a));
            try testing.expect(a.bit_xor(a).eq(U256.ZERO));
            try testing.expect(a.bit_and(U256.ZERO).eq(U256.ZERO));
            try testing.expect(a.bit_or(U256.ZERO).eq(a));
            try testing.expect(a.bit_xor(U256.ZERO).eq(a));
        }
    }
}

/// Test specific patterns that caused issues in holiman/uint256 development
test "holiman style: regression test patterns" {
    // Pattern: alternating bits
    const alternating = U256.from_limbs(.{ 
        0xAAAAAAAAAAAAAAAA, 
        0x5555555555555555,
        0xAAAAAAAAAAAAAAAA, 
        0x5555555555555555 
    });
    
    const inverse = U256.from_limbs(.{ 
        0x5555555555555555, 
        0xAAAAAAAAAAAAAAAA,
        0x5555555555555555, 
        0xAAAAAAAAAAAAAAAA 
    });
    
    // Should XOR to all 1s
    try testing.expect(alternating.bit_xor(inverse).eq(U256.MAX));
    
    // Pattern: single bit positions
    for (0..256) |i| {
        const shift: u32 = @intCast(i);
        const single_bit = U256.ONE.wrapping_shl(shift);
        
        // Single bit should have exactly one bit set
        if (@hasDecl(U256, "count_ones")) {
            try testing.expectEqual(@as(u32, 1), single_bit.count_ones());
        }
        
        // Shifting back should give original
        const shifted_back = single_bit.wrapping_shr(shift);
        if (i < 256) {
            try testing.expect(shifted_back.eq(U256.ONE));
        }
    }
    
    // Pattern: carries across all limb boundaries
    const all_f_except_last = U256.from_limbs(.{ 
        0xFFFFFFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF, 
        0xFFFFFFFFFFFFFFFF,
        0 
    });
    const result = all_f_except_last.wrapping_add(U256.ONE);
    const expected = U256.from_limbs(.{ 0, 0, 0, 1 });
    try testing.expect(result.eq(expected));
}