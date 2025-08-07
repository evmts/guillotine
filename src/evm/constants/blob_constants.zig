const std = @import("std");

/// EIP-4844 Blob Transaction Constants
/// 
/// This file contains all constants related to EIP-4844 blob transactions,
/// including blob sizes, gas costs, and market parameters.

/// Blob size constants
pub const BYTES_PER_BLOB = 131072; // 128 KB
pub const FIELD_ELEMENTS_PER_BLOB = 4096; // 4096 field elements per blob
pub const MAX_BLOBS_PER_TRANSACTION = 6; // Maximum blobs in a single transaction
pub const GAS_PER_BLOB = 131072; // Gas units consumed per blob

/// Blob gas market constants
pub const BLOB_BASE_FEE_UPDATE_FRACTION = 3338477; // Adjustment factor for base fee updates
pub const MIN_BLOB_GASPRICE = 1; // Minimum blob gas price (1 wei)
pub const MAX_BLOB_GAS_PER_BLOCK = 786432; // 6 blobs * 131072 gas per blob
pub const TARGET_BLOB_GAS_PER_BLOCK = 393216; // 3 blobs * 131072 gas per blob

/// BLS12-381 field modulus used for blob cryptography
pub const BLS_MODULUS: u256 = 0x73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001;

/// Versioned hash constants
pub const VERSION_KZG: u8 = 0x01;

test "blob constants are correct" {
    const testing = std.testing;
    
    // Verify blob sizes
    try testing.expectEqual(@as(u32, 131072), BYTES_PER_BLOB);
    try testing.expectEqual(@as(u32, 4096), FIELD_ELEMENTS_PER_BLOB);
    try testing.expectEqual(@as(u8, 6), MAX_BLOBS_PER_TRANSACTION);
    try testing.expectEqual(@as(u32, 131072), GAS_PER_BLOB);
    
    // Verify gas market parameters
    try testing.expectEqual(@as(u32, 786432), MAX_BLOB_GAS_PER_BLOCK);
    try testing.expectEqual(@as(u32, 393216), TARGET_BLOB_GAS_PER_BLOCK);
    
    // Verify target is half of max
    try testing.expectEqual(MAX_BLOB_GAS_PER_BLOCK / 2, TARGET_BLOB_GAS_PER_BLOCK);
    
    // Verify max matches expected calculation
    try testing.expectEqual(MAX_BLOBS_PER_TRANSACTION * GAS_PER_BLOB, MAX_BLOB_GAS_PER_BLOCK);
    
    // Verify version constant
    try testing.expectEqual(@as(u8, 0x01), VERSION_KZG);
}

test "blob math relationships" {
    const testing = std.testing;
    
    // 128 KB should equal 131072 bytes
    try testing.expectEqual(@as(u32, 128 * 1024), BYTES_PER_BLOB);
    
    // Each field element is 32 bytes, so 4096 * 32 should equal blob size
    try testing.expectEqual(FIELD_ELEMENTS_PER_BLOB * 32, BYTES_PER_BLOB);
    
    // Gas per blob should match blob size
    try testing.expectEqual(BYTES_PER_BLOB, GAS_PER_BLOB);
}