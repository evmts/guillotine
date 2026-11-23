/// Layer 2 configuration union.
///
/// Compile-time selection of L2 features. With `.none` (default) no L2 code is
/// referenced, so it is eliminated from the binary.
const std = @import("std");
const OpSpecId = @import("optimism/spec.zig").OpSpecId;
const base_config = @import("base/config.zig");

pub const BaseConfig = base_config.BaseConfig;

pub const Layer2Config = union(enum) {
    /// Ethereum L1 rules.
    none,
    /// A generic OP Stack chain (OP Mainnet, Zora, ...).
    optimism: OptimismConfig,
    /// Base Mainnet or Base Sepolia (OP Stack rules with Base chain parameters).
    base: BaseConfig,

    pub fn isL2(self: Layer2Config) bool {
        return switch (self) {
            .none => false,
            .optimism, .base => true,
        };
    }

    /// True if OP Stack execution rules apply (deposits, L1 fee, OP precompiles).
    pub fn isOpStack(self: Layer2Config) bool {
        return switch (self) {
            .none => false,
            .optimism, .base => true,
        };
    }

    /// OP Stack spec for OP Stack configs, null for `.none`.
    pub fn opSpec(self: Layer2Config) ?OpSpecId {
        return switch (self) {
            .none => null,
            .optimism => |cfg| cfg.spec,
            .base => |cfg| cfg.spec,
        };
    }

    pub fn name(self: Layer2Config) []const u8 {
        return switch (self) {
            .none => "mainnet",
            .optimism => "optimism",
            .base => |cfg| cfg.chain.name(),
        };
    }
};

/// Generic OP Stack configuration.
pub const OptimismConfig = struct {
    spec: OpSpecId,

    pub const DEFAULT = OptimismConfig{ .spec = OpSpecId.DEFAULT };
};

test "Layer2Config none" {
    const cfg: Layer2Config = .none;
    try std.testing.expect(!cfg.isL2());
    try std.testing.expect(!cfg.isOpStack());
    try std.testing.expect(cfg.opSpec() == null);
    try std.testing.expectEqualStrings("mainnet", cfg.name());
}

test "Layer2Config optimism" {
    const cfg: Layer2Config = .{ .optimism = OptimismConfig.DEFAULT };
    try std.testing.expect(cfg.isL2());
    try std.testing.expect(cfg.isOpStack());
    try std.testing.expectEqual(OpSpecId.JOVIAN, cfg.opSpec().?);
    try std.testing.expectEqualStrings("optimism", cfg.name());
}

test "Layer2Config base mainnet and sepolia" {
    const mainnet: Layer2Config = .{ .base = BaseConfig.MAINNET };
    try std.testing.expect(mainnet.isL2());
    try std.testing.expect(mainnet.isOpStack());
    try std.testing.expectEqual(OpSpecId.JOVIAN, mainnet.opSpec().?);
    try std.testing.expectEqualStrings("base", mainnet.name());
    try std.testing.expectEqual(@as(u64, 8453), mainnet.base.chainId());

    const sepolia: Layer2Config = .{ .base = .{ .chain = .sepolia, .spec = .FJORD } };
    try std.testing.expectEqualStrings("base-sepolia", sepolia.name());
    try std.testing.expectEqual(OpSpecId.FJORD, sepolia.opSpec().?);
    try std.testing.expectEqual(@as(u64, 84532), sepolia.base.chainId());
}

test "Layer2Config is comptime friendly" {
    comptime {
        const configs = [_]Layer2Config{
            .none,
            .{ .optimism = .{ .spec = .FJORD } },
            .{ .base = BaseConfig.SEPOLIA },
        };
        for (configs) |cfg| {
            _ = cfg.isL2();
            _ = cfg.name();
            _ = cfg.opSpec();
        }
    }
}

test "Layer2Config every spec for optimism and base" {
    for (OpSpecId.ALL) |spec| {
        const op: Layer2Config = .{ .optimism = .{ .spec = spec } };
        try std.testing.expectEqual(spec, op.opSpec().?);
        const base: Layer2Config = .{ .base = .{ .chain = .mainnet, .spec = spec } };
        try std.testing.expectEqual(spec, base.opSpec().?);
    }
}
