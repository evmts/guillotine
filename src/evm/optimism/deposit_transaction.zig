const std = @import("std");
const primitives = @import("primitives");
const Address = @import("Address").Address;

/// Optimism deposit transaction structure
/// Represents a transaction deposited from L1 to L2
pub const DepositTransaction = struct {
    /// Source hash from L1
    source_hash: primitives.B256,
    /// Sender address (from L1)
    from: Address,
    /// Recipient address (on L2)
    to: ?Address,
    /// Mint value (amount of ETH to mint on L2)
    mint: u256,
    /// Transaction value
    value: u256,
    /// Gas limit
    gas: u64,
    /// Whether this is a system transaction
    is_system_tx: bool,
    /// Transaction data
    data: []const u8,
    
    /// Validate deposit transaction
    pub fn validate(self: DepositTransaction) !void {
        // Ensure gas limit is reasonable
        if (self.gas == 0) {
            return error.InvalidGasLimit;
        }
        
        // System transactions have special rules
        if (self.is_system_tx) {
            // System transactions must have zero value
            if (self.value != 0) {
                return error.SystemTransactionWithValue;
            }
        }
    }
    
    /// Calculate the deposit transaction hash
    pub fn hash(self: DepositTransaction) primitives.B256 {
        // In real implementation, this would follow Optimism's deposit tx hash algorithm
        // For now, return a mock hash
        var result: primitives.B256 = undefined;
        @memset(&result, 0);
        // Mix in some fields to make it unique
        result[0] = @truncate(self.gas);
        result[1] = if (self.is_system_tx) 1 else 0;
        return result;
    }
};

/// Optimism-specific context for deposit transactions
pub const OptimismContext = struct {
    /// L1 block number when deposit was made
    l1_block_number: u64,
    /// L1 block timestamp
    l1_block_timestamp: u64,
    /// L1 block hash
    l1_block_hash: primitives.B256,
    /// Base fee from L1
    l1_base_fee: u256,
    /// Blob base fee from L1 (post-4844)
    l1_blob_base_fee: ?u256,
    
    /// Initialize default Optimism context
    pub fn init() OptimismContext {
        return .{
            .l1_block_number = 0,
            .l1_block_timestamp = 0,
            .l1_block_hash = std.mem.zeroes(primitives.B256),
            .l1_base_fee = 0,
            .l1_blob_base_fee = null,
        };
    }
};

test "DepositTransaction validation" {
    const tx = DepositTransaction{
        .source_hash = std.mem.zeroes(primitives.B256),
        .from = Address.ZERO,
        .to = null,
        .mint = 0,
        .value = 0,
        .gas = 100000,
        .is_system_tx = false,
        .data = &.{},
    };
    
    try tx.validate();
}

test "System transaction validation" {
    const tx = DepositTransaction{
        .source_hash = std.mem.zeroes(primitives.B256),
        .from = Address.ZERO,
        .to = null,
        .mint = 0,
        .value = 100, // Invalid for system tx
        .gas = 100000,
        .is_system_tx = true,
        .data = &.{},
    };
    
    try std.testing.expectError(error.SystemTransactionWithValue, tx.validate());
}