//! Deposit transaction (type 0x7E) execution rules.
//!
//! Port of the deposit branches of op-revm handler.rs:
//! https://github.com/ethereum-optimism/optimism/blob/develop/rust/op-revm/src/handler.rs
//! Spec: https://specs.optimism.io/protocol/deposits.html#execution
//!
//! Rules implemented here, as pure functions over account state and gas:
//!
//! | Rule                         | Bedrock                         | Regolith+                     |
//! |------------------------------|---------------------------------|-------------------------------|
//! | is_system_transaction        | allowed                         | failed deposit (see validate) |
//! | mint                         | credited before execution       | same                          |
//! | nonce                        | +1 before execution if CALL     | same                          |
//! | signature, nonce, balance    | not validated                   | same                          |
//! | gas used, success/revert     | gas_limit (system tx: 0)        | actual gas after refund       |
//! | gas refund                   | disabled                        | enabled                       |
//! | halt                         | normal halt, gas_limit          | failed deposit                |
//! | failed deposit               | revert state; nonce+1, mint;    | revert state; nonce+1, mint;  |
//! |                              | gas = system ? 0 : gas_limit    | gas = gas_limit               |
//! | L1 fee, operator fee, vaults | none                            | none                          |
//!
//! A failed deposit is any execution error (validation or halt) after which the
//! transaction is still included: the caller state is rolled back to before the
//! transaction, then the nonce is bumped and the mint credited.

const std = @import("std");
const spec_mod = @import("spec.zig");
const transaction = @import("transaction.zig");

const OpSpecId = spec_mod.OpSpecId;
const DepositTransactionParts = transaction.DepositTransactionParts;

pub const DepositError = error{
    /// Regolith+ forbids deposits with is_system_transaction = true
    /// (op-revm `OpTransactionError::DepositSystemTxPostRegolith`).
    DepositSystemTxPostRegolith,
};

/// Caller account fields touched by deposit processing.
pub const CallerState = struct {
    balance: u256,
    nonce: u64,
};

/// How the deposit's top-level frame finished.
pub const Outcome = enum {
    success,
    revert,
    halt,
};

/// Result of applying deposit rules to an execution.
pub const DepositResult = struct {
    /// Gas reported in the receipt and counted toward the block gas used.
    gas_used: u64,
    /// True if the deposit is a failed deposit: discard all state changes of the
    /// transaction and apply `failedDeposit` to the pre-transaction caller state.
    failed: bool,
};

/// Validate deposit fields against the active spec (op-revm `validate_env`).
/// An error here does not drop the deposit: op-revm `catch_error_failed_deposit` and
/// op-geth `StateTransition.execute` include it as a failed deposit (executor.zig).
pub fn validate(spec: OpSpecId, parts: DepositTransactionParts) DepositError!void {
    if (parts.is_system_transaction and spec.isAtLeast(.REGOLITH)) {
        return error.DepositSystemTxPostRegolith;
    }
}

/// Caller state before execution: mint credited (saturating) and, for CALL
/// deposits, nonce bumped. CREATE deposits bump the nonce in the create frame.
/// Deposits carry no gas price, so no balance is deducted for gas.
pub fn preExecution(caller: CallerState, parts: DepositTransactionParts, is_call: bool) CallerState {
    return .{
        .balance = caller.balance +| (parts.mint orelse 0),
        .nonce = if (is_call) caller.nonce +| 1 else caller.nonce,
    };
}

/// Caller state after a failed deposit, given the caller state before the
/// transaction: nonce + 1 (CALL or CREATE) and mint credited.
pub fn failedDeposit(caller_before_tx: CallerState, parts: DepositTransactionParts) CallerState {
    return .{
        .balance = caller_before_tx.balance +| (parts.mint orelse 0),
        .nonce = caller_before_tx.nonce +| 1,
    };
}

/// Gas used by a failed deposit (op-revm `catch_error_failed_deposit`).
pub fn failedDepositGasUsed(spec: OpSpecId, parts: DepositTransactionParts, gas_limit: u64) u64 {
    if (spec.isAtLeast(.REGOLITH) or !parts.is_system_transaction) return gas_limit;
    return 0;
}

/// True if gas refunds (SSTORE clears etc.) apply. Disabled for Bedrock deposits.
pub fn refundsEnabled(spec: OpSpecId) bool {
    return spec.isAtLeast(.REGOLITH);
}

/// Apply deposit gas accounting to a finished execution.
///
/// `gas_used_after_refund` is the gas the EVM would report for a normal
/// transaction (spent minus capped refund). Pre-Regolith it is ignored.
pub fn finalize(
    spec: OpSpecId,
    parts: DepositTransactionParts,
    outcome: Outcome,
    gas_limit: u64,
    gas_used_after_refund: u64,
) DepositResult {
    if (spec.isAtLeast(.REGOLITH)) {
        if (outcome == .halt) {
            return .{ .gas_used = failedDepositGasUsed(spec, parts, gas_limit), .failed = true };
        }
        return .{ .gas_used = gas_used_after_refund, .failed = false };
    }
    // Bedrock: all gas spent, no refund; a successful system transaction is free.
    if (parts.is_system_transaction and outcome == .success) {
        return .{ .gas_used = 0, .failed = false };
    }
    return .{ .gas_used = gas_limit, .failed = false };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn sourceHash(byte: u8) [32]u8 {
    return @as([32]u8, @splat(byte));
}

test "system transaction allowed in Bedrock, rejected from Regolith" {
    const system = DepositTransactionParts.deposit(sourceHash(1), null, true);
    try validate(.BEDROCK, system);
    for (OpSpecId.ALL[1..]) |spec| {
        try testing.expectError(error.DepositSystemTxPostRegolith, validate(spec, system));
    }
    const user = DepositTransactionParts.deposit(sourceHash(1), 5, false);
    for (OpSpecId.ALL) |spec| try validate(spec, user);
}

test "preExecution credits mint and bumps nonce for CALL only" {
    const parts = DepositTransactionParts.deposit(sourceHash(2), 1_000_000_000_000_000_000, false);
    const before = CallerState{ .balance = 7, .nonce = 3 };
    const call = preExecution(before, parts, true);
    try testing.expectEqual(@as(u256, 1_000_000_000_000_000_007), call.balance);
    try testing.expectEqual(@as(u64, 4), call.nonce);
    const create = preExecution(before, parts, false);
    try testing.expectEqual(@as(u64, 3), create.nonce);
}

test "preExecution without mint leaves balance unchanged" {
    const parts = DepositTransactionParts.deposit(sourceHash(2), null, false);
    const after = preExecution(.{ .balance = 9, .nonce = 0 }, parts, true);
    try testing.expectEqual(@as(u256, 9), after.balance);
}

test "mint and nonce saturate instead of overflowing" {
    const parts = DepositTransactionParts.deposit(sourceHash(3), std.math.maxInt(u128), false);
    const before = CallerState{ .balance = std.math.maxInt(u256), .nonce = std.math.maxInt(u64) };
    const after = preExecution(before, parts, true);
    try testing.expectEqual(@as(u256, std.math.maxInt(u256)), after.balance);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), after.nonce);
    const failed = failedDeposit(before, parts);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), failed.nonce);
}

test "failed deposit keeps mint and bumps nonce for CREATE too" {
    const parts = DepositTransactionParts.deposit(sourceHash(4), 500, false);
    const after = failedDeposit(.{ .balance = 100, .nonce = 10 }, parts);
    try testing.expectEqual(@as(u256, 600), after.balance);
    try testing.expectEqual(@as(u64, 11), after.nonce);
}

test "Regolith+ deposit reports actual gas and enables refunds" {
    const parts = DepositTransactionParts.deposit(sourceHash(5), null, false);
    for (OpSpecId.ALL[1..]) |spec| {
        try testing.expect(refundsEnabled(spec));
        const ok = finalize(spec, parts, .success, 100_000, 21_000);
        try testing.expectEqual(@as(u64, 21_000), ok.gas_used);
        try testing.expect(!ok.failed);
        const reverted = finalize(spec, parts, .revert, 100_000, 30_000);
        try testing.expectEqual(@as(u64, 30_000), reverted.gas_used);
        try testing.expect(!reverted.failed);
    }
}

test "Regolith+ halted deposit is a failed deposit using gas_limit" {
    const parts = DepositTransactionParts.deposit(sourceHash(6), 1, false);
    const result = finalize(.JOVIAN, parts, .halt, 100_000, 100_000);
    try testing.expect(result.failed);
    try testing.expectEqual(@as(u64, 100_000), result.gas_used);
}

test "Bedrock deposit uses all gas, no refunds" {
    const parts = DepositTransactionParts.deposit(sourceHash(7), null, false);
    try testing.expect(!refundsEnabled(.BEDROCK));
    try testing.expectEqual(@as(u64, 100_000), finalize(.BEDROCK, parts, .success, 100_000, 21_000).gas_used);
    try testing.expectEqual(@as(u64, 100_000), finalize(.BEDROCK, parts, .revert, 100_000, 21_000).gas_used);
    const halted = finalize(.BEDROCK, parts, .halt, 100_000, 100_000);
    try testing.expect(!halted.failed);
    try testing.expectEqual(@as(u64, 100_000), halted.gas_used);
}

test "Bedrock successful system transaction uses zero gas" {
    const parts = DepositTransactionParts.deposit(sourceHash(8), null, true);
    try testing.expectEqual(@as(u64, 0), finalize(.BEDROCK, parts, .success, 1_000_000, 50_000).gas_used);
    try testing.expectEqual(@as(u64, 1_000_000), finalize(.BEDROCK, parts, .revert, 1_000_000, 50_000).gas_used);
}

test "failed deposit gas: Bedrock system tx 0, otherwise gas_limit" {
    const system = DepositTransactionParts.deposit(sourceHash(9), null, true);
    const user = DepositTransactionParts.deposit(sourceHash(9), null, false);
    try testing.expectEqual(@as(u64, 0), failedDepositGasUsed(.BEDROCK, system, 500));
    try testing.expectEqual(@as(u64, 500), failedDepositGasUsed(.BEDROCK, user, 500));
    try testing.expectEqual(@as(u64, 500), failedDepositGasUsed(.REGOLITH, system, 500));
    try testing.expectEqual(@as(u64, 500), failedDepositGasUsed(.JOVIAN, user, 500));
}
