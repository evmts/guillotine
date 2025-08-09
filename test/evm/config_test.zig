const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const EvmConfig = Evm.EvmConfig;
const EipFlags = Evm.EipFlags;
const EipOverrides = Evm.EipOverrides;
const Hardfork = Evm.Hardfork;
const primitives = @import("primitives");

test "EvmConfig basic initialization" {
    const config = EvmConfig.init(.CANCUN);
    
    try testing.expectEqual(@as(u11, 1024), config.max_call_depth);
    try testing.expectEqual(@as(u64, 1), config.chain_id);
    try testing.expectEqual(Hardfork.CANCUN, config.hardfork);
}

test "EvmConfig predefined configurations" {
    // Test DEFAULT config
    {
        const config = EvmConfig.DEFAULT;
        try testing.expectEqual(Hardfork.CANCUN, config.hardfork);
        try testing.expect(!config.optional_balance_check);
    }
    
    // Test DEBUG config
    {
        const config = EvmConfig.DEBUG;
        try testing.expect(config.optional_balance_check);
        try testing.expect(config.optional_nonce_check);
        try testing.expect(config.clear_on_pop);
    }
    
    // Test TESTING config
    {
        const config = EvmConfig.TESTING;
        try testing.expect(config.optional_balance_check);
        try testing.expect(config.optional_nonce_check);
        try testing.expect(config.optional_base_fee);
    }
    
    // Test MINIMAL config
    {
        const config = EvmConfig.MINIMAL;
        try testing.expectEqual(@as(u64, 1024 * 1024), config.memory_limit);
        try testing.expectEqual(@as(usize, 100_000), config.max_iterations);
        try testing.expectEqual(Hardfork.FRONTIER, config.hardfork);
    }
}

test "EvmConfig L2 configurations" {
    // Test Optimism config
    {
        const config = EvmConfig.OPTIMISM;
        try testing.expectEqual(Hardfork.CANCUN, config.hardfork);
        try testing.expect(config.eip_overrides != null);
        
        const flags = config.getEipFlags();
        try testing.expect(flags.eip3198_basefee); // Force enabled
    }
    
    // Test Polygon config
    {
        const config = EvmConfig.POLYGON;
        const flags = config.getEipFlags();
        try testing.expect(!flags.eip1559_base_fee); // Force disabled
    }
    
    // Test Arbitrum config
    {
        const config = EvmConfig.ARBITRUM;
        try testing.expect(config.eip_overrides != null);
    }
}

test "EIP flag derivation from hardfork" {
    // Test Frontier - no EIPs
    {
        const config = EvmConfig.init(.FRONTIER);
        const flags = config.getEipFlags();
        
        try testing.expect(!flags.eip150_gas_costs);
        try testing.expect(!flags.eip155_chain_id);
        try testing.expect(!flags.eip1559_base_fee);
    }
    
    // Test Tangerine Whistle
    {
        const config = EvmConfig.init(.TANGERINE_WHISTLE);
        const flags = config.getEipFlags();
        
        try testing.expect(flags.eip150_gas_costs);
        try testing.expect(!flags.eip155_chain_id);
    }
    
    // Test Byzantium
    {
        const config = EvmConfig.init(.BYZANTIUM);
        const flags = config.getEipFlags();
        
        try testing.expect(flags.eip211_returndatasize);
        try testing.expect(flags.eip211_returndatacopy);
        try testing.expect(flags.eip214_staticcall);
    }
    
    // Test Constantinople vs Petersburg
    {
        const const_config = EvmConfig.init(.CONSTANTINOPLE);
        const const_flags = const_config.getEipFlags();
        try testing.expect(const_flags.eip1283_sstore_gas);
        
        const peter_config = EvmConfig.init(.PETERSBURG);
        const peter_flags = peter_config.getEipFlags();
        try testing.expect(!peter_flags.eip1283_sstore_gas); // Removed
    }
    
    // Test Cancun - latest features
    {
        const config = EvmConfig.init(.CANCUN);
        const flags = config.getEipFlags();
        
        try testing.expect(flags.eip150_gas_costs);
        try testing.expect(flags.eip155_chain_id);
        try testing.expect(flags.eip1559_base_fee);
        try testing.expect(flags.eip3855_push0);
        try testing.expect(flags.eip4844_blob_tx);
        try testing.expect(flags.eip5656_mcopy);
        try testing.expect(flags.eip6780_selfdestruct_only_same_tx);
    }
}

test "hasEip method" {
    const config = EvmConfig.init(.CANCUN);
    
    try testing.expect(config.hasEip(150));  // Tangerine Whistle
    try testing.expect(config.hasEip(155));  // Spurious Dragon
    try testing.expect(config.hasEip(1559)); // London
    try testing.expect(config.hasEip(3855)); // Shanghai
    try testing.expect(config.hasEip(5656)); // Cancun
    
    try testing.expect(!config.hasEip(9999)); // Unknown EIP
}

test "custom EIP overrides" {
    // Test enabling features early
    {
        const overrides = EipOverrides{
            .force_enable = &.{3855, 5656}, // PUSH0 and MCOPY
        };
        
        const config = EvmConfig.initWithOverrides(.BERLIN, overrides);
        const flags = config.getEipFlags();
        
        try testing.expect(flags.eip3855_push0); // Force enabled
        try testing.expect(flags.eip5656_mcopy); // Force enabled
        try testing.expect(!flags.eip1559_base_fee); // Not yet in Berlin
    }
    
    // Test disabling features
    {
        const overrides = EipOverrides{
            .force_disable = &.{1559, 4844}, // Disable base fee and blobs
        };
        
        const config = EvmConfig.initWithOverrides(.CANCUN, overrides);
        const flags = config.getEipFlags();
        
        try testing.expect(!flags.eip1559_base_fee); // Force disabled
        try testing.expect(!flags.eip4844_blob_tx); // Force disabled
        try testing.expect(flags.eip3855_push0); // Still enabled from Cancun
    }
}

test "OpcodeMetadata integration with EvmConfig" {
    const config = EvmConfig.init(.SHANGHAI);
    
    // PUSH0 should be available in Shanghai
    const push0_op = config.opcodes.get_operation(0x5f);
    try testing.expect(!push0_op.undefined);
    
    // MCOPY should not be available until Cancun
    const mcopy_op = config.opcodes.get_operation(0x5e);
    try testing.expect(mcopy_op.undefined);
}

test "gas cost configuration" {
    const config = EvmConfig.init(.CANCUN);
    
    // Test SLOAD gas costs through hardfork progression
    try testing.expectEqual(@as(u64, 0), config.getGasCost(.sload)); // Berlin+
    
    const frontier_config = EvmConfig.init(.FRONTIER);
    try testing.expectEqual(@as(u64, 50), frontier_config.getGasCost(.sload));
    
    const tangerine_config = EvmConfig.init(.TANGERINE_WHISTLE);
    try testing.expectEqual(@as(u64, 200), tangerine_config.getGasCost(.sload));
}

test "compile-time validation" {
    // This should compile successfully
    const valid_config = EvmConfig.init(.CANCUN);
    comptime valid_config.validate();
    
    // Test that calculateInitialSize works
    const initial_size = comptime valid_config.calculateInitialSize();
    try testing.expect(initial_size > 0);
}

test "EIP flags debug string" {
    const allocator = testing.allocator;
    
    const config = EvmConfig.init(.LONDON);
    const flags = config.getEipFlags();
    const debug_str = try flags.debugString(allocator);
    defer allocator.free(debug_str);
    
    // Should contain at least some EIPs
    try testing.expect(debug_str.len > 20);
    try testing.expect(std.mem.indexOf(u8, debug_str, "150") != null);
    try testing.expect(std.mem.indexOf(u8, debug_str, "1559") != null);
}

test "memory and stack configuration" {
    const config = EvmConfig.init(.CANCUN);
    
    try testing.expectEqual(@as(u64, 32 * 1024 * 1024), config.memory_limit);
    try testing.expectEqual(@as(usize, 4096), config.initial_memory_capacity);
    try testing.expectEqual(@as(usize, 43008), config.max_stack_buffer_size);
    try testing.expectEqual(@as(usize, 12800), config.stack_allocation_threshold);
    
    // Verify stack allocation threshold is less than max buffer size
    try testing.expect(config.stack_allocation_threshold < config.max_stack_buffer_size);
}