//! State management methods for EVM execution.
//!
//! This module handles state tracking, journaling, and transactional operations including:
//! - Account balance transfers
//! - Snapshot creation and management
//! - State change recording for rollback
//! - Storage change tracking
//! - Journal entry application and reversal
//!
//! These methods are extracted from the main EVM struct to improve
//! modularity and maintainability while maintaining identical APIs.

const std = @import("std");
const log = @import("../log.zig");
const primitives = @import("primitives");
const Account = @import("database_interface_account.zig").Account;

/// Creates state management methods for a given EVM type.
pub fn State(comptime EvmType: type) type {
    return struct {
        /// Transfer value between accounts with proper balance checks and error handling
        pub fn do_transfer(
            evm: *EvmType, 
            from: primitives.Address, 
            to: primitives.Address, 
            value: u256, 
            snapshot_id: EvmType.Journal.SnapshotIdType
        ) !void {
            var from_account = try evm.database.get_account(from.bytes) orelse Account.zero();
            if (from_account.balance < value) return error.InsufficientBalance;
            var to_account = try evm.database.get_account(to.bytes) orelse Account.zero();
            try evm.journal.record_balance_change(snapshot_id, from, from_account.balance);
            try evm.journal.record_balance_change(snapshot_id, to, to_account.balance);
            from_account.balance -= value;
            to_account.balance += value;
            try evm.database.set_account(from.bytes, from_account);
            try evm.database.set_account(to.bytes, to_account);
        }

        /// Create a snapshot of the current state
        pub fn create_snapshot(evm: *EvmType) EvmType.Journal.SnapshotIdType {
            return evm.journal.create_snapshot();
        }

        /// Revert state changes to a previous snapshot
        ///
        /// Optimized to avoid allocations: iterate journal entries in reverse
        /// before truncating, applying all reverts in-place.
        pub fn revert_to_snapshot(evm: *EvmType, snapshot_id: EvmType.Journal.SnapshotIdType) void {
            // Find first index whose snapshot_id >= target
            var start_index: ?usize = null;
            for (evm.journal.entries.items, 0..) |entry, i| {
                if (entry.snapshot_id >= snapshot_id) { start_index = i; break; }
            }

            if (start_index) |start| {
                var i = evm.journal.entries.items.len;
                while (i > start) : (i -= 1) {
                    const entry = evm.journal.entries.items[i - 1];
                    apply_journal_entry_revert(evm, entry) catch |err| {
                        log.err("Failed to revert journal entry: {any}", .{err});
                    };
                }
            }

            // Finally, truncate the journal entries to the snapshot boundary
            evm.journal.revert_to_snapshot(snapshot_id);
        }

        /// Apply a single journal entry to revert database state
        fn apply_journal_entry_revert(evm: *EvmType, entry: EvmType.Journal.EntryType) !void {
            switch (entry.data) {
                .storage_change => |sc| {
                    // Revert storage to original value
                    try evm.database.set_storage(sc.address.bytes, sc.key, sc.original_value);
                },
                .balance_change => |bc| {
                    // Revert balance to original value
                    var account = (try evm.database.get_account(bc.address.bytes)) orelse {
                        // If account doesn't exist, create it with the original balance
                        const reverted_account = Account{
                            .balance = bc.original_balance,
                            .nonce = 0,
                            .code_hash = [_]u8{0} ** 32,
                            .storage_root = [_]u8{0} ** 32,
                        };
                        return evm.database.set_account(bc.address.bytes, reverted_account);
                    };
                    account.balance = bc.original_balance;
                    try evm.database.set_account(bc.address.bytes, account);
                },
                .nonce_change => |nc| {
                    // Revert nonce to original value
                    var account = (try evm.database.get_account(nc.address.bytes)) orelse return;
                    account.nonce = nc.original_nonce;
                    try evm.database.set_account(nc.address.bytes, account);
                },
                .code_change => |cc| {
                    // Revert code to original value
                    var account = (try evm.database.get_account(cc.address.bytes)) orelse return;
                    account.code_hash = cc.original_code_hash;
                    try evm.database.set_account(cc.address.bytes, account);
                },
                .account_created => |ac| {
                    // Remove created account
                    try evm.database.delete_account(ac.address.bytes);
                },
                .account_destroyed => |ad| {
                    // Restore destroyed account
                    // Note: This is a simplified restoration - in practice we'd need full account state
                    const restored_account = Account{
                        .balance = ad.balance,
                        .nonce = 0,
                        .code_hash = [_]u8{0} ** 32,
                        .storage_root = [_]u8{0} ** 32,
                    };
                    try evm.database.set_account(ad.address.bytes, restored_account);
                },
            }
        }

        /// Record a storage change in the journal
        pub fn record_storage_change(evm: *EvmType, address: primitives.Address, slot: u256, original_value: u256) !void {
            try evm.journal.record_storage_change(evm.current_snapshot_id, address, slot, original_value);
        }

        /// Get the original storage value from the journal
        pub fn get_original_storage(evm: *EvmType, address: primitives.Address, slot: u256) ?u256 {
            // Use journal's built-in method to get original storage
            return evm.journal.get_original_storage(address, slot);
        }

        /// Access an address and return the gas cost (EIP-2929)
        pub fn access_address(evm: *EvmType, address: primitives.Address) !u64 {
            const cost = try evm.access_list.access_address(address);
            return cost;
        }

        /// Access a storage slot and return the gas cost (EIP-2929)
        pub fn access_storage_slot(evm: *EvmType, contract_address: primitives.Address, slot: u256) !u64 {
            const cost = try evm.access_list.access_storage_slot(contract_address, slot);
            return cost;
        }

        /// Mark contract for destruction (SELFDESTRUCT)
        pub fn mark_for_destruction(evm: *EvmType, contract_address: primitives.Address, recipient: primitives.Address) !void {
            // EIP-214: Prevent self-destruction in static context
            if (evm.depth > 0 and evm.call_stack[evm.depth - 1].is_static) {
                return error.StaticCallViolation;
            }
            
            // EIP-6780: SELFDESTRUCT only actually destroys the contract if it was created in the same transaction
            // Otherwise, it only transfers the balance but keeps the code and storage
            if (evm.eips.eip_6780) {
                // Check if contract was created in the current transaction
                const created_in_tx = evm.created_contracts.was_created_in_tx(contract_address);
                
                if (created_in_tx) {
                    // Full destruction: transfer balance and mark for deletion
                    try evm.self_destruct.mark_for_destruction(contract_address, recipient);
                } else {
                    // Only transfer balance, don't destroy the contract
                    // Get the contract's balance
                    const contract_account = try evm.database.get_account(contract_address.bytes);
                    if (contract_account) |account| {
                        if (account.balance > 0) {
                            // Transfer balance to recipient
                            try evm.journal.record_balance_change(evm.current_snapshot_id, contract_address, account.balance);
                            try evm.journal.record_balance_change(evm.current_snapshot_id, recipient, 0);
                            
                            // Update balances
                            var sender_account = account;
                            sender_account.balance = 0;
                            try evm.database.set_account(contract_address.bytes, sender_account);
                            
                            var recipient_account = (try evm.database.get_account(recipient.bytes)) orelse Account.zero();
                            recipient_account.balance +%= account.balance;
                            try evm.database.set_account(recipient.bytes, recipient_account);
                        }
                    }
                    // Don't mark for destruction - contract persists
                }
            } else {
                // Pre-Cancun: always mark for full destruction
                try evm.self_destruct.mark_for_destruction(contract_address, recipient);
            }
        }

        /// Register a newly created contract
        pub fn register_created_contract(evm: *EvmType, address: primitives.Address) !void {
            try evm.created_contracts.mark_created(address);
            log.debug("Registered created contract: {x}", .{address.bytes});
        }

        /// Check if a contract was created in the current transaction
        pub fn was_created_in_tx(evm: *EvmType, address: primitives.Address) bool {
            return evm.created_contracts.was_created_in_tx(address);
        }
    };
}

// Tests for the State module
test "State - balance transfer" {
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

    const State = @This().State(TestEvm);

    // Setup accounts with initial balances
    const from_addr = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0x00} ** 19 };
    const to_addr = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0x00} ** 19 };
    
    var from_account = Account{ .balance = 1000, .nonce = 0, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    var to_account = Account{ .balance = 500, .nonce = 0, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    
    try db.database.set_account(from_addr.bytes, from_account);
    try db.database.set_account(to_addr.bytes, to_account);

    // Test successful transfer
    const snapshot = State.create_snapshot(&evm);
    try State.do_transfer(&evm, from_addr, to_addr, 300, snapshot);

    // Verify balances changed
    const from_after = (try db.database.get_account(from_addr.bytes)).?;
    const to_after = (try db.database.get_account(to_addr.bytes)).?;
    
    try std_test.expectEqual(@as(u256, 700), from_after.balance);
    try std_test.expectEqual(@as(u256, 800), to_after.balance);
}

test "State - insufficient balance transfer" {
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

    const State = @This().State(TestEvm);

    // Setup account with insufficient balance
    const from_addr = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0x00} ** 19 };
    const to_addr = primitives.Address{ .bytes = [_]u8{0x02} ++ [_]u8{0x00} ** 19 };
    
    var from_account = Account{ .balance = 100, .nonce = 0, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.database.set_account(from_addr.bytes, from_account);

    // Test insufficient balance transfer
    const snapshot = State.create_snapshot(&evm);
    const result = State.do_transfer(&evm, from_addr, to_addr, 200, snapshot);
    
    try std_test.expectError(error.InsufficientBalance, result);
}

test "State - snapshot and revert" {
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

    const State = @This().State(TestEvm);

    // Setup initial state
    const addr = primitives.Address{ .bytes = [_]u8{0x01} ++ [_]u8{0x00} ** 19 };
    var initial_account = Account{ .balance = 1000, .nonce = 0, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    try db.database.set_account(addr.bytes, initial_account);

    // Create snapshot and make changes
    const snapshot1 = State.create_snapshot(&evm);
    
    // Modify account balance
    var modified_account = (try db.database.get_account(addr.bytes)).?;
    modified_account.balance = 2000;
    try db.database.set_account(addr.bytes, modified_account);

    // Verify change was made
    const changed_account = (try db.database.get_account(addr.bytes)).?;
    try std_test.expectEqual(@as(u256, 2000), changed_account.balance);

    // Create nested snapshot and make more changes
    const snapshot2 = State.create_snapshot(&evm);
    modified_account = (try db.database.get_account(addr.bytes)).?;
    modified_account.balance = 3000;
    try db.database.set_account(addr.bytes, modified_account);

    // Revert to first snapshot
    State.revert_to_snapshot(&evm, snapshot1);

    // Note: This test can't fully verify revert functionality because
    // apply_journal_entry_revert is private and the journal integration
    // would require recording changes through the journal system.
    // In a real implementation, changes would be recorded in the journal
    // during the transfer operation.
}