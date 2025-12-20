//! Ethereum Hardfork Management
//!
//! This module provides hardfork identifiers and version comparison utilities
//! for Ethereum protocol upgrades. Each hardfork represents a protocol upgrade
//! that changes EVM behavior, gas costs, or adds new features.
//!
//! ## Usage
//!
//! ### Basic Version Comparison
//! ```zig
//! const hardfork = @import("voltaire");
//!
//! const current = hardfork.Hardfork.CANCUN;
//! if (current.isAtLeast(.SHANGHAI)) {
//!     // PUSH0 opcode is available
//! }
//! ```
//!
//! ### Fork Transitions
//! ```zig
//! // Parse a transition like "ShanghaiToCancunAtTime15000"
//! const transition = hardfork.ForkTransition.fromString("ShanghaiToCancunAtTime15000");
//! const active = transition.?.getActiveFork(block_number, timestamp);
//! ```
//!
//! ## Hardfork Timeline
//!
//! Each hardfork builds upon previous ones, maintaining backward compatibility:
//! - **FRONTIER** (July 2015): Original Ethereum launch
//! - **HOMESTEAD** (March 2016): Added DELEGATECALL
//! - **BYZANTIUM** (October 2017): Added REVERT, STATICCALL
//! - **CONSTANTINOPLE** (February 2019): Added CREATE2, shift opcodes
//! - **ISTANBUL** (December 2019): Added CHAINID, SELFBALANCE
//! - **BERLIN** (April 2021): Gas cost changes for cold/warm access
//! - **LONDON** (August 2021): EIP-1559 fee market reform
//! - **MERGE** (September 2022): Proof of Stake transition
//! - **SHANGHAI** (April 2023): Added PUSH0 opcode
//! - **CANCUN** (March 2024): Proto-danksharding with blobs
//! - **PRAGUE** (May 2025): BLS12-381 precompiles, EIP-7702
//! - **OSAKA** (TBD): ModExp improvements

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
    /// Osaka fork (TBD).
    /// EIP-7883: ModExp gas increase.
    /// EIP-7823: ModExp upper bounds.
    /// EIP-7825: Transaction gas limit cap.
    /// EIP-7934: Block RLP limit.
    OSAKA,

    /// Default hardfork for new chains.
    /// Set to latest stable fork (currently PRAGUE).
    pub const DEFAULT = Hardfork.PRAGUE;

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

    /// Parse hardfork from string name (case-insensitive)
    /// Supports both standard names and common variations
    pub fn fromString(name: []const u8) ?Hardfork {
        // Handle comparisons like ">=Cancun" or ">Berlin"
        var clean_name = name;
        if (name.len > 0 and (name[0] == '>' or name[0] == '<')) {
            var start: usize = 1;
            if (name.len > 1 and name[1] == '=') {
                start = 2;
            }
            clean_name = name[start..];
        }

        // Case-insensitive comparison
        if (std.ascii.eqlIgnoreCase(clean_name, "Frontier")) return .FRONTIER;
        if (std.ascii.eqlIgnoreCase(clean_name, "Homestead")) return .HOMESTEAD;
        if (std.ascii.eqlIgnoreCase(clean_name, "DAO")) return .DAO;
        if (std.ascii.eqlIgnoreCase(clean_name, "TangerineWhistle")) return .TANGERINE_WHISTLE;
        if (std.ascii.eqlIgnoreCase(clean_name, "SpuriousDragon")) return .SPURIOUS_DRAGON;
        if (std.ascii.eqlIgnoreCase(clean_name, "Byzantium")) return .BYZANTIUM;
        if (std.ascii.eqlIgnoreCase(clean_name, "Constantinople")) return .CONSTANTINOPLE;
        if (std.ascii.eqlIgnoreCase(clean_name, "Petersburg")) return .PETERSBURG;
        if (std.ascii.eqlIgnoreCase(clean_name, "ConstantinopleFix")) return .PETERSBURG; // Alias for Petersburg
        if (std.ascii.eqlIgnoreCase(clean_name, "Istanbul")) return .ISTANBUL;
        if (std.ascii.eqlIgnoreCase(clean_name, "MuirGlacier")) return .MUIR_GLACIER;
        if (std.ascii.eqlIgnoreCase(clean_name, "Berlin")) return .BERLIN;
        if (std.ascii.eqlIgnoreCase(clean_name, "London")) return .LONDON;
        if (std.ascii.eqlIgnoreCase(clean_name, "ArrowGlacier")) return .ARROW_GLACIER;
        if (std.ascii.eqlIgnoreCase(clean_name, "GrayGlacier")) return .GRAY_GLACIER;
        if (std.ascii.eqlIgnoreCase(clean_name, "Merge")) return .MERGE;
        if (std.ascii.eqlIgnoreCase(clean_name, "Paris")) return .MERGE; // Alias for Merge
        if (std.ascii.eqlIgnoreCase(clean_name, "Shanghai")) return .SHANGHAI;
        if (std.ascii.eqlIgnoreCase(clean_name, "Cancun")) return .CANCUN;
        if (std.ascii.eqlIgnoreCase(clean_name, "Prague")) return .PRAGUE;
        if (std.ascii.eqlIgnoreCase(clean_name, "Osaka")) return .OSAKA;

        return null;
    }
};

/// Represents a fork transition (e.g., ShanghaiToCancunAtTime15k)
pub const ForkTransition = struct {
    from_fork: Hardfork,
    to_fork: Hardfork,
    at_block: ?u64,
    at_timestamp: ?u64,

    /// Parse a transition fork name like "ShanghaiToCancunAtTime15k" or "BerlinToLondonAt5"
    pub fn fromString(name: []const u8) ?ForkTransition {
        // Look for "To" pattern
        const to_index = std.mem.indexOf(u8, name, "To") orelse return null;

        // Extract "from" fork
        const from_str = name[0..to_index];
        const from_fork = Hardfork.fromString(from_str) orelse return null;

        // Find "At" pattern
        const at_index = std.mem.indexOf(u8, name[to_index..], "At") orelse return null;
        const at_pos = to_index + at_index;

        // Extract "to" fork
        const to_str = name[to_index + 2 .. at_pos];
        const to_fork = Hardfork.fromString(to_str) orelse return null;

        // Parse the transition point
        const transition_str = name[at_pos + 2 ..];

        // Check if it's a timestamp (contains "Time") or block number
        if (std.mem.indexOf(u8, transition_str, "Time") != null) {
            // Extract number from "Time15k" -> "15k"
            const time_index = std.mem.indexOf(u8, transition_str, "Time") orelse return null;
            const num_str = transition_str[time_index + 4 ..];
            const timestamp = parseNumber(num_str) catch return null;
            return ForkTransition{
                .from_fork = from_fork,
                .to_fork = to_fork,
                .at_block = null,
                .at_timestamp = timestamp,
            };
        } else {
            // It's a block number
            const block = parseNumber(transition_str) catch return null;
            return ForkTransition{
                .from_fork = from_fork,
                .to_fork = to_fork,
                .at_block = block,
                .at_timestamp = null,
            };
        }
    }

    /// Get the active fork at the given block number and timestamp
    pub fn getActiveFork(self: ForkTransition, block_number: u64, timestamp: u64) Hardfork {
        if (self.at_block) |at_block| {
            return if (block_number >= at_block) self.to_fork else self.from_fork;
        } else if (self.at_timestamp) |at_timestamp| {
            return if (timestamp >= at_timestamp) self.to_fork else self.from_fork;
        }
        return self.to_fork;
    }
};

/// Errors that can occur when parsing numbers
pub const ParseNumberError = error{
    EmptyString,
    InvalidFormat,
};

/// Parse a number from a string like "15k" or "5"
fn parseNumber(str: []const u8) ParseNumberError!u64 {
    if (str.len == 0) return error.EmptyString;

    // Check for 'k' suffix (multiply by 1000)
    if (str[str.len - 1] == 'k') {
        const num_str = str[0 .. str.len - 1];
        const base = std.fmt.parseInt(u64, num_str, 10) catch return error.InvalidFormat;
        return base * 1000;
    }

    return std.fmt.parseInt(u64, str, 10) catch error.InvalidFormat;
}

// Tests
const std = @import("std");
const testing = std.testing;

test "Hardfork version comparison" {
    const frontier = Hardfork.FRONTIER;
    const homestead = Hardfork.HOMESTEAD;
    const cancun = Hardfork.CANCUN;

    try testing.expect(frontier.isBefore(homestead));
    try testing.expect(homestead.isAtLeast(frontier));
    try testing.expect(cancun.isAtLeast(homestead));
    try testing.expect(!cancun.isBefore(homestead));
}

test "Hardfork fromString" {
    try testing.expectEqual(Hardfork.FRONTIER, Hardfork.fromString("Frontier").?);
    try testing.expectEqual(Hardfork.CANCUN, Hardfork.fromString("cancun").?);
    try testing.expectEqual(Hardfork.SHANGHAI, Hardfork.fromString("Shanghai").?);
    try testing.expectEqual(Hardfork.MERGE, Hardfork.fromString("Paris").?); // Alias
    try testing.expectEqual(Hardfork.PETERSBURG, Hardfork.fromString("ConstantinopleFix").?); // Alias

    // With comparison operators
    try testing.expectEqual(Hardfork.CANCUN, Hardfork.fromString(">=Cancun").?);
    try testing.expectEqual(Hardfork.BERLIN, Hardfork.fromString(">Berlin").?);

    // Invalid
    try testing.expectEqual(@as(?Hardfork, null), Hardfork.fromString("InvalidFork"));
}

test "ForkTransition fromString with block number" {
    const transition = ForkTransition.fromString("BerlinToLondonAt12965000").?;

    try testing.expectEqual(Hardfork.BERLIN, transition.from_fork);
    try testing.expectEqual(Hardfork.LONDON, transition.to_fork);
    try testing.expectEqual(@as(?u64, 12965000), transition.at_block);
    try testing.expectEqual(@as(?u64, null), transition.at_timestamp);
}

test "ForkTransition fromString with timestamp" {
    const transition = ForkTransition.fromString("ShanghaiToCancunAtTime15k").?;

    try testing.expectEqual(Hardfork.SHANGHAI, transition.from_fork);
    try testing.expectEqual(Hardfork.CANCUN, transition.to_fork);
    try testing.expectEqual(@as(?u64, null), transition.at_block);
    try testing.expectEqual(@as(?u64, 15000), transition.at_timestamp);
}

test "ForkTransition getActiveFork by block" {
    const transition = ForkTransition{
        .from_fork = .BERLIN,
        .to_fork = .LONDON,
        .at_block = 12965000,
        .at_timestamp = null,
    };

    try testing.expectEqual(Hardfork.BERLIN, transition.getActiveFork(12964999, 0));
    try testing.expectEqual(Hardfork.LONDON, transition.getActiveFork(12965000, 0));
    try testing.expectEqual(Hardfork.LONDON, transition.getActiveFork(12965001, 0));
}

test "ForkTransition getActiveFork by timestamp" {
    const transition = ForkTransition{
        .from_fork = .SHANGHAI,
        .to_fork = .CANCUN,
        .at_block = null,
        .at_timestamp = 15000,
    };

    try testing.expectEqual(Hardfork.SHANGHAI, transition.getActiveFork(0, 14999));
    try testing.expectEqual(Hardfork.CANCUN, transition.getActiveFork(0, 15000));
    try testing.expectEqual(Hardfork.CANCUN, transition.getActiveFork(0, 15001));
}

test "parseNumber" {
    try testing.expectEqual(@as(?u64, 42), parseNumber("42"));
    try testing.expectEqual(@as(?u64, 15000), parseNumber("15k"));
    try testing.expectEqual(@as(?u64, 1000), parseNumber("1k"));
    try testing.expectEqual(@as(?u64, null), parseNumber(""));
    try testing.expectEqual(@as(?u64, null), parseNumber("invalid"));
}

test "Hardfork DEFAULT constant" {
    try testing.expectEqual(Hardfork.PRAGUE, Hardfork.DEFAULT);
}

test "all hardfork variants exist" {
    // Test that each hardfork can be created and has a valid integer value
    const frontier = Hardfork.FRONTIER;
    const homestead = Hardfork.HOMESTEAD;
    const dao = Hardfork.DAO;
    const tangerine = Hardfork.TANGERINE_WHISTLE;
    const spurious = Hardfork.SPURIOUS_DRAGON;
    const byzantium = Hardfork.BYZANTIUM;
    const constantinople = Hardfork.CONSTANTINOPLE;
    const petersburg = Hardfork.PETERSBURG;
    const istanbul = Hardfork.ISTANBUL;
    const muir = Hardfork.MUIR_GLACIER;
    const berlin = Hardfork.BERLIN;
    const london = Hardfork.LONDON;
    const arrow = Hardfork.ARROW_GLACIER;
    const gray = Hardfork.GRAY_GLACIER;
    const merge = Hardfork.MERGE;
    const shanghai = Hardfork.SHANGHAI;
    const cancun = Hardfork.CANCUN;
    const prague = Hardfork.PRAGUE;
    const osaka = Hardfork.OSAKA;

    // Verify each has a valid integer representation
    try testing.expectEqual(@as(u32, 0), frontier.toInt());
    try testing.expectEqual(@as(u32, 1), homestead.toInt());
    try testing.expectEqual(@as(u32, 2), dao.toInt());
    try testing.expectEqual(@as(u32, 3), tangerine.toInt());
    try testing.expectEqual(@as(u32, 4), spurious.toInt());
    try testing.expectEqual(@as(u32, 5), byzantium.toInt());
    try testing.expectEqual(@as(u32, 6), constantinople.toInt());
    try testing.expectEqual(@as(u32, 7), petersburg.toInt());
    try testing.expectEqual(@as(u32, 8), istanbul.toInt());
    try testing.expectEqual(@as(u32, 9), muir.toInt());
    try testing.expectEqual(@as(u32, 10), berlin.toInt());
    try testing.expectEqual(@as(u32, 11), london.toInt());
    try testing.expectEqual(@as(u32, 12), arrow.toInt());
    try testing.expectEqual(@as(u32, 13), gray.toInt());
    try testing.expectEqual(@as(u32, 14), merge.toInt());
    try testing.expectEqual(@as(u32, 15), shanghai.toInt());
    try testing.expectEqual(@as(u32, 16), cancun.toInt());
    try testing.expectEqual(@as(u32, 17), prague.toInt());
    try testing.expectEqual(@as(u32, 18), osaka.toInt());
}

test "hardfork ordering is sequential" {
    // Verify that hardforks are in chronological order
    try testing.expect(Hardfork.FRONTIER.isBefore(.HOMESTEAD));
    try testing.expect(Hardfork.HOMESTEAD.isBefore(.DAO));
    try testing.expect(Hardfork.DAO.isBefore(.TANGERINE_WHISTLE));
    try testing.expect(Hardfork.TANGERINE_WHISTLE.isBefore(.SPURIOUS_DRAGON));
    try testing.expect(Hardfork.SPURIOUS_DRAGON.isBefore(.BYZANTIUM));
    try testing.expect(Hardfork.BYZANTIUM.isBefore(.CONSTANTINOPLE));
    try testing.expect(Hardfork.CONSTANTINOPLE.isBefore(.PETERSBURG));
    try testing.expect(Hardfork.PETERSBURG.isBefore(.ISTANBUL));
    try testing.expect(Hardfork.ISTANBUL.isBefore(.MUIR_GLACIER));
    try testing.expect(Hardfork.MUIR_GLACIER.isBefore(.BERLIN));
    try testing.expect(Hardfork.BERLIN.isBefore(.LONDON));
    try testing.expect(Hardfork.LONDON.isBefore(.ARROW_GLACIER));
    try testing.expect(Hardfork.ARROW_GLACIER.isBefore(.GRAY_GLACIER));
    try testing.expect(Hardfork.GRAY_GLACIER.isBefore(.MERGE));
    try testing.expect(Hardfork.MERGE.isBefore(.SHANGHAI));
    try testing.expect(Hardfork.SHANGHAI.isBefore(.CANCUN));
    try testing.expect(Hardfork.CANCUN.isBefore(.PRAGUE));
    try testing.expect(Hardfork.PRAGUE.isBefore(.OSAKA));
}

test "isAtLeast with same hardfork" {
    // A hardfork should be considered at least itself
    try testing.expect(Hardfork.FRONTIER.isAtLeast(.FRONTIER));
    try testing.expect(Hardfork.HOMESTEAD.isAtLeast(.HOMESTEAD));
    try testing.expect(Hardfork.CANCUN.isAtLeast(.CANCUN));
    try testing.expect(Hardfork.PRAGUE.isAtLeast(.PRAGUE));
    try testing.expect(Hardfork.OSAKA.isAtLeast(.OSAKA));
}

test "isAtLeast across range" {
    // Test that later hardforks are at least earlier ones
    try testing.expect(Hardfork.OSAKA.isAtLeast(.FRONTIER));
    try testing.expect(Hardfork.OSAKA.isAtLeast(.HOMESTEAD));
    try testing.expect(Hardfork.OSAKA.isAtLeast(.CANCUN));
    try testing.expect(Hardfork.OSAKA.isAtLeast(.PRAGUE));
    try testing.expect(!Hardfork.FRONTIER.isAtLeast(.OSAKA));
}

test "isBefore across range" {
    // Test that earlier hardforks are before later ones
    try testing.expect(Hardfork.FRONTIER.isBefore(.OSAKA));
    try testing.expect(Hardfork.HOMESTEAD.isBefore(.OSAKA));
    try testing.expect(Hardfork.CANCUN.isBefore(.OSAKA));
    try testing.expect(Hardfork.PRAGUE.isBefore(.OSAKA));
    try testing.expect(!Hardfork.OSAKA.isBefore(.FRONTIER));
}

test "isBefore with same hardfork" {
    // A hardfork should not be considered before itself
    try testing.expect(!Hardfork.FRONTIER.isBefore(.FRONTIER));
    try testing.expect(!Hardfork.HOMESTEAD.isBefore(.HOMESTEAD));
    try testing.expect(!Hardfork.CANCUN.isBefore(.CANCUN));
    try testing.expect(!Hardfork.PRAGUE.isBefore(.PRAGUE));
    try testing.expect(!Hardfork.OSAKA.isBefore(.OSAKA));
}

test "fromString case insensitivity" {
    // Test various case combinations
    try testing.expectEqual(Hardfork.FRONTIER, Hardfork.fromString("frontier").?);
    try testing.expectEqual(Hardfork.FRONTIER, Hardfork.fromString("FRONTIER").?);
    try testing.expectEqual(Hardfork.FRONTIER, Hardfork.fromString("FrOnTiEr").?);

    try testing.expectEqual(Hardfork.CANCUN, Hardfork.fromString("cancun").?);
    try testing.expectEqual(Hardfork.CANCUN, Hardfork.fromString("CANCUN").?);
    try testing.expectEqual(Hardfork.CANCUN, Hardfork.fromString("CaNcUn").?);

    try testing.expectEqual(Hardfork.PRAGUE, Hardfork.fromString("prague").?);
    try testing.expectEqual(Hardfork.PRAGUE, Hardfork.fromString("PRAGUE").?);
    try testing.expectEqual(Hardfork.PRAGUE, Hardfork.fromString("PrAgUe").?);
}

test "fromString all hardforks" {
    // Test that all hardforks can be parsed from their names
    try testing.expectEqual(Hardfork.FRONTIER, Hardfork.fromString("Frontier").?);
    try testing.expectEqual(Hardfork.HOMESTEAD, Hardfork.fromString("Homestead").?);
    try testing.expectEqual(Hardfork.DAO, Hardfork.fromString("DAO").?);
    try testing.expectEqual(Hardfork.TANGERINE_WHISTLE, Hardfork.fromString("TangerineWhistle").?);
    try testing.expectEqual(Hardfork.SPURIOUS_DRAGON, Hardfork.fromString("SpuriousDragon").?);
    try testing.expectEqual(Hardfork.BYZANTIUM, Hardfork.fromString("Byzantium").?);
    try testing.expectEqual(Hardfork.CONSTANTINOPLE, Hardfork.fromString("Constantinople").?);
    try testing.expectEqual(Hardfork.PETERSBURG, Hardfork.fromString("Petersburg").?);
    try testing.expectEqual(Hardfork.ISTANBUL, Hardfork.fromString("Istanbul").?);
    try testing.expectEqual(Hardfork.MUIR_GLACIER, Hardfork.fromString("MuirGlacier").?);
    try testing.expectEqual(Hardfork.BERLIN, Hardfork.fromString("Berlin").?);
    try testing.expectEqual(Hardfork.LONDON, Hardfork.fromString("London").?);
    try testing.expectEqual(Hardfork.ARROW_GLACIER, Hardfork.fromString("ArrowGlacier").?);
    try testing.expectEqual(Hardfork.GRAY_GLACIER, Hardfork.fromString("GrayGlacier").?);
    try testing.expectEqual(Hardfork.MERGE, Hardfork.fromString("Merge").?);
    try testing.expectEqual(Hardfork.SHANGHAI, Hardfork.fromString("Shanghai").?);
    try testing.expectEqual(Hardfork.CANCUN, Hardfork.fromString("Cancun").?);
    try testing.expectEqual(Hardfork.PRAGUE, Hardfork.fromString("Prague").?);
    try testing.expectEqual(Hardfork.OSAKA, Hardfork.fromString("Osaka").?);
}

test "fromString aliases" {
    // Test common aliases
    try testing.expectEqual(Hardfork.MERGE, Hardfork.fromString("Paris").?);
    try testing.expectEqual(Hardfork.PETERSBURG, Hardfork.fromString("ConstantinopleFix").?);

    // Test aliases with different cases
    try testing.expectEqual(Hardfork.MERGE, Hardfork.fromString("paris").?);
    try testing.expectEqual(Hardfork.MERGE, Hardfork.fromString("PARIS").?);
    try testing.expectEqual(Hardfork.PETERSBURG, Hardfork.fromString("constantinoplefix").?);
}

test "fromString with comparison operators" {
    // Test with >= operator
    try testing.expectEqual(Hardfork.CANCUN, Hardfork.fromString(">=Cancun").?);
    try testing.expectEqual(Hardfork.BERLIN, Hardfork.fromString(">=Berlin").?);
    try testing.expectEqual(Hardfork.FRONTIER, Hardfork.fromString(">=Frontier").?);

    // Test with > operator
    try testing.expectEqual(Hardfork.BERLIN, Hardfork.fromString(">Berlin").?);
    try testing.expectEqual(Hardfork.CANCUN, Hardfork.fromString(">Cancun").?);

    // Test with < operator
    try testing.expectEqual(Hardfork.BERLIN, Hardfork.fromString("<Berlin").?);
    try testing.expectEqual(Hardfork.CANCUN, Hardfork.fromString("<Cancun").?);

    // Test with <= operator
    try testing.expectEqual(Hardfork.BERLIN, Hardfork.fromString("<=Berlin").?);
    try testing.expectEqual(Hardfork.CANCUN, Hardfork.fromString("<=Cancun").?);
}

test "fromString invalid inputs" {
    // Test various invalid inputs
    try testing.expectEqual(@as(?Hardfork, null), Hardfork.fromString("InvalidFork"));
    try testing.expectEqual(@as(?Hardfork, null), Hardfork.fromString(""));
    try testing.expectEqual(@as(?Hardfork, null), Hardfork.fromString("Random"));
    try testing.expectEqual(@as(?Hardfork, null), Hardfork.fromString("123"));
    try testing.expectEqual(@as(?Hardfork, null), Hardfork.fromString("Frontier2"));
    try testing.expectEqual(@as(?Hardfork, null), Hardfork.fromString("NotAFork"));
}

test "ForkTransition fromString all components" {
    // Test transition with lowercase
    const t1 = ForkTransition.fromString("berlintolondonat12965000");
    try testing.expect(t1 != null);
    try testing.expectEqual(Hardfork.BERLIN, t1.?.from_fork);
    try testing.expectEqual(Hardfork.LONDON, t1.?.to_fork);
    try testing.expectEqual(@as(?u64, 12965000), t1.?.at_block);

    // Test transition with mixed case
    const t2 = ForkTransition.fromString("BerlinToLondonAt12965000");
    try testing.expect(t2 != null);
    try testing.expectEqual(Hardfork.BERLIN, t2.?.from_fork);
    try testing.expectEqual(Hardfork.LONDON, t2.?.to_fork);
}

test "ForkTransition fromString with various numbers" {
    // Test with small block number
    const t1 = ForkTransition.fromString("FrontierToHomesteadAt1");
    try testing.expect(t1 != null);
    try testing.expectEqual(@as(?u64, 1), t1.?.at_block);

    // Test with large block number
    const t2 = ForkTransition.fromString("BerlinToLondonAt12965000");
    try testing.expect(t2 != null);
    try testing.expectEqual(@as(?u64, 12965000), t2.?.at_block);

    // Test with zero
    const t3 = ForkTransition.fromString("FrontierToHomesteadAt0");
    try testing.expect(t3 != null);
    try testing.expectEqual(@as(?u64, 0), t3.?.at_block);
}

test "ForkTransition fromString with timestamp suffixes" {
    // Test with 'k' suffix
    const t1 = ForkTransition.fromString("ShanghaiToCancunAtTime15k");
    try testing.expect(t1 != null);
    try testing.expectEqual(@as(?u64, 15000), t1.?.at_timestamp);

    // Test with large 'k' value
    const t2 = ForkTransition.fromString("BerlinToLondonAtTime100k");
    try testing.expect(t2 != null);
    try testing.expectEqual(@as(?u64, 100000), t2.?.at_timestamp);

    // Test with timestamp without 'k'
    const t3 = ForkTransition.fromString("ShanghaiToCancunAtTime15000");
    try testing.expect(t3 != null);
    try testing.expectEqual(@as(?u64, 15000), t3.?.at_timestamp);
}

test "ForkTransition fromString invalid formats" {
    // Missing "To"
    try testing.expectEqual(@as(?ForkTransition, null), ForkTransition.fromString("BerlinLondonAt5"));

    // Missing "At"
    try testing.expectEqual(@as(?ForkTransition, null), ForkTransition.fromString("BerlinToLondon5"));

    // Invalid from fork
    try testing.expectEqual(@as(?ForkTransition, null), ForkTransition.fromString("InvalidToLondonAt5"));

    // Invalid to fork
    try testing.expectEqual(@as(?ForkTransition, null), ForkTransition.fromString("BerlinToInvalidAt5"));

    // Empty string
    try testing.expectEqual(@as(?ForkTransition, null), ForkTransition.fromString(""));

    // Invalid number
    try testing.expectEqual(@as(?ForkTransition, null), ForkTransition.fromString("BerlinToLondonAtInvalid"));
}

test "ForkTransition getActiveFork block boundary" {
    const transition = ForkTransition{
        .from_fork = .BERLIN,
        .to_fork = .LONDON,
        .at_block = 100,
        .at_timestamp = null,
    };

    // Before transition
    try testing.expectEqual(Hardfork.BERLIN, transition.getActiveFork(0, 0));
    try testing.expectEqual(Hardfork.BERLIN, transition.getActiveFork(99, 0));

    // At transition
    try testing.expectEqual(Hardfork.LONDON, transition.getActiveFork(100, 0));

    // After transition
    try testing.expectEqual(Hardfork.LONDON, transition.getActiveFork(101, 0));
    try testing.expectEqual(Hardfork.LONDON, transition.getActiveFork(1000000, 0));
}

test "ForkTransition getActiveFork timestamp boundary" {
    const transition = ForkTransition{
        .from_fork = .SHANGHAI,
        .to_fork = .CANCUN,
        .at_block = null,
        .at_timestamp = 15000,
    };

    // Before transition
    try testing.expectEqual(Hardfork.SHANGHAI, transition.getActiveFork(0, 0));
    try testing.expectEqual(Hardfork.SHANGHAI, transition.getActiveFork(0, 14999));

    // At transition
    try testing.expectEqual(Hardfork.CANCUN, transition.getActiveFork(0, 15000));

    // After transition
    try testing.expectEqual(Hardfork.CANCUN, transition.getActiveFork(0, 15001));
    try testing.expectEqual(Hardfork.CANCUN, transition.getActiveFork(0, 1000000));
}

test "ForkTransition getActiveFork neither block nor timestamp" {
    // When neither at_block nor at_timestamp is set, should return to_fork
    const transition = ForkTransition{
        .from_fork = .BERLIN,
        .to_fork = .LONDON,
        .at_block = null,
        .at_timestamp = null,
    };

    try testing.expectEqual(Hardfork.LONDON, transition.getActiveFork(0, 0));
    try testing.expectEqual(Hardfork.LONDON, transition.getActiveFork(100, 0));
    try testing.expectEqual(Hardfork.LONDON, transition.getActiveFork(0, 100));
    try testing.expectEqual(Hardfork.LONDON, transition.getActiveFork(100, 100));
}

test "parseNumber various formats" {
    // Plain numbers
    try testing.expectEqual(@as(u64, 0), try parseNumber("0"));
    try testing.expectEqual(@as(u64, 1), try parseNumber("1"));
    try testing.expectEqual(@as(u64, 42), try parseNumber("42"));
    try testing.expectEqual(@as(u64, 12965000), try parseNumber("12965000"));

    // Numbers with 'k' suffix
    try testing.expectEqual(@as(u64, 1000), try parseNumber("1k"));
    try testing.expectEqual(@as(u64, 15000), try parseNumber("15k"));
    try testing.expectEqual(@as(u64, 100000), try parseNumber("100k"));
}

test "parseNumber errors" {
    // Empty string
    try testing.expectError(ParseNumberError.EmptyString, parseNumber(""));

    // Invalid format
    try testing.expectError(ParseNumberError.InvalidFormat, parseNumber("invalid"));
    try testing.expectError(ParseNumberError.InvalidFormat, parseNumber("abc"));
    try testing.expectError(ParseNumberError.InvalidFormat, parseNumber("12x"));
    try testing.expectError(ParseNumberError.InvalidFormat, parseNumber("k"));
    try testing.expectError(ParseNumberError.InvalidFormat, parseNumber("1.5"));
}

test "hardfork comparison chain" {
    // Test a full comparison chain from oldest to newest
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
        .OSAKA,
    };

    // Each fork should be before all later forks
    for (forks, 0..) |fork1, i| {
        for (forks[i + 1 ..]) |fork2| {
            try testing.expect(fork1.isBefore(fork2));
            try testing.expect(!fork2.isBefore(fork1));
            try testing.expect(fork2.isAtLeast(fork1));
            try testing.expect(!fork1.isAtLeast(fork2));
        }
    }
}

test "ForkTransition comprehensive parsing" {
    // Test various realistic transitions
    const transitions = [_][]const u8{
        "FrontierToHomesteadAt1150000",
        "HomesteadToDAOAt1920000",
        "ByzantiumToConstantinopleAt7280000",
        "BerlinToLondonAt12965000",
        "ShanghaiToCancunAtTime1710338135",
        "CancunToPragueAtTime1740000000",
    };

    for (transitions) |transition_str| {
        const transition = ForkTransition.fromString(transition_str);
        try testing.expect(transition != null);
    }
}

test "toInt consistency" {
    // Verify that toInt returns consistent values
    const frontier = Hardfork.FRONTIER;
    const osaka = Hardfork.OSAKA;

    try testing.expectEqual(frontier.toInt(), frontier.toInt());
    try testing.expectEqual(osaka.toInt(), osaka.toInt());

    // Verify ordering through toInt
    try testing.expect(frontier.toInt() < osaka.toInt());
}
