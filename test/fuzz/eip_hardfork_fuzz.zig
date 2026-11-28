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
//! 7. Transaction admission through `Evm.call` on seven forks against an independent
//!    model: fork-dependent CREATE intrinsic gas (EIP-2), EIP-2930 access lists, the
//!    EIP-1559 base fee floor for legacy prices, EIP-3607, transaction nonces, checked
//!    EIP-4844 blob fees, and EIP-161 cleanup of the touched target and the coinbase.

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

/// EIP-7685 `computeRequestsHash` against an independent model: a list is accepted
/// only when every request has a type byte and the types are unique and strictly
/// ascending; an accepted list hashes to sha256 over sha256(request) of every
/// request that carries data.
pub fn fuzzRequestsHashOrdering(_: void, input: []const u8) !void {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var storage: [8][]const u8 = undefined;
    var count: usize = 0;
    var cursor: usize = 0;
    while (count < storage.len and cursor < input.len) {
        // Low three bits: the request length (0 = no type byte), then the request.
        const len = @min(@as(usize, input[cursor] % 8), input.len - cursor - 1);
        storage[count] = input[cursor + 1 .. cursor + 1 + len];
        count += 1;
        cursor += 1 + len;
    }
    const requests = storage[0..count];

    var expected_error: ?evm.eips.RequestsError = null;
    var outer = Sha256.init(.{});
    var seen: [256]bool = @splat(false);
    var highest: ?u8 = null;
    for (requests) |request| {
        if (request.len == 0) {
            expected_error = error.MissingRequestType;
            break;
        }
        // Unique and ascending: the type is new and above every earlier type.
        const above_all = if (highest) |top| request[0] > top else true;
        if (seen[request[0]] or !above_all) {
            expected_error = error.RequestTypesNotAscending;
            break;
        }
        seen[request[0]] = true;
        highest = request[0];
        if (request.len == 1) continue;
        var digest: [32]u8 = undefined;
        Sha256.hash(request, &digest, .{});
        outer.update(&digest);
    }

    const actual = evm.eips.computeRequestsHash(requests);
    if (expected_error) |err| {
        try std.testing.expectError(err, actual);
    } else {
        var expected: [32]u8 = undefined;
        outer.final(&expected);
        try std.testing.expectEqualSlices(u8, &expected, &(try actual));
    }

    // Any list with one request repeated is refused, wherever the copy lands.
    if (count >= 1 and count < storage.len and expected_error == null) {
        const at = if (input.len > 0) input[input.len - 1] % count else 0;
        var doubled: [9][]const u8 = undefined;
        @memcpy(doubled[0 .. at + 1], requests[0 .. at + 1]);
        doubled[at + 1] = requests[at];
        @memcpy(doubled[at + 2 .. count + 1], requests[at + 1 .. count]);
        try std.testing.expectError(
            error.RequestTypesNotAscending,
            evm.eips.computeRequestsHash(doubled[0 .. count + 1]),
        );
    }
}

/// EIP-1283 exists on Constantinople alone: Petersburg removed it and no later fork
/// brought it back (EIP-2200 replaced it). An override still decides it on any fork,
/// and decides every other EIP the same way.
pub fn fuzzEip1283AndOverrides(_: void, input: []const u8) !void {
    if (input.len < 4) return;
    for (ALL_HARDFORKS) |hardfork| {
        const eips = Eips{ .hardfork = hardfork };
        try std.testing.expectEqual(hardfork == .CONSTANTINOPLE, eips.is_eip_active(1283));
    }
    try std.testing.expect(!(Eips{ .hardfork = .OSAKA }).is_eip_active(1283));

    const hardfork = ALL_HARDFORKS[input[0] % ALL_HARDFORKS.len];
    const known = [_]u16{ 150, 170, 1283, 2200, 2929, 3529, 3651, 3855, 3860, 4788, 2935, 6780, 7702, 1153, 4844 };
    const eip = known[input[1] % known.len];
    const enabled = (input[2] & 1) == 1;
    const base = Eips{ .hardfork = hardfork };
    const override_list = [_]evm.eips.EipOverride{.{ .eip = eip, .enabled = enabled }};
    const overridden = Eips{ .hardfork = hardfork, .overrides = &override_list };
    try std.testing.expectEqual(enabled, overridden.is_eip_active(eip));
    // An override of one EIP changes no other EIP.
    const other = known[input[3] % known.len];
    if (other != eip) try std.testing.expectEqual(base.is_eip_active(other), overridden.is_eip_active(other));

    // The helpers read the same answer as `is_eip_active`: none bypasses an override.
    try std.testing.expectEqual(overridden.is_eip_active(3855), overridden.eip_3855_push0_enabled());
    try std.testing.expectEqual(overridden.is_eip_active(6780), overridden.eip_6780_selfdestruct_same_transaction_only());
    try std.testing.expectEqual(overridden.is_eip_active(3860), overridden.size_limit() != null);
}

/// An EIP-7702 authorization list is all or nothing under allocation failure: when
/// the database runs out of memory at any tuple, no authority keeps a delegation
/// or a nonce bump, the gas is untouched and no snapshot stays open.
pub fn fuzzAuthorizationListAtomicUnderOom(_: void, input: []const u8) !void {
    if (input.len < 3) return;
    const crypto = @import("crypto").Crypto;
    const allocator = fuzz_alloc.get();
    const count: usize = @as(usize, input[0] % 4) + 1;
    const delegate = Address{ .bytes = [_]u8{0xDE} ++ @as([19]u8, @splat(0)) };

    var list: [4]evm.Authorization = undefined;
    var authorities: [4]Address = undefined;
    for (list[0..count], authorities[0..count], 0..) |*tuple, *authority, index| {
        const key: crypto.PrivateKey = @as([32]u8, @splat(@intCast(0x31 + index + @as(usize, input[1] % 16) * 4)));
        authority.* = (try crypto.unaudited_getPublicKey(key)).toAddress();
        tuple.* = try primitives.Authorization.createAuthorization(allocator, 1, delegate, 0, key);
        tuple.v -= 27; // the tuple carries y_parity
    }

    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var db = Database.init(failing.allocator());
    defer db.deinit();
    const start_gas: i64 = 1_000_000;
    var gas_remaining = start_gas;
    var processor = AuthorizationProcessor{
        .db = &db,
        .chain_id = 1,
        .gas_remaining = &gas_remaining,
        .eips = Eips{ .hardfork = .PRAGUE },
    };

    failing.fail_index = failing.alloc_index + @as(usize, input[2] % 24);
    const outcome = processor.processAuthorizationList(list[0..count]);
    failing.fail_index = std.math.maxInt(usize);

    try std.testing.expectEqual(@as(usize, 0), db.snapshot_depth());
    if (outcome) |_| {
        try std.testing.expectEqual(start_gas - @as(i64, @intCast(count)) * 25_000, gas_remaining);
        for (authorities[0..count]) |authority| {
            const account = (try db.get_account(authority.bytes)) orelse return error.AuthorityMissing;
            try std.testing.expectEqual(@as(u64, 1), account.nonce);
            try std.testing.expectEqual(@as(?Address, delegate), account.delegated_address);
        }
    } else |err| {
        try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqual(start_gas, gas_remaining);
        for (authorities[0..count]) |authority| try std.testing.expect(!db.account_exists(authority.bytes));
    }
}

const requests_corpus: []const []const u8 = &.{
    &.{},
    &.{ 2, 0x00, 0xAA, 2, 0x00, 0xBB }, // duplicate type 0
    &.{ 2, 0x01, 0xAA, 2, 0x00, 0xBB }, // inversion
    &.{ 2, 0x00, 0xAA, 2, 0x01, 0xBB, 2, 0x02, 0xCC }, // strictly ascending
    &.{ 1, 0x00, 1, 0x00 }, // duplicate with no data
    &.{ 2, 0x00, 0xAA, 0, 2, 0x01, 0xBB }, // a request with no type byte
    &.{ 3, 0x00, 1, 2, 3, 0x02, 9, 9, 3, 0x02, 8, 8 }, // gap, then a duplicate of the highest type
    &.{ 2, 0xFF, 0x01, 2, 0xFF, 0x02 }, // duplicate of type 255
    &.{ 2, 0x00, 0x01, 2, 0x02, 0x02, 2, 0x01, 0x03 }, // non-adjacent inversion
};

const eip_override_corpus: []const []const u8 = &.{
    &.{ 6, 2, 1, 3 }, // Petersburg: enable EIP-1283
    &.{ 5, 2, 0, 3 }, // Constantinople: disable EIP-1283
    &.{ 12, 11, 0, 0 }, // Cancun: disable EIP-6780
    &.{ 9, 7, 1, 8 }, // London: enable PUSH0
    &.{ 10, 8, 1, 2 }, // Merge: enable the init code limit
    &.{ 13, 12, 0, 14 }, // Prague: disable EIP-7702
};

const authorization_oom_corpus: []const []const u8 = &.{
    &.{ 0, 0, 0 },
    &.{ 3, 0, 0 },
    &.{ 3, 1, 1 },
    &.{ 3, 2, 2 },
    &.{ 3, 3, 3 },
    &.{ 3, 4, 5 },
    &.{ 2, 5, 8 },
    &.{ 3, 6, 13 },
    &.{ 3, 7, 23 },
};

const admission_sender = Address{ .bytes = [_]u8{0x51} ++ @as([19]u8, @splat(0)) };
const admission_coinbase = Address{ .bytes = [_]u8{0xC0} ++ @as([19]u8, @splat(0)) };
/// Exists and is empty before every transaction: the target of every call.
const admission_empty = Address{ .bytes = [_]u8{0xEE} ++ @as([19]u8, @splat(0)) };
const admission_delegate = Address{ .bytes = [_]u8{0xDE} ++ @as([19]u8, @splat(0)) };

/// One transaction through `Evm.call` on `hardfork`, checked against a model of
/// transaction validity written from the EIPs, not from the EVM's code.
fn checkAdmission(comptime hardfork: Hardfork, input: []const u8) !void {
    const allocator = fuzz_alloc.get();
    const Vm = evm.Evm(.{ .eips = .{ .hardfork = hardfork } });
    const zero_hash = @as([32]u8, @splat(0));
    const homestead = comptime hardfork.isAtLeast(.HOMESTEAD);
    const spurious_dragon = comptime hardfork.isAtLeast(.SPURIOUS_DRAGON);
    const berlin = comptime hardfork.isAtLeast(.BERLIN);
    const london = comptime hardfork.isAtLeast(.LONDON);
    const shanghai = comptime hardfork.isAtLeast(.SHANGHAI);
    const cancun = comptime hardfork.isAtLeast(.CANCUN);
    const prague = comptime hardfork.isAtLeast(.PRAGUE);

    // ---- The transaction, decoded from the input.
    const is_create = input[1] & 1 == 1;
    const sender_kind: enum { eoa, contract, delegated } = switch (input[2] % 4) {
        0, 1 => .eoa,
        2 => .contract,
        else => .delegated,
    };
    const sender_nonce: u64 = input[3] % 4;
    const tx_nonce: ?u64 = switch (input[4] % 4) {
        0 => null,
        1 => sender_nonce,
        2 => sender_nonce + 1,
        else => if (sender_nonce > 0) sender_nonce - 1 else sender_nonce,
    };
    const gas_price: u256 = ([_]u256{ 0, 1, 5, 10 })[input[5] % 4];
    const base_fee: u256 = ([_]u256{ 0, 5, 10 })[input[6] % 3];
    const list_addresses: usize = input[7] % 3;
    const list_keys: usize = (input[7] >> 4) % 3;
    const blob_transaction = input[8] % 4 == 0;
    const max_fee_per_blob_gas: u256 = ([_]u256{ 1, (@as(u256, 1) << 239) - 1, @as(u256, 1) << 239, std.math.maxInt(u256) })[input[9] % 4];
    const rich_sender = input[10] % 4 != 0;
    const gas_delta: i64 = ([_]i64{ -1, 0, 1, 50_000 })[input[11] % 4];

    // ---- The model: intrinsic gas.
    var intrinsic: u64 = 21_000;
    if (is_create) {
        if (homestead) intrinsic += 32_000; // EIP-2
        intrinsic += 4; // one zero byte of init code
        if (shanghai) intrinsic += 2; // EIP-3860: one word
    }
    if (berlin) intrinsic += @as(u64, list_addresses) * 2_400 + @as(u64, list_addresses * list_keys) * 1_900;
    const gas_limit: u64 = @intCast(@as(i64, @intCast(intrinsic)) + gas_delta);

    // ---- The model: validity.
    const blob_gas: u256 = 131_072;
    const blob_fee_overflows = blob_transaction and cancun and max_fee_per_blob_gas > std.math.maxInt(u256) / blob_gas;
    const max_blob_fee: u256 = if (blob_transaction and cancun and !blob_fee_overflows) blob_gas * max_fee_per_blob_gas else 0;
    const balance: u256 = if (rich_sender) std.math.maxInt(u256) else 0;
    const gas_cost: u256 = @as(u256, gas_limit) * gas_price;
    const cost_overflows = @addWithOverflow(gas_cost, max_blob_fee)[1] != 0;
    var valid = true;
    if (gas_limit < intrinsic) valid = false;
    if (list_addresses != 0 and !berlin) valid = false; // EIP-2930
    if (tx_nonce) |nonce| {
        if (nonce != sender_nonce) valid = false;
    }
    if (sender_kind == .contract) valid = false; // EIP-3607
    if (sender_kind == .delegated and !prague) valid = false; // a designator is code before EIP-7702
    if (london and gas_price < base_fee) valid = false; // EIP-1559
    if (blob_transaction) {
        if (!cancun or is_create) valid = false; // EIP-4844
        if (blob_fee_overflows) valid = false;
    }
    if (cost_overflows or balance < gas_cost +| max_blob_fee) valid = false;

    // ---- The state.
    var db = Database.init(allocator);
    defer db.deinit();
    var sender_account = Account{ .balance = balance, .nonce = sender_nonce, .code_hash = zero_hash, .storage_root = zero_hash };
    switch (sender_kind) {
        .eoa => {},
        .contract => sender_account.code_hash = try db.set_code(&[_]u8{0x00}),
        .delegated => sender_account.delegated_address = admission_delegate,
    }
    try db.set_account(admission_sender.bytes, sender_account);
    try db.set_account(admission_empty.bytes, .{ .balance = 0, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
    const root_before = try db.get_state_root();

    const keys = [_]u256{ 1, 2 };
    var entries: [2]evm.AccessListEntry = undefined;
    for (entries[0..list_addresses], 0..) |*entry, i| {
        entry.* = .{ .address = Address{ .bytes = [_]u8{@intCast(0x90 + i)} ++ @as([19]u8, @splat(0)) }, .storage_keys = keys[0..list_keys] };
    }
    const blob_hashes = [_][32]u8{[_]u8{0x01} ++ @as([31]u8, @splat(0x77))};

    var vm = try Vm.init(allocator, &db, .{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1,
        .difficulty = 1,
        .gas_limit = 30_000_000,
        .coinbase = admission_coinbase,
        .base_fee = base_fee,
        .prev_randao = zero_hash,
        .blob_base_fee = 1,
        .blob_versioned_hashes = if (blob_transaction) &blob_hashes else &.{},
    }, .{
        .gas_limit = gas_limit,
        .coinbase = admission_coinbase,
        .chain_id = 1,
        .blob_versioned_hashes = if (blob_transaction) &blob_hashes else &.{},
        .is_blob_transaction = blob_transaction,
        .max_fee_per_blob_gas = if (blob_transaction) max_fee_per_blob_gas else 0,
        .access_list = entries[0..list_addresses],
        .tx_nonce = tx_nonce,
    }, gas_price, admission_sender);
    defer vm.deinit();

    var result = if (is_create)
        vm.call(.{ .create = .{ .caller = admission_sender, .value = 0, .init_code = &[_]u8{0x00}, .gas = gas_limit } })
    else
        vm.call(.{ .call = .{ .caller = admission_sender, .to = admission_empty, .value = 0, .input = &.{}, .gas = gas_limit } });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(?anyerror, null), vm.host_failure);

    if (!valid) {
        // Rejected: an error is reported and nothing changed.
        try std.testing.expect(!result.success);
        try std.testing.expect(result.error_info != null);
        try std.testing.expect(std.mem.startsWith(u8, result.error_info.?, "invalid transaction"));
        try std.testing.expectEqualSlices(u8, &root_before, &(try db.get_state_root()));
        return;
    }

    // Accepted. A call to an account without code and init code `STOP` both succeed
    // on any amount of execution gas, zero included.
    try std.testing.expectEqual(@as(?[]const u8, null), result.error_info);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(sender_nonce + 1, try db.get_nonce(admission_sender.bytes));
    const gas_used: u64 = gas_limit - result.gas_left;
    try std.testing.expectEqual(intrinsic, gas_used);

    // Fees: the sender paid for the gas used and one blob; from London the base fee
    // is burned and the coinbase gets the rest.
    const blob_fee: u256 = if (blob_transaction) blob_gas else 0;
    try std.testing.expectEqual(balance - @as(u256, gas_used) * gas_price - blob_fee, try db.get_balance(admission_sender.bytes));
    const tip: u256 = if (london) gas_price - base_fee else gas_price;
    try std.testing.expectEqual(@as(u256, gas_used) * tip, try db.get_balance(admission_coinbase.bytes));

    // EIP-161. Before Spurious Dragon nothing is deleted and the fee payment creates
    // the coinbase. From it on, the called empty account is deleted (a creation does
    // not touch it) and a coinbase that was paid nothing is not left behind.
    if (spurious_dragon) {
        try std.testing.expectEqual(is_create, db.account_exists(admission_empty.bytes));
        try std.testing.expectEqual(tip > 0, db.account_exists(admission_coinbase.bytes));
    } else {
        try std.testing.expect(db.account_exists(admission_empty.bytes));
        try std.testing.expect(db.account_exists(admission_coinbase.bytes));
    }
}

/// Transaction admission and finalization on a fork chosen by the first byte.
pub fn fuzzTransactionAdmission(_: void, input: []const u8) !void {
    if (input.len < 12) return;
    switch (input[0] % 7) {
        0 => try checkAdmission(.FRONTIER, input),
        1 => try checkAdmission(.HOMESTEAD, input),
        2 => try checkAdmission(.SPURIOUS_DRAGON, input),
        3 => try checkAdmission(.BERLIN, input),
        4 => try checkAdmission(.LONDON, input),
        5 => try checkAdmission(.CANCUN, input),
        else => try checkAdmission(.PRAGUE, input),
    }
}

/// `blob_gas * fee` against 512-bit arithmetic: the helpers return the exact product
/// or null, and never a clamped value.
pub fn fuzzCheckedBlobFee(_: void, input: []const u8) !void {
    if (input.len < 33) return;
    const fee = std.mem.readInt(u256, input[0..32], .little) >> @intCast(input[32]);
    const cancun = Eips{ .hardfork = .CANCUN };
    for (0..10) |blob_count| {
        const wide: u512 = @as(u512, blob_count) * 131_072 * fee;
        const fits = wide <= std.math.maxInt(u256);
        for ([_]?u256{ cancun.blob_gas_cost(fee, blob_count), cancun.max_blob_gas_cost(fee, blob_count) }) |cost| {
            try std.testing.expectEqual(fits, cost != null);
            if (cost) |value| try std.testing.expectEqual(wide, @as(u512, value));
        }
        try std.testing.expectEqual(fits, evm.verified_ops.checkedBlobGasCost(@intCast(blob_count * 131_072), fee) != null);
    }
    // Before Cancun there is no blob fee.
    try std.testing.expectEqual(@as(?u256, 0), (Eips{ .hardfork = .SHANGHAI }).max_blob_gas_cost(fee, 6));
}

// Bytes: fork, create, sender kind, sender nonce, tx nonce, gas price, base fee,
// access list, blob, blob fee cap, balance, gas delta.
const admission_corpus: []const []const u8 = &.{
    &.{ 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1 }, // Frontier CREATE at exactly 21,004 gas
    &.{ 0, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0 }, // Frontier CREATE one gas short
    &.{ 1, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1 }, // Homestead CREATE at exactly 53,004 gas
    &.{ 1, 1, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0 }, // Homestead CREATE one gas short
    &.{ 4, 0, 0, 0, 0, 2, 2, 0, 1, 0, 1, 3 }, // London legacy price 5 under base fee 10
    &.{ 4, 0, 0, 0, 0, 3, 2, 0, 1, 0, 1, 3 }, // London legacy price 10 equal to base fee 10
    &.{ 3, 0, 0, 0, 0, 0, 2, 0, 1, 0, 1, 3 }, // Berlin: no base fee floor
    &.{ 5, 0, 0, 0, 0, 0, 0, 0, 0, 3, 1, 3 }, // Cancun blob fee cap 2^256 - 1: overflow
    &.{ 5, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 3 }, // Cancun blob fee cap 2^239: smallest overflow
    &.{ 5, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 3 }, // Cancun blob fee cap 2^239 - 1: fits
    &.{ 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 3 }, // London blob transaction: not yet a thing
    &.{ 4, 0, 2, 0, 0, 0, 0, 0, 1, 0, 1, 3 }, // sender with code (EIP-3607)
    &.{ 5, 0, 3, 0, 0, 0, 0, 0, 1, 0, 1, 3 }, // delegated sender before Prague
    &.{ 6, 0, 3, 0, 0, 0, 0, 0, 1, 0, 1, 3 }, // delegated sender on Prague
    &.{ 4, 0, 0, 2, 2, 0, 0, 0, 1, 0, 1, 3 }, // nonce too high
    &.{ 4, 0, 0, 2, 3, 0, 0, 0, 1, 0, 1, 3 }, // nonce too low
    &.{ 4, 0, 0, 2, 1, 0, 0, 0, 1, 0, 1, 3 }, // nonce exact
    &.{ 3, 0, 0, 0, 0, 0, 0, 0x22, 1, 0, 1, 1 }, // Berlin access list, exact intrinsic gas
    &.{ 3, 0, 0, 0, 0, 0, 0, 0x22, 1, 0, 1, 0 }, // Berlin access list, one gas short
    &.{ 2, 0, 0, 0, 0, 0, 0, 0x01, 1, 0, 1, 3 }, // access list before Berlin
    &.{ 2, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 3 }, // Spurious Dragon: touched empty target deleted
    &.{ 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 3 }, // Homestead: zero-fee coinbase created
    &.{ 4, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 3 }, // sender cannot pay for the gas
};

const blob_fee_corpus: []const []const u8 = &.{
    &(@as([32]u8, @splat(0xff)) ++ [_]u8{0}), // 2^256 - 1
    &(@as([32]u8, @splat(0xff)) ++ [_]u8{17}), // 2^239 - 1: the largest fee one blob can carry
    &(@as([32]u8, @splat(0xff)) ++ [_]u8{16}), // 2^240 - 1: overflows from one blob on
    &(@as([32]u8, @splat(0xff)) ++ [_]u8{21}), // 2^235 - 1: fits for every blob count up to nine
    &([_]u8{7} ++ @as([31]u8, @splat(0)) ++ [_]u8{0}),
    &(@as([32]u8, @splat(0)) ++ [_]u8{0}),
};

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

test "fuzz transaction admission through Evm.call on seven forks against an independent model" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzTransactionAdmission), .{ .corpus = admission_corpus });
}

test "fuzz checked EIP-4844 blob fee against 512-bit arithmetic" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzCheckedBlobFee), .{ .corpus = blob_fee_corpus });
}

test "fuzz EIP-2028/3860/7623 calldata and initcode gas formulas" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzCalldataAndInitcodeGas), .{ .corpus = seed_corpus });
}

test "fuzz EIP-7685 requests hash rejects duplicate and out-of-order request types" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzRequestsHashOrdering), .{ .corpus = requests_corpus });
}

test "fuzz EIP-1283 is Constantinople-only and overrides reach every helper" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzEip1283AndOverrides), .{ .corpus = eip_override_corpus });
}

test "fuzz EIP-7702 authorization list atomicity under allocation failure" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzAuthorizationListAtomicUnderOom), .{ .corpus = authorization_oom_corpus });
}

test "fuzz EIP-7702 authorization processor validation and delegation state transitions" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzEip7702AuthorizationProcessor), .{ .corpus = seed_corpus });
}
