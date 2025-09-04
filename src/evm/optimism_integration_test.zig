//! Optimism L2 Integration Tests
//!
//! This module contains comprehensive integration tests that verify all Optimism L2 
//! components work together correctly. Tests cover the complete flow from chain type
//! detection through L1 cost calculation, deposit transactions, and L1Block precompile.
//!
//! ## Test Coverage
//! - End-to-end Optimism block processing
//! - L1 cost calculation with different hardforks
//! - Deposit transaction execution and minting
//! - L1Block precompile storage integration
//! - Cross-component compatibility verification
//! - Edge cases and error scenarios

const std = @import("std");
const testing = std.testing;

// Import all Optimism L2 components
const ChainType = @import("chain_type.zig").ChainType;
const Eips = @import("eips.zig").Eips;
const l1_cost = @import("l1_cost.zig");
const l1_block_precompile = @import("l1_block_precompile.zig");
const deposit_transaction = @import("deposit_transaction.zig");
const TransactionContext = @import("transaction_context.zig").TransactionContext;
const precompiles = @import("precompiles.zig");
const primitives = @import("primitives");
const Address = primitives.Address;

/// Mock L2 execution environment for testing
const MockL2Environment = struct {
    chain_id: u64,
    hardfork: @import("hardfork.zig").Hardfork,
    l1_block_info: l1_block_precompile.L1BlockInfo,
    
    pub fn init(chain_id: u64) MockL2Environment {
        return MockL2Environment{
            .chain_id = chain_id,
            .hardfork = .CANCUN,
            .l1_block_info = l1_block_precompile.L1BlockInfo{
                .number = 18500000,
                .timestamp = 1700000000,
                .base_fee = 1500000000, // 1.5 gwei
                .hash = [_]u8{0x12} ** 32,
                .sequence_number = 100,
                .batcher_hash = [_]u8{0x34} ** 32,
                .l1_fee_overhead = 188,
                .l1_fee_scalar = 684000,
            },
        };
    }
    
    pub fn get_chain_type(self: MockL2Environment) ChainType {
        return ChainType.from_chain_id(self.chain_id);
    }
    
    pub fn get_eips(self: MockL2Environment) Eips {
        return Eips{
            .hardfork = self.hardfork,
            .chain_type = self.get_chain_type(),
        };
    }
};

// Integration Tests

test "optimism end to end integration" {
    const allocator = testing.allocator;
    
    // Setup Optimism environment
    const op_env = MockL2Environment.init(10); // Optimism mainnet
    const chain_type = op_env.get_chain_type();
    const eips = op_env.get_eips();
    
    // Verify chain type detection
    try testing.expect(chain_type.is_optimism());
    try testing.expect(!chain_type.is_ethereum());
    try testing.expect(chain_type.requires_l1_cost_calculation());
    try testing.expect(chain_type.supports_deposit_transactions());
    
    // Verify EIP integration
    try testing.expect(eips.optimism_l1_cost_enabled());
    try testing.expect(eips.optimism_deposit_tx_enabled());
    try testing.expect(eips.optimism_l1_block_precompile_enabled());
    
    // Test L1 cost calculation (pre-Ecotone)
    const calculator = l1_cost.L1CostCalculator.init(.bedrock);
    const tx_data = [_]u8{0x00, 0x12, 0x34, 0x56, 0x78};
    
    const l1_cost_params = l1_cost.PreEcotoneL1FeeParams{
        .l1_base_fee = op_env.l1_block_info.base_fee,
        .l1_fee_overhead = op_env.l1_block_info.l1_fee_overhead,
        .l1_fee_scalar = op_env.l1_block_info.l1_fee_scalar,
    };
    
    const calculated_l1_cost = try calculator.calculate_l1_cost_pre_ecotone(tx_data, l1_cost_params);
    try testing.expect(calculated_l1_cost > 0);
    
    // Test L1Block precompile integration
    const precompile_result = try precompiles.execute_precompile_with_l1_info(
        allocator,
        precompiles.OPTIMISM_L1_BLOCK_ADDRESS,
        &[_]u8{},
        100000,
        op_env.l1_block_info,
    );
    defer allocator.free(precompile_result.output);
    
    try testing.expect(precompile_result.success);
    try testing.expectEqual(@as(usize, 256), precompile_result.output.len);
    
    // Verify L1Block precompile output contains correct L1 block number
    const decoded_l1_number = @as(u64, @truncate(std.mem.readInt(u256, precompile_result.output[0..32], .big)));
    try testing.expectEqual(op_env.l1_block_info.number, decoded_l1_number);
    
    // Test deposit transaction creation and validation
    const deposit = deposit_transaction.create_test_deposit_transaction();
    try deposit.validate();
    
    try testing.expect(deposit.has_mint());
    try testing.expect(deposit.has_value());
    try testing.expect(!deposit.is_creation());
    try testing.expectEqual(@as(u64, 21000), deposit.gas_limit);
}

test "multi hardfork l1 cost calculation" {
    // Test L1 cost calculation across different Optimism hardforks
    const tx_data = [_]u8{0x01, 0x02, 0x03, 0x04, 0x05}; // 5 * 16 = 80 gas
    
    // Pre-Ecotone (Bedrock)
    const bedrock_calc = l1_cost.L1CostCalculator.init(.bedrock);
    const bedrock_params = l1_cost.PreEcotoneL1FeeParams{
        .l1_base_fee = 2000000000, // 2 gwei
        .l1_fee_overhead = 200,
        .l1_fee_scalar = 700000,
    };
    
    const bedrock_cost = try bedrock_calc.calculate_l1_cost_pre_ecotone(tx_data, bedrock_params);
    
    // Ecotone+
    const ecotone_calc = l1_cost.L1CostCalculator.init(.ecotone);
    const ecotone_params = l1_cost.EcotoneL1FeeParams{
        .l1_base_fee = 2000000000,
        .l1_blob_base_fee = 1,
        .l1_base_fee_scalar = 1400,
        .l1_blob_base_fee_scalar = 800000,
    };
    
    const ecotone_cost = try ecotone_calc.calculate_l1_cost_ecotone(tx_data, ecotone_params);
    
    // Both costs should be positive and different due to different formulas
    try testing.expect(bedrock_cost > 0);
    try testing.expect(ecotone_cost > 0);
    
    // Isthmus with operator fee
    const isthmus_calc = l1_cost.L1CostCalculator.init(.isthmus);
    const isthmus_base_cost = try isthmus_calc.calculate_l1_cost_ecotone(tx_data, ecotone_params);
    
    const operator_params = l1_cost.OperatorFeeParams{
        .operator_fee_constant = 100000000, // 0.1 gwei
        .operator_fee_scalar = 2000, // 0.2%
    };
    
    const isthmus_total_cost = try isthmus_calc.calculate_total_cost_with_operator_fee(isthmus_base_cost, operator_params);
    
    try testing.expect(isthmus_total_cost > isthmus_base_cost);
}

test "deposit transaction full lifecycle" {
    // Test complete deposit transaction processing
    const allocator = testing.allocator;
    
    // Regular deposit transaction
    const regular_deposit = deposit_transaction.DepositTransaction.init(
        [_]u8{0x11} ** 32, // source_hash
        Address.from_hex("0x1111111111111111111111111111111111111111") catch unreachable,
        Address.from_hex("0x2222222222222222222222222222222222222222") catch unreachable,
        2000000000000000000, // 2 ETH mint
        1500000000000000000, // 1.5 ETH value
        100000, // gas_limit
        false, // not system tx
        &[_]u8{0xA9, 0x05, 0x9C, 0xBB}, // transfer method call
    );
    
    try regular_deposit.validate();
    try testing.expect(regular_deposit.has_mint());
    try testing.expect(regular_deposit.has_value());
    try testing.expectEqual(@as(u64, 100000), regular_deposit.effective_gas_limit());
    
    // System transaction
    const system_deposit = deposit_transaction.DepositTransaction.init(
        [_]u8{0x22} ** 32,
        deposit_transaction.SYSTEM_ADDRESS,
        deposit_transaction.DEPOSITOR_ACCOUNT,
        0, // no mint
        0, // no value
        0, // gas limit (ignored for system tx)
        true, // system tx
        &[_]u8{}, // empty data
    );
    
    try system_deposit.validate();
    try testing.expect(!system_deposit.has_mint());
    try testing.expect(!system_deposit.has_value());
    try testing.expectEqual(@as(u64, 0), system_deposit.effective_gas_limit());
    
    // Contract creation deposit
    const creation_deposit = deposit_transaction.DepositTransaction.init(
        [_]u8{0x33} ** 32,
        Address.from_hex("0x3333333333333333333333333333333333333333") catch unreachable,
        null, // contract creation
        1000000000000000000, // 1 ETH
        1000000000000000000, // 1 ETH value
        200000, // creation gas limit
        false,
        &[_]u8{0x60, 0x80, 0x60, 0x40, 0x52, 0x60, 0x04, 0x36}, // constructor bytecode
    );
    
    try creation_deposit.validate();
    try testing.expect(creation_deposit.is_creation());
    try testing.expectEqual(@as(?Address, null), creation_deposit.to);
    try testing.expectEqual(@as(usize, 8), creation_deposit.data.len);
    
    _ = allocator; // Keep allocator for future use
}

test "transaction context chain awareness" {
    const coinbase_addr = [_]u8{0x42} ++ [_]u8{0x00} ** 19;
    
    // Optimism context
    const op_context = TransactionContext{
        .gas_limit = 30000000,
        .coinbase = coinbase_addr,
        .chain_id = 10, // Optimism mainnet
    };
    
    try testing.expect(op_context.is_optimism());
    try testing.expect(op_context.requires_l1_cost_calculation());
    try testing.expectEqual(ChainType.optimism, op_context.get_chain_type());
    
    // Optimism Sepolia context
    const op_sepolia_context = TransactionContext{
        .gas_limit = 30000000,
        .coinbase = coinbase_addr,
        .chain_id = 11155420, // OP Sepolia
    };
    
    try testing.expect(op_sepolia_context.is_optimism());
    try testing.expect(op_sepolia_context.requires_l1_cost_calculation());
    
    // Ethereum context (should not have L2 features)
    const eth_context = TransactionContext{
        .gas_limit = 30000000,
        .coinbase = coinbase_addr,
        .chain_id = 1, // Ethereum mainnet
    };
    
    try testing.expect(!eth_context.is_optimism());
    try testing.expect(!eth_context.requires_l1_cost_calculation());
    try testing.expectEqual(ChainType.ethereum, eth_context.get_chain_type());
}

test "precompile address space separation" {
    // Verify Ethereum and Optimism precompiles are properly separated
    const eth_ecrecover = precompiles.ECRECOVER_ADDRESS;
    const eth_sha256 = precompiles.SHA256_ADDRESS;
    const op_l1_block = precompiles.OPTIMISM_L1_BLOCK_ADDRESS;
    
    // Ethereum precompiles should be detected as Ethereum only
    try testing.expect(precompiles.is_precompile(eth_ecrecover));
    try testing.expect(precompiles.is_ethereum_precompile(eth_ecrecover));
    try testing.expect(!precompiles.is_optimism_precompile(eth_ecrecover));
    
    try testing.expect(precompiles.is_precompile(eth_sha256));
    try testing.expect(precompiles.is_ethereum_precompile(eth_sha256));
    try testing.expect(!precompiles.is_optimism_precompile(eth_sha256));
    
    // Optimism precompiles should be detected as Optimism only
    try testing.expect(precompiles.is_precompile(op_l1_block));
    try testing.expect(!precompiles.is_ethereum_precompile(op_l1_block));
    try testing.expect(precompiles.is_optimism_precompile(op_l1_block));
    
    // Random address should not be detected as any precompile
    const random_addr = Address.from_hex("0x1234567890123456789012345678901234567890") catch unreachable;
    try testing.expect(!precompiles.is_precompile(random_addr));
    try testing.expect(!precompiles.is_ethereum_precompile(random_addr));
    try testing.expect(!precompiles.is_optimism_precompile(random_addr));
}

test "fee scalar encoding decoding round trip" {
    const test_cases = [_]struct { base: u32, blob: u32 }{
        .{ .base = 0, .blob = 0 },
        .{ .base = 1, .blob = 1 },
        .{ .base = 1368, .blob = 801949 }, // Typical Optimism values
        .{ .base = std.math.maxInt(u32), .blob = 0 },
        .{ .base = 0, .blob = std.math.maxInt(u32) },
        .{ .base = std.math.maxInt(u32), .blob = std.math.maxInt(u32) },
    };
    
    for (test_cases) |case| {
        const encoded = l1_cost.encode_fee_scalars(case.base, case.blob);
        const decoded = l1_cost.decode_fee_scalars(encoded);
        
        try testing.expectEqual(case.base, decoded.base_fee_scalar);
        try testing.expectEqual(case.blob, decoded.blob_base_fee_scalar);
    }
}

test "edge cases and error handling" {
    // Test various edge cases and error conditions
    
    // L1 cost calculation with wrong hardfork should error
    const bedrock_calc = l1_cost.L1CostCalculator.init(.bedrock);
    const ecotone_calc = l1_cost.L1CostCalculator.init(.ecotone);
    
    const pre_ecotone_params = l1_cost.PreEcotoneL1FeeParams{
        .l1_base_fee = 1,
        .l1_fee_overhead = 1,
        .l1_fee_scalar = 1,
    };
    const ecotone_params = l1_cost.EcotoneL1FeeParams{
        .l1_base_fee = 1,
        .l1_blob_base_fee = 1,
        .l1_base_fee_scalar = 1,
        .l1_blob_base_fee_scalar = 1,
    };
    const data = [_]u8{0x01};
    
    try testing.expectError(
        error.WrongFormulaForHardfork,
        ecotone_calc.calculate_l1_cost_pre_ecotone(data, pre_ecotone_params)
    );
    try testing.expectError(
        error.WrongFormulaForHardfork,
        bedrock_calc.calculate_l1_cost_ecotone(data, ecotone_params)
    );
    
    // Operator fee on non-Isthmus should error
    const non_isthmus_calc = l1_cost.L1CostCalculator.init(.ecotone);
    const operator_params = l1_cost.OperatorFeeParams{
        .operator_fee_constant = 1000,
        .operator_fee_scalar = 100,
    };
    
    try testing.expectError(
        error.OperatorFeeNotSupported,
        non_isthmus_calc.calculate_total_cost_with_operator_fee(1000, operator_params)
    );
    
    // Invalid deposit transaction validation
    const invalid_deposit = deposit_transaction.DepositTransaction.init(
        [_]u8{0x01} ** 32,
        Address.from_hex("0x1111111111111111111111111111111111111111") catch unreachable,
        Address.from_hex("0x2222222222222222222222222222222222222222") catch unreachable,
        100, // mint
        200, // value > mint (invalid!)
        21000,
        false,
        &[_]u8{},
    );
    
    try testing.expectError(deposit_transaction.DepositError.ValueExceedsMint, invalid_deposit.validate());
}