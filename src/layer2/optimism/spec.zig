/// OP Stack hardfork identifiers.
///
/// Mirrors `OpSpecId` in op-revm:
/// https://github.com/ethereum-optimism/optimism/blob/develop/rust/op-revm/src/spec.rs
///
/// Discriminants match op-revm (`BEDROCK = 100`, then sequential). Upgrades after
/// JOVIAN (Karst, Lagoon) are not modeled in this module.
const std = @import("std");
const primitives = @import("voltaire");
const Hardfork = primitives.Hardfork;

pub const OpSpecId = enum(u8) {
    /// Bedrock (June 2023). Maps to Ethereum MERGE.
    BEDROCK = 100,
    /// Regolith. Removes the 68-byte L1 data overhead and system transactions. Maps to MERGE.
    REGOLITH = 101,
    /// Canyon. Ethereum Shanghai features. Maps to SHANGHAI.
    CANYON = 102,
    /// Ecotone. Ethereum Cancun features and the blob-aware L1 fee. Maps to CANCUN.
    ECOTONE = 103,
    /// Fjord. RIP-7212 P256VERIFY and the FastLZ L1 fee estimate. Maps to CANCUN.
    FJORD = 104,
    /// Granite. BN254 pairing input limit of 112,687 bytes. Maps to CANCUN.
    GRANITE = 105,
    /// Holocene. Consensus-layer changes only; EVM matches Granite. Maps to CANCUN.
    HOLOCENE = 106,
    /// Isthmus. Ethereum Prague features, operator fee, BLS12-381 input limits. Maps to PRAGUE.
    ISTHMUS = 107,
    /// Jovian. Operator fee x100, DA footprint block limit, tighter precompile input limits.
    /// Maps to PRAGUE.
    JOVIAN = 108,

    /// Latest modeled spec. Matches op-revm's `#[default]`.
    pub const DEFAULT = OpSpecId.JOVIAN;

    /// All modeled specs in activation order.
    pub const ALL = [_]OpSpecId{ .BEDROCK, .REGOLITH, .CANYON, .ECOTONE, .FJORD, .GRANITE, .HOLOCENE, .ISTHMUS, .JOVIAN };

    /// Underlying Ethereum hardfork (op-revm `into_eth_spec`).
    pub fn toEthHardfork(self: OpSpecId) Hardfork {
        return switch (self) {
            .BEDROCK, .REGOLITH => Hardfork.MERGE,
            .CANYON => Hardfork.SHANGHAI,
            .ECOTONE, .FJORD, .GRANITE, .HOLOCENE => Hardfork.CANCUN,
            .ISTHMUS, .JOVIAN => Hardfork.PRAGUE,
        };
    }

    /// True if `self` activates at or after `target` (op-revm `is_enabled_in`).
    pub fn isAtLeast(self: OpSpecId, target: OpSpecId) bool {
        return @intFromEnum(self) >= @intFromEnum(target);
    }

    /// True if `self` activates before `target`.
    pub fn isBefore(self: OpSpecId, target: OpSpecId) bool {
        return @intFromEnum(self) < @intFromEnum(target);
    }

    pub fn toInt(self: OpSpecId) u8 {
        return @intFromEnum(self);
    }

    /// Lowercase name used by op-revm and chain configs (e.g. "jovian").
    pub fn name(self: OpSpecId) []const u8 {
        return switch (self) {
            .BEDROCK => "bedrock",
            .REGOLITH => "regolith",
            .CANYON => "canyon",
            .ECOTONE => "ecotone",
            .FJORD => "fjord",
            .GRANITE => "granite",
            .HOLOCENE => "holocene",
            .ISTHMUS => "isthmus",
            .JOVIAN => "jovian",
        };
    }
};

test "OpSpecId discriminants match op-revm" {
    try std.testing.expectEqual(@as(u8, 100), OpSpecId.BEDROCK.toInt());
    try std.testing.expectEqual(@as(u8, 101), OpSpecId.REGOLITH.toInt());
    try std.testing.expectEqual(@as(u8, 102), OpSpecId.CANYON.toInt());
    try std.testing.expectEqual(@as(u8, 103), OpSpecId.ECOTONE.toInt());
    try std.testing.expectEqual(@as(u8, 104), OpSpecId.FJORD.toInt());
    try std.testing.expectEqual(@as(u8, 105), OpSpecId.GRANITE.toInt());
    try std.testing.expectEqual(@as(u8, 106), OpSpecId.HOLOCENE.toInt());
    try std.testing.expectEqual(@as(u8, 107), OpSpecId.ISTHMUS.toInt());
    try std.testing.expectEqual(@as(u8, 108), OpSpecId.JOVIAN.toInt());
}

test "OpSpecId ALL is strictly increasing" {
    for (OpSpecId.ALL[0 .. OpSpecId.ALL.len - 1], OpSpecId.ALL[1..]) |prev, next| {
        try std.testing.expect(prev.isBefore(next));
        try std.testing.expect(next.isAtLeast(prev));
        try std.testing.expect(!prev.isAtLeast(next));
    }
    try std.testing.expectEqual(@typeInfo(OpSpecId).@"enum".field_names.len, OpSpecId.ALL.len);
}

test "OpSpecId default is JOVIAN" {
    try std.testing.expectEqual(OpSpecId.JOVIAN, OpSpecId.DEFAULT);
}

test "OpSpecId toEthHardfork matches op-revm into_eth_spec" {
    try std.testing.expectEqual(Hardfork.MERGE, OpSpecId.BEDROCK.toEthHardfork());
    try std.testing.expectEqual(Hardfork.MERGE, OpSpecId.REGOLITH.toEthHardfork());
    try std.testing.expectEqual(Hardfork.SHANGHAI, OpSpecId.CANYON.toEthHardfork());
    try std.testing.expectEqual(Hardfork.CANCUN, OpSpecId.ECOTONE.toEthHardfork());
    try std.testing.expectEqual(Hardfork.CANCUN, OpSpecId.FJORD.toEthHardfork());
    try std.testing.expectEqual(Hardfork.CANCUN, OpSpecId.GRANITE.toEthHardfork());
    try std.testing.expectEqual(Hardfork.CANCUN, OpSpecId.HOLOCENE.toEthHardfork());
    try std.testing.expectEqual(Hardfork.PRAGUE, OpSpecId.ISTHMUS.toEthHardfork());
    try std.testing.expectEqual(Hardfork.PRAGUE, OpSpecId.JOVIAN.toEthHardfork());
}

test "OpSpecId isAtLeast is reflexive" {
    for (OpSpecId.ALL) |spec| {
        try std.testing.expect(spec.isAtLeast(spec));
        try std.testing.expect(!spec.isBefore(spec));
    }
}

test "OpSpecId names" {
    try std.testing.expectEqualStrings("bedrock", OpSpecId.BEDROCK.name());
    try std.testing.expectEqualStrings("jovian", OpSpecId.JOVIAN.name());
}
