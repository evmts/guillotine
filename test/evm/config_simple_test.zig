const std = @import("std");
const testing = std.testing;
const config = @import("evm").config;
const EvmConfig = config.EvmConfig;
const Hardfork = @import("evm").Hardfork;

test "EvmConfig basic initialization" {
    const cfg = EvmConfig.init(.CANCUN);
    
    try testing.expectEqual(@as(u11, 1024), cfg.max_call_depth);
    try testing.expectEqual(@as(u64, 1), cfg.chain_id);
    try testing.expectEqual(Hardfork.Hardfork.CANCUN, cfg.hardfork);
}

test "EvmConfig predefined configurations" {
    // Test DEFAULT config
    {
        const cfg = EvmConfig.DEFAULT;
        try testing.expectEqual(Hardfork.Hardfork.CANCUN, cfg.hardfork);
        try testing.expect(!cfg.optional_balance_check);
    }
    
    // Test DEBUG config
    {
        const cfg = EvmConfig.DEBUG;
        try testing.expect(cfg.optional_balance_check);
        try testing.expect(cfg.optional_nonce_check);
        try testing.expect(cfg.clear_on_pop);
    }
    
    // Test MINIMAL config
    {
        const cfg = EvmConfig.MINIMAL;
        try testing.expectEqual(@as(u64, 1024 * 1024), cfg.memory_limit);
        try testing.expectEqual(@as(usize, 100_000), cfg.max_iterations);
        try testing.expectEqual(Hardfork.Hardfork.FRONTIER, cfg.hardfork);
    }
}

test "EvmConfig compile-time validation" {
    // validate() and calculateInitialSize() require comptime-known self
    comptime EvmConfig.init(.CANCUN).validate();
    // Test that calculateInitialSize works
    const initial_size = comptime EvmConfig.init(.CANCUN).calculateInitialSize();
    try testing.expect(initial_size > 0);
}

test "EvmConfig memory and stack configuration" {
    const cfg = EvmConfig.init(.CANCUN);
    
    try testing.expectEqual(@as(u64, 32 * 1024 * 1024), cfg.memory_limit);
    try testing.expectEqual(@as(usize, 4096), cfg.initial_memory_capacity);
    try testing.expectEqual(@as(usize, 43008), cfg.max_stack_buffer_size);
    try testing.expectEqual(@as(usize, 12800), cfg.stack_allocation_threshold);
    
    // Verify stack allocation threshold is less than max buffer size
    try testing.expect(cfg.stack_allocation_threshold < cfg.max_stack_buffer_size);
}