const std = @import("std");
const EvmConfig = @import("../config.zig").EvmConfig;
const EipOverrides = @import("overrides.zig").EipOverrides;
const Hardfork = @import("../hardforks/hardfork.zig").Hardfork;

/// Test configuration for verifying EIP-1559 behavior
pub const EIP_1559_TEST = blk: {
    var config = EvmConfig.init(.LONDON);
    config.optional_balance_check = true;
    config.optional_nonce_check = true;
    break :blk config;
};

/// Test configuration without EIP-1559 (for comparison)
pub const NO_EIP_1559_TEST = blk: {
    var config = EvmConfig.init(.BERLIN);
    config.optional_balance_check = true;
    config.optional_nonce_check = true;
    break :blk config;
};

/// Test configuration for CREATE2 testing
pub const CREATE2_TEST = EvmConfig.init(.CONSTANTINOPLE);

/// Test configuration for transient storage
pub const TRANSIENT_STORAGE_TEST = EvmConfig.init(.CANCUN);

/// Test configuration for blob transactions
pub const BLOB_TX_TEST = blk: {
    var config = EvmConfig.init(.CANCUN);
    config.chain_id = 5; // Goerli testnet
    break :blk config;
};

/// Test configuration with custom EIP enables
pub const CUSTOM_EIP_TEST = EvmConfig.initWithOverrides(.BERLIN, EipOverrides{
    .force_enable = &.{
        3855, // PUSH0 (normally Shanghai)
        5656, // MCOPY (normally Cancun)
    },
    .force_disable = &.{
        2929, // Access list gas costs
    },
});

/// Test configuration simulating pre-Byzantium
pub const LEGACY_TEST = blk: {
    var config = EvmConfig.init(.SPURIOUS_DRAGON);
    config.memory_limit = 8 * 1024 * 1024; // 8MB
    config.max_iterations = 1_000_000;
    break :blk config;
};

/// Test configuration for gas testing
pub const GAS_TEST = blk: {
    var config = EvmConfig.init(.CANCUN);
    config.optional_balance_check = false;
    config.optional_nonce_check = false;
    config.optional_base_fee = false;
    break :blk config;
};

/// Test configuration for memory stress testing
pub const MEMORY_STRESS_TEST = blk: {
    var config = EvmConfig.init(.CANCUN);
    config.memory_limit = 128 * 1024 * 1024; // 128MB
    config.initial_memory_capacity = 65536; // 64KB
    config.max_iterations = 100_000_000;
    break :blk config;
};

/// Test configuration for stack testing
pub const STACK_TEST = blk: {
    var config = EvmConfig.init(.CANCUN);
    config.max_stack_buffer_size = 86016; // Double normal size
    config.stack_allocation_threshold = 25600; // Double threshold
    config.clear_on_pop = true; // Always clear for testing
    break :blk config;
};

/// Function to create test config for specific hardfork
pub fn createTestConfig(
    hardfork: Hardfork,
    options: struct {
        chain_id: u64 = 1337, // Default test chain ID
        memory_limit: u64 = 16 * 1024 * 1024, // 16MB default
        optional_checks: bool = true,
    },
) EvmConfig {
    var config = EvmConfig.init(hardfork);
    config.chain_id = options.chain_id;
    config.memory_limit = options.memory_limit;

    if (options.optional_checks) {
        config.optional_balance_check = true;
        config.optional_nonce_check = true;
        config.optional_base_fee = true;
    }

    return config;
}

test "test configurations have expected EIPs" {
    const testing = std.testing;

    // EIP-1559 test should have base fee
    try testing.expect(EIP_1559_TEST.hasEip(1559));
    try testing.expect(EIP_1559_TEST.hasEip(3198)); // BASEFEE opcode

    // Pre-London should not have EIP-1559
    try testing.expect(!NO_EIP_1559_TEST.hasEip(1559));
    try testing.expect(!NO_EIP_1559_TEST.hasEip(3198));

    // CREATE2 test should have CREATE2
    try testing.expect(CREATE2_TEST.hasEip(1014));

    // Transient storage test should have TLOAD/TSTORE
    try testing.expect(TRANSIENT_STORAGE_TEST.hasEip(1153));

    // Blob TX test should have blob support
    try testing.expect(BLOB_TX_TEST.hasEip(4844));

    // Custom EIP test should have forced EIPs
    const custom_flags = CUSTOM_EIP_TEST.getEipFlags();
    try testing.expect(custom_flags.eip3855_push0); // Force enabled
    try testing.expect(custom_flags.eip5656_mcopy); // Force enabled
    try testing.expect(!custom_flags.eip2929_gas_costs); // Force disabled
}

test "test configuration factory" {
    const testing = std.testing;

    // Create Istanbul test config
    const istanbul_test = createTestConfig(.ISTANBUL, .{
        .chain_id = 5,
        .memory_limit = 64 * 1024 * 1024,
        .optional_checks = false,
    });

    try testing.expectEqual(@as(u64, 5), istanbul_test.chain_id);
    try testing.expectEqual(@as(u64, 64 * 1024 * 1024), istanbul_test.memory_limit);
    try testing.expect(!istanbul_test.optional_balance_check);
    try testing.expect(istanbul_test.hasEip(1344)); // CHAINID opcode
}
