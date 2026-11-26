//! 100-block Ethereum mainnet replay benchmark (`zig build bench-blocks`).
//!
//! Executes a pinned contiguous range of real Ethereum mainnet blocks (default:
//! 26,498,000..26,498,099, Osaka) offline against pre-fetched pre-state,
//! running EIP-4788 beacon root + EIP-2935 history system calls, all legacy /
//! EIP-2930 / EIP-1559 / EIP-4844 / EIP-7702 transactions, and EIP-4895
//! withdrawals, while verifying per-transaction status and gas against mainnet
//! receipts.
const std = @import("std");
const builtin = @import("builtin");
const evm = @import("guillotine");
const voltaire = @import("voltaire");

pub const std_options: std.Options = .{ .log_level = .err };

const EvmConfig = evm.EvmConfig{
    .eips = .{ .hardfork = .OSAKA },
    .enable_fusion = true,
    .dispatch_cache_entries = 8192,
    .dispatch_cache_bytes = 512 * 1024 * 1024,
    .loop_quota = 300_000_000,
    .tracer_config = .disabled,
};
const EvmType = evm.Evm(EvmConfig);
const Address = voltaire.Address.Address;
const Account = evm.Account;
const Authorization = voltaire.Authorization.Authorization;

const SYSTEM_ADDRESS = Address{ .bytes = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe } };
const BEACON_ROOTS_ADDRESS = Address{ .bytes = .{ 0x00, 0x0f, 0x3d, 0xf6, 0xd7, 0x32, 0x80, 0x7e, 0xf1, 0x31, 0x9f, 0xb7, 0xb8, 0xbb, 0x85, 0x22, 0xd0, 0xbe, 0xac, 0x02 } };
const HISTORY_STORAGE_ADDRESS = Address{ .bytes = .{ 0x00, 0x00, 0xf9, 0x08, 0x27, 0xf1, 0xc5, 0x3a, 0x10, 0xcb, 0x7a, 0x02, 0x33, 0x5b, 0x17, 0x53, 0x20, 0x00, 0x29, 0x35 } };

const JsonAccessListEntry = struct {
    address: []const u8,
    storage_keys: [][]const u8 = &.{},
};

const JsonAuthorization = struct {
    chain_id: []const u8,
    address: []const u8,
    nonce: u64,
    y_parity: u8,
    r: []const u8,
    s: []const u8,
};

const JsonTx = struct {
    type: u8 = 0,
    from: []const u8,
    to: []const u8 = "",
    nonce: u64,
    gas: u64,
    gas_price: []const u8 = "0x0",
    max_fee_per_gas: []const u8 = "",
    max_priority_fee_per_gas: []const u8 = "",
    max_fee_per_blob_gas: []const u8 = "",
    value: []const u8 = "0x0",
    input: []const u8 = "0x",
    access_list: []JsonAccessListEntry = &.{},
    blob_versioned_hashes: [][]const u8 = &.{},
    authorization_list: []JsonAuthorization = &.{},
    expected_gas_used: u64,
    expected_status: bool,
};

const JsonWithdrawal = struct {
    address: []const u8,
    amount_gwei: u64,
};

const JsonBlock = struct {
    number: u64,
    hash: []const u8,
    parent_hash: []const u8,
    timestamp: u64,
    coinbase: []const u8,
    gas_limit: u64,
    gas_used: u64,
    base_fee: []const u8,
    prev_randao: []const u8,
    excess_blob_gas: u64 = 0,
    blob_gas_used: u64 = 0,
    parent_beacon_block_root: []const u8 = "",
    withdrawals: []JsonWithdrawal = &.{},
    transactions: []JsonTx = &.{},
};

const JsonAccount = struct {
    address: []const u8,
    balance: []const u8,
    nonce: u64,
    code_id: usize = 0,
    first_block: u32 = 0,
    first_tx: u32 = 0,
    exact_pre_start: bool = false,
    storage: []std.json.Value = &.{},
};

const JsonBundle = struct {
    schema: []const u8,
    chain_id: u64,
    hardfork: []const u8,
    start_block: u64,
    end_block: u64,
    block_count: usize,
    total_transactions: usize,
    total_gas_used: u64,
    ancestor_hashes: std.json.ArrayHashMap([]const u8),
    codes: [][]const u8,
    accounts: []JsonAccount,
    blocks: []JsonBlock,
};

const AccessEntry = struct {
    address: Address,
    keys: []u256,
};

const Tx = struct {
    tx_type: u8,
    from: Address,
    to: ?Address,
    nonce: u64,
    gas: u64,
    gas_price: u256,
    max_fee_per_gas: ?u256,
    max_priority_fee_per_gas: u256,
    value: u256,
    input: []u8,
    access_list: []AccessEntry,
    blob_hashes: [][32]u8,
    authorizations: []Authorization,
    expected_gas_used: u64,
    expected_status: bool,
};

const Withdrawal = struct {
    address: Address,
    amount_wei: u256,
};

const Block = struct {
    number: u64,
    hash: [32]u8,
    parent_hash: [32]u8,
    timestamp: u64,
    coinbase: Address,
    gas_limit: u64,
    gas_used: u64,
    base_fee: u64,
    prev_randao: [32]u8,
    excess_blob_gas: u64,
    blob_gas_used: u64,
    blob_base_fee: u64,
    beacon_root: ?[32]u8,
    withdrawals: []Withdrawal,
    txs: []Tx,
};

const StorageSlot = struct {
    addr: [20]u8,
    slot: u256,
    val: u256,
    first_block: u32,
    first_tx: u32,
};

const PreAccount = struct {
    address: [20]u8,
    balance: u256,
    nonce: u64,
    code_id: usize,
    first_block: u32,
    first_tx: u32,
    exact_pre_start: bool,
};

const TruePrestate = struct {
    code_hashes: [][32]u8,
    accounts: []PreAccount,
    slots: []StorageSlot,
};

const Bundle = struct {
    chain_id: u64,
    start_block: u64,
    end_block: u64,
    total_txs: usize,
    total_gas_used: u64,
    ancestor_hashes: [256][32]u8,
    codes: [][]u8,
    accounts: []PreAccount,
    slots: []StorageSlot,
    blocks: []Block,
};

const CliOpts = struct {
    bundle_path: []const u8 = ".cache/mainnet-blocks/26498000-26498099.json",
    iterations: usize = 3,
    warmup: usize = 1,
    blob_update_fraction: u64 = 11684671,
    json_out: ?[]const u8 = null,
    verbose_mismatches: usize = 15,
};

fn nowNs(io: std.Io) u64 {
    const ts = std.Io.Timestamp.now(io, .awake);
    return @intCast(@max(ts.nanoseconds, 0));
}

fn trimHex(s: []const u8) []const u8 {
    var t = std.mem.trim(u8, s, " \t\n\r");
    if (std.mem.startsWith(u8, t, "0x") or std.mem.startsWith(u8, t, "0X")) t = t[2..];
    return t;
}

fn parseHexU256(s: []const u8) !u256 {
    const h = trimHex(s);
    if (h.len == 0) return 0;
    return std.fmt.parseInt(u256, h, 16);
}

fn parseHexU64(s: []const u8) !u64 {
    const h = trimHex(s);
    if (h.len == 0) return 0;
    return std.fmt.parseInt(u64, h, 16);
}

fn parseHexBytes(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const h = trimHex(s);
    if (h.len == 0) return allocator.alloc(u8, 0);
    if (h.len % 2 == 1) {
        const padded = try allocator.alloc(u8, h.len + 1);
        defer allocator.free(padded);
        padded[0] = 48;
        @memcpy(padded[1..], h);
        const out = try allocator.alloc(u8, padded.len / 2);
        _ = try std.fmt.hexToBytes(out, padded);
        return out;
    }
    const out = try allocator.alloc(u8, h.len / 2);
    _ = try std.fmt.hexToBytes(out, h);
    return out;
}

fn parseAddress(s: []const u8) ![20]u8 {
    const h = trimHex(s);
    var out: [20]u8 = @splat(0);
    if (h.len == 0) return out;
    if (h.len > 40) return error.InvalidAddress;
    var padded: [40]u8 = @splat(48);
    @memcpy(padded[40 - h.len ..], h);
    _ = try std.fmt.hexToBytes(&out, &padded);
    return out;
}

fn parseBytes32(s: []const u8) ![32]u8 {
    const h = trimHex(s);
    var out: [32]u8 = @splat(0);
    if (h.len == 0) return out;
    if (h.len > 64) return error.InvalidBytes32;
    var padded: [64]u8 = @splat(48);
    @memcpy(padded[64 - h.len ..], h);
    _ = try std.fmt.hexToBytes(&out, &padded);
    return out;
}

fn fakeExponential(factor: u128, numerator: u128, denominator: u128) u64 {
    var i: u128 = 1;
    var output: u128 = 0;
    var numerator_accum: u128 = factor * denominator;
    while (numerator_accum > 0) {
        output += numerator_accum;
        numerator_accum = (numerator_accum * numerator) / (denominator * i);
        i += 1;
    }
    const res = output / denominator;
    return if (res > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(res);
}

fn parseCli(args: []const []const u8) !CliOpts {
    var opts = CliOpts{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--bundle")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.bundle_path = args[i];
        } else if (std.mem.eql(u8, a, "--iterations")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.iterations = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--warmup")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.warmup = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--blob-fraction")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.blob_update_fraction = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--json")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.json_out = args[i];
        } else if (std.mem.eql(u8, a, "--verbose-mismatches")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            opts.verbose_mismatches = try std.fmt.parseInt(usize, args[i], 10);
        } else {
            return error.UnknownArgument;
        }
    }
    return opts;
}

fn loadBundle(arena: std.mem.Allocator, io: std.Io, opts: CliOpts) !Bundle {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, opts.bundle_path, arena, .limited(512 * 1024 * 1024));
    const parsed = try std.json.parseFromSlice(JsonBundle, arena, raw, .{ .ignore_unknown_fields = true });
    const jb = parsed.value;

    var ancestor_hashes: [256][32]u8 = @splat(@as([32]u8, @splat(0)));
    for (0..256) |idx| {
        if (jb.start_block < idx + 1) break;
        const bnum = jb.start_block - 1 - idx;
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{d}", .{bnum}) catch unreachable;
        if (jb.ancestor_hashes.map.get(key)) |hex_hash| {
            ancestor_hashes[idx] = try parseBytes32(hex_hash);
        }
    }

    const codes = try arena.alloc([]u8, jb.codes.len);
    for (jb.codes, 0..) |c, i| codes[i] = try parseHexBytes(arena, c);

    const accounts = try arena.alloc(PreAccount, jb.accounts.len);
    var all_slots: std.ArrayList(StorageSlot) = .empty;
    for (jb.accounts, 0..) |ja, i| {
        const addr = try parseAddress(ja.address);
        accounts[i] = .{
            .address = addr,
            .balance = try parseHexU256(ja.balance),
            .nonce = ja.nonce,
            .code_id = ja.code_id,
            .first_block = ja.first_block,
            .first_tx = ja.first_tx,
            .exact_pre_start = ja.exact_pre_start,
        };
        for (ja.storage) |sv| {
            if (sv != .array or sv.array.items.len < 2) continue;
            const items = sv.array.items;
            const slot_val = try parseHexU256(items[0].string);
            const data_val = try parseHexU256(items[1].string);
            const fb: u32 = if (items.len >= 3) @intCast(items[2].integer) else ja.first_block;
            const ft: u32 = if (items.len >= 4) @intCast(items[3].integer) else ja.first_tx;
            try all_slots.append(arena, .{
                .addr = addr,
                .slot = slot_val,
                .val = data_val,
                .first_block = fb,
                .first_tx = ft,
            });
        }
    }

    const blocks = try arena.alloc(Block, jb.blocks.len);
    for (jb.blocks, 0..) |jblk, bi| {
        const withdrawals = try arena.alloc(Withdrawal, jblk.withdrawals.len);
        for (jblk.withdrawals, 0..) |jw, wi| {
            withdrawals[wi] = .{
                .address = .{ .bytes = try parseAddress(jw.address) },
                .amount_wei = @as(u256, jw.amount_gwei) * 1_000_000_000,
            };
        }

        const txs = try arena.alloc(Tx, jblk.transactions.len);
        for (jblk.transactions, 0..) |jtx, ti| {
            const access_list = try arena.alloc(AccessEntry, jtx.access_list.len);
            for (jtx.access_list, 0..) |je, ei| {
                const keys = try arena.alloc(u256, je.storage_keys.len);
                for (je.storage_keys, 0..) |k, ki| keys[ki] = try parseHexU256(k);
                access_list[ei] = .{
                    .address = .{ .bytes = try parseAddress(je.address) },
                    .keys = keys,
                };
            }

            const blob_hashes = try arena.alloc([32]u8, jtx.blob_versioned_hashes.len);
            for (jtx.blob_versioned_hashes, 0..) |h, hi| blob_hashes[hi] = try parseBytes32(h);

            const auths = try arena.alloc(Authorization, jtx.authorization_list.len);
            for (jtx.authorization_list, 0..) |ja, ai| {
                auths[ai] = .{
                    .chain_id = try parseHexU64(ja.chain_id),
                    .address = .{ .bytes = try parseAddress(ja.address) },
                    .nonce = ja.nonce,
                    .v = ja.y_parity,
                    .r = try parseBytes32(ja.r),
                    .s = try parseBytes32(ja.s),
                };
            }

            txs[ti] = .{
                .tx_type = jtx.type,
                .from = .{ .bytes = try parseAddress(jtx.from) },
                .to = if (jtx.to.len > 0) Address{ .bytes = try parseAddress(jtx.to) } else null,
                .nonce = jtx.nonce,
                .gas = jtx.gas,
                .gas_price = try parseHexU256(jtx.gas_price),
                .max_fee_per_gas = if (jtx.max_fee_per_gas.len > 0) try parseHexU256(jtx.max_fee_per_gas) else null,
                .max_priority_fee_per_gas = if (jtx.max_priority_fee_per_gas.len > 0) try parseHexU256(jtx.max_priority_fee_per_gas) else 0,
                .value = try parseHexU256(jtx.value),
                .input = try parseHexBytes(arena, jtx.input),
                .access_list = access_list,
                .blob_hashes = blob_hashes,
                .authorizations = auths,
                .expected_gas_used = jtx.expected_gas_used,
                .expected_status = jtx.expected_status,
            };
        }

        blocks[bi] = .{
            .number = jblk.number,
            .hash = try parseBytes32(jblk.hash),
            .parent_hash = try parseBytes32(jblk.parent_hash),
            .timestamp = jblk.timestamp,
            .coinbase = .{ .bytes = try parseAddress(jblk.coinbase) },
            .gas_limit = jblk.gas_limit,
            .gas_used = jblk.gas_used,
            .base_fee = try parseHexU64(jblk.base_fee),
            .prev_randao = try parseBytes32(jblk.prev_randao),
            .excess_blob_gas = jblk.excess_blob_gas,
            .blob_gas_used = jblk.blob_gas_used,
            .blob_base_fee = fakeExponential(1, jblk.excess_blob_gas, opts.blob_update_fraction),
            .beacon_root = if (jblk.parent_beacon_block_root.len > 0) try parseBytes32(jblk.parent_beacon_block_root) else null,
            .withdrawals = withdrawals,
            .txs = txs,
        };
    }

    return .{
        .chain_id = jb.chain_id,
        .start_block = jb.start_block,
        .end_block = jb.end_block,
        .total_txs = jb.total_transactions,
        .total_gas_used = jb.total_gas_used,
        .ancestor_hashes = ancestor_hashes,
        .codes = codes,
        .accounts = accounts,
        .slots = all_slots.items,
        .blocks = blocks,
    };
}

fn insertPreAccount(db: *evm.Database, codes: []const []u8, code_hashes: []const [32]u8, acc: PreAccount) !void {
    if (acc.balance == 0 and acc.nonce == 0 and acc.code_id == 0) return;
    var acct = Account.zero();
    acct.balance = acc.balance;
    acct.nonce = acc.nonce;
    if (acc.code_id > 0) {
        const code = codes[acc.code_id];
        if (code.len == 23 and code[0] == 0xef and code[1] == 0x01 and code[2] == 0x00) {
            var target: [20]u8 = undefined;
            @memcpy(&target, code[3..23]);
            acct.delegated_address = .{ .bytes = target };
        } else {
            acct.code_hash = code_hashes[acc.code_id];
        }
    }
    try db.set_account(acc.address, acct);
}

fn populateFromTruePrestate(db: *evm.Database, bundle: *const Bundle, pre: *const TruePrestate) !void {
    for (bundle.codes[1..], 1..) |code, idx| {
        if (code.len > 0) {
            _ = try db.set_code(code);
        }
        _ = idx;
    }
    for (pre.accounts) |acc| {
        try insertPreAccount(db, bundle.codes, pre.code_hashes, acc);
    }
    for (pre.slots) |s| {
        if (s.val != 0) try db.set_storage(s.addr, s.slot, s.val);
    }
}

const ReplayStats = struct {
    elapsed_ns: u64,
    tx_count: usize,
    status_matches: usize,
    gas_matches: usize,
    exact_matches: usize,
    actual_gas_total: u64,
    expected_gas_total: u64,
};

fn resetEvmTxState(vm: *EvmType) void {
    vm.depth = 0;
    vm.access_list.clear();
    vm.journal.clear();
    vm.gas_refund_counter = 0;
    vm.logs.clearRetainingCapacity();
    vm.created_contracts.clear();
    vm.self_destruct.clear();
    vm.database.clear_transient_storage();
    vm.call_stack = @splat(.{ .caller = voltaire.ZERO_ADDRESS, .value = 0, .is_static = false });
    vm.current_snapshot_id = 0;
    vm.tx_sender_nonce_incremented = false;
    vm.host_failure = null;
    vm.frame_memory.trim();
    vm.resetTouched();
    vm.call_arena.resetRetainCapacity() catch {};
}

fn runSystemCall(vm: *EvmType, target: Address, input: []const u8) !void {
    const acc = (try vm.database.get_account(target.bytes)) orelse return;
    if (std.mem.allEqual(u8, &acc.code_hash, 0) or std.mem.eql(u8, &acc.code_hash, &voltaire.EMPTY_CODE_HASH)) return;
    resetEvmTxState(vm);
    vm.origin = SYSTEM_ADDRESS;
    vm.gas_price = 0;
    vm.context.gas_limit = 30_000_000;
    _ = vm.inner_call(.{ .call = .{
        .caller = SYSTEM_ADDRESS,
        .to = target,
        .value = 0,
        .input = input,
        .gas = 30_000_000,
    } });
    resetEvmTxState(vm);
}

fn executeOneTx(
    allocator: std.mem.Allocator,
    db: *evm.Database,
    vm: *EvmType,
    eips: evm.Eips,
    chain_id: u64,
    blk: *const Block,
    tx: *const Tx,
) !struct { success: bool, gas_used: u64 } {
    const last_precompile = comptime evm.precompiles.lastContiguousPrecompile(.OSAKA);
    resetEvmTxState(vm);

    const is_create = tx.to == null;
    const effective_price: u256 = if (tx.max_fee_per_gas) |max_fee| blk_p: {
        const cap = @as(u256, blk.base_fee) + tx.max_priority_fee_per_gas;
        break :blk_p @min(max_fee, cap);
    } else tx.gas_price;

    const tokens = eips.tokens_in_calldata(tx.input);
    var list_gas: u64 = 0;
    for (tx.access_list) |entry| {
        list_gas += 2400 + @as(u64, @intCast(entry.keys.len)) * 1900;
    }
    list_gas += @as(u64, @intCast(tx.authorizations.len)) * 25_000;

    const intrinsic: u64 = @intCast(@as(u128, eips.intrinsic_gas_cost(is_create)) + eips.calldata_gas_cost(tokens, is_create, tx.input.len) + list_gas);
    const floor: u64 = eips.floor_gas_cost(tokens);
    const execution_gas: u64 = tx.gas -| intrinsic;

    const blob_fee: u256 = @as(u256, tx.blob_hashes.len) * 131_072 * @as(u256, blk.blob_base_fee);
    const upfront_cost: u256 = @as(u256, tx.gas) * effective_price + blob_fee;

    var sender = (try db.get_account(tx.from.bytes)) orelse Account.zero();
    sender.balance -|= upfront_cost;
    sender.nonce = tx.nonce + 1;
    try db.set_account(tx.from.bytes, sender);

    vm.origin = tx.from;
    vm.gas_price = effective_price;
    vm.context.gas_limit = tx.gas;
    vm.context.blob_versioned_hashes = tx.blob_hashes;
    vm.context.is_blob_transaction = tx.tx_type == 3;
    vm.context.max_fee_per_gas = tx.max_fee_per_gas;
    vm.context.max_priority_fee_per_gas = tx.max_priority_fee_per_gas;

    try eips.pre_warm_transaction_addresses(&vm.access_list, tx.from, tx.to, blk.coinbase);
    var precompile: u16 = 0x01;
    while (precompile <= last_precompile) : (precompile += 1) {
        try vm.access_list.pre_warm_addresses(&[_]Address{Address.fromU256(precompile)});
    }
    try vm.access_list.pre_warm_addresses(&[_]Address{evm.precompiles.P256VERIFY_ADDRESS});
    for (tx.access_list) |entry| {
        try vm.access_list.pre_warm_addresses(&[_]Address{entry.address});
        for (entry.keys) |k| _ = try vm.access_list.access_storage_slot(entry.address, k);
    }

    var auth_refund: u64 = 0;
    if (tx.authorizations.len > 0) {
        var unmetered: i64 = std.math.maxInt(i64);
        var proc = evm.AuthorizationProcessor{
            .db = db,
            .chain_id = chain_id,
            .gas_remaining = &unmetered,
            .eips = eips,
        };
        var applied = try proc.processAuthorizationListWithResults(allocator, tx.authorizations);
        defer applied.deinit(allocator);
        for (applied.results) |res| {
            if (res.authority) |authority| try vm.access_list.pre_warm_addresses(&[_]Address{authority});
        }
        if (applied.refund > 0) auth_refund = @intCast(applied.refund);
    }
    if (tx.to) |to| try vm.warmDelegatedTarget(to);

    var success = false;
    var gas_left: u64 = 0;
    if (tx.to) |to| {
        const res = vm.inner_call(.{ .call = .{
            .caller = tx.from,
            .to = to,
            .value = tx.value,
            .input = tx.input,
            .gas = execution_gas,
        } });
        success = res.success;
        gas_left = res.gas_left;
    } else {
        vm.tx_sender_nonce_incremented = true;
        const res = vm.inner_call(.{ .create = .{
            .caller = tx.from,
            .value = tx.value,
            .init_code = tx.input,
            .gas = execution_gas,
        } });
        success = res.success;
        gas_left = res.gas_left;
    }
    if (vm.host_failure) |err| return err;

    var gas_used = tx.gas - gas_left;
    var refund_counter = auth_refund;
    if (success) refund_counter += vm.gas_refund_counter;
    gas_used -= @min(refund_counter, gas_used / 5);
    gas_used = @max(gas_used, floor);

    sender = (try db.get_account(tx.from.bytes)) orelse Account.zero();
    sender.balance += @as(u256, tx.gas - gas_used) * effective_price;
    try db.set_account(tx.from.bytes, sender);

    const tip: u256 = effective_price -| @as(u256, blk.base_fee);
    if (tip > 0 and gas_used > 0) {
        var cb = (try db.get_account(blk.coinbase.bytes)) orelse Account.zero();
        cb.balance += @as(u256, gas_used) * tip;
        try db.set_account(blk.coinbase.bytes, cb);
    }

    if (success and vm.self_destruct.count() > 0) {
        var it = vm.self_destruct.iterator();
        while (it.next()) |entry| {
            try db.delete_account(entry.key_ptr.bytes);
        }
    }

    return .{ .success = success, .gas_used = gas_used };
}

/// Untimed pre-pass: separates true pre-start-block accounts/slots from those created
/// mid-window by earlier transactions in the 100-block range.
fn discoverTruePrestate(allocator: std.mem.Allocator, bundle: *const Bundle, vm: *EvmType) !TruePrestate {
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const code_hashes = try allocator.alloc([32]u8, bundle.codes.len);
    code_hashes[0] = @splat(0);
    for (bundle.codes[1..], 1..) |code, idx| {
        code_hashes[idx] = if (code.len > 0) try db.set_code(code) else @as([32]u8, @splat(0));
    }

    // Group lazy-load events by global tx ordinal (bi * 65536 + ti)
    const TxKey = u64;
    var acc_by_tx: std.AutoHashMapUnmanaged(TxKey, std.ArrayList(usize)) = .empty;
    defer {
        var it = acc_by_tx.valueIterator();
        while (it.next()) |l| l.deinit(allocator);
        acc_by_tx.deinit(allocator);
    }
    var slot_by_tx: std.AutoHashMapUnmanaged(TxKey, std.ArrayList(usize)) = .empty;
    defer {
        var it = slot_by_tx.valueIterator();
        while (it.next()) |l| l.deinit(allocator);
        slot_by_tx.deinit(allocator);
    }

    var true_accounts: std.ArrayList(PreAccount) = .empty;
    var true_slots: std.ArrayList(StorageSlot) = .empty;

    for (bundle.accounts, 0..) |acc, idx| {
        if (acc.exact_pre_start or (acc.first_block == 0 and acc.first_tx == 0)) {
            if (acc.balance != 0 or acc.nonce != 0 or acc.code_id != 0) {
                try insertPreAccount(&db, bundle.codes, code_hashes, acc);
                try true_accounts.append(allocator, acc);
            }
        } else {
            const key: TxKey = (@as(u64, acc.first_block) << 32) | acc.first_tx;
            const gop = try acc_by_tx.getOrPut(allocator, key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, idx);
        }
    }

    for (bundle.slots, 0..) |sl, idx| {
        if (sl.first_block == 0 and sl.first_tx == 0) {
            if (sl.val != 0) {
                try db.set_storage(sl.addr, sl.slot, sl.val);
                try true_slots.append(allocator, sl);
            }
        } else {
            const key: TxKey = (@as(u64, sl.first_block) << 32) | sl.first_tx;
            const gop = try slot_by_tx.getOrPut(allocator, key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, idx);
        }
    }

    const eips = evm.Eips{ .hardfork = .OSAKA };
    var block_hashes: [256][32]u8 = bundle.ancestor_hashes;
    vm.database = &db;

    for (bundle.blocks, 0..) |blk, bi| {
        if (bi > 0) {
            std.mem.copyBackwards([32]u8, block_hashes[1..], block_hashes[0..255]);
            block_hashes[0] = blk.parent_hash;
        }
        vm.block_info = .{
            .chain_id = bundle.chain_id,
            .number = blk.number,
            .parent_hash = blk.parent_hash,
            .timestamp = blk.timestamp,
            .difficulty = 0,
            .gas_limit = blk.gas_limit,
            .coinbase = blk.coinbase,
            .base_fee = blk.base_fee,
            .prev_randao = blk.prev_randao,
            .blob_base_fee = blk.blob_base_fee,
            .excess_blob_gas = blk.excess_blob_gas,
            .blob_gas_used = blk.blob_gas_used,
            .block_hashes = &block_hashes,
            .beacon_root = blk.beacon_root,
        };
        vm.context = .{
            .gas_limit = blk.gas_limit,
            .coinbase = blk.coinbase,
            .chain_id = bundle.chain_id,
            .blob_base_fee = blk.blob_base_fee,
        };
        if (blk.beacon_root) |root| try runSystemCall(vm, BEACON_ROOTS_ADDRESS, &root);
        try runSystemCall(vm, HISTORY_STORAGE_ADDRESS, &blk.parent_hash);

        for (blk.txs, 0..) |tx, ti| {
            const key: TxKey = (@as(u64, @intCast(bi)) << 32) | @as(u32, @intCast(ti));
            if (acc_by_tx.get(key)) |idxs| {
                for (idxs.items) |acc_idx| {
                    const acc = bundle.accounts[acc_idx];
                    // If account is NOT in db yet, it existed before block start (not created mid-window).
                    if ((try db.get_account(acc.address)) == null) {
                        if (acc.balance != 0 or acc.nonce != 0 or acc.code_id != 0) {
                            try insertPreAccount(&db, bundle.codes, code_hashes, acc);
                            try true_accounts.append(allocator, acc);
                        }
                    }
                }
            }
            if (slot_by_tx.get(key)) |idxs| {
                for (idxs.items) |sl_idx| {
                    const sl = bundle.slots[sl_idx];
                    // If slot is still 0 in db, load its true pre-block value.
                    if ((try db.get_storage(sl.addr, sl.slot)) == 0 and sl.val != 0) {
                        try db.set_storage(sl.addr, sl.slot, sl.val);
                        try true_slots.append(allocator, sl);
                    }
                }
            }
            _ = try executeOneTx(allocator, &db, vm, eips, bundle.chain_id, &blk, &tx);
        }

        for (blk.withdrawals) |w| {
            if (w.amount_wei == 0) continue;
            var acc = (try db.get_account(w.address.bytes)) orelse Account.zero();
            acc.balance += w.amount_wei;
            try db.set_account(w.address.bytes, acc);
        }
    }

    return .{
        .code_hashes = code_hashes,
        .accounts = try true_accounts.toOwnedSlice(allocator),
        .slots = try true_slots.toOwnedSlice(allocator),
    };
}

fn replayAllBlocks(
    io: std.Io,
    allocator: std.mem.Allocator,
    db: *evm.Database,
    vm: *EvmType,
    bundle: *const Bundle,
    log_mismatches: usize,
) !ReplayStats {
    const eips = evm.Eips{ .hardfork = .OSAKA };
    var block_hashes: [256][32]u8 = bundle.ancestor_hashes;

    var status_matches: usize = 0;
    var gas_matches: usize = 0;
    var exact_matches: usize = 0;
    var tx_count: usize = 0;
    var actual_gas_total: u64 = 0;
    var expected_gas_total: u64 = 0;
    var logged: usize = 0;

    var err_buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &err_buf);

    const t0 = nowNs(io);

    for (bundle.blocks, 0..) |blk, bi| {
        if (bi > 0) {
            std.mem.copyBackwards([32]u8, block_hashes[1..], block_hashes[0..255]);
            block_hashes[0] = blk.parent_hash;
        }

        vm.block_info = .{
            .chain_id = bundle.chain_id,
            .number = blk.number,
            .parent_hash = blk.parent_hash,
            .timestamp = blk.timestamp,
            .difficulty = 0,
            .gas_limit = blk.gas_limit,
            .coinbase = blk.coinbase,
            .base_fee = blk.base_fee,
            .prev_randao = blk.prev_randao,
            .blob_base_fee = blk.blob_base_fee,
            .excess_blob_gas = blk.excess_blob_gas,
            .blob_gas_used = blk.blob_gas_used,
            .block_hashes = &block_hashes,
            .beacon_root = blk.beacon_root,
        };
        vm.context = .{
            .gas_limit = blk.gas_limit,
            .coinbase = blk.coinbase,
            .chain_id = bundle.chain_id,
            .blob_base_fee = blk.blob_base_fee,
        };

        if (blk.beacon_root) |root| try runSystemCall(vm, BEACON_ROOTS_ADDRESS, &root);
        try runSystemCall(vm, HISTORY_STORAGE_ADDRESS, &blk.parent_hash);

        for (blk.txs, 0..) |tx, ti| {
            const r = try executeOneTx(allocator, db, vm, eips, bundle.chain_id, &blk, &tx);

            tx_count += 1;
            actual_gas_total += r.gas_used;
            expected_gas_total += tx.expected_gas_used;
            const s_ok = r.success == tx.expected_status;
            const g_ok = r.gas_used == tx.expected_gas_used;
            if (s_ok) status_matches += 1;
            if (g_ok) gas_matches += 1;
            if (s_ok and g_ok) {
                exact_matches += 1;
            } else if (logged < log_mismatches) {
                logged += 1;
                stderr.interface.print(
                    "  mismatch block={d} tx={d} type={d} status={}/{} gas={d}/{d} diff={d}\n",
                    .{ blk.number, ti, tx.tx_type, r.success, tx.expected_status, r.gas_used, tx.expected_gas_used, @as(i64, @intCast(r.gas_used)) - @as(i64, @intCast(tx.expected_gas_used)) },
                ) catch {};
                stderr.interface.flush() catch {};
            }
        }

        for (blk.withdrawals) |w| {
            if (w.amount_wei == 0) continue;
            var acc = (try db.get_account(w.address.bytes)) orelse Account.zero();
            acc.balance += w.amount_wei;
            try db.set_account(w.address.bytes, acc);
        }
    }

    const elapsed_ns = nowNs(io) -| t0;
    return .{
        .elapsed_ns = elapsed_ns,
        .tx_count = tx_count,
        .status_matches = status_matches,
        .gas_matches = gas_matches,
        .exact_matches = exact_matches,
        .actual_gas_total = actual_gas_total,
        .expected_gas_total = expected_gas_total,
    };
}

pub fn main(init: std.process.Init) void {
    runMain(init.io, init.minimal.args) catch |err| {
        var buf: [4096]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(init.io, &buf);
        stderr.interface.print("guillotine-bench-blocks: {s}\n", .{@errorName(err)}) catch std.process.exit(2);
        stderr.interface.flush() catch std.process.exit(2);
        std.process.exit(1);
    };
}

const WorkerCtx = struct {
    io: std.Io,
    opts: CliOpts,
    bundle: *const Bundle,
    err: ?anyerror = null,
};

fn workerEntry(ctx: *WorkerCtx) void {
    runBenchOnLargeStack(ctx.io, ctx.opts, ctx.bundle) catch |err| {
        ctx.err = err;
    };
}

fn runBenchOnLargeStack(io: std.Io, opts: CliOpts, bundle: *const Bundle) !void {
    const allocator = std.heap.smp_allocator;
    var dummy_db = evm.Database.init(allocator);
    defer dummy_db.deinit();

    // Separate discovery VM so cold run measures genuine cold DispatchCache!
    const disc_vm = try allocator.create(EvmType);
    defer allocator.destroy(disc_vm);
    disc_vm.* = try EvmType.init(
        allocator,
        &dummy_db,
        .{
            .chain_id = bundle.chain_id,
            .number = bundle.start_block,
            .timestamp = bundle.blocks[0].timestamp,
            .difficulty = 0,
            .gas_limit = bundle.blocks[0].gas_limit,
            .coinbase = bundle.blocks[0].coinbase,
            .base_fee = bundle.blocks[0].base_fee,
            .prev_randao = bundle.blocks[0].prev_randao,
        },
        .{ .gas_limit = bundle.blocks[0].gas_limit, .coinbase = bundle.blocks[0].coinbase, .chain_id = bundle.chain_id },
        0,
        voltaire.ZERO_ADDRESS,
    );
    defer disc_vm.deinit();

    const true_pre = try discoverTruePrestate(allocator, bundle, disc_vm);
    defer allocator.free(true_pre.code_hashes);
    defer allocator.free(true_pre.accounts);
    defer allocator.free(true_pre.slots);

    // Benchmark VM (starts cold on first warmup/run, warms DispatchCache across runs)
    const vm = try allocator.create(EvmType);
    defer allocator.destroy(vm);
    vm.* = try EvmType.init(
        allocator,
        &dummy_db,
        .{
            .chain_id = bundle.chain_id,
            .number = bundle.start_block,
            .timestamp = bundle.blocks[0].timestamp,
            .difficulty = 0,
            .gas_limit = bundle.blocks[0].gas_limit,
            .coinbase = bundle.blocks[0].coinbase,
            .base_fee = bundle.blocks[0].base_fee,
            .prev_randao = bundle.blocks[0].prev_randao,
        },
        .{ .gas_limit = bundle.blocks[0].gas_limit, .coinbase = bundle.blocks[0].coinbase, .chain_id = bundle.chain_id },
        0,
        voltaire.ZERO_ADDRESS,
    );
    defer vm.deinit();

    var out_buf: [16384]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout.interface;

    var cold_stats: ReplayStats = undefined;
    var have_cold = false;

    for (0..opts.warmup) |w| {
        var db = evm.Database.init(allocator);
        defer db.deinit();
        try populateFromTruePrestate(&db, bundle, &true_pre);
        vm.database = &db;
        const st = try replayAllBlocks(io, allocator, &db, vm, bundle, if (w == 0) opts.verbose_mismatches else 0);
        if (w == 0) {
            cold_stats = st;
            have_cold = true;
        }
        vm.database = &dummy_db;
    }

    var times_ns = try allocator.alloc(u64, opts.iterations);
    defer allocator.free(times_ns);
    var last_stats: ReplayStats = undefined;

    for (0..opts.iterations) |iter| {
        var db = evm.Database.init(allocator);
        defer db.deinit();
        try populateFromTruePrestate(&db, bundle, &true_pre);
        vm.database = &db;
        const st = try replayAllBlocks(io, allocator, &db, vm, bundle, if (!have_cold and iter == 0) opts.verbose_mismatches else 0);
        times_ns[iter] = st.elapsed_ns;
        last_stats = st;
        vm.database = &dummy_db;
    }

    std.mem.sort(u64, times_ns, {}, std.sort.asc(u64));
    const median_ns = times_ns[times_ns.len / 2];
    var sum_ns: u128 = 0;
    for (times_ns) |t| sum_ns += t;
    const mean_ns: f64 = @as(f64, @floatFromInt(sum_ns)) / @as(f64, @floatFromInt(times_ns.len));
    const median_ms: f64 = @as(f64, @floatFromInt(median_ns)) / 1_000_000.0;
    const mean_ms: f64 = mean_ns / 1_000_000.0;
    const min_ms: f64 = @as(f64, @floatFromInt(times_ns[0])) / 1_000_000.0;
    const cold_ms: f64 = if (have_cold) @as(f64, @floatFromInt(cold_stats.elapsed_ns)) / 1_000_000.0 else median_ms;
    const ms_per_block: f64 = median_ms / @as(f64, @floatFromInt(bundle.blocks.len));
    const mgas_per_sec: f64 = (@as(f64, @floatFromInt(last_stats.actual_gas_total)) * 1_000.0) / @as(f64, @floatFromInt(median_ns));
    const txs_per_sec: f64 = (@as(f64, @floatFromInt(last_stats.tx_count)) * 1_000_000_000.0) / @as(f64, @floatFromInt(median_ns));

    try out.print("DispatchCache: hits={d} misses={d} evictions={d} bytes={d}\n", .{
        vm.dispatch_cache.hits,
        vm.dispatch_cache.misses,
        vm.dispatch_cache.evictions,
        vm.dispatch_cache.bytes,
    });
    try out.print(
        \\=== Guillotine 100-Block Ethereum Mainnet Replay ===
        \\Range:        {d}..{d} ({d} blocks, Osaka)
        \\Pre-state:    {d} true pre-start accounts (filtered from {d}), {d} slots, {d} contracts
        \\Transactions: {d} (exact status+gas match: {d}/{d}, status: {d}/{d}, gas: {d}/{d})
        \\Total gas:    {d} (expected mainnet: {d})
        \\Cold run:     {d:.2} ms ({d:.2} MGas/s)
        \\Warm median:  {d:.2} ms ({d:.2} ms/block, {d:.2} MGas/s, {d:.0} tx/s)
        \\Warm mean:    {d:.2} ms (min: {d:.2} ms, iters={d}, warmup={d})
        \\
    , .{
        bundle.start_block,
        bundle.end_block,
        bundle.blocks.len,
        true_pre.accounts.len,
        bundle.accounts.len,
        true_pre.slots.len,
        bundle.codes.len - 1,
        last_stats.tx_count,
        last_stats.exact_matches,
        last_stats.tx_count,
        last_stats.status_matches,
        last_stats.tx_count,
        last_stats.gas_matches,
        last_stats.tx_count,
        last_stats.actual_gas_total,
        last_stats.expected_gas_total,
        cold_ms,
        (@as(f64, @floatFromInt(last_stats.actual_gas_total)) * 1_000.0) / @as(f64, @floatFromInt(if (have_cold) cold_stats.elapsed_ns else median_ns)),
        median_ms,
        ms_per_block,
        mgas_per_sec,
        txs_per_sec,
        mean_ms,
        min_ms,
        opts.iterations,
        opts.warmup,
    });
    try out.flush();

    if (opts.json_out) |path| {
        const json_data = try std.fmt.allocPrint(
            allocator,
            "{{\"start_block\":{d},\"end_block\":{d},\"blocks\":{d},\"transactions\":{d},\"exact_matches\":{d},\"status_matches\":{d},\"gas_matches\":{d},\"actual_gas_total\":{d},\"expected_gas_total\":{d},\"cold_ms\":{d:.2},\"warm_median_ms\":{d:.2},\"warm_mean_ms\":{d:.2},\"warm_min_ms\":{d:.2},\"ms_per_block\":{d:.2},\"mgas_per_sec\":{d:.2},\"txs_per_sec\":{d:.1}}}\n",
            .{
                bundle.start_block,
                bundle.end_block,
                bundle.blocks.len,
                last_stats.tx_count,
                last_stats.exact_matches,
                last_stats.status_matches,
                last_stats.gas_matches,
                last_stats.actual_gas_total,
                last_stats.expected_gas_total,
                cold_ms,
                median_ms,
                mean_ms,
                min_ms,
                ms_per_block,
                mgas_per_sec,
                txs_per_sec,
            },
        );
        defer allocator.free(json_data);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json_data });
    }
}

fn runMain(io: std.Io, process_args: std.process.Args) !void {
    if (builtin.mode != .fast) return error.ReleaseFastRequired;
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const args = try process_args.toSlice(arena.allocator());
    const opts = try parseCli(args);

    const bundle = try loadBundle(arena.allocator(), io, opts);
    var ctx = WorkerCtx{ .io = io, .opts = opts, .bundle = &bundle };
    const thread = try std.Thread.spawn(.{ .stack_size = 32 * 1024 * 1024 }, workerEntry, .{&ctx});
    thread.join();
    if (ctx.err) |err| return err;
}
