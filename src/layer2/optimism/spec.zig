/// Optimism hardfork identifiers.
///
/// OpSpecId represents protocol upgrades specific to the Optimism L2 network.
/// Each upgrade maps to an underlying Ethereum hardfork while adding
/// Optimism-specific features and optimizations.
const std = @import("std");
const primitives = @import("primitives");
const Hardfork = primitives.Hardfork;

pub const OpSpecId = enum(u8) {
    /// Bedrock spec (October 2022).
    /// First major Optimism upgrade, maps to Ethereum MERGE.
    /// Introduces fault proofs and improved fee mechanism.
    BEDROCK = 100,

    /// Regolith spec (March 2023).
    /// Network stability improvements, maps to Ethereum MERGE.
    REGOLITH = 101,

    /// Canyon spec (January 2024).
    /// Adds Ethereum Shanghai features to Optimism.
    /// Maps to Ethereum SHANGHAI.
    CANYON = 102,

    /// Ecotone spec (March 2024).
    /// Adds Ethereum Cancun features including EIP-4844 blob transactions.
    /// Maps to Ethereum CANCUN.
    ECOTONE = 103,

    /// Fjord spec (July 2024).
    /// RIP-7212 precompile and FastLZ compression.
    /// Maps to Ethereum CANCUN.
    FJORD = 104,

    /// Granite spec (September 2024).
    /// Dispute game improvements.
    /// Maps to Ethereum CANCUN.
    GRANITE = 105,

    /// Holocene spec (February 2025).
    /// EIP-1559 parameters and proof maturation.
    /// Maps to Ethereum CANCUN.
    HOLOCENE = 106,

    /// Isthmus spec (TBD 2025).
    /// Interoperability preparation.
    /// Maps to Ethereum PRAGUE.
    ISTHMUS = 107,

    /// Interop spec (TBD 2025).
    /// Cross-chain messaging and interoperability.
    /// Maps to Ethereum PRAGUE.
    INTEROP = 108,

    /// Osaka spec (TBD 2026).
    /// Verkle tree support.
    /// Maps to Ethereum OSAKA.
    OSAKA = 109,

    /// Default spec for new Optimism chains.
    /// Currently set to ISTHMUS as the latest stable spec.
    pub const DEFAULT = OpSpecId.ISTHMUS;

    /// Convert Optimism spec to its underlying Ethereum hardfork.
    ///
    /// Each Optimism hardfork builds upon a specific Ethereum hardfork,
    /// inheriting its EVM features while adding L2-specific functionality.
    pub fn toEthHardfork(self: OpSpecId) Hardfork {
        return switch (self) {
            .BEDROCK, .REGOLITH => Hardfork.MERGE,
            .CANYON => Hardfork.SHANGHAI,
            .ECOTONE, .FJORD, .GRANITE, .HOLOCENE => Hardfork.CANCUN,
            .ISTHMUS, .INTEROP => Hardfork.PRAGUE,
            .OSAKA => Hardfork.OSAKA,
        };
    }

    /// Check if this spec is at least the target spec version.
    ///
    /// Returns true if self >= target in chronological order.
    /// Uses numeric comparison of enum values.
    pub fn isAtLeast(self: OpSpecId, target: OpSpecId) bool {
        return @intFromEnum(self) >= @intFromEnum(target);
    }

    /// Check if this spec is before the target spec version.
    ///
    /// Returns true if self < target in chronological order.
    pub fn isBefore(self: OpSpecId, target: OpSpecId) bool {
        return @intFromEnum(self) < @intFromEnum(target);
    }

    /// Convert spec to its numeric representation.
    pub fn toInt(self: OpSpecId) u8 {
        return @intFromEnum(self);
    }
};

test "OpSpecId enum ordering" {
    try std.testing.expect(@intFromEnum(OpSpecId.BEDROCK) < @intFromEnum(OpSpecId.REGOLITH));
    try std.testing.expect(@intFromEnum(OpSpecId.REGOLITH) < @intFromEnum(OpSpecId.CANYON));
    try std.testing.expect(@intFromEnum(OpSpecId.CANYON) < @intFromEnum(OpSpecId.ECOTONE));
    try std.testing.expect(@intFromEnum(OpSpecId.ECOTONE) < @intFromEnum(OpSpecId.FJORD));
    try std.testing.expect(@intFromEnum(OpSpecId.FJORD) < @intFromEnum(OpSpecId.GRANITE));
    try std.testing.expect(@intFromEnum(OpSpecId.GRANITE) < @intFromEnum(OpSpecId.HOLOCENE));
    try std.testing.expect(@intFromEnum(OpSpecId.HOLOCENE) < @intFromEnum(OpSpecId.ISTHMUS));
    try std.testing.expect(@intFromEnum(OpSpecId.ISTHMUS) < @intFromEnum(OpSpecId.INTEROP));
    try std.testing.expect(@intFromEnum(OpSpecId.INTEROP) < @intFromEnum(OpSpecId.OSAKA));
}

test "OpSpecId default is ISTHMUS" {
    try std.testing.expectEqual(OpSpecId.ISTHMUS, OpSpecId.DEFAULT);
}

test "OpSpecId toEthHardfork mapping" {
    try std.testing.expectEqual(Hardfork.MERGE, OpSpecId.BEDROCK.toEthHardfork());
    try std.testing.expectEqual(Hardfork.MERGE, OpSpecId.REGOLITH.toEthHardfork());
    try std.testing.expectEqual(Hardfork.SHANGHAI, OpSpecId.CANYON.toEthHardfork());
    try std.testing.expectEqual(Hardfork.CANCUN, OpSpecId.ECOTONE.toEthHardfork());
    try std.testing.expectEqual(Hardfork.CANCUN, OpSpecId.FJORD.toEthHardfork());
    try std.testing.expectEqual(Hardfork.CANCUN, OpSpecId.GRANITE.toEthHardfork());
    try std.testing.expectEqual(Hardfork.CANCUN, OpSpecId.HOLOCENE.toEthHardfork());
    try std.testing.expectEqual(Hardfork.PRAGUE, OpSpecId.ISTHMUS.toEthHardfork());
    try std.testing.expectEqual(Hardfork.PRAGUE, OpSpecId.INTEROP.toEthHardfork());
    try std.testing.expectEqual(Hardfork.OSAKA, OpSpecId.OSAKA.toEthHardfork());
}

test "OpSpecId isAtLeast comparison" {
    try std.testing.expect(OpSpecId.ECOTONE.isAtLeast(OpSpecId.BEDROCK));
    try std.testing.expect(OpSpecId.ECOTONE.isAtLeast(OpSpecId.ECOTONE));
    try std.testing.expect(!OpSpecId.BEDROCK.isAtLeast(OpSpecId.ECOTONE));

    try std.testing.expect(OpSpecId.FJORD.isAtLeast(OpSpecId.CANYON));
    try std.testing.expect(OpSpecId.GRANITE.isAtLeast(OpSpecId.FJORD));
    try std.testing.expect(!OpSpecId.REGOLITH.isAtLeast(OpSpecId.CANYON));
}

test "OpSpecId isBefore comparison" {
    try std.testing.expect(OpSpecId.BEDROCK.isBefore(OpSpecId.ECOTONE));
    try std.testing.expect(!OpSpecId.ECOTONE.isBefore(OpSpecId.BEDROCK));
    try std.testing.expect(!OpSpecId.ECOTONE.isBefore(OpSpecId.ECOTONE));

    try std.testing.expect(OpSpecId.CANYON.isBefore(OpSpecId.FJORD));
    try std.testing.expect(!OpSpecId.FJORD.isBefore(OpSpecId.CANYON));
}

test "OpSpecId toInt conversion" {
    try std.testing.expectEqual(@as(u8, 100), OpSpecId.BEDROCK.toInt());
    try std.testing.expectEqual(@as(u8, 101), OpSpecId.REGOLITH.toInt());
    try std.testing.expectEqual(@as(u8, 102), OpSpecId.CANYON.toInt());
    try std.testing.expectEqual(@as(u8, 103), OpSpecId.ECOTONE.toInt());
    try std.testing.expectEqual(@as(u8, 104), OpSpecId.FJORD.toInt());
    try std.testing.expectEqual(@as(u8, 105), OpSpecId.GRANITE.toInt());
    try std.testing.expectEqual(@as(u8, 106), OpSpecId.HOLOCENE.toInt());
    try std.testing.expectEqual(@as(u8, 107), OpSpecId.ISTHMUS.toInt());
    try std.testing.expectEqual(@as(u8, 108), OpSpecId.INTEROP.toInt());
    try std.testing.expectEqual(@as(u8, 109), OpSpecId.OSAKA.toInt());
}

test "OpSpecId all specs map to valid eth hardforks" {
    const all_specs = [_]OpSpecId{
        .BEDROCK,
        .REGOLITH,
        .CANYON,
        .ECOTONE,
        .FJORD,
        .GRANITE,
        .HOLOCENE,
        .ISTHMUS,
        .INTEROP,
        .OSAKA,
    };

    for (all_specs) |spec| {
        const hardfork = spec.toEthHardfork();
        try std.testing.expect(hardfork.isAtLeast(Hardfork.MERGE));
    }
}

test "OpSpecId comparison all pairs" {
    try std.testing.expect(OpSpecId.BEDROCK.isBefore(OpSpecId.REGOLITH));
    try std.testing.expect(OpSpecId.REGOLITH.isBefore(OpSpecId.CANYON));
    try std.testing.expect(OpSpecId.CANYON.isBefore(OpSpecId.ECOTONE));
    try std.testing.expect(OpSpecId.ECOTONE.isBefore(OpSpecId.FJORD));
    try std.testing.expect(OpSpecId.FJORD.isBefore(OpSpecId.GRANITE));
    try std.testing.expect(OpSpecId.GRANITE.isBefore(OpSpecId.HOLOCENE));
    try std.testing.expect(OpSpecId.HOLOCENE.isBefore(OpSpecId.ISTHMUS));
    try std.testing.expect(OpSpecId.ISTHMUS.isBefore(OpSpecId.INTEROP));
    try std.testing.expect(OpSpecId.INTEROP.isBefore(OpSpecId.OSAKA));
}

test "OpSpecId isAtLeast reflexive" {
    try std.testing.expect(OpSpecId.BEDROCK.isAtLeast(OpSpecId.BEDROCK));
    try std.testing.expect(OpSpecId.REGOLITH.isAtLeast(OpSpecId.REGOLITH));
    try std.testing.expect(OpSpecId.CANYON.isAtLeast(OpSpecId.CANYON));
    try std.testing.expect(OpSpecId.ECOTONE.isAtLeast(OpSpecId.ECOTONE));
    try std.testing.expect(OpSpecId.FJORD.isAtLeast(OpSpecId.FJORD));
    try std.testing.expect(OpSpecId.GRANITE.isAtLeast(OpSpecId.GRANITE));
    try std.testing.expect(OpSpecId.HOLOCENE.isAtLeast(OpSpecId.HOLOCENE));
    try std.testing.expect(OpSpecId.ISTHMUS.isAtLeast(OpSpecId.ISTHMUS));
    try std.testing.expect(OpSpecId.INTEROP.isAtLeast(OpSpecId.INTEROP));
    try std.testing.expect(OpSpecId.OSAKA.isAtLeast(OpSpecId.OSAKA));
}
