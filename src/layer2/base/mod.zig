//! Base (Coinbase OP Stack L2) support: chain configs, hardfork schedules, fees, precompiles.
pub const config = @import("config.zig");
pub const hardforks = @import("hardforks.zig");
pub const fees = @import("fees.zig");
pub const precompiles = @import("precompiles.zig");

pub const BaseConfig = config.BaseConfig;
pub const BaseChain = config.BaseChain;
pub const SystemContracts = config.SystemContracts;
pub const Schedule = hardforks.Schedule;
pub const MAINNET_SCHEDULE = hardforks.MAINNET;
pub const SEPOLIA_SCHEDULE = hardforks.SEPOLIA;

test "base module exposes mainnet and sepolia schedules" {
    const std = @import("std");
    try std.testing.expectEqual(BaseChain.mainnet, BaseConfig.MAINNET.chain);
    try std.testing.expectEqual(BaseChain.sepolia, BaseConfig.SEPOLIA.chain);
}
