//! Context methods for EVM execution environment queries.
//!
//! This module provides access to execution context information including:
//! - Hardfork version queries
//! - Block information access
//! - Transaction context queries
//! - Gas pricing information
//! - Chain and block identifiers
//!
//! These methods are extracted from the main EVM struct to improve
//! modularity and maintainability while maintaining identical APIs.

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
const Hardfork = @import("hardfork.zig").Hardfork;
const BlockInfo = @import("block_info.zig").DefaultBlockInfo;

/// Creates context methods for a given EVM type.
pub fn Context(comptime EvmType: type) type {
    return struct {
        /// Check if the configured hardfork is at least as recent as the target.
        pub fn is_hardfork_at_least(evm: *EvmType, target: Hardfork) bool {
            return @intFromEnum(evm.hardfork_config) >= @intFromEnum(target);
        }

        /// Get the configured hardfork version.
        pub fn get_hardfork(evm: *EvmType) Hardfork {
            return evm.hardfork_config;
        }

        /// Get the current block information.
        pub fn get_block_info(evm: *EvmType) BlockInfo {
            return evm.block_info;
        }

        /// Get the current call depth.
        pub fn get_depth(evm: *EvmType) u11 {
            return @intCast(evm.depth);
        }

        /// Get the transaction origin (sender).
        pub fn get_tx_origin(evm: *EvmType) Address {
            return evm.origin;
        }

        /// Get the current caller address.
        pub fn get_caller(evm: *EvmType) Address {
            if (evm.depth == 0) return evm.origin;
            return evm.call_stack[evm.depth - 1].caller;
        }

        /// Get the current call value.
        pub fn get_call_value(evm: *EvmType) u256 {
            if (evm.depth == 0) return 0;
            return evm.call_stack[evm.depth - 1].value;
        }

        /// Check if we're in a static call context (EIP-214).
        pub fn is_static_context(evm: *EvmType) bool {
            if (evm.depth == 0) return false;
            return evm.call_stack[evm.depth - 1].is_static;
        }

        /// Get the gas price for this transaction.
        pub fn get_gas_price(evm: *EvmType) u256 {
            return evm.gas_price;
        }

        /// Get the chain ID.
        pub fn get_chain_id(evm: *EvmType) u64 {
            return evm.block_info.chain_id;
        }

        /// Get a block hash by number.
        pub fn get_block_hash(evm: *EvmType, block_number: u64) ?[32]u8 {
            const current_block = evm.block_info.number;

            // Use EIP-2935 historical block hashes if available
            // This provides access to older block hashes via system contract
            const historical_block_hashes = @import("historical_block_hashes.zig");
            const hash_opt = historical_block_hashes.HistoricalBlockHashesContract.getBlockHash(
                evm.database,
                block_number,
                current_block,
            ) catch |err| {
                const log = @import("../log.zig");
                log.debug("Failed to get block hash from history contract: {}", .{err});
                // Fall back to standard behavior on error
                
                // EVM BLOCKHASH rules:
                // - Return null for current block and future blocks
                // - Return null for blocks older than 256 blocks
                // - Return null for block 0 (genesis)
                if (block_number >= current_block or
                    current_block > block_number + 256 or
                    block_number == 0)
                {
                    return null;
                }
                
                // For testing/simulation purposes, generate a deterministic hash
                var hash: [32]u8 = undefined;
                hash[0..8].* = std.mem.toBytes(block_number);
                hash[8..16].* = std.mem.toBytes(current_block);
                
                // Fill rest with deterministic pattern based on block number
                var i: usize = 16;
                while (i < 32) : (i += 1) {
                    hash[i] = @as(u8, @truncate(block_number +% i));
                }
                
                return hash;
            };
            
            if (hash_opt) |hash| {
                return hash;
            }
            
            // If no hash found in storage, fall back to standard behavior
            // - Return null for current block and future blocks
            // - Return null for blocks older than 256 blocks
            // - Return null for block 0 (genesis)
            if (block_number >= current_block or
                current_block > block_number + 256 or
                block_number == 0)
            {
                return null;
            }

            // For testing/simulation purposes, generate a deterministic hash
            // In a real implementation, this would look up the actual block hash
            // from the blockchain state or a block hash ring buffer
            var hash: [32]u8 = undefined;
            hash[0..8].* = std.mem.toBytes(block_number);
            hash[8..16].* = std.mem.toBytes(current_block);

            // Fill rest with deterministic pattern based on block number
            var i: usize = 16;
            while (i < 32) : (i += 1) {
                hash[i] = @as(u8, @truncate(block_number +% i));
            }

            return hash;
        }

        /// Get blob hash at index (EIP-4844).
        pub fn get_blob_hash(evm: *EvmType, index: u256) ?[32]u8 {
            if (index >= evm.context.blob_versioned_hashes.len) return null;
            return evm.context.blob_versioned_hashes[@intCast(index)];
        }

        /// Get blob base fee (EIP-4844).
        pub fn get_blob_base_fee(evm: *EvmType) u256 {
            return evm.context.blob_base_fee;
        }

        /// Get the current input data.
        pub fn get_input(evm: *EvmType) []const u8 {
            return evm.current_input;
        }

        /// Get the current return data.
        pub fn get_return_data(evm: *EvmType) []const u8 {
            return evm.return_data;
        }
    };
}

// Tests for the Context module
test "Context - hardfork queries" {
    const std_test = std.testing;
    const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
    const TransactionContext = @import("transaction_context.zig").TransactionContext;
    const EvmConfig = @import("evm_config.zig").EvmConfig;

    // Create test EVM instance
    var db = MemoryDatabase.init(std_test.allocator);
    defer db.deinit();

    const test_block_info = BlockInfo{
        .number = 1000,
        .timestamp = 1600000000,
        .chain_id = 1,
        .difficulty = 1000000,
        .gas_limit = 30000000,
        .coinbase = Address.ZERO_ADDRESS,
        .basefee = 1000000000,
        .prevrandao = [32]u8{0} ** 32,
        .blob_excess_gas_and_price = .{ .excess_blob_gas = 0, .blob_gasprice = 1 },
    };

    const test_context = TransactionContext{
        .gas_limit = 30000000,
        .coinbase = Address.ZERO_ADDRESS,
        .chain_id = 1,
    };

    const TestEvm = @import("evm.zig").Evm(EvmConfig{});
    var evm = try TestEvm.init(
        std_test.allocator,
        &db.database,
        test_block_info,
        test_context,
        1000000000,
        Address.ZERO_ADDRESS,
        .shanghai,
    );
    defer evm.deinit();

    const Context = @This().Context(TestEvm);

    // Test hardfork queries
    try std_test.expect(Context.is_hardfork_at_least(&evm, .shanghai));
    try std_test.expect(Context.is_hardfork_at_least(&evm, .london));
    try std_test.expect(!Context.is_hardfork_at_least(&evm, .cancun));

    try std_test.expectEqual(.shanghai, Context.get_hardfork(&evm));
}

test "Context - block and transaction info" {
    const std_test = std.testing;
    const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
    const TransactionContext = @import("transaction_context.zig").TransactionContext;
    const EvmConfig = @import("evm_config.zig").EvmConfig;

    // Create test EVM instance
    var db = MemoryDatabase.init(std_test.allocator);
    defer db.deinit();

    const test_block_info = BlockInfo{
        .number = 2000,
        .timestamp = 1700000000,
        .chain_id = 5,
        .difficulty = 2000000,
        .gas_limit = 40000000,
        .coinbase = Address.ZERO_ADDRESS,
        .basefee = 2000000000,
        .prevrandao = [32]u8{0} ** 32,
        .blob_excess_gas_and_price = .{ .excess_blob_gas = 100, .blob_gasprice = 1000 },
    };

    const test_context = TransactionContext{
        .gas_limit = 30000000,
        .coinbase = Address.ZERO_ADDRESS,
        .chain_id = 1,
    };

    const TestEvm = @import("evm.zig").Evm(EvmConfig{});
    var evm = try TestEvm.init(
        std_test.allocator,
        &db.database,
        test_block_info,
        test_context,
        2000000000,
        Address.ZERO_ADDRESS,
        .cancun,
    );
    defer evm.deinit();

    const Context = @This().Context(TestEvm);

    // Test context queries
    try std_test.expectEqual(test_block_info, Context.get_block_info(&evm));
    try std_test.expectEqual(@as(u11, 0), Context.get_depth(&evm));
    try std_test.expectEqual(Address.ZERO_ADDRESS, Context.get_tx_origin(&evm));
    try std_test.expectEqual(@as(u256, 2000000000), Context.get_gas_price(&evm));
    try std_test.expectEqual(@as(u64, 5), Context.get_chain_id(&evm));
    try std_test.expectEqual(@as(u256, 1000), Context.get_blob_base_fee(&evm));
}

test "Context - call stack context" {
    const std_test = std.testing;
    const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
    const TransactionContext = @import("transaction_context.zig").TransactionContext;
    const EvmConfig = @import("evm_config.zig").EvmConfig;

    // Create test EVM instance
    var db = MemoryDatabase.init(std_test.allocator);
    defer db.deinit();

    const test_block_info = BlockInfo{
        .number = 1000,
        .timestamp = 1600000000,
        .chain_id = 1,
        .difficulty = 1000000,
        .gas_limit = 30000000,
        .coinbase = Address.ZERO_ADDRESS,
        .basefee = 1000000000,
        .prevrandao = [32]u8{0} ** 32,
        .blob_excess_gas_and_price = .{ .excess_blob_gas = 0, .blob_gasprice = 1 },
    };

    const test_context = TransactionContext{
        .gas_limit = 30000000,
        .coinbase = Address.ZERO_ADDRESS,
        .chain_id = 1,
    };

    const TestEvm = @import("evm.zig").Evm(EvmConfig{});
    var evm = try TestEvm.init(
        std_test.allocator,
        &db.database,
        test_block_info,
        test_context,
        1000000000,
        Address.ZERO_ADDRESS,
        .shanghai,
    );
    defer evm.deinit();

    const Context = @This().Context(TestEvm);

    // Test initial state (no call stack)
    try std_test.expectEqual(Address.ZERO_ADDRESS, Context.get_caller(&evm));
    try std_test.expectEqual(@as(u256, 0), Context.get_call_value(&evm));
    try std_test.expect(!Context.is_static_context(&evm));
}