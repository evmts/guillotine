const std = @import("std");

/// Comprehensive test suite for bit operations equivalence between manual and std library implementations.
/// This ensures that replacing manual bit operations with std library functions maintains identical behavior.
///
/// These tests verify that std.math functions produce identical results to manual bit operations
/// across all edge cases and boundary conditions used throughout the EVM codebase.

/// Test that std.math.shl produces identical results to manual left shift
test "shl operations match manual implementation" {
    const test_cases = [_]struct { value: u256, shift: u8, expected: u256 }{
        // Basic cases
        .{ .value = 0x123, .shift = 0, .expected = 0x123 },
        .{ .value = 0x123, .shift = 1, .expected = 0x246 },
        .{ .value = 0x123, .shift = 8, .expected = 0x12300 },
        
        // Boundary cases
        .{ .value = 1, .shift = 255, .expected = (@as(u256, 1) << 255) },
        .{ .value = 0x123, .shift = 256, .expected = 0 }, // Should be 0 for >= bitwidth
        
        // Zero cases
        .{ .value = 0, .shift = 8, .expected = 0 },
        .{ .value = 0x123, .shift = 0, .expected = 0x123 },
        
        // Maximum value cases
        .{ .value = std.math.maxInt(u256), .shift = 0, .expected = std.math.maxInt(u256) },
        .{ .value = std.math.maxInt(u256), .shift = 1, .expected = 0 }, // Overflow to 0
    };
    
    for (test_cases) |case| {
        // Manual implementation (current)
        const manual_result = if (case.shift >= 256) 0 else (case.value << case.shift);
        
        // Std library implementation (target)
        const std_result = if (case.shift >= 256) 0 else std.math.shl(u256, case.value, case.shift);
        
        try std.testing.expectEqual(case.expected, manual_result);
        try std.testing.expectEqual(case.expected, std_result);
        try std.testing.expectEqual(manual_result, std_result);
    }
}

/// Test that std.math.shr produces identical results to manual right shift
test "shr operations match manual implementation" {
    const test_cases = [_]struct { value: u256, shift: u8, expected: u256 }{
        // Basic cases
        .{ .value = 0x123456, .shift = 0, .expected = 0x123456 },
        .{ .value = 0x123456, .shift = 1, .expected = 0x91a2b },
        .{ .value = 0x123456, .shift = 8, .expected = 0x1234 },
        .{ .value = 0x123456, .shift = 4, .expected = 0x12345 },
        
        // Boundary cases
        .{ .value = std.math.maxInt(u256), .shift = 255, .expected = 1 },
        .{ .value = 0x123456, .shift = 256, .expected = 0 }, // Should be 0 for >= bitwidth
        
        // Zero cases
        .{ .value = 0, .shift = 8, .expected = 0 },
        .{ .value = 0x123456, .shift = 0, .expected = 0x123456 },
        
        // Large shift cases
        .{ .value = (@as(u256, 1) << 255), .shift = 255, .expected = 1 },
    };
    
    for (test_cases) |case| {
        // Manual implementation (current)
        const manual_result = if (case.shift >= 256) 0 else (case.value >> case.shift);
        
        // Std library implementation (target)
        const std_result = if (case.shift >= 256) 0 else std.math.shr(u256, case.value, case.shift);
        
        try std.testing.expectEqual(case.expected, manual_result);
        try std.testing.expectEqual(case.expected, std_result);
        try std.testing.expectEqual(manual_result, std_result);
    }
}

/// Test byte extraction pattern used in BYTE opcode (handlers_bitwise.zig:58)
test "byte extraction operations match manual implementation" {
    const test_value: u256 = 0x123456789abcdef0fedcba9876543210;
    
    const test_cases = [_]struct { byte_index: usize, expected: u8 }{
        .{ .byte_index = 0, .expected = 0x10 }, // Rightmost byte
        .{ .byte_index = 1, .expected = 0x32 },
        .{ .byte_index = 15, .expected = 0xf0 },
        .{ .byte_index = 31, .expected = 0x12 }, // Leftmost byte
    };
    
    for (test_cases) |case| {
        const shift_amount = (31 - case.byte_index) * 8;
        
        // Manual implementation (current)
        const manual_result = @as(u8, @truncate((test_value >> shift_amount) & 0xFF));
        
        // Std library implementation (target)
        const std_result = @as(u8, @truncate(std.math.shr(u256, test_value, shift_amount) & 0xFF));
        
        try std.testing.expectEqual(case.expected, manual_result);
        try std.testing.expectEqual(case.expected, std_result);
        try std.testing.expectEqual(manual_result, std_result);
    }
}

/// Test mask creation patterns found throughout the codebase
test "mask creation operations match manual implementation" {
    const test_cases = [_]struct { bits: u8, expected: u256 }{
        .{ .bits = 0, .expected = 0 },
        .{ .bits = 1, .expected = 1 },
        .{ .bits = 8, .expected = 0xFF },
        .{ .bits = 16, .expected = 0xFFFF },
        .{ .bits = 32, .expected = 0xFFFFFFFF },
        .{ .bits = 64, .expected = 0xFFFFFFFFFFFFFFFF },
        .{ .bits = 128, .expected = (@as(u256, 1) << 128) - 1 },
        .{ .bits = 255, .expected = (@as(u256, 1) << 255) - 1 },
    };
    
    for (test_cases) |case| {
        // Manual implementation (current pattern found in codebase)
        const manual_mask = if (case.bits == 0) 0 else (@as(u256, 1) << case.bits) - 1;
        
        // Std library implementation (target)
        const std_mask = if (case.bits == 0) 0 else std.math.shl(u256, 1, case.bits) - 1;
        
        try std.testing.expectEqual(case.expected, manual_mask);
        try std.testing.expectEqual(case.expected, std_mask);
        try std.testing.expectEqual(manual_mask, std_mask);
    }
}

/// Test byte packing patterns found in bytecode operations
test "byte packing operations match manual implementation" {
    const test_cases = [_]struct { initial: u256, byte_val: u8, expected: u256 }{
        .{ .initial = 0x1234, .byte_val = 0xAB, .expected = 0x1234AB },
        .{ .initial = 0, .byte_val = 0xFF, .expected = 0xFF },
        .{ .initial = 0xFF, .byte_val = 0x00, .expected = 0xFF00 },
        .{ .initial = 0x123456789abcdef0, .byte_val = 0x42, .expected = 0x123456789abcdef042 },
    };
    
    for (test_cases) |case| {
        // Manual implementation (current pattern found in bytecode.zig)
        const manual_result = (case.initial << 8) | case.byte_val;
        
        // Std library implementation (target)
        const std_result = std.math.shl(u256, case.initial, 8) | case.byte_val;
        
        try std.testing.expectEqual(case.expected, manual_result);
        try std.testing.expectEqual(case.expected, std_result);
        try std.testing.expectEqual(manual_result, std_result);
    }
}

/// Test address byte extraction patterns found in database operations
test "address byte extraction matches manual implementation" {
    const test_addr: u256 = 0x1234567890abcdef1234567890abcdef12345678;
    
    for (0..20) |i| {
        const byte_offset = i * 8;
        
        // Manual implementation (current pattern in database.zig)
        const manual_byte = @as(u8, @truncate((test_addr >> byte_offset) & 0xFF));
        
        // Std library implementation (target)
        const std_byte = @as(u8, @truncate(std.math.shr(u256, test_addr, byte_offset) & 0xFF));
        
        try std.testing.expectEqual(manual_byte, std_byte);
    }
}

/// Test edge cases for all bit operations
test "bit operations edge cases" {
    // Test with zero
    try std.testing.expectEqual(@as(u256, 0), std.math.shl(u256, 0, 8));
    try std.testing.expectEqual(@as(u256, 0), std.math.shr(u256, 0, 8));
    
    // Test with maximum values
    const max_u256 = std.math.maxInt(u256);
    try std.testing.expectEqual(@as(u256, 0), std.math.shl(u256, max_u256, 1)); // Overflow
    try std.testing.expectEqual(@as(u256, 1), std.math.shr(u256, (@as(u256, 1) << 255), 255));
    
    // Test shift by zero
    const test_val: u256 = 0x123456789abcdef0;
    try std.testing.expectEqual(test_val, std.math.shl(u256, test_val, 0));
    try std.testing.expectEqual(test_val, std.math.shr(u256, test_val, 0));
    
    // Test maximum shift amounts
    try std.testing.expectEqual(@as(u256, 0), std.math.shl(u256, test_val, 256));
    try std.testing.expectEqual(@as(u256, 0), std.math.shr(u256, test_val, 256));
}

/// Test that all operations maintain EVM 256-bit word semantics
test "evm word semantics preserved" {
    // EVM uses 256-bit words, ensure operations respect this
    const evm_word: u256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    
    // Left shift should zero out on overflow
    try std.testing.expectEqual(@as(u256, 0), std.math.shl(u256, evm_word, 1));
    
    // Right shift should preserve precision
    const half_word = std.math.shr(u256, evm_word, 1);
    try std.testing.expectEqual(@as(u256, 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff), half_word);
    
    // Byte extraction should work with full word
    const top_byte = @as(u8, @truncate(std.math.shr(u256, evm_word, 248) & 0xFF));
    try std.testing.expectEqual(@as(u8, 0xFF), top_byte);
}