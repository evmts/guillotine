//! Base Mainnet and Base Sepolia hardfork schedules.
//!
//! Source: base/base crates/common/chains/src/config.rs (MAINNET, SEPOLIA), fetched
//! 2026-11-22; cross-checked against superchain-registry
//! superchain/configs/{mainnet,sepolia}/base.toml @ 720185c3 (last revision before Base
//! left the registry).
//!
//! Bedrock is active from L2 genesis (block 0). Regolith activates at the genesis
//! timestamp, so every Base block runs at least Regolith.
//!
//! Base-specific upgrades after Jovian (Azul, Beryl, Cobalt, Denim) change EVM rules
//! (Azul maps to Ethereum Osaka and reprices P256VERIFY). This module records their
//! timestamps but does not model them: `specAt` returns `error.UnmodeledBaseUpgrade`
//! at or after Azul instead of running those blocks with Jovian rules.

const std = @import("std");
const OpSpecId = @import("../optimism/spec.zig").OpSpecId;

pub const ScheduleError = error{
    /// Timestamp precedes L2 genesis.
    BeforeGenesis,
    /// Timestamp is at or after a Base upgrade this module does not model.
    UnmodeledBaseUpgrade,
};

/// Activation timestamps (seconds) for one Base chain.
pub const Schedule = struct {
    /// L2 genesis timestamp. Bedrock is active from genesis block 0.
    genesis_time: u64,
    regolith: u64,
    canyon: u64,
    /// Delta: span batches. Consensus-layer only, no EVM change.
    delta: u64,
    ecotone: u64,
    fjord: u64,
    granite: u64,
    holocene: u64,
    /// Sepolia only: L1 Prague blob schedule for the L1 blob base fee.
    pectra_blob_schedule: ?u64,
    isthmus: u64,
    jovian: u64,
    /// Base-specific upgrades, recorded but not modeled.
    azul: ?u64,
    beryl: ?u64,
    cobalt: ?u64,
    denim: ?u64,

    /// First Base upgrade this module does not model, if scheduled.
    pub fn firstUnmodeled(self: Schedule) ?u64 {
        return self.azul;
    }

    /// OP Stack spec active at `timestamp`.
    pub fn specAt(self: Schedule, timestamp: u64) ScheduleError!OpSpecId {
        if (timestamp < self.genesis_time) return error.BeforeGenesis;
        if (self.firstUnmodeled()) |t| {
            if (timestamp >= t) return error.UnmodeledBaseUpgrade;
        }
        if (timestamp >= self.jovian) return .JOVIAN;
        if (timestamp >= self.isthmus) return .ISTHMUS;
        if (timestamp >= self.holocene) return .HOLOCENE;
        if (timestamp >= self.granite) return .GRANITE;
        if (timestamp >= self.fjord) return .FJORD;
        if (timestamp >= self.ecotone) return .ECOTONE;
        if (timestamp >= self.canyon) return .CANYON;
        if (timestamp >= self.regolith) return .REGOLITH;
        return .BEDROCK;
    }

    /// Activation timestamp of `spec` on this chain.
    pub fn activation(self: Schedule, spec: OpSpecId) u64 {
        return switch (spec) {
            .BEDROCK => self.genesis_time,
            .REGOLITH => self.regolith,
            .CANYON => self.canyon,
            .ECOTONE => self.ecotone,
            .FJORD => self.fjord,
            .GRANITE => self.granite,
            .HOLOCENE => self.holocene,
            .ISTHMUS => self.isthmus,
            .JOVIAN => self.jovian,
        };
    }

    pub fn isActive(self: Schedule, spec: OpSpecId, timestamp: u64) bool {
        return timestamp >= self.activation(spec);
    }
};

/// Base Mainnet (chain ID 8453).
pub const MAINNET = Schedule{
    .genesis_time = 1_686_789_347, // Thu 15 Jun 2023 00:35:47 UTC
    .regolith = 1_686_789_347,
    .canyon = 1_704_992_401, // Thu 11 Jan 2024 17:00:01 UTC
    .delta = 1_708_560_000, // Thu 22 Feb 2024 00:00:00 UTC
    .ecotone = 1_710_374_401, // Thu 14 Mar 2024 00:00:01 UTC
    .fjord = 1_720_627_201, // Wed 10 Jul 2024 16:00:01 UTC
    .granite = 1_726_070_401, // Wed 11 Sep 2024 16:00:01 UTC
    .holocene = 1_736_445_601, // Thu 9 Jan 2025 18:00:01 UTC
    .pectra_blob_schedule = null,
    .isthmus = 1_746_806_401, // Fri 9 May 2025 16:00:01 UTC
    .jovian = 1_764_691_201, // Tue 2 Dec 2025 16:00:01 UTC
    .azul = 1_779_991_200,
    .beryl = 1_782_410_400,
    .cobalt = 1_790_791_200,
    .denim = 1_793_901_600,
};

/// Base Sepolia (chain ID 84532).
pub const SEPOLIA = Schedule{
    .genesis_time = 1_695_768_288, // Tue 26 Sep 2023 22:44:48 UTC
    .regolith = 1_695_768_288,
    .canyon = 1_699_981_200, // Tue 14 Nov 2023 17:00:00 UTC
    .delta = 1_703_203_200, // Fri 22 Dec 2023 00:00:00 UTC
    .ecotone = 1_708_534_800, // Wed 21 Feb 2024 17:00:00 UTC
    .fjord = 1_716_998_400, // Wed 29 May 2024 16:00:00 UTC
    .granite = 1_723_478_400, // Mon 12 Aug 2024 16:00:00 UTC
    .holocene = 1_732_633_200, // Tue 26 Nov 2024 15:00:00 UTC
    .pectra_blob_schedule = 1_742_486_400, // Thu 20 Mar 2025 16:00:00 UTC
    .isthmus = 1_744_905_600, // Thu 17 Apr 2025 16:00:00 UTC
    .jovian = 1_763_568_001, // Wed 19 Nov 2025 16:00:01 UTC
    .azul = 1_776_708_000,
    .beryl = 1_781_805_600,
    .cobalt = 1_790_186_400,
    .denim = 1_792_605_600,
};

const testing = std.testing;

test "Base mainnet spec at each activation boundary" {
    const s = MAINNET;
    try testing.expectError(error.BeforeGenesis, s.specAt(s.genesis_time - 1));
    try testing.expectEqual(OpSpecId.REGOLITH, try s.specAt(s.genesis_time));
    try testing.expectEqual(OpSpecId.REGOLITH, try s.specAt(s.canyon - 1));
    try testing.expectEqual(OpSpecId.CANYON, try s.specAt(s.canyon));
    try testing.expectEqual(OpSpecId.CANYON, try s.specAt(s.delta));
    try testing.expectEqual(OpSpecId.ECOTONE, try s.specAt(s.ecotone));
    try testing.expectEqual(OpSpecId.FJORD, try s.specAt(s.fjord));
    try testing.expectEqual(OpSpecId.GRANITE, try s.specAt(s.granite));
    try testing.expectEqual(OpSpecId.HOLOCENE, try s.specAt(s.holocene));
    try testing.expectEqual(OpSpecId.ISTHMUS, try s.specAt(s.isthmus));
    try testing.expectEqual(OpSpecId.ISTHMUS, try s.specAt(s.jovian - 1));
    try testing.expectEqual(OpSpecId.JOVIAN, try s.specAt(s.jovian));
    try testing.expectEqual(OpSpecId.JOVIAN, try s.specAt(s.azul.? - 1));
    try testing.expectError(error.UnmodeledBaseUpgrade, s.specAt(s.azul.?));
}

test "Base Sepolia spec at each activation boundary" {
    const s = SEPOLIA;
    try testing.expectError(error.BeforeGenesis, s.specAt(0));
    try testing.expectEqual(OpSpecId.REGOLITH, try s.specAt(s.genesis_time));
    try testing.expectEqual(OpSpecId.CANYON, try s.specAt(s.canyon));
    try testing.expectEqual(OpSpecId.ECOTONE, try s.specAt(s.ecotone));
    try testing.expectEqual(OpSpecId.FJORD, try s.specAt(s.fjord));
    try testing.expectEqual(OpSpecId.GRANITE, try s.specAt(s.granite));
    try testing.expectEqual(OpSpecId.HOLOCENE, try s.specAt(s.holocene));
    try testing.expectEqual(OpSpecId.HOLOCENE, try s.specAt(s.pectra_blob_schedule.?));
    try testing.expectEqual(OpSpecId.ISTHMUS, try s.specAt(s.isthmus));
    try testing.expectEqual(OpSpecId.JOVIAN, try s.specAt(s.jovian));
    try testing.expectError(error.UnmodeledBaseUpgrade, s.specAt(s.azul.?));
}

test "schedules are strictly increasing" {
    for ([_]Schedule{ MAINNET, SEPOLIA }) |s| {
        try testing.expect(s.genesis_time <= s.regolith);
        try testing.expect(s.regolith < s.canyon);
        try testing.expect(s.canyon < s.delta);
        try testing.expect(s.delta < s.ecotone);
        try testing.expect(s.ecotone < s.fjord);
        try testing.expect(s.fjord < s.granite);
        try testing.expect(s.granite < s.holocene);
        try testing.expect(s.holocene < s.isthmus);
        try testing.expect(s.isthmus < s.jovian);
        try testing.expect(s.jovian < s.azul.?);
        try testing.expect(s.azul.? < s.beryl.?);
        try testing.expect(s.beryl.? < s.cobalt.?);
        try testing.expect(s.cobalt.? < s.denim.?);
        // Regolith activates at genesis, so Bedrock is never the active spec on Base.
        try testing.expectEqual(OpSpecId.REGOLITH, try s.specAt(s.activation(.BEDROCK)));
        for (OpSpecId.ALL[1..]) |spec| {
            try testing.expectEqual(spec, try s.specAt(s.activation(spec)));
            try testing.expect(s.isActive(spec, s.activation(spec)));
        }
    }
}

test "real mainnet Fjord and Jovian dates" {
    // Superchain-registry comments: Fjord Wed 10 Jul 2024 16:00:01 UTC, Jovian Tue 2 Dec 2025 16:00:01 UTC.
    const fjord = std.time.epoch.EpochSeconds{ .secs = MAINNET.fjord };
    const fjord_day = fjord.getEpochDay().calculateYearDay();
    try testing.expectEqual(@as(u16, 2024), fjord_day.year);
    try testing.expectEqual(@as(u32, 16 * 3600 + 1), fjord.getDaySeconds().secs);
    const jovian = std.time.epoch.EpochSeconds{ .secs = MAINNET.jovian };
    try testing.expectEqual(@as(u16, 2025), jovian.getEpochDay().calculateYearDay().year);
    try testing.expectEqual(@as(u32, 16 * 3600 + 1), jovian.getDaySeconds().secs);
}
