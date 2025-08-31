/// EIP-6110: Supply validator deposits on chain
///
/// This module implements a system contract that handles validator deposits
/// from the execution layer. The contract processes deposit requests and
/// makes them available to the consensus layer.
///
/// The deposit contract is deployed at a specific address and accumulates
/// deposits that are then processed by the beacon chain.
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const Database = @import("database.zig").Database;
const BlockInfo = @import("block_info.zig").DefaultBlockInfo;
const log = @import("log.zig");

/// EIP-6110 deposit contract address
/// Deployed at 0x00000000219ab540356cBB839Cbe05303d7705Fa (mainnet deposit contract)
pub const DEPOSIT_CONTRACT_ADDRESS = Address{
    .bytes = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x21, 0x9a, 0xb5, 0x40,
        0x35, 0x6c, 0xBB, 0x83, 0x9C, 0xbe, 0x05, 0x30,
        0x3d, 0x77, 0x05, 0xFa,
    },
};

/// System address that can process deposits
/// 0xfffffffffffffffffffffffffffffffffffffffe
pub const SYSTEM_ADDRESS = Address{
    .bytes = [_]u8{
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xfe,
    },
};

/// Gas cost for processing a deposit
pub const DEPOSIT_GAS: u64 = 30000;

/// Deposit request structure
pub const DepositRequest = struct {
    /// Validator public key (48 bytes)
    pubkey: [48]u8,
    /// Withdrawal credentials (32 bytes)
    withdrawal_credentials: [32]u8,
    /// Deposit amount in Gwei
    amount: u64,
    /// Signature (96 bytes)
    signature: [96]u8,
    /// Deposit data index
    index: u64,
};

/// Validator deposits contract implementation
pub const ValidatorDepositsContract = struct {
    database: *Database,
    deposits: std.ArrayList(DepositRequest),
    
    const Self = @This();
    
    /// Initialize the deposits contract
    pub fn init(allocator: std.mem.Allocator, database: *Database) Self {
        return .{
            .database = database,
            .deposits = std.ArrayList(DepositRequest).init(allocator),
        };
    }
    
    /// Deinitialize the deposits contract
    pub fn deinit(self: *Self) void {
        self.deposits.deinit();
    }
    
    /// Execute the validator deposits contract
    /// 
    /// Input format (208 bytes):
    /// - 48 bytes: validator pubkey
    /// - 32 bytes: withdrawal credentials
    /// - 8 bytes: amount (Gwei)
    /// - 96 bytes: signature
    /// - 8 bytes: index
    /// - 16 bytes: reserved for future use
    pub fn execute(
        self: *Self,
        caller: Address,
        input: []const u8,
        gas_limit: u64,
        value: u256,
    ) !struct { output: []const u8, gas_used: u64 } {
        _ = caller; // Caller is not used in validation for deposits
        // Check gas
        if (gas_limit < DEPOSIT_GAS) {
            return error.OutOfGas;
        }
        
        // Validate input length
        if (input.len != 208) {
            log.debug("ValidatorDeposits: Invalid input length: {} (expected 208)", .{input.len});
            return .{ .output = &.{}, .gas_used = 0 };
        }
        
        // Parse deposit request
        var deposit = DepositRequest{
            .pubkey = undefined,
            .withdrawal_credentials = undefined,
            .amount = 0,
            .signature = undefined,
            .index = 0,
        };
        
        // Copy pubkey
        @memcpy(&deposit.pubkey, input[0..48]);
        
        // Copy withdrawal credentials
        @memcpy(&deposit.withdrawal_credentials, input[48..80]);
        
        // Parse amount (8 bytes, big-endian)
        for (input[80..88]) |byte| {
            deposit.amount = (deposit.amount << 8) | byte;
        }
        
        // Copy signature
        @memcpy(&deposit.signature, input[88..184]);
        
        // Parse index (8 bytes, big-endian)
        for (input[184..192]) |byte| {
            deposit.index = (deposit.index << 8) | byte;
        }
        
        // Validate deposit amount (minimum 1 ETH = 1e9 Gwei)
        if (deposit.amount < 1_000_000_000) {
            log.debug("ValidatorDeposits: Deposit amount too low: {} Gwei", .{deposit.amount});
            return .{ .output = &.{}, .gas_used = DEPOSIT_GAS };
        }
        
        // Validate value matches amount (value is in Wei, amount is in Gwei)
        const expected_value = deposit.amount * 1_000_000_000; // Convert Gwei to Wei
        if (value != expected_value) {
            log.debug("ValidatorDeposits: Value mismatch: {} Wei != {} Wei", .{ value, expected_value });
            return .{ .output = &.{}, .gas_used = DEPOSIT_GAS };
        }
        
        // Store deposit for processing
        try self.deposits.append(deposit);
        
        // Store deposit count in storage
        const deposit_count = self.deposits.items.len;
        try self.database.set_storage(
            DEPOSIT_CONTRACT_ADDRESS.bytes,
            0, // Storage slot 0 for deposit count
            deposit_count,
        );
        
        // Store deposit data hash at slot = index + 1
        var deposit_hash: u256 = 0;
        // Simple hash: XOR all bytes (in production, use proper Merkle tree)
        for (deposit.pubkey) |byte| {
            deposit_hash ^= byte;
        }
        for (deposit.withdrawal_credentials) |byte| {
            deposit_hash ^= (@as(u256, byte) << 8);
        }
        
        try self.database.set_storage(
            DEPOSIT_CONTRACT_ADDRESS.bytes,
            deposit.index + 1,
            deposit_hash,
        );
        
        log.debug("ValidatorDeposits: Processed deposit #{} for {} Gwei", .{ deposit.index, deposit.amount });
        
        // Return success (32 bytes with deposit index)
        var output: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &output, deposit.index, .big);
        
        return .{ .output = &output, .gas_used = DEPOSIT_GAS };
    }
    
    /// Get pending deposits for consensus layer processing
    pub fn getPendingDeposits(self: *Self) []const DepositRequest {
        return self.deposits.items;
    }
    
    /// Clear processed deposits (called after consensus layer processes them)
    pub fn clearProcessedDeposits(self: *Self, up_to_index: u64) !void {
        var new_deposits = std.ArrayList(DepositRequest).init(self.deposits.allocator);
        errdefer new_deposits.deinit();
        
        for (self.deposits.items) |deposit| {
            if (deposit.index > up_to_index) {
                try new_deposits.append(deposit);
            }
        }
        
        self.deposits.deinit();
        self.deposits = new_deposits;
    }
    
    /// Process deposits at block boundary
    /// This would be called by the EVM to make deposits available to consensus layer
    pub fn processBlockDeposits(
        database: *Database,
        block_info: *const BlockInfo,
    ) !void {
        // In a real implementation, this would:
        // 1. Collect all deposits from the current block
        // 2. Update the deposit Merkle tree
        // 3. Make the deposit root available to the consensus layer
        
        const deposit_count = try database.get_storage(
            DEPOSIT_CONTRACT_ADDRESS.bytes,
            0,
        );
        
        if (deposit_count > 0) {
            log.debug("ValidatorDeposits: {} deposits ready for block {}", .{ deposit_count, block_info.number });
        }
    }
};

// Tests
test "validator deposit processing" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var database = try Database.init(allocator);
    defer database.deinit();
    
    var contract = ValidatorDepositsContract.init(allocator, &database);
    defer contract.deinit();
    
    // Create a valid deposit request
    var input: [208]u8 = [_]u8{0} ** 208;
    
    // Set validator pubkey (48 bytes)
    input[0..48].* = [_]u8{0xAA} ** 48;
    
    // Set withdrawal credentials (32 bytes)
    input[48..80].* = [_]u8{0xBB} ** 32;
    
    // Set amount (32 ETH = 32e9 Gwei)
    const amount: u64 = 32_000_000_000;
    std.mem.writeInt(u64, input[80..88], amount, .big);
    
    // Set signature (96 bytes)
    input[88..184].* = [_]u8{0xCC} ** 96;
    
    // Set index
    const index: u64 = 0;
    std.mem.writeInt(u64, input[184..192], index, .big);
    
    // Execute deposit
    const value = amount * 1_000_000_000; // Convert to Wei
    const result = try contract.execute(
        primitives.ZERO_ADDRESS,
        &input,
        100000,
        value,
    );
    
    try testing.expectEqual(DEPOSIT_GAS, result.gas_used);
    
    // Verify deposit was stored
    const deposits = contract.getPendingDeposits();
    try testing.expectEqual(@as(usize, 1), deposits.len);
    try testing.expectEqual(amount, deposits[0].amount);
    try testing.expectEqual(index, deposits[0].index);
    
    // Verify storage was updated
    const stored_count = try database.get_storage(DEPOSIT_CONTRACT_ADDRESS.bytes, 0);
    try testing.expectEqual(@as(u256, 1), stored_count);
}

test "deposit validation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var database = try Database.init(allocator);
    defer database.deinit();
    
    var contract = ValidatorDepositsContract.init(allocator, &database);
    defer contract.deinit();
    
    // Test with invalid input length
    const bad_input = [_]u8{0} ** 100;
    const result1 = try contract.execute(
        primitives.ZERO_ADDRESS,
        &bad_input,
        100000,
        0,
    );
    try testing.expectEqual(@as(u64, 0), result1.gas_used);
    
    // Test with insufficient gas
    var input: [208]u8 = [_]u8{0} ** 208;
    const result2 = contract.execute(
        primitives.ZERO_ADDRESS,
        &input,
        100, // Too low
        0,
    ) catch |err| {
        try testing.expectEqual(error.OutOfGas, err);
        return;
    };
    _ = result2;
    
    // Should have returned OutOfGas error
    try testing.expect(false);
}