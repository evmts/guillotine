/// Ethereum hardfork identifiers.
///
/// Hardforks represent protocol upgrades that change EVM behavior,
/// gas costs, or add new features. Each hardfork builds upon the
/// previous ones, maintaining backward compatibility while adding
/// improvements.
pub const Hardfork = enum {
    /// Original Ethereum launch (July 2015).
    /// Base EVM with fundamental opcodes.
    FRONTIER,
    /// First planned hardfork (March 2016).
    /// Added DELEGATECALL and fixed critical issues.
    HOMESTEAD,
    /// Emergency fork for DAO hack (July 2016).
    /// No EVM changes, only state modifications.
    DAO,
    /// Gas repricing fork (October 2016).
    /// EIP-150: Increased gas costs for IO-heavy operations.
    TANGERINE_WHISTLE,
    /// State cleaning fork (November 2016).
    /// EIP-161: Removed empty accounts.
    SPURIOUS_DRAGON,
    /// Major feature fork (October 2017).
    /// Added REVERT, RETURNDATASIZE, RETURNDATACOPY, STATICCALL.
    BYZANTIUM,
    /// Efficiency improvements (February 2019).
    /// Added CREATE2, shift opcodes, EXTCODEHASH.
    CONSTANTINOPLE,
    /// Quick fix fork (February 2019).
    /// Removed EIP-1283 due to reentrancy concerns.
    PETERSBURG,
    /// Gas optimization fork (December 2019).
    /// EIP-2200: Rebalanced SSTORE costs.
    /// Added CHAINID and SELFBALANCE.
    ISTANBUL,
    /// Difficulty bomb delay (January 2020).
    /// No EVM changes.
    MUIR_GLACIER,
    /// Access list fork (April 2021).
    /// EIP-2929: Gas cost for cold/warm access.
    /// EIP-2930: Optional access lists.
    BERLIN,
    /// Fee market reform (August 2021).
    /// EIP-1559: Base fee and new transaction types.
    /// Added BASEFEE opcode.
    LONDON,
    /// Difficulty bomb delay (December 2021).
    /// No EVM changes.
    ARROW_GLACIER,
    /// Difficulty bomb delay (June 2022).
    /// No EVM changes.
    GRAY_GLACIER,
    /// Proof of Stake transition (September 2022).
    /// Replaced DIFFICULTY with PREVRANDAO.
    MERGE,
    /// Withdrawal enabling fork (April 2023).
    /// EIP-3855: PUSH0 opcode.
    SHANGHAI,
    /// Proto-danksharding fork (March 2024).
    /// EIP-4844: Blob transactions.
    /// EIP-1153: Transient storage (TLOAD/TSTORE).
    /// EIP-5656: MCOPY opcode.
    CANCUN,
    /// Prague-Electra fork (May 2025).
    /// EIP-2537: BLS12-381 precompiles.
    /// EIP-7702: Set EOA account code for one transaction.
    /// EIP-7251: Increase max effective balance.
    /// EIP-7002: Execution layer triggerable exits.
    PRAGUE,
    /// Osaka fork (TBD 2026).
    /// EIP-7883: Verkle Tree state structure.
    /// EIP-7823: Verkle proof gas costs.
    /// EIP-7825: Witness gas costs.
    /// EIP-7934: State migration optimizations.
    OSAKA,
    /// Default hardfork for new chains.
    /// Set to latest stable fork (currently CANCUN).
    /// CANCUN is the current mainnet hardfork as of March 2024.
    pub const DEFAULT = Hardfork.CANCUN;

    /// Convert hardfork to its numeric representation for version comparisons
    pub fn toInt(self: Hardfork) u32 {
        return @intFromEnum(self);
    }

    /// Check if this hardfork is at least the specified version
    pub fn isAtLeast(self: Hardfork, target: Hardfork) bool {
        return self.toInt() >= target.toInt();
    }

    /// Check if this hardfork is before the specified version
    pub fn isBefore(self: Hardfork, target: Hardfork) bool {
        return self.toInt() < target.toInt();
    }

    /// Mainnet activation block numbers for each hardfork
    /// Returns null if hardfork hasn't been activated yet or is network-specific
    pub fn mainnetActivationBlock(self: Hardfork) ?u64 {
        return switch (self) {
            .FRONTIER => 0,
            .HOMESTEAD => 1150000,
            .DAO => 1920000,
            .TANGERINE_WHISTLE => 2463000,
            .SPURIOUS_DRAGON => 2675000,
            .BYZANTIUM => 4370000,
            .CONSTANTINOPLE => 7280000,
            .PETERSBURG => 7280000,
            .ISTANBUL => 9069000,
            .MUIR_GLACIER => 9200000,
            .BERLIN => 12244000,
            .LONDON => 12965000,
            .ARROW_GLACIER => 13773000,
            .GRAY_GLACIER => 15050000,
            .MERGE => 15537394,
            .SHANGHAI => 17034870,
            .CANCUN => 19426587,
            .PRAGUE => null, // Not yet activated on mainnet
            .OSAKA => null, // Not yet activated on mainnet
        };
    }

    /// Mainnet activation timestamps for post-Merge hardforks
    /// Returns null if hardfork is pre-Merge or hasn't been activated yet
    pub fn mainnetActivationTimestamp(self: Hardfork) ?u64 {
        return switch (self) {
            .FRONTIER, .HOMESTEAD, .DAO, .TANGERINE_WHISTLE, .SPURIOUS_DRAGON, .BYZANTIUM, .CONSTANTINOPLE, .PETERSBURG, .ISTANBUL, .MUIR_GLACIER, .BERLIN, .LONDON, .ARROW_GLACIER, .GRAY_GLACIER => null,
            .MERGE => 1663224162,
            .SHANGHAI => 1681338455,
            .CANCUN => 1710338135,
            .PRAGUE => null, // Not yet activated on mainnet
            .OSAKA => null, // Not yet activated on mainnet
        };
    }

    /// Check if a specific EIP number is active in this hardfork
    /// This delegates to the Eips struct for the actual EIP tracking
    pub fn isEipActive(self: Hardfork, eip: u16) bool {
        const Eips = @import("eips.zig").Eips;
        const eips = Eips{ .hardfork = self };
        return eips.is_eip_active(eip);
    }
};

const std = @import("std");

test "hardfork enum ordering" {
    try std.testing.expect(@intFromEnum(Hardfork.FRONTIER) < @intFromEnum(Hardfork.HOMESTEAD));
    try std.testing.expect(@intFromEnum(Hardfork.HOMESTEAD) < @intFromEnum(Hardfork.BYZANTIUM));
    try std.testing.expect(@intFromEnum(Hardfork.BYZANTIUM) < @intFromEnum(Hardfork.CANCUN));
    try std.testing.expect(@intFromEnum(Hardfork.CANCUN) < @intFromEnum(Hardfork.PRAGUE));
}

test "hardfork default is cancun" {
    try std.testing.expectEqual(Hardfork.CANCUN, Hardfork.DEFAULT);
}

test "hardfork toInt conversion" {
    try std.testing.expect(Hardfork.FRONTIER.toInt() == 0);
    try std.testing.expect(Hardfork.HOMESTEAD.toInt() == 1);
    try std.testing.expect(Hardfork.CANCUN.toInt() > Hardfork.FRONTIER.toInt());
    try std.testing.expect(Hardfork.PRAGUE.toInt() > Hardfork.CANCUN.toInt());
}

test "hardfork isAtLeast comparison" {
    try std.testing.expect(Hardfork.CANCUN.isAtLeast(Hardfork.FRONTIER));
    try std.testing.expect(Hardfork.CANCUN.isAtLeast(Hardfork.CANCUN));
    try std.testing.expect(!Hardfork.FRONTIER.isAtLeast(Hardfork.CANCUN));

    try std.testing.expect(Hardfork.BERLIN.isAtLeast(Hardfork.BERLIN));
    try std.testing.expect(Hardfork.LONDON.isAtLeast(Hardfork.BERLIN));
    try std.testing.expect(!Hardfork.HOMESTEAD.isAtLeast(Hardfork.BERLIN));
}

test "hardfork isBefore comparison" {
    try std.testing.expect(Hardfork.FRONTIER.isBefore(Hardfork.CANCUN));
    try std.testing.expect(!Hardfork.CANCUN.isBefore(Hardfork.FRONTIER));
    try std.testing.expect(!Hardfork.CANCUN.isBefore(Hardfork.CANCUN));

    try std.testing.expect(Hardfork.HOMESTEAD.isBefore(Hardfork.BERLIN));
    try std.testing.expect(!Hardfork.BERLIN.isBefore(Hardfork.HOMESTEAD));
}

test "hardfork OSAKA ordering" {
    try std.testing.expect(Hardfork.PRAGUE.isBefore(Hardfork.OSAKA));
    try std.testing.expect(Hardfork.OSAKA.isAtLeast(Hardfork.PRAGUE));
    try std.testing.expect(Hardfork.OSAKA.isAtLeast(Hardfork.CANCUN));
    try std.testing.expect(@intFromEnum(Hardfork.OSAKA) > @intFromEnum(Hardfork.PRAGUE));
}

test "hardfork mainnet activation blocks" {
    try std.testing.expectEqual(@as(?u64, 0), Hardfork.FRONTIER.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 1150000), Hardfork.HOMESTEAD.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 1920000), Hardfork.DAO.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 2463000), Hardfork.TANGERINE_WHISTLE.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 2675000), Hardfork.SPURIOUS_DRAGON.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 4370000), Hardfork.BYZANTIUM.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 7280000), Hardfork.CONSTANTINOPLE.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 7280000), Hardfork.PETERSBURG.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 9069000), Hardfork.ISTANBUL.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 9200000), Hardfork.MUIR_GLACIER.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 12244000), Hardfork.BERLIN.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 12965000), Hardfork.LONDON.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 13773000), Hardfork.ARROW_GLACIER.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 15050000), Hardfork.GRAY_GLACIER.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 15537394), Hardfork.MERGE.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 17034870), Hardfork.SHANGHAI.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 19426587), Hardfork.CANCUN.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, null), Hardfork.PRAGUE.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, null), Hardfork.OSAKA.mainnetActivationBlock());
}

test "hardfork mainnet activation timestamps" {
    try std.testing.expectEqual(@as(?u64, null), Hardfork.FRONTIER.mainnetActivationTimestamp());
    try std.testing.expectEqual(@as(?u64, null), Hardfork.HOMESTEAD.mainnetActivationTimestamp());
    try std.testing.expectEqual(@as(?u64, null), Hardfork.BERLIN.mainnetActivationTimestamp());
    try std.testing.expectEqual(@as(?u64, null), Hardfork.LONDON.mainnetActivationTimestamp());

    try std.testing.expectEqual(@as(?u64, 1663224162), Hardfork.MERGE.mainnetActivationTimestamp());
    try std.testing.expectEqual(@as(?u64, 1681338455), Hardfork.SHANGHAI.mainnetActivationTimestamp());
    try std.testing.expectEqual(@as(?u64, 1710338135), Hardfork.CANCUN.mainnetActivationTimestamp());
    try std.testing.expectEqual(@as(?u64, null), Hardfork.PRAGUE.mainnetActivationTimestamp());
    try std.testing.expectEqual(@as(?u64, null), Hardfork.OSAKA.mainnetActivationTimestamp());
}

test "hardfork activation block ordering" {
    const frontier = Hardfork.FRONTIER.mainnetActivationBlock().?;
    const homestead = Hardfork.HOMESTEAD.mainnetActivationBlock().?;
    const berlin = Hardfork.BERLIN.mainnetActivationBlock().?;
    const london = Hardfork.LONDON.mainnetActivationBlock().?;
    const merge = Hardfork.MERGE.mainnetActivationBlock().?;
    const shanghai = Hardfork.SHANGHAI.mainnetActivationBlock().?;
    const cancun = Hardfork.CANCUN.mainnetActivationBlock().?;

    try std.testing.expect(frontier < homestead);
    try std.testing.expect(homestead < berlin);
    try std.testing.expect(berlin < london);
    try std.testing.expect(london < merge);
    try std.testing.expect(merge < shanghai);
    try std.testing.expect(shanghai < cancun);
}

test "hardfork activation timestamp ordering" {
    const merge = Hardfork.MERGE.mainnetActivationTimestamp().?;
    const shanghai = Hardfork.SHANGHAI.mainnetActivationTimestamp().?;
    const cancun = Hardfork.CANCUN.mainnetActivationTimestamp().?;

    try std.testing.expect(merge < shanghai);
    try std.testing.expect(shanghai < cancun);
}

test "hardfork isEipActive delegation" {
    try std.testing.expect(!Hardfork.FRONTIER.isEipActive(150));
    try std.testing.expect(Hardfork.TANGERINE_WHISTLE.isEipActive(150));

    try std.testing.expect(!Hardfork.ISTANBUL.isEipActive(2929));
    try std.testing.expect(Hardfork.BERLIN.isEipActive(2929));

    try std.testing.expect(!Hardfork.BERLIN.isEipActive(1559));
    try std.testing.expect(Hardfork.LONDON.isEipActive(1559));

    try std.testing.expect(!Hardfork.LONDON.isEipActive(3855));
    try std.testing.expect(Hardfork.SHANGHAI.isEipActive(3855));

    try std.testing.expect(!Hardfork.SHANGHAI.isEipActive(1153));
    try std.testing.expect(Hardfork.CANCUN.isEipActive(1153));
    try std.testing.expect(Hardfork.CANCUN.isEipActive(4844));
    try std.testing.expect(Hardfork.CANCUN.isEipActive(6780));

    try std.testing.expect(!Hardfork.CANCUN.isEipActive(7702));
    try std.testing.expect(Hardfork.PRAGUE.isEipActive(7702));
    try std.testing.expect(Hardfork.PRAGUE.isEipActive(2537));
    try std.testing.expect(Hardfork.PRAGUE.isEipActive(7002));

    try std.testing.expect(Hardfork.OSAKA.isEipActive(7883));
    try std.testing.expect(Hardfork.OSAKA.isEipActive(7823));
    try std.testing.expect(Hardfork.OSAKA.isEipActive(7702));
}

test "hardfork constantinople petersburg same block" {
    const constantinople_block = Hardfork.CONSTANTINOPLE.mainnetActivationBlock().?;
    const petersburg_block = Hardfork.PETERSBURG.mainnetActivationBlock().?;

    try std.testing.expectEqual(constantinople_block, petersburg_block);
}

test "hardfork complete enum coverage" {
    const all_hardforks = [_]Hardfork{
        .FRONTIER,
        .HOMESTEAD,
        .DAO,
        .TANGERINE_WHISTLE,
        .SPURIOUS_DRAGON,
        .BYZANTIUM,
        .CONSTANTINOPLE,
        .PETERSBURG,
        .ISTANBUL,
        .MUIR_GLACIER,
        .BERLIN,
        .LONDON,
        .ARROW_GLACIER,
        .GRAY_GLACIER,
        .MERGE,
        .SHANGHAI,
        .CANCUN,
        .PRAGUE,
        .OSAKA,
    };

    for (all_hardforks) |fork| {
        _ = fork.toInt();
        _ = fork.mainnetActivationBlock();
        _ = fork.mainnetActivationTimestamp();
    }
}

test "hardfork comparison all pairs" {
    try std.testing.expect(Hardfork.FRONTIER.isBefore(Hardfork.HOMESTEAD));
    try std.testing.expect(Hardfork.HOMESTEAD.isBefore(Hardfork.BYZANTIUM));
    try std.testing.expect(Hardfork.BYZANTIUM.isBefore(Hardfork.CONSTANTINOPLE));
    try std.testing.expect(Hardfork.CONSTANTINOPLE.isBefore(Hardfork.ISTANBUL));
    try std.testing.expect(Hardfork.ISTANBUL.isBefore(Hardfork.BERLIN));
    try std.testing.expect(Hardfork.BERLIN.isBefore(Hardfork.LONDON));
    try std.testing.expect(Hardfork.LONDON.isBefore(Hardfork.MERGE));
    try std.testing.expect(Hardfork.MERGE.isBefore(Hardfork.SHANGHAI));
    try std.testing.expect(Hardfork.SHANGHAI.isBefore(Hardfork.CANCUN));
    try std.testing.expect(Hardfork.CANCUN.isBefore(Hardfork.PRAGUE));
    try std.testing.expect(Hardfork.PRAGUE.isBefore(Hardfork.OSAKA));
}

test "hardfork isAtLeast reflexive" {
    try std.testing.expect(Hardfork.FRONTIER.isAtLeast(Hardfork.FRONTIER));
    try std.testing.expect(Hardfork.HOMESTEAD.isAtLeast(Hardfork.HOMESTEAD));
    try std.testing.expect(Hardfork.BERLIN.isAtLeast(Hardfork.BERLIN));
    try std.testing.expect(Hardfork.LONDON.isAtLeast(Hardfork.LONDON));
    try std.testing.expect(Hardfork.SHANGHAI.isAtLeast(Hardfork.SHANGHAI));
    try std.testing.expect(Hardfork.CANCUN.isAtLeast(Hardfork.CANCUN));
    try std.testing.expect(Hardfork.PRAGUE.isAtLeast(Hardfork.PRAGUE));
    try std.testing.expect(Hardfork.OSAKA.isAtLeast(Hardfork.OSAKA));
}