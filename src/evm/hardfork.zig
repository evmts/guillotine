// TODO REMOVE this file it's part of eips.zig now
/// Ethereum hardfork identifiers.
///
/// Hardforks represent protocol upgrades that change EVM behavior,
/// gas costs, or add new features. Each hardfork builds upon the
/// previous ones, maintaining backward compatibility while adding
/// improvements.
///
/// ## Hardfork History
/// The EVM has evolved through multiple hardforks, each addressing
/// specific issues or adding new capabilities:
/// - Early forks focused on security and gas pricing
/// - Later forks added new opcodes and features
/// - Recent forks optimize performance and add L2 support
///
/// ## Using Hardforks
/// Hardforks are primarily used to:
/// - Configure jump tables with correct opcodes
/// - Set appropriate gas costs for operations
/// - Enable/disable features based on fork rules
///
/// Example:
/// ```zig
/// const table = OpcodeMetadata.init_from_hardfork(.CANCUN);
/// const is_berlin_plus = @intFromEnum(hardfork) >= @intFromEnum(Hardfork.BERLIN);
/// ```
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
    /// Prague/Electra fork (Expected 2025).
    /// EIP-2537: BLS12-381 precompiles.
    /// EIP-7702: Set EOA account code for one transaction.
    /// EIP-2935: Serve historical block hashes from state.
    /// EIP-6110: Supply validator deposits on chain.
    /// EIP-7002: Execution layer triggerable exits.
    PRAGUE,
    /// Default hardfork for new chains.
    /// Set to latest stable fork (currently CANCUN).
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

test "hardfork version comparisons edge cases" {
    // Test adjacent forks
    try std.testing.expect(Hardfork.BERLIN.isBefore(Hardfork.LONDON));
    try std.testing.expect(Hardfork.LONDON.isAtLeast(Hardfork.BERLIN));

    // Test same fork
    try std.testing.expect(!Hardfork.ISTANBUL.isBefore(Hardfork.ISTANBUL));
    try std.testing.expect(Hardfork.ISTANBUL.isAtLeast(Hardfork.ISTANBUL));
}

test "hardfork major milestone checks" {
    // Pre-Byzantium (no REVERT opcode)
    try std.testing.expect(Hardfork.HOMESTEAD.isBefore(Hardfork.BYZANTIUM));
    try std.testing.expect(Hardfork.TANGERINE_WHISTLE.isBefore(Hardfork.BYZANTIUM));

    // Post-Berlin (warm/cold access)
    try std.testing.expect(Hardfork.BERLIN.isAtLeast(Hardfork.BERLIN));
    try std.testing.expect(Hardfork.LONDON.isAtLeast(Hardfork.BERLIN));
    try std.testing.expect(Hardfork.CANCUN.isAtLeast(Hardfork.BERLIN));

    // Shanghai introduces PUSH0
    try std.testing.expect(Hardfork.SHANGHAI.isAtLeast(Hardfork.SHANGHAI));
    try std.testing.expect(Hardfork.CANCUN.isAtLeast(Hardfork.SHANGHAI));

    // Cancun introduces transient storage
    try std.testing.expect(Hardfork.CANCUN.isAtLeast(Hardfork.CANCUN));
    
    // Prague introduces account abstraction features
    try std.testing.expect(Hardfork.PRAGUE.isAtLeast(Hardfork.PRAGUE));
}

test "hardfork complete sequence ordering" {
    const forks = [_]Hardfork{
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
    };

    // Verify each fork is properly ordered
    for (forks[0..forks.len-1], 1..) |fork, next_index| {
        try std.testing.expect(fork.toInt() < forks[next_index].toInt());
        try std.testing.expect(fork.isBefore(forks[next_index]));
        try std.testing.expect(forks[next_index].isAtLeast(fork));
    }
}

test "hardfork toInt values are consecutive" {
    // Verify that hardfork enum values are consecutive integers starting from 0
    try std.testing.expectEqual(@as(u32, 0), Hardfork.FRONTIER.toInt());
    try std.testing.expectEqual(@as(u32, 1), Hardfork.HOMESTEAD.toInt());
    try std.testing.expectEqual(@as(u32, 2), Hardfork.DAO.toInt());
    try std.testing.expectEqual(@as(u32, 3), Hardfork.TANGERINE_WHISTLE.toInt());
    try std.testing.expectEqual(@as(u32, 4), Hardfork.SPURIOUS_DRAGON.toInt());
    try std.testing.expectEqual(@as(u32, 5), Hardfork.BYZANTIUM.toInt());
    try std.testing.expectEqual(@as(u32, 6), Hardfork.CONSTANTINOPLE.toInt());
    try std.testing.expectEqual(@as(u32, 7), Hardfork.PETERSBURG.toInt());
    try std.testing.expectEqual(@as(u32, 8), Hardfork.ISTANBUL.toInt());
    try std.testing.expectEqual(@as(u32, 9), Hardfork.MUIR_GLACIER.toInt());
    try std.testing.expectEqual(@as(u32, 10), Hardfork.BERLIN.toInt());
    try std.testing.expectEqual(@as(u32, 11), Hardfork.LONDON.toInt());
    try std.testing.expectEqual(@as(u32, 12), Hardfork.ARROW_GLACIER.toInt());
    try std.testing.expectEqual(@as(u32, 13), Hardfork.GRAY_GLACIER.toInt());
    try std.testing.expectEqual(@as(u32, 14), Hardfork.MERGE.toInt());
    try std.testing.expectEqual(@as(u32, 15), Hardfork.SHANGHAI.toInt());
    try std.testing.expectEqual(@as(u32, 16), Hardfork.CANCUN.toInt());
    try std.testing.expectEqual(@as(u32, 17), Hardfork.PRAGUE.toInt());
}

test "hardfork DAO special case" {
    // DAO fork was special - it changed state but not EVM rules
    // Should still be properly ordered between Homestead and Tangerine Whistle
    try std.testing.expect(Hardfork.HOMESTEAD.isBefore(Hardfork.DAO));
    try std.testing.expect(Hardfork.DAO.isBefore(Hardfork.TANGERINE_WHISTLE));
    try std.testing.expect(Hardfork.DAO.isAtLeast(Hardfork.HOMESTEAD));
    try std.testing.expect(Hardfork.TANGERINE_WHISTLE.isAtLeast(Hardfork.DAO));
}

test "hardfork constantinople petersburg relationship" {
    // Petersburg was a quick fix to Constantinople - same protocol level
    // but Petersburg should come after Constantinople in ordering
    try std.testing.expect(Hardfork.CONSTANTINOPLE.isBefore(Hardfork.PETERSBURG));
    try std.testing.expect(Hardfork.PETERSBURG.isAtLeast(Hardfork.CONSTANTINOPLE));
    try std.testing.expectEqual(@as(u32, 7), Hardfork.PETERSBURG.toInt());
    try std.testing.expectEqual(@as(u32, 6), Hardfork.CONSTANTINOPLE.toInt());
}

test "hardfork difficulty bomb delays" {
    // Test difficulty bomb delay forks that don't change EVM behavior
    // These forks should be properly ordered
    try std.testing.expect(Hardfork.MUIR_GLACIER.isBefore(Hardfork.ARROW_GLACIER));
    try std.testing.expect(Hardfork.ARROW_GLACIER.isBefore(Hardfork.GRAY_GLACIER));
    
    // They should come in the right sequence relative to other forks
    try std.testing.expect(Hardfork.ISTANBUL.isBefore(Hardfork.MUIR_GLACIER));
    try std.testing.expect(Hardfork.MUIR_GLACIER.isBefore(Hardfork.BERLIN));
    try std.testing.expect(Hardfork.LONDON.isBefore(Hardfork.ARROW_GLACIER));
    try std.testing.expect(Hardfork.ARROW_GLACIER.isBefore(Hardfork.GRAY_GLACIER));
    try std.testing.expect(Hardfork.GRAY_GLACIER.isBefore(Hardfork.MERGE));
}

test "hardfork merge special properties" {
    // MERGE replaced DIFFICULTY with PREVRANDAO
    // Should be properly positioned after Gray Glacier, before Shanghai
    try std.testing.expect(Hardfork.GRAY_GLACIER.isBefore(Hardfork.MERGE));
    try std.testing.expect(Hardfork.MERGE.isBefore(Hardfork.SHANGHAI));
    try std.testing.expect(Hardfork.MERGE.isAtLeast(Hardfork.LONDON));
}

test "hardfork recent forks" {
    // Test the most recent forks have proper ordering
    try std.testing.expect(Hardfork.MERGE.isBefore(Hardfork.SHANGHAI));
    try std.testing.expect(Hardfork.SHANGHAI.isBefore(Hardfork.CANCUN));
    try std.testing.expect(Hardfork.CANCUN.isBefore(Hardfork.PRAGUE));
    
    // All recent forks should be at least Berlin (for access lists)
    try std.testing.expect(Hardfork.MERGE.isAtLeast(Hardfork.BERLIN));
    try std.testing.expect(Hardfork.SHANGHAI.isAtLeast(Hardfork.BERLIN));
    try std.testing.expect(Hardfork.CANCUN.isAtLeast(Hardfork.BERLIN));
    try std.testing.expect(Hardfork.PRAGUE.isAtLeast(Hardfork.BERLIN));
}

test "hardfork gas repricing forks" {
    // Test forks that primarily changed gas costs
    try std.testing.expect(Hardfork.TANGERINE_WHISTLE.isAtLeast(Hardfork.HOMESTEAD));
    try std.testing.expect(Hardfork.BERLIN.isAtLeast(Hardfork.ISTANBUL));
    
    // Tangerine Whistle (EIP-150) increased gas costs for IO operations
    try std.testing.expect(Hardfork.TANGERINE_WHISTLE.isBefore(Hardfork.SPURIOUS_DRAGON));
    
    // Berlin introduced access lists and changed SLOAD/SSTORE costs
    try std.testing.expect(Hardfork.ISTANBUL.isBefore(Hardfork.BERLIN));
}

test "hardfork feature introduction points" {
    // Test key feature introduction points
    
    // DELEGATECALL introduced in Homestead
    try std.testing.expect(Hardfork.HOMESTEAD.isAtLeast(Hardfork.HOMESTEAD));
    try std.testing.expect(Hardfork.FRONTIER.isBefore(Hardfork.HOMESTEAD));
    
    // REVERT, RETURNDATASIZE, RETURNDATACOPY introduced in Byzantium
    try std.testing.expect(Hardfork.BYZANTIUM.isAtLeast(Hardfork.BYZANTIUM));
    try std.testing.expect(Hardfork.SPURIOUS_DRAGON.isBefore(Hardfork.BYZANTIUM));
    
    // CREATE2 introduced in Constantinople (then removed in Petersburg, then re-added)
    try std.testing.expect(Hardfork.CONSTANTINOPLE.isBefore(Hardfork.PETERSBURG));
    
    // CHAINID and SELFBALANCE introduced in Istanbul
    try std.testing.expect(Hardfork.ISTANBUL.isAtLeast(Hardfork.ISTANBUL));
    try std.testing.expect(Hardfork.PETERSBURG.isBefore(Hardfork.ISTANBUL));
    
    // BASEFEE introduced in London
    try std.testing.expect(Hardfork.LONDON.isAtLeast(Hardfork.LONDON));
    try std.testing.expect(Hardfork.BERLIN.isBefore(Hardfork.LONDON));
    
    // PUSH0 introduced in Shanghai
    try std.testing.expect(Hardfork.SHANGHAI.isAtLeast(Hardfork.SHANGHAI));
    try std.testing.expect(Hardfork.MERGE.isBefore(Hardfork.SHANGHAI));
    
    // TLOAD/TSTORE introduced in Cancun
    try std.testing.expect(Hardfork.CANCUN.isAtLeast(Hardfork.CANCUN));
    try std.testing.expect(Hardfork.SHANGHAI.isBefore(Hardfork.CANCUN));
    
    // Account abstraction features in Prague
    try std.testing.expect(Hardfork.PRAGUE.isAtLeast(Hardfork.PRAGUE));
    try std.testing.expect(Hardfork.CANCUN.isBefore(Hardfork.PRAGUE));
}

test "hardfork transitivity of comparisons" {
    // Test that if A < B and B < C, then A < C
    const examples = [_][3]Hardfork{
        .{ .FRONTIER, .HOMESTEAD, .BYZANTIUM },
        .{ .TANGERINE_WHISTLE, .SPURIOUS_DRAGON, .BYZANTIUM },
        .{ .BERLIN, .LONDON, .SHANGHAI },
        .{ .CONSTANTINOPLE, .PETERSBURG, .ISTANBUL },
    };
    
    for (examples) |example| {
        const a, const b, const c = example;
        // Verify A < B < C
        try std.testing.expect(a.isBefore(b));
        try std.testing.expect(b.isBefore(c));
        try std.testing.expect(a.isBefore(c)); // Transitivity
        
        // Verify C >= B >= A
        try std.testing.expect(c.isAtLeast(b));
        try std.testing.expect(b.isAtLeast(a));
        try std.testing.expect(c.isAtLeast(a)); // Transitivity
    }
}

test "hardfork comparison consistency" {
    const all_forks = [_]Hardfork{
        .FRONTIER, .HOMESTEAD, .DAO, .TANGERINE_WHISTLE, .SPURIOUS_DRAGON,
        .BYZANTIUM, .CONSTANTINOPLE, .PETERSBURG, .ISTANBUL, .MUIR_GLACIER,
        .BERLIN, .LONDON, .ARROW_GLACIER, .GRAY_GLACIER, .MERGE, .SHANGHAI, .CANCUN, .PRAGUE
    };
    
    // Test all pairs for consistency
    for (all_forks, 0..) |fork_a, i| {
        for (all_forks, 0..) |fork_b, j| {
            if (i < j) {
                // fork_a should be before fork_b
                try std.testing.expect(fork_a.isBefore(fork_b));
                try std.testing.expect(fork_b.isAtLeast(fork_a));
                try std.testing.expect(!fork_b.isBefore(fork_a));
                try std.testing.expect(fork_a.toInt() < fork_b.toInt());
            } else if (i == j) {
                // Same fork
                try std.testing.expect(!fork_a.isBefore(fork_b));
                try std.testing.expect(fork_a.isAtLeast(fork_b));
                try std.testing.expect(fork_b.isAtLeast(fork_a));
                try std.testing.expect(fork_a.toInt() == fork_b.toInt());
            } else {
                // fork_a should be after fork_b
                try std.testing.expect(fork_b.isBefore(fork_a));
                try std.testing.expect(fork_a.isAtLeast(fork_b));
                try std.testing.expect(!fork_a.isBefore(fork_b));
                try std.testing.expect(fork_a.toInt() > fork_b.toInt());
            }
        }
    }
}

test "hardfork default is latest" {
    // DEFAULT should be the most recent stable fork
    try std.testing.expectEqual(Hardfork.CANCUN, Hardfork.DEFAULT);
    
    // Verify DEFAULT is at least all other forks
    const all_forks = [_]Hardfork{
        .FRONTIER, .HOMESTEAD, .DAO, .TANGERINE_WHISTLE, .SPURIOUS_DRAGON,
        .BYZANTIUM, .CONSTANTINOPLE, .PETERSBURG, .ISTANBUL, .MUIR_GLACIER,
        .BERLIN, .LONDON, .ARROW_GLACIER, .GRAY_GLACIER, .MERGE, .SHANGHAI
    };
    
    for (all_forks) |fork| {
        try std.testing.expect(Hardfork.DEFAULT.isAtLeast(fork));
    }
}

test "hardfork enum completeness" {
    // Verify we have all expected hardforks based on the highest toInt() value
    // This helps catch if we add new forks but forget to update tests
    const max_int = Hardfork.PRAGUE.toInt();
    try std.testing.expectEqual(@as(u32, 17), max_int); // 18 total forks (0-17)
    
    // Verify there are no gaps in the sequence
    var expected_int: u32 = 0;
    const all_forks = [_]Hardfork{
        .FRONTIER, .HOMESTEAD, .DAO, .TANGERINE_WHISTLE, .SPURIOUS_DRAGON,
        .BYZANTIUM, .CONSTANTINOPLE, .PETERSBURG, .ISTANBUL, .MUIR_GLACIER,
        .BERLIN, .LONDON, .ARROW_GLACIER, .GRAY_GLACIER, .MERGE, .SHANGHAI, .CANCUN, .PRAGUE
    };
    
    for (all_forks) |fork| {
        try std.testing.expectEqual(expected_int, fork.toInt());
        expected_int += 1;
    }
}

test "hardfork comparison edge cases with same values" {
    // Test edge cases where we compare a fork with itself
    const fork = Hardfork.LONDON;
    
    try std.testing.expect(fork.isAtLeast(fork)); // Should be true
    try std.testing.expect(!fork.isBefore(fork)); // Should be false
    try std.testing.expectEqual(fork.toInt(), fork.toInt()); // Should be equal
}

test "hardfork historical context validation" {
    // Verify historical timeline makes sense
    
    // Frontier (Genesis) should be first
    try std.testing.expectEqual(@as(u32, 0), Hardfork.FRONTIER.toInt());
    
    // Homestead should be second (first planned fork)
    try std.testing.expectEqual(@as(u32, 1), Hardfork.HOMESTEAD.toInt());
    
    // DAO fork should come after Homestead
    try std.testing.expect(Hardfork.DAO.isAtLeast(Hardfork.HOMESTEAD));
    
    // Berlin should come well after the early forks
    try std.testing.expect(Hardfork.BERLIN.toInt() >= 10);
    
    // Recent forks should be in the upper range
    try std.testing.expect(Hardfork.SHANGHAI.toInt() >= 15);
    try std.testing.expect(Hardfork.CANCUN.toInt() >= 16);
    try std.testing.expect(Hardfork.PRAGUE.toInt() >= 17);
}
