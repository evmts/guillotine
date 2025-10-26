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
const Database = @import("../storage/database.zig").Database;
const BlockInfo = @import("../block/block_info.zig").BlockInfo(.{});
const log = @import("../log.zig");

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

/// Compute Keccak256 hash of deposit data
/// This follows the deposit contract's hash computation for Merkle tree
fn computeDepositHash(deposit: *const DepositRequest) !u256 {
    const Keccak256 = std.crypto.hash.sha3.Keccak256;

    // Create buffer for all deposit data: pubkey(48) + creds(32) + amount(8) + sig(96) + index(8) = 192 bytes
    var data: [192]u8 = undefined;

    // Copy pubkey
    @memcpy(data[0..48], &deposit.pubkey);

    // Copy withdrawal credentials
    @memcpy(data[48..80], &deposit.withdrawal_credentials);

    // Copy amount (8 bytes, big-endian)
    std.mem.writeInt(u64, data[80..88], deposit.amount, .big);

    // Copy signature
    @memcpy(data[88..184], &deposit.signature);

    // Copy index (8 bytes, big-endian)
    std.mem.writeInt(u64, data[184..192], deposit.index, .big);

    // Compute Keccak256 hash
    var hash: [32]u8 = undefined;
    Keccak256.hash(&data, &hash, .{});

    // Convert hash to u256 (big-endian)
    return std.mem.readInt(u256, &hash, .big);
}

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
    allocator: std.mem.Allocator,
    deposits: std.ArrayList(DepositRequest),

    const Self = @This();

    /// Initialize the deposits contract
    pub fn init(allocator: std.mem.Allocator, database: *Database) Self {
        return .{
            .database = database,
            .allocator = allocator,
            .deposits = std.ArrayList(DepositRequest){},
        };
    }

    /// Deinitialize the deposits contract
    pub fn deinit(self: *Self) void {
        self.deposits.deinit(self.allocator);
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
            deposit.amount = std.math.shl(u64, deposit.amount, 8) | byte;
        }
        
        // Copy signature
        @memcpy(&deposit.signature, input[88..184]);
        
        // Parse index (8 bytes, big-endian)
        for (input[184..192]) |byte| {
            deposit.index = std.math.shl(u64, deposit.index, 8) | byte;
        }
        
        // Validate deposit amount (minimum 1 ETH = 1e9 Gwei)
        if (deposit.amount < 1_000_000_000) {
            log.debug("ValidatorDeposits: Deposit amount too low: {} Gwei", .{deposit.amount});
            return .{ .output = &.{}, .gas_used = DEPOSIT_GAS };
        }
        
        // Validate value matches amount (value is in Wei, amount is in Gwei)
        const expected_value: u256 = @as(u256, deposit.amount) * @as(u256, 1_000_000_000); // Convert Gwei to Wei
        if (value != expected_value) {
            log.debug("ValidatorDeposits: Value mismatch: {} Wei != {} Wei", .{ value, expected_value });
            return .{ .output = &.{}, .gas_used = DEPOSIT_GAS };
        }
        
        // Store deposit for processing
        try self.deposits.append(self.allocator, deposit);
        
        // Store deposit count in storage
        const deposit_count = self.deposits.items.len;
        try self.database.set_storage(
            DEPOSIT_CONTRACT_ADDRESS.bytes,
            0, // Storage slot 0 for deposit count
            @as(u256, deposit_count),
        );
        
        // Store deposit data hash at slot = index + 1
        // Compute proper Keccak256 hash of deposit data
        const deposit_hash = try computeDepositHash(&deposit);

        try self.database.set_storage(
            DEPOSIT_CONTRACT_ADDRESS.bytes,
            @as(u256, deposit.index + 1),
            deposit_hash,
        );
        
        log.debug("ValidatorDeposits: Processed deposit #{} for {} Gwei", .{ deposit.index, deposit.amount });

        // Return success (32 bytes with deposit index) - heap allocated
        const output = try self.allocator.alloc(u8, 32);
        errdefer self.allocator.free(output);
        @memset(output, 0);
        std.mem.writeInt(u256, output[0..32], @as(u256, deposit.index), .big);

        return .{ .output = output, .gas_used = DEPOSIT_GAS };
    }
    
    /// Get pending deposits for consensus layer processing
    pub fn getPendingDeposits(self: *Self) []const DepositRequest {
        return self.deposits.items;
    }
    
    /// Clear processed deposits (called after consensus layer processes them)
    pub fn clearProcessedDeposits(self: *Self, up_to_index: u64) !void {
        var new_deposits = std.ArrayList(DepositRequest){};
        errdefer new_deposits.deinit(self.allocator);
        
        for (self.deposits.items) |deposit| {
            if (deposit.index > up_to_index) {
                try new_deposits.append(self.allocator, deposit);
            }
        }
        
        self.deposits.deinit(self.allocator);
        self.deposits = new_deposits;
    }
    
    /// Process deposits at block boundary
    /// This is called by the EVM to make deposits available to consensus layer
    pub fn processBlockDeposits(
        database: *Database,
        block_info: *const BlockInfo,
    ) !void {
        // Get total deposit count from storage slot 0
        const deposit_count = try database.get_storage(
            DEPOSIT_CONTRACT_ADDRESS.bytes,
            0,
        );

        if (deposit_count == 0) {
            return; // No deposits to process
        }

        log.debug("ValidatorDeposits: Processing {} deposits for block {}", .{ deposit_count, block_info.number });

        // In a production implementation, this would:
        // 1. Collect all deposit hashes from storage (slots 1..deposit_count)
        // 2. Construct the deposit Merkle tree root
        // 3. Make the deposit root available to the consensus layer via block header
        // 4. Verify deposit data integrity

        // For now, we verify that all deposits have valid hashes stored
        var i: u256 = 1;
        while (i <= deposit_count) : (i += 1) {
            const deposit_hash = try database.get_storage(
                DEPOSIT_CONTRACT_ADDRESS.bytes,
                i,
            );

            // Verify hash is non-zero (valid deposit)
            if (deposit_hash == 0) {
                log.warn("ValidatorDeposits: Invalid deposit hash at index {} in block {}", .{ i - 1, block_info.number });
                return error.InvalidDepositHash;
            }
        }

        log.debug("ValidatorDeposits: Successfully validated {} deposits for block {}", .{ deposit_count, block_info.number });
    }
};

// Tests
test "validator deposit processing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
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
    const value: u256 = @as(u256, amount) * @as(u256, 1_000_000_000); // Convert to Wei
    const result = try contract.execute(
        primitives.ZERO_ADDRESS,
        &input,
        100000,
        value,
    );
    defer allocator.free(result.output); // Free heap-allocated output

    try testing.expectEqual(DEPOSIT_GAS, result.gas_used);
    try testing.expectEqual(@as(usize, 32), result.output.len);

    // Verify deposit was stored
    const deposits = contract.getPendingDeposits();
    try testing.expectEqual(@as(usize, 1), deposits.len);
    try testing.expectEqual(amount, deposits[0].amount);
    try testing.expectEqual(index, deposits[0].index);

    // Verify storage was updated
    const stored_count = try database.get_storage(DEPOSIT_CONTRACT_ADDRESS.bytes, 0);
    try testing.expectEqual(@as(u256, 1), stored_count);

    // Verify deposit hash was stored (should be non-zero)
    const deposit_hash = try database.get_storage(DEPOSIT_CONTRACT_ADDRESS.bytes, 1);
    try testing.expect(deposit_hash != 0);
}

test "deposit validation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
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

test "multiple deposits with proper memory management" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = ValidatorDepositsContract.init(allocator, &database);
    defer contract.deinit();

    // Create and execute 3 deposits
    const num_deposits = 3;
    var i: usize = 0;
    while (i < num_deposits) : (i += 1) {
        var input: [208]u8 = [_]u8{0} ** 208;

        // Unique pubkey for each deposit
        input[0..48].* = [_]u8{@as(u8, @intCast(i)) + 0xA0} ** 48;

        // Set withdrawal credentials
        input[48..80].* = [_]u8{0xBB} ** 32;

        // Set amount (32 ETH)
        const amount: u64 = 32_000_000_000;
        std.mem.writeInt(u64, input[80..88], amount, .big);

        // Set signature
        input[88..184].* = [_]u8{@as(u8, @intCast(i)) + 0xC0} ** 96;

        // Set index
        std.mem.writeInt(u64, input[184..192], i, .big);

        // Execute deposit
        const value: u256 = @as(u256, amount) * @as(u256, 1_000_000_000);
        const result = try contract.execute(
            primitives.ZERO_ADDRESS,
            &input,
            100000,
            value,
        );
        defer allocator.free(result.output);

        try testing.expectEqual(DEPOSIT_GAS, result.gas_used);
    }

    // Verify all deposits stored
    const deposits = contract.getPendingDeposits();
    try testing.expectEqual(@as(usize, num_deposits), deposits.len);

    // Verify storage count
    const stored_count = try database.get_storage(DEPOSIT_CONTRACT_ADDRESS.bytes, 0);
    try testing.expectEqual(@as(u256, num_deposits), stored_count);
}

test "clear processed deposits" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = ValidatorDepositsContract.init(allocator, &database);
    defer contract.deinit();

    // Add 5 deposits with indices 0-4
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var input: [208]u8 = [_]u8{0} ** 208;
        input[0..48].* = [_]u8{@as(u8, @intCast(i))} ** 48;
        input[48..80].* = [_]u8{0xBB} ** 32;

        const amount: u64 = 32_000_000_000;
        std.mem.writeInt(u64, input[80..88], amount, .big);
        input[88..184].* = [_]u8{0xCC} ** 96;
        std.mem.writeInt(u64, input[184..192], i, .big);

        const value: u256 = @as(u256, amount) * @as(u256, 1_000_000_000);
        const result = try contract.execute(
            primitives.ZERO_ADDRESS,
            &input,
            100000,
            value,
        );
        defer allocator.free(result.output);
    }

    // Verify all 5 deposits exist
    try testing.expectEqual(@as(usize, 5), contract.getPendingDeposits().len);

    // Clear deposits up to index 2 (removes deposits 0, 1, 2)
    try contract.clearProcessedDeposits(2);

    // Should have 2 deposits remaining (indices 3, 4)
    const remaining = contract.getPendingDeposits();
    try testing.expectEqual(@as(usize, 2), remaining.len);
    try testing.expectEqual(@as(u64, 3), remaining[0].index);
    try testing.expectEqual(@as(u64, 4), remaining[1].index);
}

test "deposit index ordering" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = ValidatorDepositsContract.init(allocator, &database);
    defer contract.deinit();

    // Add deposits with non-sequential indices
    const indices = [_]u64{ 10, 5, 15, 3 };
    for (indices) |index| {
        var input: [208]u8 = [_]u8{0} ** 208;
        input[0..48].* = [_]u8{@as(u8, @intCast(index))} ** 48;
        input[48..80].* = [_]u8{0xBB} ** 32;

        const amount: u64 = 32_000_000_000;
        std.mem.writeInt(u64, input[80..88], amount, .big);
        input[88..184].* = [_]u8{0xCC} ** 96;
        std.mem.writeInt(u64, input[184..192], index, .big);

        const value: u256 = @as(u256, amount) * @as(u256, 1_000_000_000);
        const result = try contract.execute(
            primitives.ZERO_ADDRESS,
            &input,
            100000,
            value,
        );
        defer allocator.free(result.output);
    }

    // Verify deposits maintain insertion order
    const deposits = contract.getPendingDeposits();
    try testing.expectEqual(@as(usize, 4), deposits.len);
    try testing.expectEqual(@as(u64, 10), deposits[0].index);
    try testing.expectEqual(@as(u64, 5), deposits[1].index);
    try testing.expectEqual(@as(u64, 15), deposits[2].index);
    try testing.expectEqual(@as(u64, 3), deposits[3].index);
}

test "value mismatch validation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = ValidatorDepositsContract.init(allocator, &database);
    defer contract.deinit();

    var input: [208]u8 = [_]u8{0} ** 208;
    input[0..48].* = [_]u8{0xAA} ** 48;
    input[48..80].* = [_]u8{0xBB} ** 32;

    const amount: u64 = 32_000_000_000;
    std.mem.writeInt(u64, input[80..88], amount, .big);
    input[88..184].* = [_]u8{0xCC} ** 96;
    std.mem.writeInt(u64, input[184..192], 0, .big);

    // Pass incorrect value (1 Wei less than expected)
    const wrong_value: u256 = (@as(u256, amount) * @as(u256, 1_000_000_000)) - 1;
    const result = try contract.execute(
        primitives.ZERO_ADDRESS,
        &input,
        100000,
        wrong_value,
    );

    // Should consume gas but not store deposit
    try testing.expectEqual(DEPOSIT_GAS, result.gas_used);
    try testing.expectEqual(@as(usize, 0), contract.getPendingDeposits().len);
}

test "minimum deposit amount validation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = ValidatorDepositsContract.init(allocator, &database);
    defer contract.deinit();

    var input: [208]u8 = [_]u8{0} ** 208;
    input[0..48].* = [_]u8{0xAA} ** 48;
    input[48..80].* = [_]u8{0xBB} ** 32;

    // Amount too low (999,999,999 Gwei < 1 ETH minimum)
    const amount: u64 = 999_999_999;
    std.mem.writeInt(u64, input[80..88], amount, .big);
    input[88..184].* = [_]u8{0xCC} ** 96;
    std.mem.writeInt(u64, input[184..192], 0, .big);

    const value: u256 = @as(u256, amount) * @as(u256, 1_000_000_000);
    const result = try contract.execute(
        primitives.ZERO_ADDRESS,
        &input,
        100000,
        value,
    );

    // Should consume gas but not store deposit
    try testing.expectEqual(DEPOSIT_GAS, result.gas_used);
    try testing.expectEqual(@as(usize, 0), contract.getPendingDeposits().len);
}

test "96-byte signature boundary conditions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = ValidatorDepositsContract.init(allocator, &database);
    defer contract.deinit();

    var input: [208]u8 = [_]u8{0} ** 208;
    input[0..48].* = [_]u8{0xAA} ** 48;
    input[48..80].* = [_]u8{0xBB} ** 32;

    const amount: u64 = 32_000_000_000;
    std.mem.writeInt(u64, input[80..88], amount, .big);

    // Test all-zeros signature (boundary)
    input[88..184].* = [_]u8{0x00} ** 96;
    std.mem.writeInt(u64, input[184..192], 0, .big);

    const value: u256 = @as(u256, amount) * @as(u256, 1_000_000_000);
    const result1 = try contract.execute(
        primitives.ZERO_ADDRESS,
        &input,
        100000,
        value,
    );
    defer allocator.free(result1.output);

    try testing.expectEqual(DEPOSIT_GAS, result1.gas_used);
    const deposits1 = contract.getPendingDeposits();
    try testing.expectEqual(@as(usize, 1), deposits1.len);
    try testing.expect(std.mem.eql(u8, &deposits1[0].signature, &([_]u8{0x00} ** 96)));

    // Test all-ones signature (boundary)
    input[88..184].* = [_]u8{0xFF} ** 96;
    std.mem.writeInt(u64, input[184..192], 1, .big);

    const result2 = try contract.execute(
        primitives.ZERO_ADDRESS,
        &input,
        100000,
        value,
    );
    defer allocator.free(result2.output);

    try testing.expectEqual(DEPOSIT_GAS, result2.gas_used);
    const deposits2 = contract.getPendingDeposits();
    try testing.expectEqual(@as(usize, 2), deposits2.len);
    try testing.expect(std.mem.eql(u8, &deposits2[1].signature, &([_]u8{0xFF} ** 96)));
}

test "deposit hash computation consistency" {
    const testing = std.testing;

    // Create two identical deposits
    const deposit1 = DepositRequest{
        .pubkey = [_]u8{0xAA} ** 48,
        .withdrawal_credentials = [_]u8{0xBB} ** 32,
        .amount = 32_000_000_000,
        .signature = [_]u8{0xCC} ** 96,
        .index = 0,
    };

    const deposit2 = DepositRequest{
        .pubkey = [_]u8{0xAA} ** 48,
        .withdrawal_credentials = [_]u8{0xBB} ** 32,
        .amount = 32_000_000_000,
        .signature = [_]u8{0xCC} ** 96,
        .index = 0,
    };

    // Hashes should be identical
    const hash1 = try computeDepositHash(&deposit1);
    const hash2 = try computeDepositHash(&deposit2);
    try testing.expectEqual(hash1, hash2);

    // Different deposit should have different hash
    const deposit3 = DepositRequest{
        .pubkey = [_]u8{0xDD} ** 48, // Different pubkey
        .withdrawal_credentials = [_]u8{0xBB} ** 32,
        .amount = 32_000_000_000,
        .signature = [_]u8{0xCC} ** 96,
        .index = 0,
    };

    const hash3 = try computeDepositHash(&deposit3);
    try testing.expect(hash1 != hash3);
}

test "process block deposits" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = ValidatorDepositsContract.init(allocator, &database);
    defer contract.deinit();

    // Add a deposit
    var input: [208]u8 = [_]u8{0} ** 208;
    input[0..48].* = [_]u8{0xAA} ** 48;
    input[48..80].* = [_]u8{0xBB} ** 32;

    const amount: u64 = 32_000_000_000;
    std.mem.writeInt(u64, input[80..88], amount, .big);
    input[88..184].* = [_]u8{0xCC} ** 96;
    std.mem.writeInt(u64, input[184..192], 0, .big);

    const value: u256 = @as(u256, amount) * @as(u256, 1_000_000_000);
    const result = try contract.execute(
        primitives.ZERO_ADDRESS,
        &input,
        100000,
        value,
    );
    defer allocator.free(result.output);

    // Create block info
    const block_info = BlockInfo{
        .number = 100,
        .timestamp = 1000000,
        .gas_limit = 30_000_000,
        .difficulty = 0,
        .base_fee_per_gas = 1_000_000_000,
    };

    // Process deposits
    try ValidatorDepositsContract.processBlockDeposits(&database, &block_info);
}

test "process block deposits with empty storage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    const block_info = BlockInfo{
        .number = 100,
        .timestamp = 1000000,
        .gas_limit = 30_000_000,
        .difficulty = 0,
        .base_fee_per_gas = 1_000_000_000,
    };

    // Should not error with no deposits
    try ValidatorDepositsContract.processBlockDeposits(&database, &block_info);
}

test "memory leak detection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = ValidatorDepositsContract.init(allocator, &database);
    defer contract.deinit();

    // Create and execute many deposits to stress test memory management
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        var input: [208]u8 = [_]u8{0} ** 208;
        input[0..48].* = [_]u8{@as(u8, @intCast(i % 256))} ** 48;
        input[48..80].* = [_]u8{0xBB} ** 32;

        const amount: u64 = 32_000_000_000;
        std.mem.writeInt(u64, input[80..88], amount, .big);
        input[88..184].* = [_]u8{0xCC} ** 96;
        std.mem.writeInt(u64, input[184..192], i, .big);

        const value: u256 = @as(u256, amount) * @as(u256, 1_000_000_000);
        const result = try contract.execute(
            primitives.ZERO_ADDRESS,
            &input,
            100000,
            value,
        );
        defer allocator.free(result.output); // Must free heap-allocated output
    }

    // Verify all deposits stored
    try testing.expectEqual(@as(usize, 100), contract.getPendingDeposits().len);

    // Clear some deposits
    try contract.clearProcessedDeposits(49);
    try testing.expectEqual(@as(usize, 50), contract.getPendingDeposits().len);
}

test "output contains correct deposit index" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = ValidatorDepositsContract.init(allocator, &database);
    defer contract.deinit();

    const test_index: u64 = 42;

    var input: [208]u8 = [_]u8{0} ** 208;
    input[0..48].* = [_]u8{0xAA} ** 48;
    input[48..80].* = [_]u8{0xBB} ** 32;

    const amount: u64 = 32_000_000_000;
    std.mem.writeInt(u64, input[80..88], amount, .big);
    input[88..184].* = [_]u8{0xCC} ** 96;
    std.mem.writeInt(u64, input[184..192], test_index, .big);

    const value: u256 = @as(u256, amount) * @as(u256, 1_000_000_000);
    const result = try contract.execute(
        primitives.ZERO_ADDRESS,
        &input,
        100000,
        value,
    );
    defer allocator.free(result.output);

    // Verify output contains the deposit index
    try testing.expectEqual(@as(usize, 32), result.output.len);
    const output_index = std.mem.readInt(u256, result.output[0..32], .big);
    try testing.expectEqual(@as(u256, test_index), output_index);
}
