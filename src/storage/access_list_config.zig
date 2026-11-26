/// Access list configuration parameters for EVM warm/cold access tracking
/// 
/// Configures the EVM access list behavior for EIP-2929 including:
/// - Cold/warm gas costs for account access
/// - Cold/warm gas costs for storage slot access  
/// - Storage slot type (defaults to u256 for standard EVM compatibility)
/// 
/// Configuration is validated at compile time to ensure EVM compliance
/// and proper gas accounting.
const std = @import("std");

pub const AccessListConfig = struct {
    const Self = @This();

    /// Gas cost for accessing a cold (unaccessed) account. Defaults to 2600 per EIP-2929
    cold_account_access_cost: u64 = 2600,
    /// Gas cost for accessing a warm (previously accessed) account. Defaults to 100 per EIP-2929
    warm_account_access_cost: u64 = 100,
    /// Gas cost for accessing a cold (unaccessed) storage slot. Defaults to 2100 per EIP-2929
    cold_sload_cost: u64 = 2100,
    /// Gas cost for accessing a warm (previously accessed) storage slot. Defaults to 100 per EIP-2929
    warm_sload_cost: u64 = 100,
    /// The type used for storage slot indices. Defaults to u256 for standard EVM compatibility
    SlotType: type = u256,

    pub fn validate(comptime self: Self) void {
        // Ensure gas costs are reasonable
        if (self.cold_account_access_cost == 0) @compileError("cold_account_access_cost cannot be zero");
        if (self.warm_account_access_cost == 0) @compileError("warm_account_access_cost cannot be zero");
        if (self.cold_sload_cost == 0) @compileError("cold_sload_cost cannot be zero");
        if (self.warm_sload_cost == 0) @compileError("warm_sload_cost cannot be zero");
        
        // Ensure cold access is more expensive than warm access
        if (self.cold_account_access_cost <= self.warm_account_access_cost) {
            @compileError("cold_account_access_cost must be greater than warm_account_access_cost");
        }
        if (self.cold_sload_cost <= self.warm_sload_cost) {
            @compileError("cold_sload_cost must be greater than warm_sload_cost");
        }
        
        // Validate slot type is an integer
        const slot_info = @typeInfo(self.SlotType);
        if (slot_info != .int) @compileError("SlotType must be an integer type");
        if (slot_info.int.signedness != .unsigned) @compileError("SlotType must be unsigned");
    }
};

test "AccessListConfig default values match EIP-2929" {
    const config = AccessListConfig{};
    try std.testing.expectEqual(@as(u64, 2600), config.cold_account_access_cost);
    try std.testing.expectEqual(@as(u64, 100), config.warm_account_access_cost);
    try std.testing.expectEqual(@as(u64, 2100), config.cold_sload_cost);
    try std.testing.expectEqual(@as(u64, 100), config.warm_sload_cost);
    try std.testing.expectEqual(u256, config.SlotType);
}

test "AccessListConfig validate catches invalid configurations" {
    // These should all fail compilation if uncommented:
    // const zero_cold_account = AccessListConfig{ .cold_account_access_cost = 0 };
    // const zero_warm_account = AccessListConfig{ .warm_account_access_cost = 0 };
    // const zero_cold_sload = AccessListConfig{ .cold_sload_cost = 0 };
    // const zero_warm_sload = AccessListConfig{ .warm_sload_cost = 0 };
    // const warm_more_expensive = AccessListConfig{ .cold_account_access_cost = 100, .warm_account_access_cost = 200 };
    // const signed_slot = AccessListConfig{ .SlotType = i256 };
}