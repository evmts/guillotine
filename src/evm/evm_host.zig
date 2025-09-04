//! Host interface methods for EVM execution environment.
//!
//! This module provides the host interface that allows the EVM to interact
//! with the external environment including:
//! - Account balance and existence queries
//! - Contract code retrieval
//! - Storage operations with proper journaling
//! - Log emission
//! - EIP-214 static call constraint enforcement
//!
//! These methods are extracted from the main EVM struct to improve
//! modularity and maintainability while maintaining identical APIs.

const std = @import("std");
const log = @import("../log.zig");
const primitives = @import("primitives");

/// Creates host interface methods for a given EVM type.
pub fn Host(comptime EvmType: type) type {
    return struct {
        /// Get account balance
        pub fn get_balance(evm: *EvmType, address: primitives.Address) u256 {
            return evm.database.get_balance(address.bytes) catch 0;
        }

        /// Check if account exists
        pub fn account_exists(evm: *EvmType, address: primitives.Address) bool {
            return evm.database.account_exists(address.bytes);
        }

        /// Get contract code at address
        pub fn get_code(evm: *EvmType, address: primitives.Address) []const u8 {
            return evm.database.get_code_by_address(address.bytes) catch &.{};
        }

        /// Get block information (via context module)
        pub fn get_block_info(evm: *EvmType) @import("block_info.zig").DefaultBlockInfo {
            return evm.block_info;
        }

        /// Emit log event
        pub fn emit_log(evm: *EvmType, contract_address: primitives.Address, topics: []const u256, data: []const u8) void {
            // EIP-214: Prevent log emission in static context
            if (evm.depth > 0 and evm.call_stack[evm.depth - 1].is_static) {
                return; // Silently fail in static context
            }
            
            // Allocate copies with the main allocator so tests can free via evm.allocator
            const topics_copy = evm.allocator.dupe(u256, topics) catch return;
            const data_copy = evm.allocator.dupe(u8, data) catch return;

            evm.logs.append(evm.allocator, @import("call_result.zig").Log{
                .address = contract_address,
                .topics = topics_copy,
                .data = data_copy,
            }) catch return;
        }

        /// Host interface for inner calls - delegates to main call
        pub fn host_inner_call(evm: *EvmType, params: @import("call_params.zig").CallParams) !@import("call_result.zig").CallResult {
            return evm.inner_call(params);
        }

        /// Get storage value
        pub fn get_storage(evm: *EvmType, address: primitives.Address, slot: u256) u256 {
            return evm.database.get_storage(address.bytes, slot) catch 0;
        }

        /// Set storage value with proper journaling and static context checks
        pub fn set_storage(evm: *EvmType, address: primitives.Address, slot: u256, value: u256) !void {
            // EIP-214: Prevent storage writes in static context
            if (evm.depth > 0 and evm.call_stack[evm.depth - 1].is_static) {
                return error.StaticCallViolation;
            }
            // Record original value for journal
            const original_value = get_storage(evm, address, slot);
            try evm.journal.record_storage_change(evm.current_snapshot_id, address, slot, original_value);
            try evm.database.set_storage(address.bytes, slot, value);
        }
    };
}

// Tests for the Host module
test "Host - account operations" {
    const std_test = std.testing;
    const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
    const TransactionContext = @import("transaction_context.zig").TransactionContext;
    const EvmConfig = @import("evm_config.zig").EvmConfig;
    const BlockInfo = @import("block_info.zig").DefaultBlockInfo;
    const Account = @import("database_interface_account.zig").Account;

    // Create test EVM instance
    var db = MemoryDatabase.init(std_test.allocator);
    defer db.deinit();

    const test_block_info = BlockInfo{
        .number = 1000,
        .timestamp = 1600000000,
        .chain_id = 1,
        .difficulty = 1000000,
        .gas_limit = 30000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .basefee = 1000000000,
        .prevrandao = [32]u8{0} ** 32,
        .blob_excess_gas_and_price = .{ .excess_blob_gas = 0, .blob_gasprice = 1 },
    };

    const test_context = TransactionContext{
        .gas_limit = 30000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .chain_id = 1,
    };

    const TestEvm = @import("evm.zig").Evm(EvmConfig{});
    var evm = try TestEvm.init(
        std_test.allocator,
        &db.database,
        test_block_info,
        test_context,
        1000000000,
        primitives.Address.ZERO_ADDRESS,
        .shanghai,
    );
    defer evm.deinit();

    const Host = @This().Host(TestEvm);

    // Setup test account
    const test_addr = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0x00} ** 19 };
    const test_account = Account{ .balance = 5000, .nonce = 1, .code_hash = [_]u8{0x01} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.database.set_account(test_addr.bytes, test_account);

    // Test balance query
    const balance = Host.get_balance(&evm, test_addr);
    try std_test.expectEqual(@as(u256, 5000), balance);

    // Test account existence
    try std_test.expect(Host.account_exists(&evm, test_addr));
    try std_test.expect(!Host.account_exists(&evm, primitives.Address.ZERO_ADDRESS));

    // Test zero balance for non-existent account
    const zero_balance = Host.get_balance(&evm, primitives.Address.ZERO_ADDRESS);
    try std_test.expectEqual(@as(u256, 0), zero_balance);
}

test "Host - storage operations" {
    const std_test = std.testing;
    const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
    const TransactionContext = @import("transaction_context.zig").TransactionContext;
    const EvmConfig = @import("evm_config.zig").EvmConfig;
    const BlockInfo = @import("block_info.zig").DefaultBlockInfo;

    // Create test EVM instance
    var db = MemoryDatabase.init(std_test.allocator);
    defer db.deinit();

    const test_block_info = BlockInfo{
        .number = 1000,
        .timestamp = 1600000000,
        .chain_id = 1,
        .difficulty = 1000000,
        .gas_limit = 30000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .basefee = 1000000000,
        .prevrandao = [32]u8{0} ** 32,
        .blob_excess_gas_and_price = .{ .excess_blob_gas = 0, .blob_gasprice = 1 },
    };

    const test_context = TransactionContext{
        .gas_limit = 30000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .chain_id = 1,
    };

    const TestEvm = @import("evm.zig").Evm(EvmConfig{});
    var evm = try TestEvm.init(
        std_test.allocator,
        &db.database,
        test_block_info,
        test_context,
        1000000000,
        primitives.Address.ZERO_ADDRESS,
        .shanghai,
    );
    defer evm.deinit();

    const Host = @This().Host(TestEvm);

    // Test storage operations
    const address = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0x00} ** 19 };
    const key = 42;
    const value = 1337;

    // Initially should return 0
    const initial_value = Host.get_storage(&evm, address, key);
    try std_test.expectEqual(@as(u256, 0), initial_value);

    // Set storage value
    try Host.set_storage(&evm, address, key, value);

    // Verify value was stored
    const stored_value = Host.get_storage(&evm, address, key);
    try std_test.expectEqual(@as(u256, value), stored_value);
}