const std = @import("std");
const primitives = @import("primitives");

/// Precompile addresses as defined by the Ethereum specification
/// These addresses are reserved for built-in precompiled contracts
/// ECRECOVER precompile - signature recovery
pub const ECRECOVER_ADDRESS: primitives.Address.Address = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01 };

/// SHA256 precompile - SHA-256 hash function
pub const SHA256_ADDRESS: primitives.Address.Address = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02 };

/// RIPEMD160 precompile - RIPEMD-160 hash function
pub const RIPEMD160_ADDRESS: primitives.Address.Address = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x03 };

/// IDENTITY precompile - returns input data unchanged
pub const IDENTITY_ADDRESS: primitives.Address.Address = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x04 };

/// MODEXP precompile - modular exponentiation
pub const MODEXP_ADDRESS: primitives.Address.Address = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x05 };

/// ECADD precompile - elliptic curve addition on alt_bn128
pub const ECADD_ADDRESS: primitives.Address.Address = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x06 };

/// ECMUL precompile - elliptic curve scalar multiplication on alt_bn128
pub const ECMUL_ADDRESS: primitives.Address.Address = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x07 };

/// ECPAIRING precompile - elliptic curve pairing check on alt_bn128
pub const ECPAIRING_ADDRESS: primitives.Address.Address = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x08 };

/// BLAKE2F precompile - BLAKE2b F compression function
pub const BLAKE2F_ADDRESS: primitives.Address.Address = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x09 };

/// POINT_EVALUATION precompile - KZG point evaluation (EIP-4844)
pub const POINT_EVALUATION_ADDRESS: primitives.Address.Address = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x0A };

/// Checks if the given address is a precompile address
/// @param address The address to check
/// @return true if the address is a known precompile, false otherwise
pub fn is_precompile(address: primitives.Address.Address) bool {
    // Optimized check using larger integer comparisons
    const part1 = std.mem.readInt(u64, address[0..8], .big);
    const part2 = std.mem.readInt(u64, address[8..16], .big);
    // check bytes 16, 17, 18
    if (part1 != 0 or part2 != 0 or address[16] != 0 or address[17] != 0 or address[18] != 0) {
        @branchHint(.cold);
        return false;
    }

    // Check if the last byte is in the precompile range (1-10)
    const last_byte = address[19];
    return last_byte >= 1 and last_byte <= 10;
}

/// Gets the precompile ID from an address
/// @param address The precompile address
/// @return The precompile ID (1-10) or 0 if not a precompile
pub fn get_precompile_id(address: primitives.Address.Address) u8 {
    if (!is_precompile(address)) {
        @branchHint(.cold);
        return 0;
    }
    return address[19];
}

/// Gets the precompile ID from an address, returning null if not a precompile
/// This variant avoids redundant is_precompile checks
/// @param address The precompile address
/// @return The precompile ID (1-10) or null if not a precompile
pub fn get_precompile_id_checked(address: primitives.Address.Address) ?u8 {
    // Optimized check using larger integer comparisons
    const part1 = std.mem.readInt(u64, address[0..8], .big);
    const part2 = std.mem.readInt(u64, address[8..16], .big);
    // check bytes 16, 17, 18
    if (part1 != 0 or part2 != 0 or address[16] != 0 or address[17] != 0 or address[18] != 0) {
        @branchHint(.cold);
        return null;
    }

    // Check if the last byte is in the precompile range (1-10)
    const last_byte = address[19];
    if (last_byte >= 1 and last_byte <= 10) {
        return last_byte;
    }
    return null;
}

test "get_precompile_id_checked optimization" {
    const testing = std.testing;

    // Test all valid precompile addresses
    try testing.expectEqual(@as(?u8, 1), get_precompile_id_checked(ECRECOVER_ADDRESS));
    try testing.expectEqual(@as(?u8, 2), get_precompile_id_checked(SHA256_ADDRESS));
    try testing.expectEqual(@as(?u8, 3), get_precompile_id_checked(RIPEMD160_ADDRESS));
    try testing.expectEqual(@as(?u8, 4), get_precompile_id_checked(IDENTITY_ADDRESS));
    try testing.expectEqual(@as(?u8, 5), get_precompile_id_checked(MODEXP_ADDRESS));
    try testing.expectEqual(@as(?u8, 6), get_precompile_id_checked(ECADD_ADDRESS));
    try testing.expectEqual(@as(?u8, 7), get_precompile_id_checked(ECMUL_ADDRESS));
    try testing.expectEqual(@as(?u8, 8), get_precompile_id_checked(ECPAIRING_ADDRESS));
    try testing.expectEqual(@as(?u8, 9), get_precompile_id_checked(BLAKE2F_ADDRESS));
    try testing.expectEqual(@as(?u8, 10), get_precompile_id_checked(POINT_EVALUATION_ADDRESS));

    // Test non-precompile addresses
    const non_precompile1 = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF };
    const non_precompile2 = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }; // All zeros
    const non_precompile3 = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 11 }; // ID out of range

    try testing.expectEqual(@as(?u8, null), get_precompile_id_checked(non_precompile1));
    try testing.expectEqual(@as(?u8, null), get_precompile_id_checked(non_precompile2));
    try testing.expectEqual(@as(?u8, null), get_precompile_id_checked(non_precompile3));
}
