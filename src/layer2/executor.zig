//! Transaction boundary for an OP Stack execution host.
//! The host owns state and checkpoints. executeFrame must execute value transfer
//! and ordinary transaction/CREATE nonce handling, but MUST NOT charge fees.
//! CALL deposit nonce increments are performed here and must not be repeated. It returns EVM failures as Outcome;
//! infrastructure errors propagate. An invalid user transaction (e.g. below intrinsic
//! gas) must be an error; an invalid deposit is `Result.invalid` (a failed deposit
//! on every spec, Bedrock included, where a frame halt is not). The frame's
//! GASPRICE is `gasPrice(tx)`. configure installs ALL nested-call precompile
//! overrides from optimism/precompiles.zig, not merely top-level input checks.
const std = @import("std");
const fees = @import("base/fees.zig");
const deposits = @import("optimism/deposit.zig");
const transaction = @import("optimism/transaction.zig");
const constants = @import("optimism/constants.zig");
pub const OpSpecId = @import("optimism/spec.zig").OpSpecId;
pub const Address = @import("voltaire").Address;
/// EIP-7702 authorization tuple. `v` is the y_parity (0 or 1), not 27 + y_parity.
pub const Authorization = @import("voltaire").Authorization.Authorization;

/// One EIP-2930 access list entry. Duplicate addresses and keys are allowed; each
/// occurrence costs intrinsic gas (EIP-2930).
pub const AccessListEntry = struct {
    address: Address,
    storage_keys: []const u256 = &.{},
};

/// EIP-2930 intrinsic gas per access list address.
pub const ACCESS_LIST_ADDRESS_COST: u64 = 2_400;
/// EIP-2930 intrinsic gas per access list storage key.
pub const ACCESS_LIST_STORAGE_KEY_COST: u64 = 1_900;
/// EIP-7702 PER_EMPTY_ACCOUNT_COST: intrinsic gas per authorization tuple.
pub const AUTHORIZATION_COST: u64 = 25_000;
/// Fee fields of a user transaction. Deposits carry no gas price (use `.legacy = 0`).
pub const Fee = union(enum) {
    /// Legacy (0x00) and EIP-2930 (0x01): one gas price that is both cap and price.
    legacy: u256,
    /// EIP-1559 (0x02) and EIP-7702 (0x04) dynamic fee fields.
    dynamic: struct { max_fee_per_gas: u256, max_priority_fee_per_gas: u256 },

    /// Highest price per gas the sender may pay; the balance check reserves it.
    pub fn cap(self: Fee) u256 {
        return switch (self) {
            .legacy => |price| price,
            .dynamic => |d| d.max_fee_per_gas,
        };
    }

    /// Price per gas actually charged: min(max_fee, base_fee + max_priority_fee).
    /// Rejects a cap below the base fee and a tip above the cap
    /// (revm `validate_priority_fee_tx`, geth `ErrTipAboveFeeCap`/`ErrFeeCapTooLow`).
    pub fn effectiveGasPrice(
        self: Fee,
        base_fee: u256,
    ) error{ GasPriceBelowBaseFee, PriorityFeeGreaterThanMaxFee }!u256 {
        switch (self) {
            .legacy => |price| {
                if (price < base_fee) return error.GasPriceBelowBaseFee;
                return price;
            },
            .dynamic => |d| {
                if (d.max_priority_fee_per_gas > d.max_fee_per_gas) return error.PriorityFeeGreaterThanMaxFee;
                if (d.max_fee_per_gas < base_fee) return error.GasPriceBelowBaseFee;
                // Saturation is exact here: the result is capped by max_fee_per_gas.
                return @min(d.max_fee_per_gas, base_fee +| d.max_priority_fee_per_gas);
            },
        }
    }
};

pub const Transaction = struct {
    sender: Address,
    envelope: []const u8,
    gas_limit: u64,
    fee: Fee = .{ .legacy = 0 },
    base_fee: u256,
    value: u256 = 0,
    /// Sender nonce carried by the transaction. Ignored for deposits, which have none.
    nonce: u64 = 0,
    /// CALL target; null for CREATE. Must agree with `is_call`.
    to: ?Address = null,
    /// Calldata for CALL, init code for CREATE.
    input: []const u8 = &.{},
    is_call: bool = true,
    deposit: ?transaction.DepositTransactionParts = null,
    /// EIP-2930 access list. Types 0x01, 0x02 and 0x04 only.
    access_list: []const AccessListEntry = &.{},
    /// EIP-7702 authorization list. Type 0x04 only, where it must be non-empty.
    authorization_list: []const Authorization = &.{},
};
pub const Result = struct {
    outcome: deposits.Outcome,
    gas_used: u64,
    /// Deposits only: the deposit failed transaction validation (intrinsic gas, init
    /// code size, value above balance) and did not execute. op-revm
    /// `catch_error_failed_deposit` includes it as a failed deposit on every spec;
    /// before Regolith that differs from a halt, which keeps the frame's nonce and gas.
    invalid: bool = false,
};

/// Price per gas the frame observes (GASPRICE) and pays: zero for deposits.
pub fn gasPrice(tx: Transaction) !u256 {
    if (tx.deposit != null) return 0;
    return tx.fee.effectiveGasPrice(tx.base_fee);
}

/// Host contract: checkpoint() !Token, rollback(Token) void, commit(Token) void,
/// caller(Address) !CallerState, setCaller(Address, CallerState) !void,
/// credit(Address,u256) !void, configure(OpSpecId) !void,
/// executeFrame(Transaction) !Result. rollback must be infallible and restore all
/// account/storage/log changes. A frame revert/halt must revert frame effects.
/// Configure must install the spec's Ethereum fork and OP precompile overrides.
/// Deposit envelopes must already be authenticated by the rollup derivation layer.
pub fn execute(host: anytype, info: fees.L1BlockInfo, spec: OpSpecId, tx: Transaction, coinbase: Address) !Result {
    if (tx.envelope.len == 0) return error.MissingEnvelope;
    const tx_type = try transaction.OpTxType.decode(tx.envelope, spec);
    if (tx_type.isDeposit() != (tx.deposit != null)) return error.DepositTypeMismatch;
    // `decode` already refused type 0x04 before Isthmus (OpTxType.isSupported).
    switch (tx_type) {
        .Legacy => if (tx.fee != .legacy) return error.FeeTypeMismatch,
        .Eip2930 => if (tx.fee != .legacy) return error.FeeTypeMismatch,
        .Eip1559 => if (tx.fee != .dynamic) return error.FeeTypeMismatch,
        .Eip7702 => {
            if (tx.fee != .dynamic) return error.FeeTypeMismatch;
            // EIP-7702: a set-code transaction has a non-empty list and a destination.
            if (tx.authorization_list.len == 0) return error.EmptyAuthorizationList;
            if (tx.to == null) return error.AuthorizationListCreate;
        },
        .Eip4844 => return error.TxTypeNotSupported,
        .Deposit => {},
    }
    // Legacy and deposit transactions have no access list field.
    if ((tx_type == .Legacy or tx_type == .Deposit) and tx.access_list.len != 0) return error.AccessListUnsupported;
    if (tx_type != .Eip7702 and tx.authorization_list.len != 0) return error.AuthorizationListUnsupported;
    if (tx.is_call != (tx.to != null)) return error.CallTargetMismatch;
    try host.configure(spec);
    const checkpoint = try host.checkpoint();
    var active = true;
    errdefer if (active) host.rollback(checkpoint);
    const before = try host.caller(tx.sender);
    var attributes = info;
    attributes.clearTxL1Cost();
    if (tx.deposit) |parts| {
        // op-revm `catch_error` and op-geth `StateTransition.execute`: a deposit that
        // fails validation (e.g. a Regolith+ system transaction) is still included as a
        // failed deposit: no execution, mint kept, nonce bumped, gas_limit used.
        deposits.validate(spec, parts) catch |err| switch (err) {
            error.DepositSystemTxPostRegolith => {
                try host.setCaller(tx.sender, deposits.failedDeposit(before, parts));
                host.commit(checkpoint);
                active = false;
                return .{ .outcome = .halt, .gas_used = deposits.failedDepositGasUsed(spec, parts, tx.gas_limit) };
            },
        };
        try host.setCaller(tx.sender, deposits.preExecution(before, parts, tx.is_call));
        const result = try host.executeFrame(tx);
        if (result.gas_used > tx.gas_limit) return error.GasUsedExceedsGasLimit;
        const final: deposits.DepositResult = if (result.invalid)
            .{ .gas_used = deposits.failedDepositGasUsed(spec, parts, tx.gas_limit), .failed = true }
        else
            deposits.finalize(spec, parts, result.outcome, tx.gas_limit, result.gas_used);
        if (final.failed) {
            host.rollback(checkpoint);
            active = false;
            const recovery = try host.checkpoint();
            errdefer host.rollback(recovery);
            try host.setCaller(tx.sender, deposits.failedDeposit(before, parts));
            host.commit(recovery);
            return .{ .outcome = result.outcome, .gas_used = final.gas_used };
        }
        host.commit(checkpoint);
        active = false;
        return .{ .outcome = result.outcome, .gas_used = final.gas_used };
    }
    const price = try tx.fee.effectiveGasPrice(tx.base_fee);
    // Nonce rules (revm `validate_against_state`, geth `preCheck`): exact match, and
    // EIP-2681 forbids a transaction from an account whose nonce is 2^64-1.
    if (tx.nonce > before.nonce) return error.NonceTooHigh;
    if (tx.nonce < before.nonce) return error.NonceTooLow;
    if (before.nonce == std.math.maxInt(u64)) return error.NonceOverflow;
    // op-revm `validate_against_state_and_deduct_caller`: the balance must cover the
    // L1 data fee and operator fee (at gas_limit) plus gas_limit * max_fee + value;
    // the debit uses the effective gas price. Wide arithmetic rejects instead of saturating.
    const extra = try attributes.txCost(tx.envelope, tx.gas_limit, spec);
    const reserved = @as(u512, tx.gas_limit) * tx.fee.cap() + tx.value + extra;
    if (reserved > before.balance) return error.InsufficientBalance;
    const prepaid = @as(u512, tx.gas_limit) * price + extra;
    var caller = before;
    caller.balance -= @intCast(prepaid);
    try host.setCaller(tx.sender, caller);
    const result = try host.executeFrame(tx);
    // An invalid user transaction must be an error from the host, never a result.
    if (result.invalid) return error.InvalidUserTransactionResult;
    const settlement = try fees.settle(
        &attributes,
        spec,
        tx.envelope,
        tx.gas_limit,
        result.gas_used,
        tx.base_fee,
        price,
    );
    try host.credit(tx.sender, settlement.caller_refund);
    try host.credit(coinbase, settlement.sequencer_fee_vault);
    try host.credit(constants.BASE_FEE_VAULT_ADDRESS, settlement.base_fee_vault);
    try host.credit(constants.L1_FEE_VAULT_ADDRESS, settlement.l1_fee_vault);
    try host.credit(constants.OPERATOR_FEE_VAULT_ADDRESS, settlement.operator_fee_vault);
    host.commit(checkpoint);
    active = false;
    return result;
}

pub fn executeBase(
    host: anytype,
    info: fees.L1BlockInfo,
    chain_id: u64,
    timestamp: u64,
    tx: Transaction,
    coinbase: Address,
) !Result {
    const chain = @import("base/config.zig").BaseChain.fromChainId(chain_id) orelse return error.UnsupportedChain;
    return execute(host, info, try chain.schedule().specAt(timestamp), tx, coinbase);
}

const TestHost = struct {
    state: deposits.CallerState = .{ .balance = 1_000_000, .nonce = 0 },
    saved: deposits.CallerState = undefined,
    vaults: u256 = 0,
    saved_vaults: u256 = 0,
    result: Result = .{ .outcome = .success, .gas_used = 21 },
    configured: ?OpSpecId = null,
    fail: bool = false,
    fn configure(self: *@This(), spec: OpSpecId) !void {
        self.configured = spec;
    }
    fn checkpoint(self: *@This()) !void {
        self.saved = self.state;
        self.saved_vaults = self.vaults;
    }
    fn rollback(self: *@This(), _: void) void {
        self.state = self.saved;
        self.vaults = self.saved_vaults;
    }
    fn commit(_: *@This(), _: void) void {}
    fn caller(self: *@This(), _: Address) !deposits.CallerState {
        return self.state;
    }
    fn setCaller(self: *@This(), _: Address, state: deposits.CallerState) !void {
        self.state = state;
    }
    fn credit(self: *@This(), address: Address, amount: u256) !void {
        if (address.bytes[19] == 1) {
            self.state.balance = try std.math.add(u256, self.state.balance, amount);
            return;
        }
        self.vaults = try std.math.add(u256, self.vaults, amount);
    }
    fn executeFrame(self: *@This(), _: Transaction) !Result {
        if (self.fail) return error.HostFailure;
        self.state.nonce += 1;
        return self.result;
    }
};

test "executor fee conservation across all forks and reverted frames" {
    for (OpSpecId.ALL) |spec| {
        for ([_]deposits.Outcome{ .success, .revert, .halt }) |outcome| {
            var host = TestHost{};
            host.result.outcome = outcome;
            var info = fees.L1BlockInfo.empty();
            info.operator_fee_scalar = 1;
            info.operator_fee_constant = 7;
            const tx = Transaction{ .sender = Address.fromU256(1), .envelope = &.{1}, .gas_limit = 100, .fee = .{ .legacy = 3 }, .base_fee = 2, .to = Address.fromU256(2) };
            _ = try execute(&host, info, spec, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
            try std.testing.expectEqual(@as(u256, 1_000_000), host.state.balance + host.vaults);
            try std.testing.expectEqual(spec, host.configured.?);
        }
    }
}

test "executor failed deposit preserves mint and nonce without vault charges" {
    var host = TestHost{};
    host.result = .{ .outcome = .halt, .gas_used = 21 };
    const tx = Transaction{ .sender = Address.fromU256(1), .envelope = &.{0x7e}, .gas_limit = 100, .base_fee = 2, .to = Address.fromU256(2), .deposit = transaction.DepositTransactionParts.deposit(@as([32]u8, @splat(1)), 50, false) };
    const result = try execute(&host, fees.L1BlockInfo.empty(), .JOVIAN, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
    try std.testing.expectEqual(@as(u64, 100), result.gas_used);
    try std.testing.expectEqual(@as(u256, 1_000_050), host.state.balance);
    try std.testing.expectEqual(@as(u64, 1), host.state.nonce);
    try std.testing.expectEqual(@as(u256, 0), host.vaults);
}

test "executor errors restore state and reject invalid admission" {
    var host = TestHost{};
    var tx = Transaction{ .sender = Address.fromU256(1), .envelope = &.{1}, .gas_limit = 100, .fee = .{ .legacy = 3 }, .base_fee = 2, .to = Address.fromU256(2) };
    host.fail = true;
    try std.testing.expectError(error.HostFailure, execute(&host, fees.L1BlockInfo.empty(), .FJORD, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    try std.testing.expectEqual(@as(u256, 1_000_000), host.state.balance);
    tx.value = 1_000_000;
    try std.testing.expectError(error.InsufficientBalance, execute(&host, fees.L1BlockInfo.empty(), .FJORD, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    tx.envelope = &.{2};
    try std.testing.expectError(error.FeeTypeMismatch, execute(&host, fees.L1BlockInfo.empty(), .FJORD, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    tx.envelope = &.{4};
    try std.testing.expectError(error.TxTypeNotSupported, execute(&host, fees.L1BlockInfo.empty(), .FJORD, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    try std.testing.expectError(error.FeeTypeMismatch, execute(&host, fees.L1BlockInfo.empty(), .ISTHMUS, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    tx.envelope = &.{3};
    try std.testing.expectError(error.TxTypeNotSupported, execute(&host, fees.L1BlockInfo.empty(), .JOVIAN, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    try std.testing.expectEqual(OpSpecId.FJORD, host.configured.?);
    tx.envelope = &.{0x7e};
    try std.testing.expectError(error.DepositTypeMismatch, execute(&host, fees.L1BlockInfo.empty(), .FJORD, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
}

test "executor EIP-1559 reserves gas_limit * max_fee but charges the effective price" {
    const dynamic = Fee{ .dynamic = .{ .max_fee_per_gas = 10, .max_priority_fee_per_gas = 1 } };
    const tx = Transaction{ .sender = Address.fromU256(1), .envelope = &.{2}, .gas_limit = 100, .fee = dynamic, .base_fee = 2, .value = 5, .to = Address.fromU256(2) };
    try std.testing.expectEqual(@as(u256, 3), try gasPrice(tx));
    var poor = TestHost{ .state = .{ .balance = 100 * 10 + 5 - 1, .nonce = 0 } };
    try std.testing.expectError(error.InsufficientBalance, execute(&poor, fees.L1BlockInfo.empty(), .FJORD, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    try std.testing.expectEqual(@as(u256, 1004), poor.state.balance);
    try std.testing.expectEqual(@as(u64, 0), poor.state.nonce);
    var host = TestHost{ .state = .{ .balance = 100 * 10 + 5, .nonce = 0 } };
    _ = try execute(&host, fees.L1BlockInfo.empty(), .FJORD, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
    // TestHost does not move value; the caller pays 21 gas at 3 wei: 21 * 1 tip + 21 * 2 base.
    try std.testing.expectEqual(@as(u256, 1005 - 21 * 3), host.state.balance);
    try std.testing.expectEqual(@as(u256, 21 * 3), host.vaults);
}

test "executor rejects dynamic fee fields that op-revm rejects" {
    var host = TestHost{};
    var tx = Transaction{ .sender = Address.fromU256(1), .envelope = &.{2}, .gas_limit = 100, .fee = .{ .dynamic = .{ .max_fee_per_gas = 5, .max_priority_fee_per_gas = 6 } }, .base_fee = 2, .to = Address.fromU256(2) };
    try std.testing.expectError(error.PriorityFeeGreaterThanMaxFee, execute(&host, fees.L1BlockInfo.empty(), .FJORD, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    tx.fee = .{ .dynamic = .{ .max_fee_per_gas = 1, .max_priority_fee_per_gas = 0 } };
    try std.testing.expectError(error.GasPriceBelowBaseFee, execute(&host, fees.L1BlockInfo.empty(), .FJORD, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    tx.fee = .{ .legacy = 1 };
    tx.envelope = &.{1};
    try std.testing.expectError(error.GasPriceBelowBaseFee, execute(&host, fees.L1BlockInfo.empty(), .FJORD, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    // A tip above (max_fee - base_fee) is capped by max_fee.
    tx.fee = .{ .dynamic = .{ .max_fee_per_gas = std.math.maxInt(u256), .max_priority_fee_per_gas = std.math.maxInt(u256) } };
    try std.testing.expectEqual(@as(u256, std.math.maxInt(u256)), try tx.fee.effectiveGasPrice(2));
    try std.testing.expectEqual(@as(u256, 1_000_000), host.state.balance);
}

test "executor validates the sender nonce and EIP-2681 overflow" {
    var host = TestHost{ .state = .{ .balance = 1_000_000, .nonce = 5 } };
    var tx = Transaction{ .sender = Address.fromU256(1), .envelope = &.{1}, .gas_limit = 100, .fee = .{ .legacy = 3 }, .base_fee = 2, .nonce = 4, .to = Address.fromU256(2) };
    try std.testing.expectError(error.NonceTooLow, execute(&host, fees.L1BlockInfo.empty(), .FJORD, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    tx.nonce = 6;
    try std.testing.expectError(error.NonceTooHigh, execute(&host, fees.L1BlockInfo.empty(), .FJORD, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    try std.testing.expectEqual(@as(u256, 1_000_000), host.state.balance);
    tx.nonce = 5;
    _ = try execute(&host, fees.L1BlockInfo.empty(), .FJORD, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
    try std.testing.expectEqual(@as(u64, 6), host.state.nonce);

    var full = TestHost{ .state = .{ .balance = 1_000_000, .nonce = std.math.maxInt(u64) } };
    tx.nonce = std.math.maxInt(u64);
    try std.testing.expectError(error.NonceOverflow, execute(&full, fees.L1BlockInfo.empty(), .FJORD, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    try std.testing.expectEqual(@as(u256, 1_000_000), full.state.balance);
}

test "executor includes a post-Regolith system deposit as a failed deposit" {
    const parts = transaction.DepositTransactionParts.deposit(@as([32]u8, @splat(3)), 50, true);
    const tx = Transaction{ .sender = Address.fromU256(1), .envelope = &.{0x7e}, .gas_limit = 1_000, .base_fee = 2, .to = Address.fromU256(2), .deposit = parts };
    for (OpSpecId.ALL[1..]) |spec| {
        // A failing frame proves no execution happens.
        var host = TestHost{ .fail = true };
        const result = try execute(&host, fees.L1BlockInfo.empty(), spec, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
        try std.testing.expectEqual(deposits.Outcome.halt, result.outcome);
        try std.testing.expectEqual(@as(u64, 1_000), result.gas_used);
        try std.testing.expectEqual(@as(u256, 1_000_050), host.state.balance);
        try std.testing.expectEqual(@as(u64, 1), host.state.nonce);
        try std.testing.expectEqual(@as(u256, 0), host.vaults);
    }
    // Bedrock still executes system transactions; a successful one uses no gas.
    var bedrock = TestHost{};
    const result = try execute(&bedrock, fees.L1BlockInfo.empty(), .BEDROCK, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
    try std.testing.expectEqual(deposits.Outcome.success, result.outcome);
    try std.testing.expectEqual(@as(u64, 0), result.gas_used);
}

test "executor includes a deposit the host reports invalid as a failed deposit on every spec" {
    for (OpSpecId.ALL) |spec| {
        for ([_]bool{ false, true }) |system| {
            // Regolith+ system deposits never reach the host (DepositSystemTxPostRegolith).
            if (system and spec.isAtLeast(.REGOLITH)) continue;
            var host = TestHost{};
            host.result = .{ .outcome = .halt, .gas_used = 1_000, .invalid = true };
            const parts = transaction.DepositTransactionParts.deposit(@as([32]u8, @splat(4)), 50, system);
            const tx = Transaction{ .sender = Address.fromU256(1), .envelope = &.{0x7e}, .gas_limit = 1_000, .base_fee = 2, .is_call = false, .deposit = parts };
            const result = try execute(&host, fees.L1BlockInfo.empty(), spec, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
            try std.testing.expectEqual(deposits.Outcome.halt, result.outcome);
            // A Bedrock system deposit that fails is free; any other uses its gas limit.
            try std.testing.expectEqual(@as(u64, if (system) 0 else 1_000), result.gas_used);
            try std.testing.expectEqual(@as(u256, 1_000_050), host.state.balance);
            try std.testing.expectEqual(@as(u64, 1), host.state.nonce);
            try std.testing.expectEqual(@as(u256, 0), host.vaults);
        }
    }
    // A host must report an invalid user transaction as an error.
    var host = TestHost{};
    host.result = .{ .outcome = .halt, .gas_used = 21, .invalid = true };
    const user = Transaction{ .sender = Address.fromU256(1), .envelope = &.{1}, .gas_limit = 100, .fee = .{ .legacy = 3 }, .base_fee = 2, .to = Address.fromU256(2) };
    try std.testing.expectError(error.InvalidUserTransactionResult, execute(&host, fees.L1BlockInfo.empty(), .FJORD, user, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    try std.testing.expectEqual(@as(u256, 1_000_000), host.state.balance);
    try std.testing.expectEqual(@as(u64, 0), host.state.nonce);
}

test "executor requires a call target exactly for calls" {
    var host = TestHost{};
    var tx = Transaction{ .sender = Address.fromU256(1), .envelope = &.{1}, .gas_limit = 100, .fee = .{ .legacy = 3 }, .base_fee = 2 };
    try std.testing.expectError(error.CallTargetMismatch, execute(&host, fees.L1BlockInfo.empty(), .JOVIAN, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    tx.is_call = false;
    tx.to = Address.fromU256(2);
    try std.testing.expectError(error.CallTargetMismatch, execute(&host, fees.L1BlockInfo.empty(), .JOVIAN, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    try std.testing.expect(host.configured == null);
}

test "executor validates access and authorization lists against the transaction type" {
    const keys = [_]u256{7};
    const entries = [_]AccessListEntry{.{ .address = Address.fromU256(9), .storage_keys = &keys }};
    const auth = Authorization{ .chain_id = 0, .address = Address.fromU256(5), .nonce = 0, .v = 0, .r = @as([32]u8, @splat(1)), .s = @as([32]u8, @splat(1)) };
    const auths = [_]Authorization{auth};
    const dynamic = Fee{ .dynamic = .{ .max_fee_per_gas = 3, .max_priority_fee_per_gas = 0 } };
    const base = Transaction{ .sender = Address.fromU256(1), .envelope = &.{0}, .gas_limit = 100, .fee = .{ .legacy = 3 }, .base_fee = 2, .to = Address.fromU256(2) };
    var info = fees.L1BlockInfo.empty();
    info.operator_fee_scalar = 0;
    info.operator_fee_constant = 0;

    // A legacy transaction has no access list; a deposit has neither list.
    var tx = base;
    tx.access_list = &entries;
    var host = TestHost{};
    try std.testing.expectError(error.AccessListUnsupported, execute(&host, info, .JOVIAN, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    tx.envelope = &.{0x7e};
    tx.fee = .{ .legacy = 0 };
    tx.deposit = transaction.DepositTransactionParts.deposit(@as([32]u8, @splat(1)), 0, false);
    try std.testing.expectError(error.AccessListUnsupported, execute(&host, info, .JOVIAN, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    tx.access_list = &.{};
    tx.authorization_list = &auths;
    try std.testing.expectError(error.AuthorizationListUnsupported, execute(&host, info, .JOVIAN, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    try std.testing.expect(host.configured == null);

    // Types 0x01 and 0x02 carry an access list but no authorization list.
    for ([_]u8{ 1, 2 }) |tx_type| {
        tx = base;
        tx.envelope = if (tx_type == 1) &.{1} else &.{2};
        if (tx_type == 2) tx.fee = dynamic;
        tx.access_list = &entries;
        var ok = TestHost{};
        _ = try execute(&ok, info, .JOVIAN, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
        tx.authorization_list = &auths;
        try std.testing.expectError(error.AuthorizationListUnsupported, execute(&ok, info, .JOVIAN, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    }

    // Type 0x04: Isthmus and later, dynamic fee, non-empty list, never a creation.
    tx = base;
    tx.envelope = &.{4};
    tx.fee = dynamic;
    tx.authorization_list = &auths;
    tx.access_list = &entries;
    for ([_]OpSpecId{ .BEDROCK, .REGOLITH, .CANYON, .ECOTONE, .FJORD, .GRANITE, .HOLOCENE }) |spec| {
        try std.testing.expectError(error.TxTypeNotSupported, execute(&host, info, spec, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    }
    for ([_]OpSpecId{ .ISTHMUS, .JOVIAN }) |spec| {
        var ok = TestHost{};
        _ = try execute(&ok, info, spec, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
        try std.testing.expectEqual(spec, ok.configured.?);
        var empty = tx;
        empty.authorization_list = &.{};
        try std.testing.expectError(error.EmptyAuthorizationList, execute(&ok, info, spec, empty, constants.SEQUENCER_FEE_VAULT_ADDRESS));
        var create = tx;
        create.to = null;
        create.is_call = false;
        try std.testing.expectError(error.AuthorizationListCreate, execute(&ok, info, spec, create, constants.SEQUENCER_FEE_VAULT_ADDRESS));
        var legacy = tx;
        legacy.fee = .{ .legacy = 3 };
        try std.testing.expectError(error.FeeTypeMismatch, execute(&ok, info, spec, legacy, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    }
}

/// Install these overrides in every frame, including nested calls. The switch
/// converts runtime block selection to the precompile table's comptime spec.
pub fn precompileOverrides(comptime Override: type, spec: OpSpecId) []const Override {
    return switch (spec) {
        inline else => |fork| @import("optimism/precompiles.zig").overrides(Override, fork),
    };
}

test "executor Base chain resolution covers both networks and fails closed" {
    for ([_]u64{ 8453, 84532 }) |chain_id| {
        var host = TestHost{};
        const chain = @import("base/config.zig").BaseChain.fromChainId(chain_id).?;
        var info = fees.L1BlockInfo.empty();
        info.operator_fee_scalar = 0;
        info.operator_fee_constant = 0;
        const tx = Transaction{ .sender = Address.fromU256(1), .envelope = &.{1}, .gas_limit = 100, .fee = .{ .legacy = 3 }, .base_fee = 2, .to = Address.fromU256(2) };
        _ = try executeBase(&host, info, chain_id, chain.schedule().jovian, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
        try std.testing.expectEqual(OpSpecId.JOVIAN, host.configured.?);
        try std.testing.expectError(error.BeforeGenesis, executeBase(&host, info, chain_id, 0, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
        try std.testing.expectError(error.UnmodeledBaseUpgrade, executeBase(&host, info, chain_id, chain.schedule().azul.?, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
        try std.testing.expectError(error.UnsupportedChain, executeBase(&host, info, 1, 0, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    }
}
