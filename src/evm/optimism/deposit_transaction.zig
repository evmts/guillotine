const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
const OptimismRules = @import("hardfork.zig").OptimismRules;
const B256 = @import("crypto").Hash.B256;

/// Deposit transaction type identifier (0x7E)
pub const DEPOSIT_TX_TYPE: u8 = 0x7E;

/// Optimism deposit transaction structure
/// Represents a transaction deposited from L1 to L2
///
/// Deposit transactions have special properties:
/// - They can mint ETH on L2
/// - They skip nonce and balance validation
/// - System transactions have additional restrictions
pub const DepositTransaction = struct {
    /// Source hash from L1
    source_hash: B256,
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
    
    /// Check if this is a halted deposit (non-system with zero gas)
    pub fn isHalted(self: DepositTransaction) bool {
        return !self.is_system_tx and self.gas == 0;
    }
    
    /// Validate deposit transaction
    pub fn validate(self: DepositTransaction, op_rules: OptimismRules) !void {
        // Pre-Regolith: system transactions must have reasonable gas
        if (!op_rules.isRegolith() and self.is_system_tx) {
            if (self.gas > 1_000_000) {
                return error.SystemTransactionGasTooHigh;
            }
        }
        
        // System transactions cannot send value
        if (self.is_system_tx and self.value != 0) {
            return error.SystemTransactionWithValue;
        }
        
        // Check for halted deposits (non-system with zero gas)
        if (self.isHalted()) {
            // Halted deposits are valid but won't execute
            return;
        }
    }
    
    /// Calculate the deposit transaction hash
    pub fn hash(self: DepositTransaction) B256 {
        // In real implementation, this would follow Optimism's deposit tx hash algorithm
        // For now, return a mock hash
        var result: B256 = undefined;
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
    l1_block_hash: B256,
    /// Base fee from L1
    l1_base_fee: u256,
    /// Blob base fee from L1 (post-4844)
    l1_blob_base_fee: ?u256,
    
    /// Initialize default Optimism context
    pub fn init() OptimismContext {
        return .{
            .l1_block_number = 0,
            .l1_block_timestamp = 0,
            .l1_block_hash = std.mem.zeroes(B256),
            .l1_base_fee = 0,
            .l1_blob_base_fee = null,
        };
    }
};

test "DepositTransaction validation" {
    const tx = DepositTransaction{
        .source_hash = std.mem.zeroes(B256),
        .from = Address.ZERO,
        .to = null,
        .mint = 0,
        .value = 0,
        .gas = 100000,
        .is_system_tx = false,
        .data = &.{},
    };
    
    const op_rules = OptimismRules{ .hardfork = .BEDROCK };
    try tx.validate(op_rules);
}

test "System transaction validation" {
    const tx = DepositTransaction{
        .source_hash = std.mem.zeroes(B256),
        .from = Address.ZERO,
        .to = null,
        .mint = 0,
        .value = 100, // Invalid for system tx
        .gas = 100000,
        .is_system_tx = true,
        .data = &.{},
    };
    
    const op_rules = OptimismRules{ .hardfork = .BEDROCK };
    try std.testing.expectError(error.SystemTransactionWithValue, tx.validate(op_rules));
}

test "Halted deposit detection" {
    const tx = DepositTransaction{
        .source_hash = std.mem.zeroes(B256),
        .from = Address.ZERO,
        .to = null,
        .mint = 1000,
        .value = 0,
        .gas = 0, // Zero gas = halted
        .is_system_tx = false,
        .data = &.{},
    };
    
    try std.testing.expect(tx.isHalted());
    
    // Halted deposits are still valid
    const op_rules = OptimismRules{ .hardfork = .REGOLITH };
    try tx.validate(op_rules);
}