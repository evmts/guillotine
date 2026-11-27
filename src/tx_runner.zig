//! First-class Ethereum transaction and block-envelope runner for Guillotine.
//!
//! Encapsulates full transaction execution semantics (Legacy, EIP-2930, EIP-1559,
//! EIP-4844, EIP-7702) over any `Evm(config)` specialization — including custom
//! `EvmConfig.DatabaseType` implementations — so downstream clients, RPC nodes,
//! FFI consumers, and block runners share one verified implementation.

const std = @import("std");
const primitives = @import("voltaire");
const precompiles = @import("precompiles");
const Account = @import("storage/database_interface_account.zig").Account;
const eips_mod = @import("eips_and_hardforks/eips.zig");
const AuthorizationProcessorFor = @import("eips_and_hardforks/authorization_processor.zig").AuthorizationProcessorFor;
const call_result_mod = @import("frame/call_result.zig");

const Address = primitives.Address;
const Authorization = primitives.Authorization.Authorization;

pub const SYSTEM_ADDRESS = Address{
    .bytes = .{
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe,
    },
};

pub const AccessListEntry = struct {
    address: Address,
    storage_keys: []const u256 = &.{},
};

pub const Withdrawal = struct {
    address: Address,
    amount_wei: u256,
};

pub const Transaction = struct {
    tx_type: u8 = 0,
    from: Address,
    to: ?Address = null,
    nonce: ?u64 = null,
    gas_limit: u64,
    gas_price: u256 = 0,
    max_fee_per_gas: ?u256 = null,
    max_priority_fee_per_gas: u256 = 0,
    value: u256 = 0,
    input: []const u8 = &.{},
    access_list: []const AccessListEntry = &.{},
    blob_hashes: []const [32]u8 = &.{},
    authorizations: []const Authorization = &.{},
    /// When true, skips sender balance deduction (useful for eth_call / simulations).
    disable_balance_check: bool = false,
};

pub const TxResult = struct {
    success: bool,
    gas_used: u64,
    gas_left: u64,
    effective_gas_price: u256,
    refund: u64,
    output: []const u8,
    created_address: ?Address = null,
    logs: []const call_result_mod.Log = &.{},

    pub fn deinit(self: *TxResult, allocator: std.mem.Allocator) void {
        if (self.output.len > 0) allocator.free(self.output);
        for (self.logs) |entry| {
            if (entry.topics.len > 0) allocator.free(entry.topics);
            if (entry.data.len > 0) allocator.free(entry.data);
        }
        if (self.logs.len > 0) allocator.free(self.logs);
        self.* = undefined;
    }
};

pub const TxError = error{
    GasLimitExceedsCap,
    GasBelowIntrinsic,
    GasLimitExceedsBlock,
    MaxFeeBelowBaseFee,
    PriorityFeeExceedsMaxFee,
    InsufficientBalance,
    NonceMismatch,
    NonceOverflow,
    InitcodeTooLarge,
    HostFailure,
    OutOfMemory,
};

/// Compute effective EIP-1559 or legacy gas price with EIP-1559 fee validation.
pub fn computeEffectiveGasPrice(tx: Transaction, base_fee: u256) TxError!u256 {
    const max_fee = tx.max_fee_per_gas orelse return tx.gas_price;
    if (tx.max_priority_fee_per_gas > max_fee) return error.PriorityFeeExceedsMaxFee;
    if (max_fee < base_fee) return error.MaxFeeBelowBaseFee;
    const cap = std.math.add(u256, base_fee, tx.max_priority_fee_per_gas) catch max_fee;
    return @min(max_fee, cap);
}

/// Compute intrinsic gas cost and EIP-7623 calldata floor for a transaction.
pub fn computeGasSchedule(eips: eips_mod.Eips, tx: Transaction) struct { intrinsic: u64, floor: u64 } {
    const is_create = tx.to == null;
    const tokens = eips.tokens_in_calldata(tx.input);
    var list_gas: u128 = 0;
    for (tx.access_list) |entry| {
        list_gas += 2400 + @as(u128, entry.storage_keys.len) * 1900;
    }
    list_gas += @as(u128, tx.authorizations.len) * 25_000;
    const intrinsic_wide: u128 = @as(u128, eips.intrinsic_gas_cost(is_create)) +
        @as(u128, eips.calldata_gas_cost(tokens, is_create, tx.input.len)) + list_gas;
    const intrinsic: u64 = if (intrinsic_wide > std.math.maxInt(u64))
        std.math.maxInt(u64)
    else
        @intCast(intrinsic_wide);
    return .{ .intrinsic = intrinsic, .floor = eips.floor_gas_cost(tokens) };
}

fn prewarmTransaction(comptime EvmType: type, vm: *EvmType, eips: eips_mod.Eips, tx: Transaction) !void {
    const hardfork = eips.hardfork;
    try eips.pre_warm_transaction_addresses(&vm.access_list, tx.from, tx.to, vm.block_info.coinbase);
    const last_precompile = precompiles.lastContiguousPrecompile(hardfork);
    var addr_id: u16 = 0x01;
    while (addr_id <= last_precompile) : (addr_id += 1) {
        try vm.access_list.pre_warm_addresses(&[_]Address{Address.fromU256(addr_id)});
    }
    if (hardfork.isAtLeast(.OSAKA)) {
        try vm.access_list.pre_warm_addresses(&[_]Address{precompiles.P256VERIFY_ADDRESS});
    }
    for (tx.access_list) |entry| {
        try vm.access_list.pre_warm_addresses(&[_]Address{entry.address});
        for (entry.storage_keys) |slot| _ = try vm.access_list.access_storage_slot(entry.address, slot);
    }
}

fn cloneLogs(allocator: std.mem.Allocator, logs: []const call_result_mod.Log) ![]call_result_mod.Log {
    if (logs.len == 0) return &.{};
    const out = try allocator.alloc(call_result_mod.Log, logs.len);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |entry| {
            if (entry.topics.len > 0) allocator.free(entry.topics);
            if (entry.data.len > 0) allocator.free(entry.data);
        }
        allocator.free(out);
    }
    for (logs, 0..) |entry, idx| {
        const topics = if (entry.topics.len > 0) try allocator.dupe(u256, entry.topics) else &.{};
        errdefer if (topics.len > 0) allocator.free(topics);
        const data = if (entry.data.len > 0) try allocator.dupe(u8, entry.data) else &.{};
        out[idx] = .{ .address = entry.address, .topics = topics, .data = data };
        copied += 1;
    }
    return out;
}

/// Validate and execute a full Ethereum transaction on `vm`, committing state changes
/// and returning an owned `TxResult`. Caller must call `result.deinit(allocator)`.
pub fn executeTx(
    comptime EvmType: type,
    allocator: std.mem.Allocator,
    vm: *EvmType,
    tx: Transaction,
) TxError!TxResult {
    const hardfork = EvmType.Frame.config.hardfork;
    const eips = eips_mod.Eips{ .hardfork = hardfork };
    eips.validate_transaction_gas_limit(tx.gas_limit) catch return error.GasLimitExceedsCap;
    if (tx.to == null and hardfork.isAtLeast(.SHANGHAI) and tx.input.len > primitives.GasConstants.MaxInitcodeSize) {
        return error.InitcodeTooLarge;
    }

    const effective_price = try computeEffectiveGasPrice(tx, vm.block_info.base_fee);
    const schedule = computeGasSchedule(eips, tx);
    if (tx.gas_limit < schedule.intrinsic) return error.GasBelowIntrinsic;

    vm.resetForTx();
    const db = vm.database;
    var sender = (db.get_account(tx.from.bytes) catch return error.HostFailure) orelse Account.zero();
    if (tx.nonce) |expected| {
        if (sender.nonce != expected) return error.NonceMismatch;
    }
    const next_nonce = std.math.add(u64, sender.nonce, 1) catch return error.NonceOverflow;

    const blob_fee: u256 = @as(u256, tx.blob_hashes.len) * 131_072 * @as(u256, vm.block_info.blob_base_fee);
    const max_price = tx.max_fee_per_gas orelse effective_price;
    const max_upfront = @as(u256, tx.gas_limit) * max_price + blob_fee + tx.value;
    const actual_upfront = @as(u256, tx.gas_limit) * effective_price + blob_fee;
    if (!tx.disable_balance_check and sender.balance < max_upfront) return error.InsufficientBalance;

    if (!tx.disable_balance_check) sender.balance -= actual_upfront;
    sender.nonce = next_nonce;
    db.set_account(tx.from.bytes, sender) catch return error.HostFailure;

    configureVmContext(EvmType, vm, tx, effective_price);
    prewarmTransaction(EvmType, vm, eips, tx) catch return error.HostFailure;
    const auth_refund = try processAuthorizations(EvmType, allocator, vm, eips, tx);
    if (tx.to) |to| vm.warmDelegatedTarget(to) catch return error.HostFailure;

    const exec_gas = tx.gas_limit - schedule.intrinsic;
    const call_res = runInnerMessage(EvmType, vm, tx, exec_gas);
    if (vm.host_failure != null) return error.HostFailure;

    const settled = try settlePostExecution(
        EvmType,
        vm,
        tx,
        effective_price,
        schedule.floor,
        auth_refund,
        call_res.success,
        call_res.gas_left,
    );
    const owned_output = if (call_res.output.len > 0) try allocator.dupe(u8, call_res.output) else &.{};
    errdefer if (owned_output.len > 0) allocator.free(owned_output);
    const owned_logs = if (call_res.success) try cloneLogs(allocator, vm.logs.items) else &.{};

    return TxResult{
        .success = call_res.success,
        .gas_used = settled.gas_used,
        .gas_left = tx.gas_limit - settled.gas_used,
        .effective_gas_price = effective_price,
        .refund = settled.refund,
        .output = owned_output,
        .created_address = if (call_res.success) call_res.created_address else null,
        .logs = owned_logs,
    };
}

fn configureVmContext(comptime EvmType: type, vm: *EvmType, tx: Transaction, effective_price: u256) void {
    vm.origin = tx.from;
    vm.gas_price = effective_price;
    vm.context.gas_limit = tx.gas_limit;
    vm.context.blob_versioned_hashes = tx.blob_hashes;
    vm.context.is_blob_transaction = tx.tx_type == 3;
    vm.context.max_fee_per_gas = tx.max_fee_per_gas;
    vm.context.max_priority_fee_per_gas = tx.max_priority_fee_per_gas;
}

fn processAuthorizations(
    comptime EvmType: type,
    allocator: std.mem.Allocator,
    vm: *EvmType,
    eips: eips_mod.Eips,
    tx: Transaction,
) TxError!u64 {
    if (tx.authorizations.len == 0) return 0;
    if (comptime EvmType.Db != @import("storage/database.zig").Database) return 0;
    var unmetered: i64 = std.math.maxInt(i64);
    const AuthProc = AuthorizationProcessorFor(EvmType.Db);
    var proc = AuthProc{
        .db = vm.database,
        .chain_id = vm.block_info.chain_id,
        .gas_remaining = &unmetered,
        .eips = eips,
    };
    var applied = proc.processAuthorizationListWithResults(allocator, tx.authorizations) catch return error.HostFailure;
    defer applied.deinit(allocator);
    for (applied.results) |res| {
        if (res.authority) |authority| {
            vm.access_list.pre_warm_addresses(&[_]Address{authority}) catch return error.HostFailure;
        }
    }
    return if (applied.refund > 0) @intCast(applied.refund) else 0;
}

fn runInnerMessage(comptime EvmType: type, vm: *EvmType, tx: Transaction, exec_gas: u64) EvmType.CallResult {
    if (tx.to) |to| {
        return vm.inner_call(.{ .call = .{
            .caller = tx.from,
            .to = to,
            .value = tx.value,
            .input = tx.input,
            .gas = exec_gas,
        } });
    }
    vm.tx_sender_nonce_incremented = true;
    return vm.inner_call(.{ .create = .{
        .caller = tx.from,
        .value = tx.value,
        .init_code = tx.input,
        .gas = exec_gas,
    } });
}

fn settlePostExecution(
    comptime EvmType: type,
    vm: *EvmType,
    tx: Transaction,
    effective_price: u256,
    floor: u64,
    auth_refund: u64,
    success: bool,
    gas_left: u64,
) TxError!struct { gas_used: u64, refund: u64 } {
    const db = vm.database;
    const raw_used = tx.gas_limit -| gas_left;
    const raw_refund = auth_refund + if (success) vm.gas_refund_counter else 0;
    const max_refund = raw_used / 5;
    const applied_refund = @min(raw_refund, max_refund);
    const gas_used = @max(raw_used - applied_refund, floor);

    if (!tx.disable_balance_check) {
        var sender = (db.get_account(tx.from.bytes) catch return error.HostFailure) orelse Account.zero();
        sender.balance += @as(u256, tx.gas_limit - gas_used) * effective_price;
        db.set_account(tx.from.bytes, sender) catch return error.HostFailure;

        const tip: u256 = effective_price -| @as(u256, vm.block_info.base_fee);
        if (tip > 0 and gas_used > 0) {
            var cb = (db.get_account(vm.block_info.coinbase.bytes) catch return error.HostFailure) orelse
                Account.zero();
            cb.balance += @as(u256, gas_used) * tip;
            db.set_account(vm.block_info.coinbase.bytes, cb) catch return error.HostFailure;
        }
    }

    if (success and vm.self_destruct.count() > 0) {
        var it = vm.self_destruct.iterator();
        while (it.next()) |entry| {
            db.delete_account(entry.key_ptr.bytes) catch return error.HostFailure;
        }
    }
    return .{ .gas_used = gas_used, .refund = applied_refund };
}

/// Execute a protocol system call (EIP-4788, EIP-2935, EIP-7002, EIP-7251) from `SYSTEM_ADDRESS`.
pub fn runSystemCall(comptime EvmType: type, vm: *EvmType, target: Address, input: []const u8) TxError!void {
    const acc = (vm.database.get_account(target.bytes) catch return error.HostFailure) orelse return;
    if (std.mem.allEqual(u8, &acc.code_hash, 0) or
        std.mem.eql(u8, &acc.code_hash, &primitives.EMPTY_CODE_HASH)) return;
    vm.resetForTx();
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
    if (vm.host_failure != null) return error.HostFailure;
    vm.resetForTx();
}

/// Apply EIP-4895 post-block validator withdrawals directly to `database`.
pub fn applyWithdrawals(database: anytype, withdrawals: []const Withdrawal) TxError!void {
    for (withdrawals) |w| {
        if (w.amount_wei == 0) continue;
        var acc = (database.get_account(w.address.bytes) catch return error.HostFailure) orelse Account.zero();
        acc.balance += w.amount_wei;
        database.set_account(w.address.bytes, acc) catch return error.HostFailure;
    }
}

const testing = std.testing;

test "tx_runner computes effective EIP-1559 gas price and rejects invalid caps" {
    try testing.expectEqual(@as(u256, 15), try computeEffectiveGasPrice(.{
        .from = primitives.ZERO_ADDRESS,
        .gas_limit = 21_000,
        .max_fee_per_gas = 20,
        .max_priority_fee_per_gas = 5,
    }, 10));
    try testing.expectEqual(@as(u256, 12), try computeEffectiveGasPrice(.{
        .from = primitives.ZERO_ADDRESS,
        .gas_limit = 21_000,
        .max_fee_per_gas = 12,
        .max_priority_fee_per_gas = 5,
    }, 10));
    try testing.expectError(error.MaxFeeBelowBaseFee, computeEffectiveGasPrice(.{
        .from = primitives.ZERO_ADDRESS,
        .gas_limit = 21_000,
        .max_fee_per_gas = 9,
        .max_priority_fee_per_gas = 1,
    }, 10));
    try testing.expectError(error.PriorityFeeExceedsMaxFee, computeEffectiveGasPrice(.{
        .from = primitives.ZERO_ADDRESS,
        .gas_limit = 21_000,
        .max_fee_per_gas = 10,
        .max_priority_fee_per_gas = 11,
    }, 10));
}

test "tx_runner computes Osaka intrinsic gas and EIP-7623 floor" {
    const eips = eips_mod.Eips{ .hardfork = .OSAKA };
    const calldata: [100]u8 = @splat(0xAB);
    const sched = computeGasSchedule(eips, .{
        .from = primitives.ZERO_ADDRESS,
        .to = Address.fromU256(1),
        .gas_limit = 100_000,
        .input = &calldata,
    });
    try testing.expectEqual(@as(u64, 21_000 + 100 * 16), sched.intrinsic);
    try testing.expectEqual(@as(u64, 21_000 + 400 * 10), sched.floor);
}
