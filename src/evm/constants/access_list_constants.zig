const std = @import("std");

/// Access List Gas Constants
///
/// This file contains constants related to EIP-2929 access lists, which introduced
/// warm/cold gas pricing for account and storage slot access.
/// Gas cost for accessing a cold (not previously accessed) account
/// Applied to BALANCE, EXTCODESIZE, EXTCODECOPY, EXTCODEHASH, and CALL family opcodes
pub const COLD_ACCOUNT_ACCESS_COST: u64 = 2600;

/// Gas cost for accessing a warm (previously accessed) account
/// Much cheaper than cold access to incentivize locality
pub const WARM_ACCOUNT_ACCESS_COST: u64 = 100;

/// Gas cost for loading from a cold (not previously accessed) storage slot
/// Applied to SLOAD opcode
pub const COLD_SLOAD_COST: u64 = 2100;

/// Gas cost for loading from a warm (previously accessed) storage slot
/// Much cheaper than cold access to incentivize locality
pub const WARM_SLOAD_COST: u64 = 100;

/// Additional gas cost when making a cold call vs warm call
/// This is the difference between cold and warm account access
pub const COLD_CALL_EXTRA_COST: u64 = COLD_ACCOUNT_ACCESS_COST - WARM_ACCOUNT_ACCESS_COST;

test "access list gas constants are correct" {
    const testing = std.testing;

    // Verify EIP-2929 gas costs
    try testing.expectEqual(@as(u64, 2600), COLD_ACCOUNT_ACCESS_COST);
    try testing.expectEqual(@as(u64, 100), WARM_ACCOUNT_ACCESS_COST);
    try testing.expectEqual(@as(u64, 2100), COLD_SLOAD_COST);
    try testing.expectEqual(@as(u64, 100), WARM_SLOAD_COST);

    // Verify derived constants
    try testing.expectEqual(@as(u64, 2500), COLD_CALL_EXTRA_COST);

    // Verify cold costs are significantly higher than warm costs
    try testing.expect(COLD_ACCOUNT_ACCESS_COST > WARM_ACCOUNT_ACCESS_COST * 10);
    try testing.expect(COLD_SLOAD_COST > WARM_SLOAD_COST * 10);
}
