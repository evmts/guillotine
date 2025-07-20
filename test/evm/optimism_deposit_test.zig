const std = @import("std");
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const B256 = @import("crypto").Hash.B256;

test "deposit transaction validation" {
    const op_rules = Evm.optimism.OptimismRules{ .hardfork = .BEDROCK };
    const context = Evm.optimism.DepositExecutionContext.init(op_rules, 1000);
    
    // Valid deposit
    const valid_deposit = Evm.optimism.DepositTransaction{
        .source_hash = std.mem.zeroes(B256),
        .from = Address.ZERO,
        .to = null,
        .mint = 1000,
        .value = 0,
        .gas = 100000,
        .is_system_tx = false,
        .data = &.{},
    };
    try Evm.optimism.validateDeposit(valid_deposit, context);
    
    // System transaction with value (invalid)
    const invalid_deposit = Evm.optimism.DepositTransaction{
        .source_hash = std.mem.zeroes(B256),
        .from = Address.ZERO,
        .to = null,
        .mint = 0,
        .value = 100, // System tx cannot have value
        .gas = 100000,
        .is_system_tx = true,
        .data = &.{},
    };
    try std.testing.expectError(error.SystemTransactionWithValue, Evm.optimism.validateDeposit(invalid_deposit, context));
}

test "deposit gas reporting Bedrock vs Regolith" {
    // Bedrock context
    const bedrock_context = Evm.optimism.DepositExecutionContext.init(
        Evm.optimism.OptimismRules{ .hardfork = .BEDROCK },
        1000,
    );
    
    // Regolith context
    const regolith_context = Evm.optimism.DepositExecutionContext.init(
        Evm.optimism.OptimismRules{ .hardfork = .REGOLITH },
        1000,
    );
    
    // Non-system deposit
    const deposit = Evm.optimism.DepositTransaction{
        .source_hash = std.mem.zeroes(B256),
        .from = Address.ZERO,
        .to = null,
        .mint = 0,
        .value = 0,
        .gas = 100000,
        .is_system_tx = false,
        .data = &.{},
    };
    
    // Bedrock: successful non-system deposit reports gas limit
    const bedrock_gas = Evm.optimism.calculateDepositGasUsed(deposit, 50000, true, bedrock_context);
    try std.testing.expectEqual(@as(u64, 100000), bedrock_gas);
    
    // Regolith: reports actual gas used
    const regolith_gas = Evm.optimism.calculateDepositGasUsed(deposit, 50000, true, regolith_context);
    try std.testing.expectEqual(@as(u64, 50000), regolith_gas);
}

test "deposit behavior flags" {
    const deposit = Evm.optimism.DepositTransaction{
        .source_hash = std.mem.zeroes(B256),
        .from = Address.ZERO,
        .to = null,
        .mint = 1000,
        .value = 0,
        .gas = 100000,
        .is_system_tx = false,
        .data = &.{},
    };
    
    const behavior = Evm.optimism.getDepositBehavior(deposit);
    
    // Verify all special deposit behaviors
    try std.testing.expect(behavior.skip_nonce_check);
    try std.testing.expect(behavior.skip_balance_check);
    try std.testing.expect(behavior.skip_l1_cost);
    try std.testing.expect(behavior.persist_mint_on_failure);
    try std.testing.expect(behavior.persist_nonce_on_failure);
    try std.testing.expect(behavior.skip_fee_distribution);
}

test "halted deposit detection" {
    // Halted deposit: non-system with zero gas
    const halted_deposit = Evm.optimism.DepositTransaction{
        .source_hash = std.mem.zeroes(B256),
        .from = Address.ZERO,
        .to = null,
        .mint = 1000,
        .value = 0,
        .gas = 0, // Zero gas = halted
        .is_system_tx = false,
        .data = &.{},
    };
    
    try std.testing.expect(halted_deposit.isHalted());
    
    // Halted deposits are still valid
    const context = Evm.optimism.DepositExecutionContext.init(
        Evm.optimism.OptimismRules{ .hardfork = .REGOLITH },
        1000,
    );
    try Evm.optimism.validateDeposit(halted_deposit, context);
}

test "system deposit gas reporting" {
    const context = Evm.optimism.DepositExecutionContext.init(
        Evm.optimism.OptimismRules{ .hardfork = .BEDROCK },
        1000,
    );
    
    // System deposit
    const system_deposit = Evm.optimism.DepositTransaction{
        .source_hash = std.mem.zeroes(B256),
        .from = Address.ZERO,
        .to = null,
        .mint = 0,
        .value = 0,
        .gas = 100000,
        .is_system_tx = true,
        .data = &.{},
    };
    
    // Successful system deposit reports 0 gas in Bedrock
    const success_gas = Evm.optimism.calculateDepositGasUsed(system_deposit, 50000, true, context);
    try std.testing.expectEqual(@as(u64, 0), success_gas);
    
    // Failed system deposit reports gas limit
    const fail_gas = Evm.optimism.calculateDepositGasUsed(system_deposit, 50000, false, context);
    try std.testing.expectEqual(@as(u64, 100000), fail_gas);
}

test "deposit transaction type constant" {
    try std.testing.expectEqual(@as(u8, 0x7E), Evm.optimism.DEPOSIT_TX_TYPE);
}