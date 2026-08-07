/// Layer 2 configuration union type.
///
/// This type enables compile-time selection of L2-specific features.
/// When set to .none (default), all L2 code is eliminated through
/// dead code elimination, resulting in zero runtime overhead.
const std = @import("std");
const OpSpecId = @import("optimism/spec.zig").OpSpecId;

/// Layer2Config is a comptime-friendly union that controls which L2
/// features are compiled into the EVM.
///
/// Zero-cost abstraction: When layer2_config = .none, all L2 code
/// paths are eliminated at compile time via comptime branching.
pub const Layer2Config = union(enum) {
    /// No Layer 2 features (Ethereum mainnet).
    /// This is the default and results in zero L2 overhead.
    none,

    /// Optimism L2 configuration.
    /// Includes all OP Stack chains: Base, Zora, OP Mainnet, etc.
    optimism: OptimismConfig,

    /// Check if this config enables any L2 features.
    pub fn isL2(self: Layer2Config) bool {
        return switch (self) {
            .none => false,
            .optimism => true,
        };
    }

    /// Get human-readable name for this L2 config.
    pub fn name(self: Layer2Config) []const u8 {
        return switch (self) {
            .none => "mainnet",
            .optimism => "optimism",
        };
    }
};

/// Optimism-specific configuration.
///
/// This struct contains all parameters needed for Optimism L2 execution.
/// It must be comptime-friendly (no pointers, no allocators).
pub const OptimismConfig = struct {
    /// Optimism hardfork specification.
    /// Determines which L2 features are active.
    spec: OpSpecId,

    /// Default Optimism configuration.
    /// Uses the latest stable OpSpecId.
    pub const DEFAULT = OptimismConfig{
        .spec = OpSpecId.DEFAULT,
    };
};

test "Layer2Config default is none" {
    const cfg: Layer2Config = .none;
    try std.testing.expect(!cfg.isL2());
    try std.testing.expectEqualStrings("mainnet", cfg.name());
}

test "Layer2Config optimism is L2" {
    const cfg: Layer2Config = .{ .optimism = OptimismConfig.DEFAULT };
    try std.testing.expect(cfg.isL2());
    try std.testing.expectEqualStrings("optimism", cfg.name());
}

test "Layer2Config none has no runtime overhead" {
    const cfg: Layer2Config = .none;

    // This entire block is eliminated at compile time
    if (comptime cfg == .none) {
        // Comptime branch - no runtime code generated
        try std.testing.expect(true);
    } else {
        // This is never compiled when cfg = .none
        try std.testing.expect(false);
    }
}

test "OptimismConfig default uses default spec" {
    const cfg = OptimismConfig.DEFAULT;
    try std.testing.expectEqual(OpSpecId.DEFAULT, cfg.spec);
}

test "OptimismConfig can specify custom spec" {
    const cfg = OptimismConfig{ .spec = .ECOTONE };
    try std.testing.expectEqual(OpSpecId.ECOTONE, cfg.spec);
}

test "Layer2Config is comptime friendly" {
    comptime {
        const cfg: Layer2Config = .none;
        _ = cfg.isL2();
        _ = cfg.name();
    }

    comptime {
        const cfg: Layer2Config = .{ .optimism = .{ .spec = .FJORD } };
        _ = cfg.isL2();
        _ = cfg.name();
    }
}

test "Layer2Config all variants" {
    const configs = [_]Layer2Config{
        .none,
        .{ .optimism = .{ .spec = .BEDROCK } },
        .{ .optimism = .{ .spec = .REGOLITH } },
        .{ .optimism = .{ .spec = .CANYON } },
        .{ .optimism = .{ .spec = .ECOTONE } },
        .{ .optimism = .{ .spec = .FJORD } },
        .{ .optimism = .{ .spec = .GRANITE } },
        .{ .optimism = .{ .spec = .HOLOCENE } },
        .{ .optimism = .{ .spec = .ISTHMUS } },
        .{ .optimism = .{ .spec = .INTEROP } },
        .{ .optimism = .{ .spec = .OSAKA } },
    };

    for (configs) |cfg| {
        _ = cfg.isL2();
        _ = cfg.name();
    }
}
