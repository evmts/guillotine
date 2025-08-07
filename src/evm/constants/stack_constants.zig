const std = @import("std");

/// EVM Stack Constants
/// 
/// This file contains constants related to the EVM's operand stack,
/// which stores 256-bit words and has a maximum depth of 1024 elements.

/// Maximum number of elements that can be stored on the EVM stack
/// This is defined in the Ethereum Yellow Paper
pub const CAPACITY: usize = 1024;

test "stack constants are correct" {
    const testing = std.testing;
    
    // Verify stack capacity matches EVM specification
    try testing.expectEqual(@as(usize, 1024), CAPACITY);
    
    // Verify capacity is a power of 2 for efficient operations
    try testing.expect(std.math.isPowerOfTwo(CAPACITY));
}