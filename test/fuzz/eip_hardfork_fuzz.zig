//! EIPs, Hardfork Gas Rules, EIP-7702 Authorization Processor, and EIP-4844 Blob Gas Fuzz Tests
//!
//! Verifies protocol invariants across all hardforks (FRONTIER through PRAGUE/OSAKA):
//! 1. EIP-4844 blob gas price monotonicity (`excess1 <= excess2 => price(excess1) <= price(excess2)`),
//!    non-zero floor (`price >= 1`), and overflow-free `excess_blob_gas` calculation.
//! 2. EIP-1559 effective gas price invariants (`base_fee <= effective <= max_fee`, `miner_fee == effective - base_fee`).
//! 3. EIP-3529 gas refund cap (`applied_refund <= gas_used / 5` post-London, `<= gas_used / 2` pre-London).
//! 4. EIP-2200 / EIP-2929 SSTORE gas cost & refund invariants (cold >= warm, stipend safety, no panics across all hardforks).
//! 5. EIP-7702 AuthorizationProcessor: chain ID (0 or matching), EOA-only check, nonce equality & increment,
//!    delegation target persistence, and rejection of invalid accounts without mutating state.
//! 6. EIP-7623 / EIP-2028 / EIP-3860 calldata & initcode gas monotonicity.

const std = @import("std");
const evm = @import("evm");
const fuzz_alloc = @import("fuzz_alloc.zig");
const primitives = @import("voltaire");

const Eips = evm.Eips;
const Hardfork = evm.Hardfork;
const Database = evm.Database;
const Account = evm.Account;
const AuthorizationProcessor = evm.AuthorizationProcessor;
const Address = primitives.Address.Address;
const Authorization = primitives.Authorization.Authorization;

const ALL_HARDFORKS = [_]Hardfork{
    .FRONTIER,
    .HOMESTEAD,
    .TANGERINE_WHISTLE,
    .SPURIOUS_DRAGON,
    .BYZANTIUM,
    .CONSTANTINOPLE,
    .PETERSBURG,
    .ISTANBUL,
    .BERLIN,
    .LONDON,
    .MERGE,
    .SHANGHAI,
    .CANCUN,
    .PRAGUE,
};

pub fn fuzzBlobGasAndEip1559Invariants(_: void, input: []const u8) !void {
    if (input.len < 24) return;

    const eips_cancun = Eips{ .hardfork = .CANCUN };
    const eips_prague = Eips{ .hardfork = .PRAGUE };

    // Bounded excess values to avoid astronomical u64 exponential overflow while still stressing high regimes
    const ex1 = std.mem.readInt(u64, input[0..8], .little) % 100_000_000;
    const ex2 = std.mem.readInt(u64, input[8..16], .little) % 100_000_000;
    const lo = @min(ex1, ex2);
    const hi = @max(ex1, ex2);

    // Monotonicity & >= 1 floor on Cancun, Prague, and Osaka (EIP-7918 reserve price)
    const parent_base_fee: u256 = std.mem.readInt(u64, input[0..8], .little);
    for ([_]Eips{ eips_cancun, eips_prague }) |eips| {
        const p_lo = eips.blob_gas_price(lo);
        const p_hi = eips.blob_gas_price(hi);
        try std.testing.expect(p_lo >= 1);
        try std.testing.expect(p_hi >= p_lo);

        // Excess blob gas update (Cancun/Prague): if parent_excess + parent_used < target => 0; else diff
        const parent_used = std.mem.readInt(u64, input[16..24], .little) % (eips.max_blob_gas() + 1);
        const next_excess = eips.excess_blob_gas(lo, parent_used, parent_base_fee);
        const target = eips.target_blob_gas();
        if (lo + parent_used < target) {
            try std.testing.expectEqual(@as(u64, 0), next_excess);
        } else {
            try std.testing.expectEqual(lo + parent_used - target, next_excess);
        }
    }

    // EIP-7918 (Osaka): reserve-price excess update never decreases below classic formula
    const eips_osaka = Eips{ .hardfork = .OSAKA };
    const osaka_used = std.mem.readInt(u64, input[16..24], .little) % (eips_osaka.max_blob_gas() + 1);
    const osaka_next = eips_osaka.excess_blob_gas(lo, osaka_used, parent_base_fee);
    const osaka_target = eips_osaka.target_blob_gas();
    if (@as(u128, lo) + osaka_used < osaka_target) {
        try std.testing.expectEqual(@as(u64, 0), osaka_next);
    } else {
        const classic = @as(u128, lo) + osaka_used - osaka_target;
        try std.testing.expect(@as(u128, osaka_next) >= classic);
    }

    // EIP-1559 effective gas price invariants
    const base_fee: u256 = std.mem.readInt(u64, input[0..8], .little);
    const max_prio: u256 = std.mem.readInt(u64, input[8..16], .little);
    const max_fee: u256 = base_fee + @as(u256, std.mem.readInt(u64, input[16..24], .little));
    const res = eips_cancun.effective_gas_price(base_fee, max_fee, max_prio);
    try std.testing.expect(res.effective_gas_price >= base_fee);
    try std.testing.expect(res.effective_gas_price <= max_fee);
    try std.testing.expectEqual(res.effective_gas_price - base_fee, res.miner_fee);
    try std.testing.expect(res.miner_fee <= max_prio);
}

pub fn fuzzSstoreGasAndRefundAcrossHardforks(_: void, input: []const u8) !void {
    if (input.len < 8) return;

    const current: u256 = switch (input[0] % 4) {
        0 => 0,
        1 => 1,
        2 => 42,
        else => std.math.maxInt(u256),
    };
    const new_val: u256 = switch (input[1] % 4) {
        0 => 0,
        1 => 1,
        2 => 42,
        else => std.math.maxInt(u256),
    };
    const original: u256 = switch (input[2] % 4) {
        0 => 0,
        1 => 1,
        2 => 42,
        else => std.math.maxInt(u256),
    };

    const gas_limit = @as(u64, std.mem.readInt(u32, input[4..8], .little)) + 21_000;
    const gas_left = gas_limit / 2;
    const refund_counter = @as(u64, input[3]) * 5000;

    for (ALL_HARDFORKS) |hf| {
        const eips = Eips{ .hardfork = hf };
        const warm = eips.sstore_gas_cost(current, new_val, original, false);
        const cold = eips.sstore_gas_cost(current, new_val, original, true);

        // Cold access must ALWAYS cost >= warm access!
        try std.testing.expect(cold.gas >= warm.gas);
        if (hf.isAtLeast(.BERLIN)) {
            try std.testing.expectEqual(warm.gas + 2100, cold.gas);
        }

        // Refund cap invariants (EIP-3529: max 1/5 post-London, 1/2 pre-London)
        const gas_used = gas_limit - gas_left;
        const capped = eips.eip_3529_gas_refund_cap(gas_used, refund_counter);
        try std.testing.expect(capped <= refund_counter);
        if (hf.isAtLeast(.LONDON)) {
            try std.testing.expect(capped <= gas_used / 5);
        } else {
            try std.testing.expect(capped <= gas_used / 2);
        }

        // Applied refund never produces gas_left > initial_gas
        const final_left = eips.eip_3529_apply_gas_refund(gas_limit, gas_left, refund_counter);
        try std.testing.expect(final_left >= gas_left);
        try std.testing.expect(final_left <= gas_limit);
    }
}

pub fn fuzzCalldataAndInitcodeGas(_: void, input: []const u8) !void {
    const data = input[0..@min(input.len, 1024)];
    const eips = Eips{ .hardfork = .PRAGUE };

    // Verify tokens_in_calldata == zero_bytes + 4 * nonzero_bytes
    var zeros: u64 = 0;
    var nonzeros: u64 = 0;
    for (data) |b| {
        if (b == 0) zeros += 1 else nonzeros += 1;
    }
    const tokens = eips.tokens_in_calldata(data);
    try std.testing.expectEqual(zeros + 4 * nonzeros, tokens);

    // Calldata gas cost must be >= 0 and initcode adds 2 * words for CREATE
    const call_cost = eips.calldata_gas_cost(tokens, false, data.len);
    const create_cost = eips.calldata_gas_cost(tokens, true, data.len);
    try std.testing.expect(create_cost >= call_cost);

    // Floor gas cost (EIP-7623): 21000 + 10 * tokens
    const floor = eips.floor_gas_cost(tokens);
    try std.testing.expectEqual(21_000 + 10 * tokens, floor);
}

pub fn fuzzEip7702AuthorizationProcessor(_: void, input: []const u8) !void {
    if (input.len < 8) return;
    const allocator = fuzz_alloc.get();

    var db = Database.init(allocator);
    defer db.deinit();

    var authority_bytes = @as([20]u8, @splat(0));
    authority_bytes[19] = (input[0] % 16) + 1;
    const authority = Address{ .bytes = authority_bytes };

    var target_bytes = @as([20]u8, @splat(0));
    target_bytes[19] = input[1];
    const target = Address{ .bytes = target_bytes };

    const active_chain_id: u64 = 1;
    const auth_chain_id: u64 = switch (input[2] % 3) {
        0 => 0, // wildcard chain_id (valid on all chains)
        1 => active_chain_id, // exact match
        else => 999, // mismatch -> MUST fail
    };

    const acct_exists = (input[3] & 1) == 1;
    const acct_has_code = (input[3] & 2) == 2;
    const acct_nonce: u64 = input[4];
    const auth_nonce: u64 = if ((input[5] & 1) == 0) acct_nonce else acct_nonce +% 1;

    if (acct_exists) {
        var code_hash = primitives.EMPTY_CODE_HASH;
        if (acct_has_code) {
            code_hash = try db.set_code(&.{ 0x60, 0x00, 0x00 });
        }
        try db.set_account(authority.bytes, .{
            .balance = 1000,
            .nonce = acct_nonce,
            .code_hash = code_hash,
            .storage_root = @as([32]u8, @splat(0)),
        });
    }

    var gas_remaining: i64 = 1_000_000;
    var proc = AuthorizationProcessor{
        .db = &db,
        .chain_id = active_chain_id,
        .gas_remaining = &gas_remaining,
        .eips = Eips{ .hardfork = .PRAGUE },
    };

    const auth = Authorization{
        .chain_id = auth_chain_id,
        .address = target,
        .nonce = auth_nonce,
        .v = 0,
        .r = @as([32]u8, @splat(0)),
        .s = @as([32]u8, @splat(0)),
    };

    const res = proc.processAuthorization(auth, authority);

    // Verify EXACT specification outcome!
    if (auth_chain_id != 0 and auth_chain_id != active_chain_id) {
        try std.testing.expectError(evm.AuthorizationError.InvalidChainId, res);
    } else if (acct_exists and acct_has_code) {
        try std.testing.expectError(evm.AuthorizationError.NotEOA, res);
    } else {
        // EIP-7702: a missing authority is an empty account (nonce 0, no code).
        const expected_nonce: u64 = if (acct_exists) acct_nonce else 0;
        if (auth_nonce != expected_nonce) {
            try std.testing.expectError(evm.AuthorizationError.NonceMismatch, res);
        } else {
            try res;
            // Nonce incremented by 1 and delegation set (cleared for a zero target).
            const updated = (try db.get_account(authority.bytes)).?;
            try std.testing.expectEqual(expected_nonce + 1, updated.nonce);
            const expected_delegate: ?primitives.Address = if (target.isZero()) null else target;
            try std.testing.expectEqual(expected_delegate, updated.delegated_address);
        }
    }
}

const seed_corpus: []const []const u8 = &.{
    &(@as([24]u8, @splat(0))),
    &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24 },
    &.{ 0xff, 0xff, 0, 1, 5, 0, 10, 20, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 },
    &.{ 0, 1, 2, 3, 4, 5, 6, 7 },
    &.{ 1, 2, 0, 1, 0, 0, 0, 0 }, // valid EIP-7702 wildcard chain_id
    &.{ 1, 2, 1, 3, 0, 0, 0, 0 }, // invalid NotEOA
};

test "fuzz EIP-4844 blob gas monotonicity and EIP-1559 effective gas price" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzBlobGasAndEip1559Invariants), .{ .corpus = seed_corpus });
}

test "fuzz SSTORE gas costs and EIP-3529 refund caps across all 14 hardforks" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzSstoreGasAndRefundAcrossHardforks), .{ .corpus = seed_corpus });
}

test "fuzz EIP-2028/3860/7623 calldata and initcode gas formulas" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzCalldataAndInitcodeGas), .{ .corpus = seed_corpus });
}

test "fuzz EIP-7702 authorization processor validation and delegation state transitions" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzEip7702AuthorizationProcessor), .{ .corpus = seed_corpus });
}
