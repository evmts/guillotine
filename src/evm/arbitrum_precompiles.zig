/// Arbitrum L2 precompiled contracts implementation
/// 
/// Arbitrum precompiles provide system information and L2-specific functionality:
/// - 0x64: ArbSys - System information and utilities
/// - 0x65: ArbInfo - Chain metadata and information
/// - 0x66: ArbAddressTable - Address aliasing utilities  
/// - 0x69: ArbosTest - Testing utilities (development only)
/// - 0x6C: ArbGasInfo - Gas pricing and optimization info
/// - 0x6D: ArbAggregator - Batch and sequencer information
/// - 0x6E: ArbRetryableTx - Retryable transaction management
/// - 0x6F: ArbStatistics - Chain statistics and metrics
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
const PrecompileError = @import("precompiles.zig").PrecompileError;
const PrecompileOutput = @import("precompiles.zig").PrecompileOutput;
const ChainConfig = @import("chain_config.zig").ChainConfig;

/// Arbitrum precompile addresses
pub const ARB_SYS_ADDRESS = primitives.Address.from_u256(0x64);
pub const ARB_INFO_ADDRESS = primitives.Address.from_u256(0x65);
pub const ARB_ADDRESS_TABLE_ADDRESS = primitives.Address.from_u256(0x66);
pub const ARB_OS_TEST_ADDRESS = primitives.Address.from_u256(0x69);
pub const ARB_GAS_INFO_ADDRESS = primitives.Address.from_u256(0x6C);
pub const ARB_AGGREGATOR_ADDRESS = primitives.Address.from_u256(0x6D);
pub const ARB_RETRYABLE_TX_ADDRESS = primitives.Address.from_u256(0x6E);
pub const ARB_STATISTICS_ADDRESS = primitives.Address.from_u256(0x6F);

/// Gas costs for Arbitrum precompiles
pub const ArbitrumGasCosts = struct {
    pub const ARB_SYS_BASE = 100;
    pub const ARB_INFO_BASE = 50;
    pub const ARB_ADDRESS_TABLE_BASE = 75;
    pub const ARB_OS_TEST_BASE = 25;
    pub const ARB_GAS_INFO_BASE = 50;
    pub const ARB_AGGREGATOR_BASE = 100;
    pub const ARB_RETRYABLE_TX_BASE = 150;
    pub const ARB_STATISTICS_BASE = 50;
};

/// Check if an address is an Arbitrum precompile
pub fn is_arbitrum_precompile(address: Address) bool {
    // Check if all bytes except the last one are zero
    for (address.bytes[0..19]) |byte| {
        if (byte != 0) return false;
    }
    // Check if the last byte is one of the Arbitrum precompile addresses
    return switch (address.bytes[19]) {
        0x64, 0x65, 0x66, 0x69, 0x6C, 0x6D, 0x6E, 0x6F => true,
        else => false,
    };
}

/// Execute an Arbitrum precompile based on its address
pub fn execute_arbitrum_precompile(
    allocator: std.mem.Allocator,
    address: Address,
    input: []const u8,
    gas_limit: u64,
    chain_config: ChainConfig,
) PrecompileError!PrecompileOutput {
    // Only execute if this is an Arbitrum chain
    if (chain_config.chain_type != .ARBITRUM) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = 0,
            .success = false,
        };
    }
    
    if (!is_arbitrum_precompile(address)) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = 0,
            .success = false,
        };
    }
    
    const precompile_id = address.bytes[19];
    return switch (precompile_id) {
        0x64 => execute_arb_sys(allocator, input, gas_limit, chain_config),
        0x65 => execute_arb_info(allocator, input, gas_limit, chain_config),
        0x66 => execute_arb_address_table(allocator, input, gas_limit, chain_config),
        0x69 => execute_arb_os_test(allocator, input, gas_limit, chain_config),
        0x6C => execute_arb_gas_info(allocator, input, gas_limit, chain_config),
        0x6D => execute_arb_aggregator(allocator, input, gas_limit, chain_config),
        0x6E => execute_arb_retryable_tx(allocator, input, gas_limit, chain_config),
        0x6F => execute_arb_statistics(allocator, input, gas_limit, chain_config),
        else => PrecompileOutput{
            .output = &.{},
            .gas_used = 0,
            .success = false,
        },
    };
}

/// 0x64: ArbSys - System information and utilities
/// Provides access to Arbitrum system information like chain ID, block numbers, etc.
pub fn execute_arb_sys(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
    chain_config: ChainConfig,
) PrecompileError!PrecompileOutput {
    const required_gas = ArbitrumGasCosts.ARB_SYS_BASE;
    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    // Parse function selector from first 4 bytes
    if (input.len < 4) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = required_gas,
            .success = false,
        };
    }

    const selector = std.mem.readInt(u32, input[0..4], .big);
    
    return switch (selector) {
        // chainId() -> uint256
        0x9a8a0592 => arb_sys_chain_id(allocator, input[4..], required_gas, chain_config),
        // arbBlockNumber() -> uint256  
        0x43ca5161 => arb_sys_block_number(allocator, input[4..], required_gas, chain_config),
        // arbBlockHash(uint256) -> bytes32
        0x1f4ba0ea => arb_sys_block_hash(allocator, input[4..], required_gas, chain_config),
        // isTopLevelCall() -> bool
        0x6a3f43ad => arb_sys_is_top_level_call(allocator, input[4..], required_gas, chain_config),
        // sendTxToL1(address,bytes) -> uint256
        0x36c2fb4e => arb_sys_send_tx_to_l1(allocator, input[4..], required_gas, chain_config),
        else => PrecompileOutput{
            .output = &.{},
            .gas_used = required_gas,
            .success = false,
        },
    };
}

fn arb_sys_chain_id(
    allocator: std.mem.Allocator,
    _: []const u8,
    required_gas: u64,
    chain_config: ChainConfig,
) PrecompileError!PrecompileOutput {
    const output = try allocator.alloc(u8, 32);
    @memset(output, 0);
    
    // Encode chain ID as 32-byte big-endian integer
    var chain_id = chain_config.chain_id;
    var i: usize = 32;
    while (i > 0 and chain_id > 0) {
        i -= 1;
        output[i] = @intCast(chain_id & 0xFF);
        chain_id >>= 8;
    }
    
    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

fn arb_sys_block_number(
    allocator: std.mem.Allocator,
    _: []const u8,
    required_gas: u64,
    _: ChainConfig,
) PrecompileError!PrecompileOutput {
    const output = try allocator.alloc(u8, 32);
    @memset(output, 0);
    
    // Mock block number - in real implementation this would come from EVM context
    const mock_block_number: u64 = 12345678;
    
    var block_num = mock_block_number;
    var i: usize = 32;
    while (i > 0 and block_num > 0) {
        i -= 1;
        output[i] = @intCast(block_num & 0xFF);
        block_num >>= 8;
    }
    
    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

fn arb_sys_block_hash(
    allocator: std.mem.Allocator,
    input: []const u8,
    required_gas: u64,
    _: ChainConfig,
) PrecompileError!PrecompileOutput {
    // Requires 32-byte block number input
    if (input.len < 32) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = required_gas,
            .success = false,
        };
    }
    
    const output = try allocator.alloc(u8, 32);
    
    // Mock block hash - in real implementation this would come from block storage
    // For now, return a deterministic hash based on input
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(input[0..32]);
    hasher.update("arbitrum_block_hash");
    hasher.final(output);
    
    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

fn arb_sys_is_top_level_call(
    allocator: std.mem.Allocator,
    _: []const u8,
    required_gas: u64,
    _: ChainConfig,
) PrecompileError!PrecompileOutput {
    const output = try allocator.alloc(u8, 32);
    @memset(output, 0);
    
    // Mock: always return true for top-level call
    // In real implementation, this would check call stack depth
    output[31] = 1;
    
    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

fn arb_sys_send_tx_to_l1(
    allocator: std.mem.Allocator,
    input: []const u8,
    required_gas: u64,
    _: ChainConfig,
) PrecompileError!PrecompileOutput {
    // Requires at least 64 bytes (address + bytes offset/length)
    if (input.len < 64) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = required_gas,
            .success = false,
        };
    }
    
    const output = try allocator.alloc(u8, 32);
    @memset(output, 0);
    
    // Mock: return a deterministic transaction ID based on input
    var tx_id: u64 = 1000000;
    for (input[0..@min(input.len, 32)]) |byte| {
        tx_id = (tx_id * 33) + byte;
    }
    
    // Encode transaction ID as 32-byte big-endian integer
    var id = tx_id;
    var i: usize = 32;
    while (i > 0 and id > 0) {
        i -= 1;
        output[i] = @intCast(id & 0xFF);
        id >>= 8;
    }
    
    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

/// 0x65: ArbInfo - Chain metadata and information
pub fn execute_arb_info(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
    chain_config: ChainConfig,
) PrecompileError!PrecompileOutput {
    const required_gas = ArbitrumGasCosts.ARB_INFO_BASE;
    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    if (input.len < 4) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = required_gas,
            .success = false,
        };
    }

    const selector = std.mem.readInt(u32, input[0..4], .big);
    
    return switch (selector) {
        // getBalance(address) -> uint256
        0xf8b2cb4f => arb_info_get_balance(allocator, input[4..], required_gas, chain_config),
        // getCode(address) -> bytes
        0x7e105ce2 => arb_info_get_code(allocator, input[4..], required_gas, chain_config),
        else => PrecompileOutput{
            .output = &.{},
            .gas_used = required_gas,
            .success = false,
        },
    };
}

fn arb_info_get_balance(
    allocator: std.mem.Allocator,
    input: []const u8,
    required_gas: u64,
    _: ChainConfig,
) PrecompileError!PrecompileOutput {
    // Requires 32-byte address input
    if (input.len < 32) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = required_gas,
            .success = false,
        };
    }
    
    const output = try allocator.alloc(u8, 32);
    @memset(output, 0);
    
    // Mock balance - in real implementation would query state
    const mock_balance: u64 = 1000000000000000000; // 1 ETH in wei
    
    var balance = mock_balance;
    var i: usize = 32;
    while (i > 0 and balance > 0) {
        i -= 1;
        output[i] = @intCast(balance & 0xFF);
        balance >>= 8;
    }
    
    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

fn arb_info_get_code(
    allocator: std.mem.Allocator,
    input: []const u8,
    required_gas: u64,
    _: ChainConfig,
) PrecompileError!PrecompileOutput {
    // Requires 32-byte address input
    if (input.len < 32) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = required_gas,
            .success = false,
        };
    }
    
    // Mock empty code - in real implementation would query state
    const mock_code = "";
    
    const output = try allocator.alloc(u8, 32 + mock_code.len);
    @memset(output, 0);
    
    // Encode as bytes: offset(32) + length(32) + data
    output[31] = 32; // Offset to data
    // Length is already 0 for empty code
    
    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

/// Implement stubs for remaining precompiles
pub fn execute_arb_address_table(
    allocator: std.mem.Allocator,
    _: []const u8,
    gas_limit: u64,
    _: ChainConfig,
) PrecompileError!PrecompileOutput {
    const required_gas = ArbitrumGasCosts.ARB_ADDRESS_TABLE_BASE;
    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    const output = try allocator.alloc(u8, 32);
    @memset(output, 0);
    
    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

pub fn execute_arb_os_test(
    allocator: std.mem.Allocator,
    _: []const u8,
    gas_limit: u64,
    _: ChainConfig,
) PrecompileError!PrecompileOutput {
    const required_gas = ArbitrumGasCosts.ARB_OS_TEST_BASE;
    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    const output = try allocator.alloc(u8, 32);
    @memset(output, 0);
    
    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

pub fn execute_arb_gas_info(
    allocator: std.mem.Allocator,
    _: []const u8,
    gas_limit: u64,
    _: ChainConfig,
) PrecompileError!PrecompileOutput {
    const required_gas = ArbitrumGasCosts.ARB_GAS_INFO_BASE;
    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    const output = try allocator.alloc(u8, 32);
    @memset(output, 0);
    
    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

pub fn execute_arb_aggregator(
    allocator: std.mem.Allocator,
    _: []const u8,
    gas_limit: u64,
    _: ChainConfig,
) PrecompileError!PrecompileOutput {
    const required_gas = ArbitrumGasCosts.ARB_AGGREGATOR_BASE;
    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    const output = try allocator.alloc(u8, 32);
    @memset(output, 0);
    
    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

pub fn execute_arb_retryable_tx(
    allocator: std.mem.Allocator,
    _: []const u8,
    gas_limit: u64,
    _: ChainConfig,
) PrecompileError!PrecompileOutput {
    const required_gas = ArbitrumGasCosts.ARB_RETRYABLE_TX_BASE;
    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    const output = try allocator.alloc(u8, 32);
    @memset(output, 0);
    
    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

pub fn execute_arb_statistics(
    allocator: std.mem.Allocator,
    _: []const u8,
    gas_limit: u64,
    _: ChainConfig,
) PrecompileError!PrecompileOutput {
    const required_gas = ArbitrumGasCosts.ARB_STATISTICS_BASE;
    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    const output = try allocator.alloc(u8, 32);
    @memset(output, 0);
    
    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "arbitrum precompile address detection" {
    // Test all Arbitrum precompile addresses
    try testing.expect(is_arbitrum_precompile(ARB_SYS_ADDRESS));
    try testing.expect(is_arbitrum_precompile(ARB_INFO_ADDRESS));
    try testing.expect(is_arbitrum_precompile(ARB_ADDRESS_TABLE_ADDRESS));
    try testing.expect(is_arbitrum_precompile(ARB_OS_TEST_ADDRESS));
    try testing.expect(is_arbitrum_precompile(ARB_GAS_INFO_ADDRESS));
    try testing.expect(is_arbitrum_precompile(ARB_AGGREGATOR_ADDRESS));
    try testing.expect(is_arbitrum_precompile(ARB_RETRYABLE_TX_ADDRESS));
    try testing.expect(is_arbitrum_precompile(ARB_STATISTICS_ADDRESS));
    
    // Test non-Arbitrum addresses
    try testing.expect(!is_arbitrum_precompile(primitives.Address.from_u256(0x01))); // Regular precompile
    try testing.expect(!is_arbitrum_precompile(primitives.Address.from_u256(0x63))); // Below Arbitrum range
    try testing.expect(!is_arbitrum_precompile(primitives.Address.from_u256(0x70))); // Above Arbitrum range
    try testing.expect(!is_arbitrum_precompile(primitives.Address.from_u256(0x67))); // Gap in range
}

test "execute_arb_sys_chain_id" {
    const chain_config = ChainConfig.from_chain_id(42161); // Arbitrum One
    
    // chainId() function selector: 0x9a8a0592
    const input = [_]u8{0x9a, 0x8a, 0x05, 0x92};
    
    const result = try execute_arb_sys(testing.allocator, &input, 1000, chain_config);
    defer testing.allocator.free(result.output);
    
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    try testing.expectEqual(ArbitrumGasCosts.ARB_SYS_BASE, result.gas_used);
    
    // Verify chain ID encoding (42161 = 0xA4B1)
    try testing.expectEqual(@as(u8, 0xA4), result.output[30]);
    try testing.expectEqual(@as(u8, 0xB1), result.output[31]);
    
    // Verify zero padding
    for (result.output[0..30]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "execute_arb_sys_block_number" {
    const chain_config = ChainConfig.from_chain_id(42161);
    
    // arbBlockNumber() function selector: 0x43ca5161
    const input = [_]u8{0x43, 0xca, 0x51, 0x61};
    
    const result = try execute_arb_sys(testing.allocator, &input, 1000, chain_config);
    defer testing.allocator.free(result.output);
    
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    // Verify mock block number is encoded
    var decoded_block_num: u64 = 0;
    for (result.output) |byte| {
        decoded_block_num = (decoded_block_num << 8) | byte;
    }
    try testing.expectEqual(@as(u64, 12345678), decoded_block_num);
}

test "execute_arb_sys_block_hash" {
    const chain_config = ChainConfig.from_chain_id(42161);
    
    // arbBlockHash(uint256) function selector + block number
    var input = [_]u8{0x1f, 0x4b, 0xa0, 0xea} ++ [_]u8{0} ** 32;
    input[35] = 100; // Block number 100
    
    const result = try execute_arb_sys(testing.allocator, &input, 1000, chain_config);
    defer testing.allocator.free(result.output);
    
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    // Verify it's not all zeros (deterministic hash)
    var all_zero = true;
    for (result.output) |byte| {
        if (byte != 0) {
            all_zero = false;
            break;
        }
    }
    try testing.expect(!all_zero);
}

test "execute_arb_sys_is_top_level_call" {
    const chain_config = ChainConfig.from_chain_id(42161);
    
    // isTopLevelCall() function selector: 0x6a3f43ad
    const input = [_]u8{0x6a, 0x3f, 0x43, 0xad};
    
    const result = try execute_arb_sys(testing.allocator, &input, 1000, chain_config);
    defer testing.allocator.free(result.output);
    
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    // Should return true (1) for top-level call
    try testing.expectEqual(@as(u8, 1), result.output[31]);
    
    // Verify zero padding
    for (result.output[0..31]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "execute_arb_sys_send_tx_to_l1" {
    const chain_config = ChainConfig.from_chain_id(42161);
    
    // sendTxToL1(address,bytes) function selector + mock data
    var input = [_]u8{0x36, 0xc2, 0xfb, 0x4e} ++ [_]u8{0} ** 64;
    // Add some test data to generate deterministic tx ID
    input[20] = 0x12;
    input[21] = 0x34;
    
    const result = try execute_arb_sys(testing.allocator, &input, 1000, chain_config);
    defer testing.allocator.free(result.output);
    
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    // Verify it's not all zeros (should have tx ID)
    var all_zero = true;
    for (result.output) |byte| {
        if (byte != 0) {
            all_zero = false;
            break;
        }
    }
    try testing.expect(!all_zero);
}

test "execute_arb_info_get_balance" {
    const chain_config = ChainConfig.from_chain_id(42161);
    
    // getBalance(address) function selector + address
    var input = [_]u8{0xf8, 0xb2, 0xcb, 0x4f} ++ [_]u8{0} ** 32;
    input[35] = 0x42; // Test address
    
    const result = try execute_arb_info(testing.allocator, &input, 1000, chain_config);
    defer testing.allocator.free(result.output);
    
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    // Verify mock balance is encoded (1 ETH = 10^18 wei)
    var decoded_balance: u64 = 0;
    for (result.output[24..32]) |byte| {
        decoded_balance = (decoded_balance << 8) | byte;
    }
    try testing.expectEqual(@as(u64, 1000000000000000000), decoded_balance);
}

test "execute_arb_info_get_code" {
    const chain_config = ChainConfig.from_chain_id(42161);
    
    // getCode(address) function selector + address
    var input = [_]u8{0x7e, 0x10, 0x5c, 0xe2} ++ [_]u8{0} ** 32;
    input[35] = 0x42; // Test address
    
    const result = try execute_arb_info(testing.allocator, &input, 1000, chain_config);
    defer testing.allocator.free(result.output);
    
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    // Should return offset to empty data
    try testing.expectEqual(@as(u8, 32), result.output[31]); // Offset
    // Length should be 0 (already zeroed)
}

test "arbitrum_precompile_gas_costs" {
    // Test that all gas costs are positive and reasonable
    try testing.expect(ArbitrumGasCosts.ARB_SYS_BASE > 0);
    try testing.expect(ArbitrumGasCosts.ARB_INFO_BASE > 0);
    try testing.expect(ArbitrumGasCosts.ARB_ADDRESS_TABLE_BASE > 0);
    try testing.expect(ArbitrumGasCosts.ARB_OS_TEST_BASE > 0);
    try testing.expect(ArbitrumGasCosts.ARB_GAS_INFO_BASE > 0);
    try testing.expect(ArbitrumGasCosts.ARB_AGGREGATOR_BASE > 0);
    try testing.expect(ArbitrumGasCosts.ARB_RETRYABLE_TX_BASE > 0);
    try testing.expect(ArbitrumGasCosts.ARB_STATISTICS_BASE > 0);
    
    // Test relative gas costs make sense
    try testing.expect(ArbitrumGasCosts.ARB_RETRYABLE_TX_BASE >= ArbitrumGasCosts.ARB_SYS_BASE); // More complex operation
    try testing.expect(ArbitrumGasCosts.ARB_OS_TEST_BASE <= ArbitrumGasCosts.ARB_SYS_BASE); // Test function cheaper
}

test "arbitrum_precompile_insufficient_gas" {
    const chain_config = ChainConfig.from_chain_id(42161);
    const input = [_]u8{0x9a, 0x8a, 0x05, 0x92}; // chainId()
    
    // Test with insufficient gas
    const result = try execute_arb_sys(testing.allocator, &input, 50, chain_config);
    
    try testing.expect(!result.success);
    try testing.expectEqual(@as(usize, 0), result.output.len);
    try testing.expectEqual(@as(u64, 50), result.gas_used); // Should use all available gas
}

test "arbitrum_precompile_invalid_selector" {
    const chain_config = ChainConfig.from_chain_id(42161);
    const input = [_]u8{0xFF, 0xFF, 0xFF, 0xFF}; // Invalid selector
    
    const result = try execute_arb_sys(testing.allocator, &input, 1000, chain_config);
    
    try testing.expect(!result.success);
    try testing.expectEqual(@as(usize, 0), result.output.len);
}

test "arbitrum_precompile_non_arbitrum_chain" {
    const eth_chain_config = ChainConfig.from_chain_id(1); // Ethereum mainnet
    const input = [_]u8{0x9a, 0x8a, 0x05, 0x92}; // chainId()
    
    const result = try execute_arbitrum_precompile(
        testing.allocator,
        ARB_SYS_ADDRESS,
        &input,
        1000,
        eth_chain_config,
    );
    
    try testing.expect(!result.success);
    try testing.expectEqual(@as(usize, 0), result.output.len);
}

test "execute_all_arbitrum_precompiles_smoke_test" {
    const chain_config = ChainConfig.from_chain_id(42161);
    const addresses = [_]Address{
        ARB_SYS_ADDRESS,
        ARB_INFO_ADDRESS,
        ARB_ADDRESS_TABLE_ADDRESS,
        ARB_OS_TEST_ADDRESS,
        ARB_GAS_INFO_ADDRESS,
        ARB_AGGREGATOR_ADDRESS,
        ARB_RETRYABLE_TX_ADDRESS,
        ARB_STATISTICS_ADDRESS,
    };
    
    for (addresses) |addr| {
        const result = try execute_arbitrum_precompile(
            testing.allocator,
            addr,
            &[_]u8{},
            1000,
            chain_config,
        );
        defer if (result.output.len > 0) testing.allocator.free(result.output);
        
        // All should at least not error with gas (may fail due to invalid input)
        try testing.expect(result.gas_used <= 1000);
    }
}