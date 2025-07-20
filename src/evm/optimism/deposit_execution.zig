const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
const B256 = @import("crypto").Hash.B256;
const DepositTransaction = @import("deposit_transaction.zig").DepositTransaction;
const OptimismRules = @import("hardfork.zig").OptimismRules;

/// Special halt reason for failed deposit transactions
pub const HaltReason = enum {
    Success,
    OutOfGas,
    InvalidInstruction,
    Revert,
    FailedDeposit,
    Other,
};

/// Result of deposit transaction execution
pub const DepositExecutionResult = struct {
    /// Whether execution succeeded
    success: bool,
    /// Gas used (special handling for deposits)
    gas_used: u64,
    /// Return data
    return_data: []const u8,
    /// Halt reason
    halt_reason: HaltReason,
};

/// Context for deposit transaction execution
pub const DepositExecutionContext = struct {
    /// Current Optimism rules
    op_rules: OptimismRules,
    /// Current L2 block number
    l2_block_number: u64,
    /// Whether to enable gas refunds
    enable_refunds: bool,
    
    /// Initialize context
    pub fn init(op_rules: OptimismRules, l2_block_number: u64) DepositExecutionContext {
        return .{
            .op_rules = op_rules,
            .l2_block_number = l2_block_number,
            // Refunds enabled for deposits starting from Regolith
            .enable_refunds = op_rules.isRegolith(),
        };
    }
};

/// Calculate gas to report for deposit transaction
pub fn calculateDepositGasUsed(
    deposit: DepositTransaction,
    actual_gas_used: u64,
    success: bool,
    context: DepositExecutionContext,
) u64 {
    // Regolith+ always reports actual gas used
    if (context.op_rules.isRegolith()) {
        return actual_gas_used;
    }
    
    // Pre-Regolith (Bedrock) behavior:
    if (success) {
        // Successful non-system deposits report gas limit
        // Successful system deposits report 0
        return if (deposit.is_system_tx) 0 else deposit.gas;
    } else {
        // All failed deposits report gas limit
        return deposit.gas;
    }
}

/// Validate deposit transaction before execution
pub fn validateDeposit(deposit: DepositTransaction, context: DepositExecutionContext) !void {
    // Pre-Regolith: system transactions must have reasonable gas
    if (!context.op_rules.isRegolith() and deposit.is_system_tx) {
        if (deposit.gas > 1_000_000) {
            return error.SystemTransactionGasTooHigh;
        }
    }
    
    // System transactions cannot send value
    if (deposit.is_system_tx and deposit.value != 0) {
        return error.SystemTransactionWithValue;
    }
    
    // Check for halted deposits (non-system with zero gas)
    if (deposit.isHalted()) {
        // Halted deposits are valid but won't execute
        return;
    }
}

/// Special behavior for deposit transactions
pub const DepositBehavior = struct {
    /// Skip nonce validation
    skip_nonce_check: bool = true,
    /// Skip balance check for gas fees
    skip_balance_check: bool = true,
    /// No L1 cost for deposits
    skip_l1_cost: bool = true,
    /// Mint value persists even on failure
    persist_mint_on_failure: bool = true,
    /// Nonce increments even on failure
    persist_nonce_on_failure: bool = true,
    /// No fee distribution to vaults
    skip_fee_distribution: bool = true,
};

/// Get deposit transaction behavior flags
pub fn getDepositBehavior(deposit: DepositTransaction) DepositBehavior {
    _ = deposit;
    return DepositBehavior{};
}

/// Apply mint value to account before execution
pub fn applyMintValue(account_balance: *u256, mint_value: u256) void {
    // Add mint value to account balance
    // This happens before any execution
    account_balance.* = account_balance.* + mint_value;
}

/// Handle post-execution for deposit transactions
pub fn handleDepositPostExecution(
    deposit: DepositTransaction,
    success: bool,
    actual_gas_used: u64,
    context: DepositExecutionContext,
) DepositExecutionResult {
    const gas_used = calculateDepositGasUsed(deposit, actual_gas_used, success, context);
    
    return DepositExecutionResult{
        .success = success,
        .gas_used = gas_used,
        .return_data = &.{},
        .halt_reason = if (success) .Success else .FailedDeposit,
    };
}

test "deposit gas calculation pre-Regolith" {
    const context = DepositExecutionContext.init(OptimismRules{ .hardfork = .BEDROCK }, 1000);
    
    // Successful non-system deposit reports gas limit
    const deposit1 = DepositTransaction{
        .source_hash = std.mem.zeroes(B256),
        .from = Address.ZERO,
        .to = null,
        .mint = 0,
        .value = 0,
        .gas = 100000,
        .is_system_tx = false,
        .data = &.{},
    };
    try std.testing.expectEqual(@as(u64, 100000), calculateDepositGasUsed(deposit1, 50000, true, context));
    
    // Successful system deposit reports 0
    const deposit2 = DepositTransaction{
        .source_hash = std.mem.zeroes(B256),
        .from = Address.ZERO,
        .to = null,
        .mint = 0,
        .value = 0,
        .gas = 100000,
        .is_system_tx = true,
        .data = &.{},
    };
    try std.testing.expectEqual(@as(u64, 0), calculateDepositGasUsed(deposit2, 50000, true, context));
    
    // Failed deposits report gas limit
    try std.testing.expectEqual(@as(u64, 100000), calculateDepositGasUsed(deposit1, 50000, false, context));
    try std.testing.expectEqual(@as(u64, 100000), calculateDepositGasUsed(deposit2, 50000, false, context));
}

test "deposit gas calculation Regolith+" {
    const context = DepositExecutionContext.init(OptimismRules{ .hardfork = .REGOLITH }, 1000);
    
    const deposit = DepositTransaction{
        .source_hash = std.mem.zeroes(B256),
        .from = Address.ZERO,
        .to = null,
        .mint = 0,
        .value = 0,
        .gas = 100000,
        .is_system_tx = false,
        .data = &.{},
    };
    
    // Always reports actual gas used
    try std.testing.expectEqual(@as(u64, 50000), calculateDepositGasUsed(deposit, 50000, true, context));
    try std.testing.expectEqual(@as(u64, 75000), calculateDepositGasUsed(deposit, 75000, false, context));
}

test "deposit behavior flags" {
    const deposit = DepositTransaction{
        .source_hash = std.mem.zeroes(B256),
        .from = Address.ZERO,
        .to = null,
        .mint = 1000,
        .value = 0,
        .gas = 100000,
        .is_system_tx = false,
        .data = &.{},
    };
    
    const behavior = getDepositBehavior(deposit);
    try std.testing.expect(behavior.skip_nonce_check);
    try std.testing.expect(behavior.skip_balance_check);
    try std.testing.expect(behavior.skip_l1_cost);
    try std.testing.expect(behavior.persist_mint_on_failure);
    try std.testing.expect(behavior.persist_nonce_on_failure);
    try std.testing.expect(behavior.skip_fee_distribution);
}