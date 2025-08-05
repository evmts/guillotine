//! Transaction Receipt - Ethereum transaction execution results
//!
//! Represents the result of executing a transaction, including gas usage,
//! contract creation, event logs, and execution status.
//!
//! ## EIP Compliance
//! - EIP-658: Post-Byzantium status field
//! - EIP-1559: Effective gas price for dynamic fee transactions
//! - EIP-2930: Compatible with access list transactions
//! - EIP-4844: Forward compatible with blob transactions
//!
//! ## Memory Management
//! TransactionReceipt owns its logs array and is responsible for cleanup.
//! Always call deinit() to prevent memory leaks.
//!
//! ## Usage Example
//! ```zig
//! var receipt = TransactionReceipt{
//!     .transaction_hash = tx_hash,
//!     .logs = try allocator.alloc(EventLog, log_count),
//!     // ... other fields
//! };
//! defer receipt.deinit(allocator);
//! ```

const std = @import("std");
const testing = std.testing;
const Address = @import("address.zig").Address;
const EventLog = @import("event_log.zig").EventLog;
const crypto_pkg = @import("crypto");
const Hash = crypto_pkg.Hash;
const Allocator = std.mem.Allocator;

pub const TransactionReceipt = struct {
    // Core identification
    transaction_hash: Hash,
    transaction_index: u64,
    block_hash: Hash,
    block_number: u64,
    
    // Execution context
    from: Address,
    to: ?Address,
    contract_address: ?Address,
    
    // Gas and fees
    cumulative_gas_used: u64,
    gas_used: u64,
    effective_gas_price: u256,
    
    // Execution results
    status: u8,
    logs: []EventLog,
    
    /// Clean up allocated memory for logs array
    pub fn deinit(self: *const TransactionReceipt, allocator: Allocator) void {
        for (self.logs) |*log| {
            log.deinit(allocator);
        }
        allocator.free(self.logs);
    }
    
    /// Check if transaction executed successfully
    pub fn isSuccess(self: *const TransactionReceipt) bool {
        return self.status == 1;
    }
    
    /// Check if transaction failed
    pub fn isFailure(self: *const TransactionReceipt) bool {
        return self.status == 0;
    }
    
    /// Check if this receipt represents a contract creation
    pub fn isContractCreation(self: *const TransactionReceipt) bool {
        return self.contract_address != null;
    }
    
    /// Get the number of events emitted
    pub fn getLogCount(self: *const TransactionReceipt) usize {
        return self.logs.len;
    }
};

test "TransactionReceipt basic construction and cleanup" {
    const allocator = testing.allocator;
    
    // Create minimal receipt
    const logs = try allocator.alloc(EventLog, 0);
    const receipt = TransactionReceipt{
        .transaction_hash = Hash.ZERO,
        .transaction_index = 0,
        .block_hash = Hash.ZERO,
        .block_number = 1000000,
        .from = Address.ZERO,
        .to = null,
        .contract_address = null,
        .cumulative_gas_used = 21000,
        .gas_used = 21000,
        .effective_gas_price = 20000000000, // 20 gwei
        .status = 1,
        .logs = logs,
    };
    defer receipt.deinit(allocator);
    
    try testing.expect(receipt.isSuccess());
    try testing.expect(!receipt.isFailure());
    try testing.expectEqual(@as(usize, 0), receipt.getLogCount());
}

test "TransactionReceipt contract creation" {
    const allocator = testing.allocator;
    
    const contract_addr = try Address.fromHex("0x742d35Cc6634C0532925a3b844Bc9e7595f6E97b");
    const logs = try allocator.alloc(EventLog, 0);
    
    const receipt = TransactionReceipt{
        .transaction_hash = Hash.ZERO,
        .transaction_index = 5,
        .block_hash = Hash.ZERO,
        .block_number = 2000000,
        .from = Address.ZERO,
        .to = null, // Contract creation has null 'to'
        .contract_address = contract_addr,
        .cumulative_gas_used = 500000,
        .gas_used = 300000,
        .effective_gas_price = 25000000000, // 25 gwei
        .status = 1,
        .logs = logs,
    };
    defer receipt.deinit(allocator);
    
    try testing.expect(receipt.isContractCreation());
    try testing.expectEqual(contract_addr, receipt.contract_address.?);
}

test "TransactionReceipt failed transaction" {
    const allocator = testing.allocator;
    
    const logs = try allocator.alloc(EventLog, 0);
    const receipt = TransactionReceipt{
        .transaction_hash = Hash.ZERO,
        .transaction_index = 10,
        .block_hash = Hash.ZERO,
        .block_number = 3000000,
        .from = Address.ZERO,
        .to = Address.ZERO,
        .contract_address = null,
        .cumulative_gas_used = 100000,
        .gas_used = 50000,
        .effective_gas_price = 15000000000, // 15 gwei
        .status = 0, // Failed transaction
        .logs = logs,
    };
    defer receipt.deinit(allocator);
    
    try testing.expect(receipt.isFailure());
    try testing.expect(!receipt.isSuccess());
    try testing.expect(!receipt.isContractCreation());
}

test "TransactionReceipt with event logs" {
    const allocator = testing.allocator;
    
    // Create mock event logs
    const logs = try allocator.alloc(EventLog, 2);
    logs[0] = EventLog{
        .address = Address.ZERO,
        .topics = &[_]Hash{},
        .data = &[_]u8{},
        .block_number = 4000000,
        .transaction_hash = Hash.ZERO,
        .transaction_index = 15,
        .log_index = 0,
        .removed = false,
    };
    logs[1] = EventLog{
        .address = Address.ZERO,
        .topics = &[_]Hash{},
        .data = &[_]u8{},
        .block_number = 4000000,
        .transaction_hash = Hash.ZERO,
        .transaction_index = 15,
        .log_index = 1,
        .removed = false,
    };
    
    const receipt = TransactionReceipt{
        .transaction_hash = Hash.ZERO,
        .transaction_index = 15,
        .block_hash = Hash.ZERO,
        .block_number = 4000000,
        .from = Address.ZERO,
        .to = Address.ZERO,
        .contract_address = null,
        .cumulative_gas_used = 200000,
        .gas_used = 150000,
        .effective_gas_price = 30000000000, // 30 gwei
        .status = 1,
        .logs = logs,
    };
    defer receipt.deinit(allocator);
    
    try testing.expectEqual(@as(usize, 2), receipt.getLogCount());
    try testing.expect(receipt.isSuccess());
}

test "TransactionReceipt memory management with complex logs" {
    const allocator = testing.allocator;
    
    // Create logs with allocated data to test proper cleanup
    const logs = try allocator.alloc(EventLog, 1);
    const log_data = try allocator.dupe(u8, "test event data");
    const topics = try allocator.alloc(Hash, 1);
    topics[0] = Hash.ZERO;
    
    logs[0] = EventLog{
        .address = Address.ZERO,
        .topics = topics,
        .data = log_data,
        .block_number = 5000000,
        .transaction_hash = Hash.ZERO,
        .transaction_index = 20,
        .log_index = 0,
        .removed = false,
    };
    
    const receipt = TransactionReceipt{
        .transaction_hash = Hash.ZERO,
        .transaction_index = 20,
        .block_hash = Hash.ZERO,
        .block_number = 5000000,
        .from = Address.ZERO,
        .to = Address.ZERO,
        .contract_address = null,
        .cumulative_gas_used = 75000,
        .gas_used = 75000,
        .effective_gas_price = 10000000000, // 10 gwei
        .status = 1,
        .logs = logs,
    };
    defer receipt.deinit(allocator);
    
    try testing.expectEqual(@as(usize, 1), receipt.getLogCount());
}

test "TransactionReceipt edge cases - large values" {
    const allocator = testing.allocator;
    
    const logs = try allocator.alloc(EventLog, 0);
    const receipt = TransactionReceipt{
        .transaction_hash = Hash.ZERO,
        .transaction_index = std.math.maxInt(u64),
        .block_hash = Hash.ZERO,
        .block_number = std.math.maxInt(u64),
        .from = Address.ZERO,
        .to = Address.ZERO,
        .contract_address = null,
        .cumulative_gas_used = std.math.maxInt(u64),
        .gas_used = std.math.maxInt(u64),
        .effective_gas_price = std.math.maxInt(u256),
        .status = 1,
        .logs = logs,
    };
    defer receipt.deinit(allocator);
    
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), receipt.transaction_index);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), receipt.gas_used);
    try testing.expectEqual(@as(u256, std.math.maxInt(u256)), receipt.effective_gas_price);
}

test "TransactionReceipt status boundary values" {
    const allocator = testing.allocator;
    
    // Test status = 1 (success)
    const logs1 = try allocator.alloc(EventLog, 0);
    const success_receipt = TransactionReceipt{
        .transaction_hash = Hash.ZERO,
        .transaction_index = 0,
        .block_hash = Hash.ZERO,
        .block_number = 1,
        .from = Address.ZERO,
        .to = Address.ZERO,
        .contract_address = null,
        .cumulative_gas_used = 21000,
        .gas_used = 21000,
        .effective_gas_price = 1000000000,
        .status = 1,
        .logs = logs1,
    };
    defer success_receipt.deinit(allocator);
    
    try testing.expect(success_receipt.isSuccess());
    try testing.expect(!success_receipt.isFailure());
    
    // Test status = 0 (failure)
    const logs2 = try allocator.alloc(EventLog, 0);
    const failure_receipt = TransactionReceipt{
        .transaction_hash = Hash.ZERO,
        .transaction_index = 0,
        .block_hash = Hash.ZERO,
        .block_number = 1,
        .from = Address.ZERO,
        .to = Address.ZERO,
        .contract_address = null,
        .cumulative_gas_used = 21000,
        .gas_used = 21000,
        .effective_gas_price = 1000000000,
        .status = 0,
        .logs = logs2,
    };
    defer failure_receipt.deinit(allocator);
    
    try testing.expect(failure_receipt.isFailure());
    try testing.expect(!failure_receipt.isSuccess());
    
    // Test invalid status (neither 0 nor 1)
    const logs3 = try allocator.alloc(EventLog, 0);
    const invalid_receipt = TransactionReceipt{
        .transaction_hash = Hash.ZERO,
        .transaction_index = 0,
        .block_hash = Hash.ZERO,
        .block_number = 1,
        .from = Address.ZERO,
        .to = Address.ZERO,
        .contract_address = null,
        .cumulative_gas_used = 21000,
        .gas_used = 21000,
        .effective_gas_price = 1000000000,
        .status = 2, // Invalid status
        .logs = logs3,
    };
    defer invalid_receipt.deinit(allocator);
    
    try testing.expect(!invalid_receipt.isSuccess());
    try testing.expect(!invalid_receipt.isFailure());
}