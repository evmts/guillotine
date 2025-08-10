const std = @import("std");

/// EVM Runtime Limits
///
/// This file contains constants that define execution limits and boundaries for the EVM,
/// including call depth, code sizes, input limits, and other runtime constraints.
/// Maximum call depth allowed in the EVM (1024 levels)
/// This prevents infinite recursion and stack overflow attacks
pub const MAX_CALL_DEPTH: u11 = 1024;

/// Maximum EVM contract bytecode size in bytes (24KB - EIP-170)
/// This is enforced at contract deployment time
pub const MAX_CODE_SIZE: u32 = 24576;

/// Gas cost per byte of deployed code (200 gas per byte)
/// Applied when deploying contracts with CREATE/CREATE2
pub const DEPLOY_CODE_GAS_PER_BYTE: u64 = 200;

/// Maximum input size for interpreter operations (128 KB)
/// This prevents excessive memory usage in single operations
pub const MAX_INPUT_SIZE: u18 = 128 * 1024; // 128 kb

/// Cache line size for alignment optimizations (64 bytes)
/// Used in jump table and other performance-critical structures
pub const CACHE_LINE_SIZE = 64;

/// Maximum number of precompiles supported
/// Used for precompile table sizing
pub const MAX_PRECOMPILES = 10;

/// EIP-7702 magic bytes for account delegation
/// Used to identify delegated accounts in EIP-7702
pub const EIP7702_MAGIC_BYTES = [2]u8{ 0xE7, 0x02 };

/// Transaction type identifier for blob transactions (EIP-4844)
pub const BLOB_TX_TYPE = 0x03;

/// Memory expansion lookup table size
/// Covers 0-4KB in 32-byte words for fast gas calculations
pub const SMALL_MEMORY_LOOKUP_SIZE = 128;

/// Buffer sizes for crypto operations
pub const SMALL_BUFFER_SIZE = 64; // Most common (addresses, small data)
pub const MEDIUM_BUFFER_SIZE = 256; // Common for event data
pub const LARGE_BUFFER_SIZE = 1024; // Reasonable max for stack allocation

/// Page size for memory allocator (4KB)
pub const PAGE_SIZE: usize = 4096;

/// Compile-time log version for debugging
pub const COMPILE_TIME_LOG_VERSION = "2024_LOG_FIX_V2";

test "evm limits are reasonable" {
    const testing = std.testing;

    // Verify call depth is within reasonable bounds
    try testing.expect(MAX_CALL_DEPTH >= 256);
    try testing.expect(MAX_CALL_DEPTH <= 4096);

    // Verify code size matches EIP-170
    try testing.expectEqual(@as(u32, 24576), MAX_CODE_SIZE);
    try testing.expectEqual(@as(u32, 0x6000), MAX_CODE_SIZE);

    // Verify input size is reasonable
    try testing.expect(MAX_INPUT_SIZE >= 64 * 1024); // At least 64KB
    try testing.expect(MAX_INPUT_SIZE <= 1024 * 1024); // At most 1MB
}

test "magic bytes are correct" {
    const testing = std.testing;

    // EIP-7702 magic bytes
    try testing.expectEqual(@as(u8, 0xE7), EIP7702_MAGIC_BYTES[0]);
    try testing.expectEqual(@as(u8, 0x02), EIP7702_MAGIC_BYTES[1]);

    // Blob transaction type
    try testing.expectEqual(@as(u8, 0x03), BLOB_TX_TYPE);
}
