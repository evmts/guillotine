//! Ethereum Block with Transactions - Complete block data structure
//!
//! Represents a full Ethereum block including all transaction data,
//! not just transaction hashes. This is essential for block verification
//! and detailed transaction analysis.
//!
//! ## Block Evolution
//! - Pre-EIP-1559: No base fee, simple gas pricing
//! - EIP-1559 (London): Base fee mechanism for dynamic pricing
//! - EIP-4844 (Cancun): Blob transactions support
//! - Proof-of-Stake: Difficulty may be 0, miner is validator
//!
//! ## Memory Management
//! BlockWithTransactions owns its transactions array and is responsible
//! for cleanup. Always call deinit() to prevent memory leaks.
//!
//! ## Usage Example
//! ```zig
//! var block = BlockWithTransactions{
//!     .transactions = try allocator.alloc(Transaction.Transaction, tx_count),
//!     // ... other fields
//! };
//! defer block.deinit(allocator);
//! ```

const std = @import("std");
const testing = std.testing;
const Transaction = @import("transaction.zig");
const Address = @import("address.zig").Address;
const crypto_pkg = @import("crypto");
const Hash = crypto_pkg.Hash;
const Allocator = std.mem.Allocator;

pub const BlockWithTransactions = struct {
    // Block identification
    hash: Hash,
    number: u64,
    parent_hash: Hash,
    
    // Block metadata
    timestamp: u64,
    miner: Address,
    difficulty: u256,
    total_difficulty: u256,
    size: u64,
    
    // Gas and fees
    gas_limit: u64,
    gas_used: u64,
    base_fee_per_gas: ?u256, // null for pre-EIP-1559 blocks
    
    // Merkle roots
    state_root: Hash,
    transactions_root: Hash,
    receipts_root: Hash,
    
    // Transaction data
    transactions: []Transaction.Transaction,
    
    /// Clean up allocated memory for transactions array
    pub fn deinit(self: *const BlockWithTransactions, allocator: Allocator) void {
        for (self.transactions) |*tx| {
            tx.deinit(allocator);
        }
        allocator.free(self.transactions);
    }
    
    /// Get the number of transactions in this block
    pub fn getTransactionCount(self: *const BlockWithTransactions) usize {
        return self.transactions.len;
    }
    
    /// Check if this is an EIP-1559 block (has base fee)
    pub fn hasBaseFee(self: *const BlockWithTransactions) bool {
        return self.base_fee_per_gas != null;
    }
    
    /// Check if this is a Proof-of-Stake block (difficulty is 0)
    pub fn isProofOfStake(self: *const BlockWithTransactions) bool {
        return self.difficulty == 0;
    }
    
    /// Get the base fee per gas (0 if not EIP-1559)
    pub fn getBaseFee(self: *const BlockWithTransactions) u256 {
        return self.base_fee_per_gas orelse 0;
    }
    
    /// Calculate gas utilization percentage (0-100)
    pub fn getGasUtilization(self: *const BlockWithTransactions) u8 {
        if (self.gas_limit == 0) return 0;
        const utilization = (self.gas_used * 100) / self.gas_limit;
        return @intCast(std.math.min(utilization, 100));
    }
    
    /// Find transaction by hash (linear search)
    pub fn findTransaction(self: *const BlockWithTransactions, tx_hash: Hash) ?*const Transaction.Transaction {
        for (self.transactions) |*tx| {
            if (std.mem.eql(u8, &tx.getHash().bytes, &tx_hash.bytes)) {
                return tx;
            }
        }
        return null;
    }
    
    /// Get transaction by index
    pub fn getTransaction(self: *const BlockWithTransactions, index: usize) ?*const Transaction.Transaction {
        if (index >= self.transactions.len) return null;
        return &self.transactions[index];
    }
    
    /// Check if block is empty (no transactions)
    pub fn isEmpty(self: *const BlockWithTransactions) bool {
        return self.transactions.len == 0;
    }
};

test "BlockWithTransactions basic construction and cleanup" {
    const allocator = testing.allocator;
    
    // Create empty block
    const transactions = try allocator.alloc(Transaction.Transaction, 0);
    const block = BlockWithTransactions{
        .hash = Hash.ZERO,
        .number = 1000000,
        .parent_hash = Hash.ZERO,
        .timestamp = 1640995200, // 2022-01-01
        .miner = Address.ZERO,
        .difficulty = 1000000000000000,
        .total_difficulty = 50000000000000000000,
        .size = 1024,
        .gas_limit = 30000000,
        .gas_used = 0,
        .base_fee_per_gas = null, // Pre-EIP-1559
        .state_root = Hash.ZERO,
        .transactions_root = Hash.ZERO,
        .receipts_root = Hash.ZERO,
        .transactions = transactions,
    };
    defer block.deinit(allocator);
    
    try testing.expectEqual(@as(usize, 0), block.getTransactionCount());
    try testing.expect(block.isEmpty());
    try testing.expect(!block.hasBaseFee());
    try testing.expect(!block.isProofOfStake());
    try testing.expectEqual(@as(u8, 0), block.getGasUtilization());
}

test "BlockWithTransactions EIP-1559 block" {
    const allocator = testing.allocator;
    
    const transactions = try allocator.alloc(Transaction.Transaction, 0);
    const block = BlockWithTransactions{
        .hash = Hash.ZERO,
        .number = 15000000, // Post-London
        .parent_hash = Hash.ZERO,
        .timestamp = 1660000000,
        .miner = Address.ZERO,
        .difficulty = 1000000000000000,
        .total_difficulty = 60000000000000000000,
        .size = 2048,
        .gas_limit = 30000000,
        .gas_used = 15000000, // 50% utilization
        .base_fee_per_gas = 20000000000, // 20 gwei
        .state_root = Hash.ZERO,
        .transactions_root = Hash.ZERO,
        .receipts_root = Hash.ZERO,
        .transactions = transactions,
    };
    defer block.deinit(allocator);
    
    try testing.expect(block.hasBaseFee());
    try testing.expectEqual(@as(u256, 20000000000), block.getBaseFee());
    try testing.expectEqual(@as(u8, 50), block.getGasUtilization());
}

test "BlockWithTransactions Proof-of-Stake block" {
    const allocator = testing.allocator;
    
    const transactions = try allocator.alloc(Transaction.Transaction, 0);
    const block = BlockWithTransactions{
        .hash = Hash.ZERO,
        .number = 18000000, // Post-Merge
        .parent_hash = Hash.ZERO,
        .timestamp = 1670000000,
        .miner = Address.ZERO, // Actually validator
        .difficulty = 0, // PoS has no difficulty
        .total_difficulty = 58750003716598352816469,
        .size = 1500,
        .gas_limit = 30000000,
        .gas_used = 12000000,
        .base_fee_per_gas = 15000000000, // 15 gwei
        .state_root = Hash.ZERO,
        .transactions_root = Hash.ZERO,
        .receipts_root = Hash.ZERO,
        .transactions = transactions,
    };
    defer block.deinit(allocator);
    
    try testing.expect(block.isProofOfStake());
    try testing.expect(block.hasBaseFee());
    try testing.expectEqual(@as(u8, 40), block.getGasUtilization());
}

test "BlockWithTransactions with transactions" {
    const allocator = testing.allocator;
    
    // Create mock transactions
    const transactions = try allocator.alloc(Transaction.Transaction, 2);
    
    // Mock legacy transaction
    transactions[0] = Transaction.Transaction{
        .legacy = Transaction.LegacyTransaction{
            .nonce = 0,
            .gas_price = 20000000000,
            .gas_limit = 21000,
            .to = Address.ZERO,
            .value = 1000000000000000000, // 1 ETH
            .data = &[_]u8{},
            .v = 27,
            .r = [_]u8{0} ** 32,
            .s = [_]u8{0} ** 32,
        },
    };
    
    // Mock EIP-1559 transaction
    transactions[1] = Transaction.Transaction{
        .eip1559 = Transaction.Eip1559Transaction{
            .chain_id = 1,
            .nonce = 1,
            .max_priority_fee_per_gas = 2000000000,
            .max_fee_per_gas = 25000000000,
            .gas_limit = 50000,
            .to = Address.ZERO,
            .value = 500000000000000000, // 0.5 ETH
            .data = &[_]u8{},
            .access_list = &[_]Transaction.AccessListItem{},
            .y_parity = 0,
            .r = [_]u8{0} ** 32,
            .s = [_]u8{0} ** 32,
        },
    };
    
    const block = BlockWithTransactions{
        .hash = Hash.ZERO,
        .number = 16000000,
        .parent_hash = Hash.ZERO,
        .timestamp = 1675000000,
        .miner = Address.ZERO,
        .difficulty = 0,
        .total_difficulty = 59000000000000000000,
        .size = 4096,
        .gas_limit = 30000000,
        .gas_used = 71000, // Sum of transaction gas limits
        .base_fee_per_gas = 18000000000,
        .state_root = Hash.ZERO,
        .transactions_root = Hash.ZERO,
        .receipts_root = Hash.ZERO,
        .transactions = transactions,
    };
    defer block.deinit(allocator);
    
    try testing.expectEqual(@as(usize, 2), block.getTransactionCount());
    try testing.expect(!block.isEmpty());
    
    // Test transaction access
    const tx0 = block.getTransaction(0);
    try testing.expect(tx0 != null);
    try testing.expect(tx0.?.* == .legacy);
    
    const tx1 = block.getTransaction(1);
    try testing.expect(tx1 != null);
    try testing.expect(tx1.?.* == .eip1559);
    
    // Test out of bounds
    const tx_invalid = block.getTransaction(2);
    try testing.expect(tx_invalid == null);
}

test "BlockWithTransactions transaction search" {
    const allocator = testing.allocator;
    
    const transactions = try allocator.alloc(Transaction.Transaction, 1);
    transactions[0] = Transaction.Transaction{
        .legacy = Transaction.LegacyTransaction{
            .nonce = 42,
            .gas_price = 20000000000,
            .gas_limit = 21000,
            .to = Address.ZERO,
            .value = 1000000000000000000,
            .data = &[_]u8{},
            .v = 27,
            .r = [_]u8{1} ** 32, // Unique signature
            .s = [_]u8{2} ** 32,
        },
    };
    
    const block = BlockWithTransactions{
        .hash = Hash.ZERO,
        .number = 17000000,
        .parent_hash = Hash.ZERO,
        .timestamp = 1680000000,
        .miner = Address.ZERO,
        .difficulty = 0,
        .total_difficulty = 59500000000000000000,
        .size = 2048,
        .gas_limit = 30000000,
        .gas_used = 21000,
        .base_fee_per_gas = 12000000000,
        .state_root = Hash.ZERO,
        .transactions_root = Hash.ZERO,
        .receipts_root = Hash.ZERO,
        .transactions = transactions,
    };
    defer block.deinit(allocator);
    
    // Calculate expected transaction hash
    const expected_hash = transactions[0].getHash();
    
    // Test finding transaction
    const found_tx = block.findTransaction(expected_hash);
    try testing.expect(found_tx != null);
    try testing.expect(found_tx.?.* == .legacy);
    
    // Test not finding transaction
    const not_found = block.findTransaction(Hash.ZERO);
    try testing.expect(not_found == null);
}

test "BlockWithTransactions gas utilization edge cases" {
    const allocator = testing.allocator;
    
    const transactions = try allocator.alloc(Transaction.Transaction, 0);
    
    // Test 100% utilization
    const block_full = BlockWithTransactions{
        .hash = Hash.ZERO,
        .number = 18000000,
        .parent_hash = Hash.ZERO,
        .timestamp = 1685000000,
        .miner = Address.ZERO,
        .difficulty = 0,
        .total_difficulty = 60000000000000000000,
        .size = 1024,
        .gas_limit = 30000000,
        .gas_used = 30000000, // 100% utilization
        .base_fee_per_gas = 10000000000,
        .state_root = Hash.ZERO,
        .transactions_root = Hash.ZERO,
        .receipts_root = Hash.ZERO,
        .transactions = transactions,
    };
    defer block_full.deinit(allocator);
    
    try testing.expectEqual(@as(u8, 100), block_full.getGasUtilization());
    
    // Test zero gas limit (edge case)
    const transactions2 = try allocator.alloc(Transaction.Transaction, 0);
    const block_zero = BlockWithTransactions{
        .hash = Hash.ZERO,
        .number = 0,
        .parent_hash = Hash.ZERO,
        .timestamp = 0,
        .miner = Address.ZERO,
        .difficulty = 0,
        .total_difficulty = 0,
        .size = 0,
        .gas_limit = 0, // Edge case
        .gas_used = 0,
        .base_fee_per_gas = null,
        .state_root = Hash.ZERO,
        .transactions_root = Hash.ZERO,
        .receipts_root = Hash.ZERO,
        .transactions = transactions2,
    };
    defer block_zero.deinit(allocator);
    
    try testing.expectEqual(@as(u8, 0), block_zero.getGasUtilization());
}

test "BlockWithTransactions memory management with complex transactions" {
    const allocator = testing.allocator;
    
    // Create transactions with allocated data
    const transactions = try allocator.alloc(Transaction.Transaction, 3);
    
    // Transaction with data
    const data1 = try allocator.dupe(u8, "contract deployment bytecode");
    transactions[0] = Transaction.Transaction{
        .legacy = Transaction.LegacyTransaction{
            .nonce = 0,
            .gas_price = 20000000000,
            .gas_limit = 100000,
            .to = null, // Contract creation
            .value = 0,
            .data = data1,
            .v = 27,
            .r = [_]u8{0} ** 32,
            .s = [_]u8{0} ** 32,
        },
    };
    
    // EIP-2930 transaction with access list
    const access_list = try allocator.alloc(Transaction.AccessListItem, 1);
    const storage_keys = try allocator.alloc([32]u8, 2);
    storage_keys[0] = [_]u8{1} ** 32;
    storage_keys[1] = [_]u8{2} ** 32;
    access_list[0] = Transaction.AccessListItem{
        .address = Address.ZERO,
        .storage_keys = storage_keys,
    };
    
    const data2 = try allocator.dupe(u8, "method call data");
    transactions[1] = Transaction.Transaction{
        .eip2930 = Transaction.Eip2930Transaction{
            .chain_id = 1,
            .nonce = 1,
            .gas_price = 25000000000,
            .gas_limit = 80000,
            .to = Address.ZERO,
            .value = 100000000000000000,
            .data = data2,
            .access_list = access_list,
            .y_parity = 1,
            .r = [_]u8{3} ** 32,
            .s = [_]u8{4} ** 32,
        },
    };
    
    // EIP-4844 blob transaction
    const blob_hashes = try allocator.alloc([32]u8, 1);
    blob_hashes[0] = [_]u8{5} ** 32;
    
    const data3 = try allocator.dupe(u8, "blob transaction data");
    transactions[2] = Transaction.Transaction{
        .eip4844 = Transaction.Eip4844Transaction{
            .chain_id = 1,
            .nonce = 2,
            .max_priority_fee_per_gas = 3000000000,
            .max_fee_per_gas = 30000000000,
            .gas_limit = 150000,
            .to = Address.ZERO,
            .value = 200000000000000000,
            .data = data3,
            .access_list = &[_]Transaction.AccessListItem{},
            .y_parity = 0,
            .r = [_]u8{6} ** 32,
            .s = [_]u8{7} ** 32,
            .max_fee_per_blob_gas = 1000000000,
            .blob_hashes = blob_hashes,
        },
    };
    
    const block = BlockWithTransactions{
        .hash = Hash.ZERO,
        .number = 19000000,
        .parent_hash = Hash.ZERO,
        .timestamp = 1690000000,
        .miner = Address.ZERO,
        .difficulty = 0,
        .total_difficulty = 61000000000000000000,
        .size = 8192,
        .gas_limit = 30000000,
        .gas_used = 330000,
        .base_fee_per_gas = 8000000000,
        .state_root = Hash.ZERO,
        .transactions_root = Hash.ZERO,
        .receipts_root = Hash.ZERO,
        .transactions = transactions,
    };
    defer block.deinit(allocator);
    
    try testing.expectEqual(@as(usize, 3), block.getTransactionCount());
    
    // Verify transaction types
    try testing.expect(block.getTransaction(0).?.* == .legacy);
    try testing.expect(block.getTransaction(1).?.* == .eip2930);
    try testing.expect(block.getTransaction(2).?.* == .eip4844);
}

test "BlockWithTransactions large block handling" {
    const allocator = testing.allocator;
    
    // Create a large block with many transactions
    const tx_count = 500;
    const transactions = try allocator.alloc(Transaction.Transaction, tx_count);
    
    // Fill with simple transactions
    for (transactions, 0..) |*tx, i| {
        tx.* = Transaction.Transaction{
            .legacy = Transaction.LegacyTransaction{
                .nonce = @intCast(i),
                .gas_price = 20000000000,
                .gas_limit = 21000,
                .to = Address.ZERO,
                .value = 1000000000000000, // 0.001 ETH
                .data = &[_]u8{},
                .v = 27,
                .r = [_]u8{@intCast(i % 256)} ** 32,
                .s = [_]u8{@intCast((i + 1) % 256)} ** 32,
            },
        };
    }
    
    const block = BlockWithTransactions{
        .hash = Hash.ZERO,
        .number = 20000000,
        .parent_hash = Hash.ZERO,
        .timestamp = 1695000000,
        .miner = Address.ZERO,
        .difficulty = 0,
        .total_difficulty = 62000000000000000000,
        .size = 65536, // Large block
        .gas_limit = 30000000,
        .gas_used = 10500000, // 500 * 21000
        .base_fee_per_gas = 5000000000,
        .state_root = Hash.ZERO,
        .transactions_root = Hash.ZERO,
        .receipts_root = Hash.ZERO,
        .transactions = transactions,
    };
    defer block.deinit(allocator);
    
    try testing.expectEqual(@as(usize, tx_count), block.getTransactionCount());
    try testing.expectEqual(@as(u8, 35), block.getGasUtilization());
    
    // Test accessing transactions at various indices
    try testing.expect(block.getTransaction(0) != null);
    try testing.expect(block.getTransaction(249) != null);
    try testing.expect(block.getTransaction(499) != null);
    try testing.expect(block.getTransaction(500) == null); // Out of bounds
}