//! Transaction boundary for an OP Stack execution host.
//! The host owns state and checkpoints. executeFrame must execute value transfer
//! and ordinary transaction/CREATE nonce handling, but MUST NOT charge fees.
//! CALL deposit nonce increments are performed here and must not be repeated. It returns EVM failures as Outcome;
//! infrastructure errors propagate. configure installs ALL nested-call precompile
//! overrides from optimism/precompiles.zig, not merely top-level input checks.
const std = @import("std");
const fees = @import("base/fees.zig");
const deposits = @import("optimism/deposit.zig");
const transaction = @import("optimism/transaction.zig");
const constants = @import("optimism/constants.zig");
pub const OpSpecId = @import("optimism/spec.zig").OpSpecId;
pub const Address = @import("voltaire").Address;
pub const Transaction = struct {
    sender: Address,
    envelope: []const u8,
    gas_limit: u64,
    gas_price: u256,
    base_fee: u256,
    value: u256 = 0,
    is_call: bool = true,
    deposit: ?transaction.DepositTransactionParts = null,
};
pub const Result = struct { outcome: deposits.Outcome, gas_used: u64 };

/// Host contract: checkpoint() !Token, rollback(Token) void, commit(Token) void,
/// caller(Address) !CallerState, setCaller(Address, CallerState) !void,
/// credit(Address,u256) !void, configure(OpSpecId) !void,
/// executeFrame(Transaction) !Result. rollback must be infallible and restore all
/// account/storage/log changes. A frame revert/halt must revert frame effects.
/// Configure must install the spec's Ethereum fork and OP precompile overrides.
/// Deposit envelopes must already be authenticated by the rollup derivation layer.
pub fn execute(host: anytype, info: fees.L1BlockInfo, spec: OpSpecId, tx: Transaction, coinbase: Address) !Result {
    if (tx.envelope.len == 0) return error.MissingEnvelope;
    if ((tx.envelope[0] == 0x7e) != (tx.deposit != null)) return error.DepositTypeMismatch;
    try host.configure(spec);
    const checkpoint = try host.checkpoint();
    var active = true;
    errdefer if (active) host.rollback(checkpoint);
    const before = try host.caller(tx.sender);
    var attributes = info;
    attributes.clearTxL1Cost();
    if (tx.deposit) |parts| {
        try deposits.validate(spec, parts);
        try host.setCaller(tx.sender, deposits.preExecution(before, parts, tx.is_call));
        const result = try host.executeFrame(tx);
        if (result.gas_used > tx.gas_limit) return error.GasUsedExceedsGasLimit;
        const final = deposits.finalize(spec, parts, result.outcome, tx.gas_limit, result.gas_used);
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
        return .{ .outcome = result.outcome, .gas_used = final.gas_used };
    }
    if (tx.gas_price < tx.base_fee) return error.GasPriceBelowBaseFee;
    // Use wide arithmetic to reject saturation rather than undercharge on overflow.
    const extra = try attributes.txCost(tx.envelope, tx.gas_limit, spec);
    const prepaid = @as(u512, tx.gas_limit) * tx.gas_price + extra;
    if (prepaid + tx.value > before.balance) return error.InsufficientBalance;
    var caller = before;
    caller.balance -= @intCast(prepaid);
    try host.setCaller(tx.sender, caller);
    const result = try host.executeFrame(tx);
    const settlement = try fees.settle(&attributes, spec, tx.envelope, tx.gas_limit, result.gas_used, tx.base_fee, tx.gas_price);
    try host.credit(tx.sender, settlement.caller_refund);
    try host.credit(coinbase, settlement.sequencer_fee_vault);
    try host.credit(constants.BASE_FEE_VAULT_ADDRESS, settlement.base_fee_vault);
    try host.credit(constants.L1_FEE_VAULT_ADDRESS, settlement.l1_fee_vault);
    try host.credit(constants.OPERATOR_FEE_VAULT_ADDRESS, settlement.operator_fee_vault);
    host.commit(checkpoint);
    return result;
}

pub fn executeBase(host: anytype, info: fees.L1BlockInfo, chain_id: u64, timestamp: u64, tx: Transaction, coinbase: Address) !Result {
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
            const tx = Transaction{ .sender = Address.fromU256(1), .envelope = &.{2}, .gas_limit = 100, .gas_price = 3, .base_fee = 2 };
            _ = try execute(&host, info, spec, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
            try std.testing.expectEqual(@as(u256, 1_000_000), host.state.balance + host.vaults);
            try std.testing.expectEqual(spec, host.configured.?);
        }
    }
}

test "executor failed deposit preserves mint and nonce without vault charges" {
    var host = TestHost{};
    host.result = .{ .outcome = .halt, .gas_used = 21 };
    const tx = Transaction{ .sender = Address.fromU256(1), .envelope = &.{0x7e}, .gas_limit = 100, .gas_price = 0, .base_fee = 2, .deposit = transaction.DepositTransactionParts.deposit(@as([32]u8, @splat(1)), 50, false) };
    const result = try execute(&host, fees.L1BlockInfo.empty(), .JOVIAN, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
    try std.testing.expectEqual(@as(u64, 100), result.gas_used);
    try std.testing.expectEqual(@as(u256, 1_000_050), host.state.balance);
    try std.testing.expectEqual(@as(u64, 1), host.state.nonce);
    try std.testing.expectEqual(@as(u256, 0), host.vaults);
}

test "executor errors restore state and reject invalid admission" {
    var host = TestHost{};
    var tx = Transaction{ .sender = Address.fromU256(1), .envelope = &.{2}, .gas_limit = 100, .gas_price = 3, .base_fee = 2 };
    host.fail = true;
    try std.testing.expectError(error.HostFailure, execute(&host, fees.L1BlockInfo.empty(), .FJORD, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    try std.testing.expectEqual(@as(u256, 1_000_000), host.state.balance);
    tx.value = 1_000_000;
    try std.testing.expectError(error.InsufficientBalance, execute(&host, fees.L1BlockInfo.empty(), .FJORD, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    tx.envelope = &.{0x7e};
    try std.testing.expectError(error.DepositTypeMismatch, execute(&host, fees.L1BlockInfo.empty(), .FJORD, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
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
        const tx = Transaction{ .sender = Address.fromU256(1), .envelope = &.{2}, .gas_limit = 100, .gas_price = 3, .base_fee = 2 };
        _ = try executeBase(&host, info, chain_id, chain.schedule().jovian, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS);
        try std.testing.expectEqual(OpSpecId.JOVIAN, host.configured.?);
        try std.testing.expectError(error.BeforeGenesis, executeBase(&host, info, chain_id, 0, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
        try std.testing.expectError(error.UnmodeledBaseUpgrade, executeBase(&host, info, chain_id, chain.schedule().azul.?, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
        try std.testing.expectError(error.UnsupportedChain, executeBase(&host, info, 1, 0, tx, constants.SEQUENCER_FEE_VAULT_ADDRESS));
    }
}
