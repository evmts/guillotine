/// Memory configuration parameters for EVM memory management
/// 
/// Configures EVM memory behavior including:
/// - Initial capacity for memory allocation (default 4KB)
/// - Maximum memory limit to prevent resource exhaustion (default 16MB) 
/// - Growth strategy and alignment requirements
/// - Integration with gas cost calculations
/// 
/// Memory configuration affects both performance and resource usage.
/// Larger initial capacity reduces allocations, while limits prevent DoS attacks.
const std = @import("std");

pub const MemoryConfig = struct {
    const Self = @This();
    
    // The initial capacity for memory allocation
    initial_capacity: usize = 4096,
    // The maximum memory limit
    memory_limit: u64 = 0xFFFFFF,
    // Whether this memory instance owns its buffer
    owned: bool = true,
    // SIMD vector length for optimized operations (1 = scalar)
    vector_length: comptime_int = 1,
    
    pub fn validate(comptime self: Self) void {
        if (self.memory_limit > std.math.maxInt(u32)) @compileError("memory_limit cannot exceed u32 max");
        if (self.initial_capacity > self.memory_limit) @compileError("initial_capacity cannot exceed memory_limit");
    }
};

test "memory config default values" {
    const config = MemoryConfig{};
    try std.testing.expectEqual(@as(usize, 4096), config.initial_capacity);
    try std.testing.expectEqual(@as(u64, 0xFFFFFF), config.memory_limit);
    
    // Verify default values are valid
    try std.testing.expect(config.initial_capacity <= config.memory_limit);
}

test "memory config custom values" {
    const config = MemoryConfig{
        .initial_capacity = 8192,
        .memory_limit = 0x100000, // 1MB
    };
    
    try std.testing.expectEqual(@as(usize, 8192), config.initial_capacity);
    try std.testing.expectEqual(@as(u64, 0x100000), config.memory_limit);
    try std.testing.expect(config.initial_capacity <= config.memory_limit);
}

test "memory config validation runtime checks" {
    // Test valid configurations
    const valid_config = MemoryConfig{
        .initial_capacity = 1024,
        .memory_limit = 0x10000,
    };
    
    try std.testing.expectEqual(@as(usize, 1024), valid_config.initial_capacity);
    try std.testing.expectEqual(@as(u64, 0x10000), valid_config.memory_limit);
    
    // Test edge case: initial_capacity equals memory_limit
    const edge_config = MemoryConfig{
        .initial_capacity = 1000,
        .memory_limit = 1000,
    };
    
    try std.testing.expectEqual(@as(usize, 1000), edge_config.initial_capacity);
    try std.testing.expectEqual(@as(u64, 1000), edge_config.memory_limit);
}

test "memory config boundary values" {
    // Test minimum valid values
    const min_config = MemoryConfig{
        .initial_capacity = 0,
        .memory_limit = 0,
    };
    
    try std.testing.expectEqual(@as(usize, 0), min_config.initial_capacity);
    try std.testing.expectEqual(@as(u64, 0), min_config.memory_limit);
    
    // Test maximum valid memory limit (u32 max)
    const max_config = MemoryConfig{
        .initial_capacity = 4096,
        .memory_limit = std.math.maxInt(u32),
    };
    
    try std.testing.expectEqual(@as(usize, 4096), max_config.initial_capacity);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u32)), max_config.memory_limit);
}

test "memory config ethereum memory limit" {
    // Test Ethereum's typical memory limit (16MB - 1 byte = 0xFFFFFF)
    const ethereum_config = MemoryConfig{
        .initial_capacity = 4096,      // 4KB initial
        .memory_limit = 0xFFFFFF,      // ~16MB limit
    };
    
    try std.testing.expectEqual(@as(usize, 4096), ethereum_config.initial_capacity);
    try std.testing.expectEqual(@as(u64, 0xFFFFFF), ethereum_config.memory_limit);
    
    // Verify this is less than 32MB
    try std.testing.expect(ethereum_config.memory_limit < 32 * 1024 * 1024);
    // Verify this is about 16MB
    try std.testing.expect(ethereum_config.memory_limit > 15 * 1024 * 1024);
}

test "memory config powers of two" {
    // Test common power-of-two values
    const powers_config = MemoryConfig{
        .initial_capacity = 8192,      // 8KB
        .memory_limit = 1 << 20,       // 1MB
    };
    
    try std.testing.expectEqual(@as(usize, 8192), powers_config.initial_capacity);
    try std.testing.expectEqual(@as(u64, 1 << 20), powers_config.memory_limit);
    try std.testing.expect(std.math.isPowerOfTwo(powers_config.initial_capacity));
    try std.testing.expect(std.math.isPowerOfTwo(powers_config.memory_limit));
}

test "memory config size relationships" {
    const config = MemoryConfig{};
    
    // Initial capacity should be much smaller than memory limit
    try std.testing.expect(config.initial_capacity < config.memory_limit);
    
    // Memory limit should accommodate multiple initial capacity allocations
    const ratio = config.memory_limit / config.initial_capacity;
    try std.testing.expect(ratio > 100); // At least 100x difference
}

test "memory config reasonable sizes" {
    const config = MemoryConfig{};
    
    // Initial capacity should be at least 1KB but not huge
    try std.testing.expect(config.initial_capacity >= 1024);
    try std.testing.expect(config.initial_capacity <= 1024 * 1024); // <= 1MB
    
    // Memory limit should be reasonable for EVM operations
    try std.testing.expect(config.memory_limit >= 1024 * 1024); // >= 1MB
    try std.testing.expect(config.memory_limit <= std.math.maxInt(u32)); // <= u32 max
}