//! Fork-dependent gas rules shared by the Frame handlers, the bytecode block
//! analysis and MinimalEvm.
//!
//! `OPCODE_INFO` holds the Berlin+ static schedule. Everything that differs on an
//! earlier fork (state-access opcode prices, SSTORE metering, refunds) is defined
//! here once, so the optimized and the reference interpreter cannot drift apart.
//!
//! Sources: execution-specs `vm/gas.py` and `vm/instructions/storage.py` of each
//! fork, EIP-150, EIP-1283, EIP-1884, EIP-2200, EIP-2929, EIP-3529.
const std = @import("std");
const Hardfork = @import("../eips_and_hardforks/eips.zig").Hardfork;

pub const sstore_set_gas: u64 = 20000;
pub const sstore_reset_gas: u64 = 5000;
pub const sstore_sentry_gas: u64 = 2300;
pub const cold_sload_cost: u64 = 2100;
pub const cold_account_access_cost: u64 = 2600;
pub const warm_access_cost: u64 = 100;
pub const selfdestruct_refund_gas: u64 = 24000;
pub const new_account_gas: u64 = 25000;

/// The three SSTORE metering schemes that have existed.
pub const SstoreScheme = enum {
    /// Frontier..Byzantium and Petersburg: priced on (current, new) only.
    legacy,
    /// Net gas metering on (original, current, new): EIP-1283 (Constantinople),
    /// EIP-2200 (Istanbul), EIP-2929 (Berlin), EIP-3529 (London).
    net_metered,
};

pub fn sstoreScheme(hardfork: Hardfork) SstoreScheme {
    if (hardfork.isAtLeast(.ISTANBUL)) return .net_metered;
    // EIP-1283 was live only in Constantinople; Petersburg removed it again.
    if (hardfork == .CONSTANTINOPLE) return .net_metered;
    return .legacy;
}

/// EIP-2200 (Istanbul+): SSTORE fails when gas left is at or below the call stipend.
pub fn sstoreHasSentry(hardfork: Hardfork) bool {
    return hardfork.isAtLeast(.ISTANBUL);
}

/// Gas charged for an SSTORE that leaves the slot unchanged or touches an already
/// dirty slot ("SLOAD_GAS" in EIP-1283/2200, the warm read cost from Berlin on).
pub fn sstoreNoopGas(hardfork: Hardfork) u64 {
    if (hardfork.isAtLeast(.BERLIN)) return warm_access_cost;
    if (hardfork.isAtLeast(.ISTANBUL)) return 800;
    return 200;
}

/// Refund for clearing a slot (non-zero -> zero). EIP-3529 lowered it in London.
pub fn sstoreClearRefund(hardfork: Hardfork) u64 {
    return if (hardfork.isAtLeast(.LONDON)) 4800 else 15000;
}

pub const SstoreCost = struct {
    /// Total gas charged by this SSTORE, cold surcharge included.
    gas: u64,
    /// Change to the transaction refund counter. Negative when an earlier refund
    /// for the same slot is taken back.
    refund: i64,
};

/// Gas and refund of one SSTORE.
///
/// `original` is the slot value at the start of the transaction, `current` the value
/// before this SSTORE and `new` the value being written. `is_cold` is only consulted
/// from Berlin on (EIP-2929).
pub fn sstoreCost(hardfork: Hardfork, original: u256, current: u256, new: u256, is_cold: bool) SstoreCost {
    if (sstoreScheme(hardfork) == .legacy) {
        const gas: u64 = if (current == 0 and new != 0) sstore_set_gas else sstore_reset_gas;
        const refund: i64 = if (current != 0 and new == 0) 15000 else 0;
        return .{ .gas = gas, .refund = refund };
    }

    const berlin = hardfork.isAtLeast(.BERLIN);
    const noop_gas = sstoreNoopGas(hardfork);
    // EIP-2929 moved the cold-read part of a reset out of SSTORE_RESET_GAS.
    const reset_gas: u64 = if (berlin) sstore_reset_gas - cold_sload_cost else sstore_reset_gas;
    const clear_refund: i64 = @intCast(sstoreClearRefund(hardfork));

    var gas: u64 = 0;
    var refund: i64 = 0;

    if (berlin and is_cold) gas += cold_sload_cost;

    if (current == new) {
        gas += noop_gas;
        return .{ .gas = gas, .refund = 0 };
    }

    if (original == current) {
        if (original == 0) {
            gas += sstore_set_gas;
        } else {
            gas += reset_gas;
            if (new == 0) refund += clear_refund;
        }
        return .{ .gas = gas, .refund = refund };
    }

    // Dirty slot: already changed earlier in this transaction.
    gas += noop_gas;
    if (original != 0) {
        if (current == 0) {
            refund -= clear_refund;
        } else if (new == 0) {
            refund += clear_refund;
        }
    }
    if (original == new) {
        if (original == 0) {
            refund += @intCast(sstore_set_gas - noop_gas);
        } else {
            refund += @intCast(reset_gas - noop_gas);
        }
    }
    return .{ .gas = gas, .refund = refund };
}

/// Static gas of `opcode` on `hardfork`, given its Berlin+ table value `berlin_cost`.
///
/// Before Berlin the state-access opcodes had a single flat price (no warm/cold
/// split), and that price changed in Tangerine Whistle (EIP-150) and Istanbul
/// (EIP-1884). From Berlin on the table value (the warm cost) applies and the
/// handlers add the cold surcharge.
pub fn staticGas(hardfork: Hardfork, opcode: u8, berlin_cost: u64) u64 {
    if (hardfork.isAtLeast(.BERLIN)) return berlin_cost;
    const tangerine = hardfork.isAtLeast(.TANGERINE_WHISTLE);
    const istanbul = hardfork.isAtLeast(.ISTANBUL);
    return switch (opcode) {
        0x54 => if (istanbul) 800 else if (tangerine) 200 else 50, // SLOAD
        0x31 => if (istanbul) 700 else if (tangerine) 400 else 20, // BALANCE
        0x3b, 0x3c => if (tangerine) 700 else 20, // EXTCODESIZE, EXTCODECOPY
        0x3f => if (istanbul) 700 else 400, // EXTCODEHASH (Constantinople+)
        0xf1, 0xf2, 0xf4, 0xfa => if (tangerine) 700 else 40, // CALL, CALLCODE, DELEGATECALL, STATICCALL
        0xff => if (tangerine) 5000 else 0, // SELFDESTRUCT
        else => berlin_cost,
    };
}

/// True when `opcode` is defined on `hardfork`. Opcodes added by a later fork are
/// undefined before it and halt exceptionally like any other undefined opcode
/// (execution-specs: each fork's `vm/instructions/__init__.py` op table).
pub fn isOpcodeDefined(hardfork: Hardfork, opcode: u8) bool {
    const introduced: Hardfork = switch (opcode) {
        0xf4 => .HOMESTEAD, // DELEGATECALL (EIP-7)
        0x3d, 0x3e, 0xfa, 0xfd => .BYZANTIUM, // RETURNDATASIZE, RETURNDATACOPY, STATICCALL, REVERT
        0x1b, 0x1c, 0x1d, 0x3f, 0xf5 => .CONSTANTINOPLE, // SHL, SHR, SAR, EXTCODEHASH, CREATE2
        0x46, 0x47 => .ISTANBUL, // CHAINID, SELFBALANCE
        0x48 => .LONDON, // BASEFEE
        0x5f => .SHANGHAI, // PUSH0
        0x49, 0x4a, 0x5c, 0x5d, 0x5e => .CANCUN, // BLOBHASH, BLOBBASEFEE, TLOAD, TSTORE, MCOPY
        0x1e => .OSAKA, // CLZ (EIP-7939)
        else => return true,
    };
    return hardfork.isAtLeast(introduced);
}

/// True when the fork distinguishes cold from warm state access (EIP-2929).
pub fn hasAccessLists(hardfork: Hardfork) bool {
    return hardfork.isAtLeast(.BERLIN);
}

/// EIP-150 (Tangerine Whistle+): a call or creation forwards at most all but one
/// 64th of the gas left. Earlier forks forward exactly what was requested and fail
/// with OutOfGas when that is more than the gas left.
pub fn hasAllButOne64th(hardfork: Hardfork) bool {
    return hardfork.isAtLeast(.TANGERINE_WHISTLE);
}

/// EIP-161 (Spurious Dragon+): the new-account surcharge applies only when value is
/// sent to a dead (non-existent or empty) account. Earlier forks charge it whenever
/// the target account does not exist, whatever the value.
pub fn newAccountNeedsValue(hardfork: Hardfork) bool {
    return hardfork.isAtLeast(.SPURIOUS_DRAGON);
}

/// SELFDESTRUCT refund, removed by EIP-3529 in London.
pub fn selfdestructRefund(hardfork: Hardfork) u64 {
    return if (hardfork.isAtLeast(.LONDON)) 0 else selfdestruct_refund_gas;
}

const testing = std.testing;

const net_metered_forks = [_]Hardfork{ .CONSTANTINOPLE, .ISTANBUL, .BERLIN, .LONDON, .SHANGHAI, .CANCUN, .PRAGUE, .OSAKA };
const legacy_forks = [_]Hardfork{ .FRONTIER, .HOMESTEAD, .TANGERINE_WHISTLE, .SPURIOUS_DRAGON, .BYZANTIUM, .PETERSBURG };

test "sstoreScheme: only Constantinople and Istanbul+ use net metering" {
    for (legacy_forks) |fork| try testing.expectEqual(SstoreScheme.legacy, sstoreScheme(fork));
    for (net_metered_forks) |fork| try testing.expectEqual(SstoreScheme.net_metered, sstoreScheme(fork));
}

test "sstoreHasSentry: Istanbul and later only" {
    for (legacy_forks) |fork| try testing.expect(!sstoreHasSentry(fork));
    try testing.expect(!sstoreHasSentry(.CONSTANTINOPLE));
    for ([_]Hardfork{ .ISTANBUL, .BERLIN, .LONDON, .SHANGHAI, .CANCUN, .PRAGUE, .OSAKA }) |fork| try testing.expect(sstoreHasSentry(fork));
}

test "sstoreCost legacy: priced on current and new only" {
    for (legacy_forks) |fork| {
        // 0 -> 0
        try testing.expectEqual(SstoreCost{ .gas = 5000, .refund = 0 }, sstoreCost(fork, 0, 0, 0, true));
        // 0 -> 1
        try testing.expectEqual(SstoreCost{ .gas = 20000, .refund = 0 }, sstoreCost(fork, 0, 0, 1, true));
        // 1 -> 1
        try testing.expectEqual(SstoreCost{ .gas = 5000, .refund = 0 }, sstoreCost(fork, 1, 1, 1, false));
        // 1 -> 2
        try testing.expectEqual(SstoreCost{ .gas = 5000, .refund = 0 }, sstoreCost(fork, 1, 1, 2, false));
        // 1 -> 0
        try testing.expectEqual(SstoreCost{ .gas = 5000, .refund = 15000 }, sstoreCost(fork, 1, 1, 0, false));
        // Dirty slots get no discount: original 0, 1 -> 2 and original 0, 1 -> 0.
        try testing.expectEqual(SstoreCost{ .gas = 5000, .refund = 0 }, sstoreCost(fork, 0, 1, 2, false));
        try testing.expectEqual(SstoreCost{ .gas = 5000, .refund = 15000 }, sstoreCost(fork, 0, 1, 0, false));
        // Original 1, cleared, set again: full set price.
        try testing.expectEqual(SstoreCost{ .gas = 20000, .refund = 0 }, sstoreCost(fork, 1, 0, 1, false));
    }
}

test "sstoreCost Constantinople (EIP-1283): 200 gas no-op, 15000 clear refund" {
    const fork = Hardfork.CONSTANTINOPLE;
    try testing.expectEqual(SstoreCost{ .gas = 200, .refund = 0 }, sstoreCost(fork, 0, 0, 0, true));
    try testing.expectEqual(SstoreCost{ .gas = 20000, .refund = 0 }, sstoreCost(fork, 0, 0, 1, true));
    try testing.expectEqual(SstoreCost{ .gas = 200, .refund = 0 }, sstoreCost(fork, 1, 1, 1, true));
    try testing.expectEqual(SstoreCost{ .gas = 5000, .refund = 0 }, sstoreCost(fork, 1, 1, 2, true));
    try testing.expectEqual(SstoreCost{ .gas = 5000, .refund = 15000 }, sstoreCost(fork, 1, 1, 0, true));
    // Dirty: original 0, 1 -> 0 restores the original zero.
    try testing.expectEqual(SstoreCost{ .gas = 200, .refund = 19800 }, sstoreCost(fork, 0, 1, 0, false));
    // Dirty: original 1, 2 -> 1 restores the original non-zero.
    try testing.expectEqual(SstoreCost{ .gas = 200, .refund = 4800 }, sstoreCost(fork, 1, 2, 1, false));
    // Dirty: original 1, 0 -> 2 takes the clear refund back.
    try testing.expectEqual(SstoreCost{ .gas = 200, .refund = -15000 }, sstoreCost(fork, 1, 0, 2, false));
    // Dirty: original 1, 0 -> 1 takes the clear refund back and restores.
    try testing.expectEqual(SstoreCost{ .gas = 200, .refund = -15000 + 4800 }, sstoreCost(fork, 1, 0, 1, false));
}

test "sstoreCost Istanbul (EIP-2200): 800 gas no-op, no cold surcharge" {
    const fork = Hardfork.ISTANBUL;
    try testing.expectEqual(SstoreCost{ .gas = 800, .refund = 0 }, sstoreCost(fork, 0, 0, 0, true));
    try testing.expectEqual(SstoreCost{ .gas = 20000, .refund = 0 }, sstoreCost(fork, 0, 0, 1, true));
    try testing.expectEqual(SstoreCost{ .gas = 800, .refund = 0 }, sstoreCost(fork, 1, 1, 1, true));
    try testing.expectEqual(SstoreCost{ .gas = 5000, .refund = 0 }, sstoreCost(fork, 1, 1, 2, true));
    try testing.expectEqual(SstoreCost{ .gas = 5000, .refund = 15000 }, sstoreCost(fork, 1, 1, 0, true));
    try testing.expectEqual(SstoreCost{ .gas = 800, .refund = 19200 }, sstoreCost(fork, 0, 1, 0, false));
    try testing.expectEqual(SstoreCost{ .gas = 800, .refund = 0 }, sstoreCost(fork, 0, 1, 2, false));
    try testing.expectEqual(SstoreCost{ .gas = 800, .refund = 4200 }, sstoreCost(fork, 1, 2, 1, false));
    try testing.expectEqual(SstoreCost{ .gas = 800, .refund = 15000 }, sstoreCost(fork, 1, 2, 0, false));
    try testing.expectEqual(SstoreCost{ .gas = 800, .refund = -15000 }, sstoreCost(fork, 1, 0, 2, false));
    try testing.expectEqual(SstoreCost{ .gas = 800, .refund = -15000 + 4200 }, sstoreCost(fork, 1, 0, 1, false));
}

test "sstoreCost Berlin (EIP-2929): cold surcharge, 2900 reset, 15000 clear refund" {
    const fork = Hardfork.BERLIN;
    // Cold slot.
    try testing.expectEqual(SstoreCost{ .gas = 2100 + 100, .refund = 0 }, sstoreCost(fork, 0, 0, 0, true));
    try testing.expectEqual(SstoreCost{ .gas = 2100 + 20000, .refund = 0 }, sstoreCost(fork, 0, 0, 1, true));
    try testing.expectEqual(SstoreCost{ .gas = 2100 + 100, .refund = 0 }, sstoreCost(fork, 1, 1, 1, true));
    try testing.expectEqual(SstoreCost{ .gas = 2100 + 2900, .refund = 0 }, sstoreCost(fork, 1, 1, 2, true));
    try testing.expectEqual(SstoreCost{ .gas = 2100 + 2900, .refund = 15000 }, sstoreCost(fork, 1, 1, 0, true));
    // Warm slot.
    try testing.expectEqual(SstoreCost{ .gas = 100, .refund = 0 }, sstoreCost(fork, 0, 0, 0, false));
    try testing.expectEqual(SstoreCost{ .gas = 20000, .refund = 0 }, sstoreCost(fork, 0, 0, 1, false));
    try testing.expectEqual(SstoreCost{ .gas = 100, .refund = 0 }, sstoreCost(fork, 1, 1, 1, false));
    try testing.expectEqual(SstoreCost{ .gas = 2900, .refund = 0 }, sstoreCost(fork, 1, 1, 2, false));
    try testing.expectEqual(SstoreCost{ .gas = 2900, .refund = 15000 }, sstoreCost(fork, 1, 1, 0, false));
    // Dirty slot.
    try testing.expectEqual(SstoreCost{ .gas = 100, .refund = 19900 }, sstoreCost(fork, 0, 1, 0, false));
    try testing.expectEqual(SstoreCost{ .gas = 100, .refund = 2800 }, sstoreCost(fork, 1, 2, 1, false));
    try testing.expectEqual(SstoreCost{ .gas = 100, .refund = 15000 }, sstoreCost(fork, 1, 2, 0, false));
    try testing.expectEqual(SstoreCost{ .gas = 100, .refund = -15000 }, sstoreCost(fork, 1, 0, 2, false));
    try testing.expectEqual(SstoreCost{ .gas = 100, .refund = -15000 + 2800 }, sstoreCost(fork, 1, 0, 1, false));
}

test "sstoreCost London+ (EIP-3529): 4800 clear refund, same gas as Berlin" {
    for ([_]Hardfork{ .LONDON, .MERGE, .SHANGHAI, .CANCUN, .PRAGUE, .OSAKA }) |fork| {
        // Cold slot.
        try testing.expectEqual(SstoreCost{ .gas = 2200, .refund = 0 }, sstoreCost(fork, 0, 0, 0, true));
        try testing.expectEqual(SstoreCost{ .gas = 22100, .refund = 0 }, sstoreCost(fork, 0, 0, 1, true));
        try testing.expectEqual(SstoreCost{ .gas = 2200, .refund = 0 }, sstoreCost(fork, 1, 1, 1, true));
        try testing.expectEqual(SstoreCost{ .gas = 5000, .refund = 0 }, sstoreCost(fork, 1, 1, 2, true));
        try testing.expectEqual(SstoreCost{ .gas = 5000, .refund = 4800 }, sstoreCost(fork, 1, 1, 0, true));
        // Warm slot.
        try testing.expectEqual(SstoreCost{ .gas = 100, .refund = 0 }, sstoreCost(fork, 0, 0, 0, false));
        try testing.expectEqual(SstoreCost{ .gas = 20000, .refund = 0 }, sstoreCost(fork, 0, 0, 1, false));
        try testing.expectEqual(SstoreCost{ .gas = 100, .refund = 0 }, sstoreCost(fork, 1, 1, 1, false));
        try testing.expectEqual(SstoreCost{ .gas = 2900, .refund = 0 }, sstoreCost(fork, 1, 1, 2, false));
        try testing.expectEqual(SstoreCost{ .gas = 2900, .refund = 4800 }, sstoreCost(fork, 1, 1, 0, false));
        // Dirty slot.
        try testing.expectEqual(SstoreCost{ .gas = 100, .refund = 19900 }, sstoreCost(fork, 0, 1, 0, false));
        try testing.expectEqual(SstoreCost{ .gas = 100, .refund = 0 }, sstoreCost(fork, 0, 1, 2, false));
        try testing.expectEqual(SstoreCost{ .gas = 100, .refund = 2800 }, sstoreCost(fork, 1, 2, 1, false));
        try testing.expectEqual(SstoreCost{ .gas = 100, .refund = 0 }, sstoreCost(fork, 1, 2, 3, false));
        try testing.expectEqual(SstoreCost{ .gas = 100, .refund = 4800 }, sstoreCost(fork, 1, 2, 0, false));
        try testing.expectEqual(SstoreCost{ .gas = 100, .refund = -4800 }, sstoreCost(fork, 1, 0, 2, false));
        try testing.expectEqual(SstoreCost{ .gas = 100, .refund = -4800 + 2800 }, sstoreCost(fork, 1, 0, 1, false));
    }
}

test "sstoreCost: a set-then-clear sequence never leaves a negative refund total" {
    for (net_metered_forks) |fork| {
        // original 1: 1 -> 0 (clear refund), 0 -> 2 (refund taken back), 2 -> 0 (refund again).
        var total: i64 = 0;
        total += sstoreCost(fork, 1, 1, 0, true).refund;
        try testing.expect(total > 0);
        total += sstoreCost(fork, 1, 0, 2, false).refund;
        try testing.expectEqual(@as(i64, 0), total);
        total += sstoreCost(fork, 1, 2, 0, false).refund;
        try testing.expectEqual(@as(i64, @intCast(sstoreClearRefund(fork))), total);
    }
}

test "staticGas: state-access prices per fork" {
    // SLOAD
    try testing.expectEqual(@as(u64, 50), staticGas(.FRONTIER, 0x54, 100));
    try testing.expectEqual(@as(u64, 50), staticGas(.HOMESTEAD, 0x54, 100));
    try testing.expectEqual(@as(u64, 200), staticGas(.TANGERINE_WHISTLE, 0x54, 100));
    try testing.expectEqual(@as(u64, 200), staticGas(.PETERSBURG, 0x54, 100));
    try testing.expectEqual(@as(u64, 800), staticGas(.ISTANBUL, 0x54, 100));
    try testing.expectEqual(@as(u64, 100), staticGas(.BERLIN, 0x54, 100));
    try testing.expectEqual(@as(u64, 100), staticGas(.OSAKA, 0x54, 100));
    // BALANCE
    try testing.expectEqual(@as(u64, 20), staticGas(.FRONTIER, 0x31, 100));
    try testing.expectEqual(@as(u64, 400), staticGas(.TANGERINE_WHISTLE, 0x31, 100));
    try testing.expectEqual(@as(u64, 400), staticGas(.PETERSBURG, 0x31, 100));
    try testing.expectEqual(@as(u64, 700), staticGas(.ISTANBUL, 0x31, 100));
    try testing.expectEqual(@as(u64, 100), staticGas(.BERLIN, 0x31, 100));
    // EXTCODESIZE, EXTCODECOPY
    for ([_]u8{ 0x3b, 0x3c }) |opcode| {
        try testing.expectEqual(@as(u64, 20), staticGas(.HOMESTEAD, opcode, 100));
        try testing.expectEqual(@as(u64, 700), staticGas(.TANGERINE_WHISTLE, opcode, 100));
        try testing.expectEqual(@as(u64, 700), staticGas(.ISTANBUL, opcode, 100));
        try testing.expectEqual(@as(u64, 100), staticGas(.BERLIN, opcode, 100));
    }
    // EXTCODEHASH
    try testing.expectEqual(@as(u64, 400), staticGas(.PETERSBURG, 0x3f, 100));
    try testing.expectEqual(@as(u64, 700), staticGas(.ISTANBUL, 0x3f, 100));
    try testing.expectEqual(@as(u64, 100), staticGas(.LONDON, 0x3f, 100));
    // CALL family
    for ([_]u8{ 0xf1, 0xf2, 0xf4, 0xfa }) |opcode| {
        try testing.expectEqual(@as(u64, 40), staticGas(.FRONTIER, opcode, 100));
        try testing.expectEqual(@as(u64, 40), staticGas(.HOMESTEAD, opcode, 100));
        try testing.expectEqual(@as(u64, 700), staticGas(.TANGERINE_WHISTLE, opcode, 100));
        try testing.expectEqual(@as(u64, 700), staticGas(.ISTANBUL, opcode, 100));
        try testing.expectEqual(@as(u64, 100), staticGas(.BERLIN, opcode, 100));
    }
    // SELFDESTRUCT
    try testing.expectEqual(@as(u64, 0), staticGas(.FRONTIER, 0xff, 5000));
    try testing.expectEqual(@as(u64, 0), staticGas(.HOMESTEAD, 0xff, 5000));
    try testing.expectEqual(@as(u64, 5000), staticGas(.TANGERINE_WHISTLE, 0xff, 5000));
    try testing.expectEqual(@as(u64, 5000), staticGas(.CANCUN, 0xff, 5000));
    // Everything else keeps its table value on every fork.
    for ([_]Hardfork{ .FRONTIER, .ISTANBUL, .OSAKA }) |fork| {
        try testing.expectEqual(@as(u64, 3), staticGas(fork, 0x01, 3));
        try testing.expectEqual(@as(u64, 0), staticGas(fork, 0x55, 0));
        try testing.expectEqual(@as(u64, 1), staticGas(fork, 0x5b, 1));
    }
}

test "fork predicates" {
    try testing.expect(!hasAccessLists(.ISTANBUL));
    try testing.expect(hasAccessLists(.BERLIN));
    try testing.expect(!hasAllButOne64th(.HOMESTEAD));
    try testing.expect(hasAllButOne64th(.TANGERINE_WHISTLE));
    try testing.expect(!newAccountNeedsValue(.TANGERINE_WHISTLE));
    try testing.expect(newAccountNeedsValue(.SPURIOUS_DRAGON));
    try testing.expectEqual(@as(u64, 24000), selfdestructRefund(.BERLIN));
    try testing.expectEqual(@as(u64, 0), selfdestructRefund(.LONDON));
}
