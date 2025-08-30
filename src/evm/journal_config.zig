/// Configuration options for the Journal implementation
const std = @import("std");

pub const JournalConfig = struct {
    /// Type used for snapshot IDs
    SnapshotIdType: type = u32,
    
    /// Type used for word-sized values (balances, storage values, etc.)
    WordType: type = u256,
    
    /// Type used for nonces
    NonceType: type = u64,
    
    /// Initial capacity for journal entries
    initial_capacity: usize = 128,
    
    /// Whether to use data-oriented design for entries
    use_soa: bool = false,
    
    pub fn validate(comptime self: JournalConfig) void {
        // Validate SnapshotIdType is an unsigned integer
        const snapshot_info = @typeInfo(self.SnapshotIdType);
        if (snapshot_info != .int or snapshot_info.int.signedness != .unsigned) {
            @compileError("SnapshotIdType must be an unsigned integer");
        }
        
        // Validate WordType is an unsigned integer
        const word_info = @typeInfo(self.WordType);
        if (word_info != .int or word_info.int.signedness != .unsigned) {
            @compileError("WordType must be an unsigned integer");
        }
        
        // Validate NonceType is an unsigned integer
        const nonce_info = @typeInfo(self.NonceType);
        if (nonce_info != .int or nonce_info.int.signedness != .unsigned) {
            @compileError("NonceType must be an unsigned integer");
        }
        
        // Validate initial capacity
        if (self.initial_capacity == 0) {
            @compileError("initial_capacity must be greater than 0");
        }
    }
    
    /// Returns the optimal snapshot ID type based on maximum expected snapshots
    pub fn get_optimal_snapshot_type(max_snapshots: usize) type {
        if (max_snapshots <= std.math.maxInt(u8)) return u8;
        if (max_snapshots <= std.math.maxInt(u16)) return u16;
        if (max_snapshots <= std.math.maxInt(u32)) return u32;
        return u64;
    }
};

/// Default configuration for EVM journal
pub const default_config = JournalConfig{};

/// Minimal configuration for testing
pub const minimal_config = JournalConfig{
    .SnapshotIdType = u8,
    .WordType = u64,
    .NonceType = u32,
    .initial_capacity = 16,
};

/// Configuration for maximum performance with data-oriented design
pub const performance_config = JournalConfig{
    .SnapshotIdType = u16,
    .WordType = u256,
    .NonceType = u64,
    .initial_capacity = 256,
    .use_soa = true,
};

test "JournalConfig validation" {
    const testing = std.testing;
    
    // Test default config
    default_config.validate();
    
    // Test minimal config
    minimal_config.validate();
    
    // Test performance config
    performance_config.validate();
    
    // Test optimal snapshot type selection
    try testing.expectEqual(u8, JournalConfig.get_optimal_snapshot_type(100));
    try testing.expectEqual(u16, JournalConfig.get_optimal_snapshot_type(1000));
    try testing.expectEqual(u32, JournalConfig.get_optimal_snapshot_type(100000));
    try testing.expectEqual(u64, JournalConfig.get_optimal_snapshot_type(std.math.maxInt(u64)));
}

test "JournalConfig - default configuration values" {
    const testing = std.testing;
    
    try testing.expectEqual(u32, default_config.SnapshotIdType);
    try testing.expectEqual(u256, default_config.WordType);
    try testing.expectEqual(u64, default_config.NonceType);
    try testing.expectEqual(@as(usize, 128), default_config.initial_capacity);
    try testing.expectEqual(false, default_config.use_soa);
}

test "JournalConfig - minimal configuration values" {
    const testing = std.testing;
    
    try testing.expectEqual(u8, minimal_config.SnapshotIdType);
    try testing.expectEqual(u64, minimal_config.WordType);
    try testing.expectEqual(u32, minimal_config.NonceType);
    try testing.expectEqual(@as(usize, 16), minimal_config.initial_capacity);
    try testing.expectEqual(false, minimal_config.use_soa);
}

test "JournalConfig - performance configuration values" {
    const testing = std.testing;
    
    try testing.expectEqual(u16, performance_config.SnapshotIdType);
    try testing.expectEqual(u256, performance_config.WordType);
    try testing.expectEqual(u64, performance_config.NonceType);
    try testing.expectEqual(@as(usize, 256), performance_config.initial_capacity);
    try testing.expectEqual(true, performance_config.use_soa);
}

test "JournalConfig - custom configuration" {
    const testing = std.testing;
    
    const custom_config = JournalConfig{
        .SnapshotIdType = u16,
        .WordType = u128,
        .NonceType = u32,
        .initial_capacity = 64,
        .use_soa = true,
    };
    
    custom_config.validate();
    
    try testing.expectEqual(u16, custom_config.SnapshotIdType);
    try testing.expectEqual(u128, custom_config.WordType);
    try testing.expectEqual(u32, custom_config.NonceType);
    try testing.expectEqual(@as(usize, 64), custom_config.initial_capacity);
    try testing.expectEqual(true, custom_config.use_soa);
}

test "JournalConfig - maximum values configuration" {
    const testing = std.testing;
    
    const max_config = JournalConfig{
        .SnapshotIdType = u64,
        .WordType = u256,
        .NonceType = u64,
        .initial_capacity = std.math.maxInt(u16), // Large but reasonable capacity
        .use_soa = true,
    };
    
    max_config.validate();
    
    try testing.expectEqual(u64, max_config.SnapshotIdType);
    try testing.expectEqual(u256, max_config.WordType);
    try testing.expectEqual(u64, max_config.NonceType);
    try testing.expectEqual(@as(usize, std.math.maxInt(u16)), max_config.initial_capacity);
    try testing.expectEqual(true, max_config.use_soa);
}

test "JournalConfig - optimal snapshot type selection boundary values" {
    const testing = std.testing;
    
    // Test boundary values for u8
    try testing.expectEqual(u8, JournalConfig.get_optimal_snapshot_type(1));
    try testing.expectEqual(u8, JournalConfig.get_optimal_snapshot_type(std.math.maxInt(u8)));
    try testing.expectEqual(u16, JournalConfig.get_optimal_snapshot_type(std.math.maxInt(u8) + 1));
    
    // Test boundary values for u16
    try testing.expectEqual(u16, JournalConfig.get_optimal_snapshot_type(std.math.maxInt(u16)));
    try testing.expectEqual(u32, JournalConfig.get_optimal_snapshot_type(std.math.maxInt(u16) + 1));
    
    // Test boundary values for u32
    try testing.expectEqual(u32, JournalConfig.get_optimal_snapshot_type(std.math.maxInt(u32)));
    try testing.expectEqual(u64, JournalConfig.get_optimal_snapshot_type(@as(usize, std.math.maxInt(u32)) + 1));
    
    // Test very large values
    try testing.expectEqual(u64, JournalConfig.get_optimal_snapshot_type(std.math.maxInt(usize)));
}

test "JournalConfig - zero capacity edge case" {
    const testing = std.testing;
    
    // This should trigger a compile error, but we can't test that directly
    // Instead we test that non-zero capacities work
    const valid_config = JournalConfig{
        .initial_capacity = 1, // Minimum valid capacity
    };
    
    valid_config.validate();
    try testing.expectEqual(@as(usize, 1), valid_config.initial_capacity);
}

test "JournalConfig - all unsigned integer types" {
    _ = std.testing;
    
    // Test with various unsigned integer types
    const u8_config = JournalConfig{
        .SnapshotIdType = u8,
        .WordType = u8,
        .NonceType = u8,
        .initial_capacity = 1,
    };
    u8_config.validate();
    
    const u16_config = JournalConfig{
        .SnapshotIdType = u16,
        .WordType = u16,
        .NonceType = u16,
        .initial_capacity = 1,
    };
    u16_config.validate();
    
    const u32_config = JournalConfig{
        .SnapshotIdType = u32,
        .WordType = u32,
        .NonceType = u32,
        .initial_capacity = 1,
    };
    u32_config.validate();
    
    const u64_config = JournalConfig{
        .SnapshotIdType = u64,
        .WordType = u64,
        .NonceType = u64,
        .initial_capacity = 1,
    };
    u64_config.validate();
    
    const u128_config = JournalConfig{
        .SnapshotIdType = u128,
        .WordType = u128,
        .NonceType = u128,
        .initial_capacity = 1,
    };
    u128_config.validate();
    
    const u256_config = JournalConfig{
        .SnapshotIdType = u256,
        .WordType = u256,
        .NonceType = u256,
        .initial_capacity = 1,
    };
    u256_config.validate();
}

test "JournalConfig - mixed type sizes configuration" {
    const testing = std.testing;
    
    const mixed_config = JournalConfig{
        .SnapshotIdType = u8,    // Small snapshot ID
        .WordType = u256,        // Large word type
        .NonceType = u16,        // Medium nonce type
        .initial_capacity = 32,
        .use_soa = false,
    };
    
    mixed_config.validate();
    
    try testing.expectEqual(u8, mixed_config.SnapshotIdType);
    try testing.expectEqual(u256, mixed_config.WordType);
    try testing.expectEqual(u16, mixed_config.NonceType);
    try testing.expectEqual(@as(usize, 32), mixed_config.initial_capacity);
    try testing.expectEqual(false, mixed_config.use_soa);
}

test "JournalConfig - soa flag variations" {
    const testing = std.testing;
    
    const soa_enabled = JournalConfig{
        .use_soa = true,
    };
    soa_enabled.validate();
    try testing.expectEqual(true, soa_enabled.use_soa);
    
    const soa_disabled = JournalConfig{
        .use_soa = false,
    };
    soa_disabled.validate();
    try testing.expectEqual(false, soa_disabled.use_soa);
}

test "JournalConfig - large initial capacity" {
    const testing = std.testing;
    
    const large_config = JournalConfig{
        .initial_capacity = 1024 * 1024, // 1MB worth of entries
    };
    
    large_config.validate();
    try testing.expectEqual(@as(usize, 1024 * 1024), large_config.initial_capacity);
}