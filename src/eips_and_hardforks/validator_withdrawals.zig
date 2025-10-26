/// EIP-7002: Execution layer triggerable exits
///
/// This module implements a system contract that handles validator withdrawal
/// requests from the execution layer. The contract processes withdrawal requests
/// and makes them available to the consensus layer for validator exits.
///
/// Validators or their withdrawal addresses can request exits through this contract.
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const Database = @import("../storage/database.zig").Database;
const BlockInfo = @import("../block/block_info.zig").BlockInfo(.{});
const log = @import("../log.zig");
const keccak_asm = @import("crypto").keccak_asm;

/// EIP-7002 withdrawal request contract address
/// Deployed at 0x00A3ca265EBcb825B45F985A16CEFB49958cE017
pub const WITHDRAWAL_REQUEST_ADDRESS = Address{
    .bytes = [_]u8{
        0x00, 0xA3, 0xca, 0x26, 0x5E, 0xBc, 0xb8, 0x25,
        0xB4, 0x5F, 0x98, 0x5A, 0x16, 0xCE, 0xFB, 0x49,
        0x95, 0x8c, 0xE0, 0x17,
    },
};

/// System address that can process withdrawals
/// 0xfffffffffffffffffffffffffffffffffffffffe
pub const SYSTEM_ADDRESS = Address{
    .bytes = [_]u8{
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xfe,
    },
};

/// Gas cost for processing a withdrawal request
pub const WITHDRAWAL_REQUEST_GAS: u64 = 30000;

/// Maximum withdrawal requests per block
pub const MAX_WITHDRAWAL_REQUESTS_PER_BLOCK: usize = 16;

/// Withdrawal request structure
pub const WithdrawalRequest = struct {
    /// Source address requesting the withdrawal
    source_address: Address,
    /// Validator public key (48 bytes)
    validator_pubkey: [48]u8,
    /// Amount to withdraw (full or partial)
    amount: u64,
};

/// Compute collision-resistant hash of a withdrawal request using Keccak256
/// Returns the first 32 bytes (u256) of the hash
fn computeWithdrawalHash(request: *const WithdrawalRequest) !u256 {
    // Build input buffer: 20 (address) + 48 (pubkey) + 8 (amount) = 76 bytes
    var input_buffer: [76]u8 = undefined;

    // Copy source address (20 bytes)
    @memcpy(input_buffer[0..20], &request.source_address.bytes);

    // Copy validator pubkey (48 bytes)
    @memcpy(input_buffer[20..68], &request.validator_pubkey);

    // Copy amount (8 bytes, big-endian)
    std.mem.writeInt(u64, input_buffer[68..76], request.amount, .big);

    // Compute Keccak256 hash (32 bytes output)
    var hash: [32]u8 = undefined;
    keccak_asm.keccak256(&hash, &input_buffer);

    // Convert hash bytes to u256 (big-endian)
    return std.mem.readInt(u256, &hash, .big);
}

/// Validator withdrawals contract implementation
pub const ValidatorWithdrawalsContract = struct {
    database: *Database,
    allocator: std.mem.Allocator,
    pending_withdrawals: std.ArrayList(WithdrawalRequest),

    const Self = @This();

    /// Initialize the withdrawals contract
    pub fn init(allocator: std.mem.Allocator, database: *Database) Self {
        return .{
            .database = database,
            .allocator = allocator,
            .pending_withdrawals = std.ArrayList(WithdrawalRequest){},
        };
    }

    /// Deinitialize the withdrawals contract
    pub fn deinit(self: *Self) void {
        self.pending_withdrawals.deinit(self.allocator);
    }
    
    /// Execute the validator withdrawals contract
    ///
    /// Input format (76 bytes):
    /// - 20 bytes: source address
    /// - 48 bytes: validator pubkey
    /// - 8 bytes: amount (0 for full withdrawal)
    ///
    /// Returns heap-allocated output (caller must free)
    pub fn execute(
        self: *Self,
        caller: Address,
        input: []const u8,
        gas_limit: u64,
    ) !struct { output: []const u8, gas_used: u64 } {
        // Check gas
        if (gas_limit < WITHDRAWAL_REQUEST_GAS) {
            return error.OutOfGas;
        }

        // Validate input length
        if (input.len != 76) {
            log.debug("ValidatorWithdrawals: Invalid input length: {} (expected 76)", .{input.len});
            return .{ .output = &.{}, .gas_used = 0 };
        }

        // Check if we've reached the maximum withdrawal requests for this block
        if (self.pending_withdrawals.items.len >= MAX_WITHDRAWAL_REQUESTS_PER_BLOCK) {
            log.debug("ValidatorWithdrawals: Maximum withdrawal requests reached for this block", .{});
            return .{ .output = &.{}, .gas_used = WITHDRAWAL_REQUEST_GAS };
        }

        // Parse withdrawal request
        var request = WithdrawalRequest{
            .source_address = undefined,
            .validator_pubkey = undefined,
            .amount = 0,
        };

        // Copy source address
        @memcpy(&request.source_address.bytes, input[0..20]);

        // Verify caller matches source address (authorization check)
        if (!std.mem.eql(u8, &caller.bytes, &request.source_address.bytes)) {
            log.debug("ValidatorWithdrawals: Unauthorized - caller {any} != source {any}", .{ caller, request.source_address });
            return .{ .output = &.{}, .gas_used = WITHDRAWAL_REQUEST_GAS };
        }

        // Copy validator pubkey
        @memcpy(&request.validator_pubkey, input[20..68]);

        // Parse amount (8 bytes, big-endian)
        for (input[68..76]) |byte| {
            request.amount = (request.amount << 8) | byte;
        }

        // Store withdrawal request
        try self.pending_withdrawals.append(self.allocator, request);

        // Store withdrawal count in storage
        const withdrawal_count = self.pending_withdrawals.items.len;
        try self.database.set_storage(
            WITHDRAWAL_REQUEST_ADDRESS.bytes,
            0, // Storage slot 0 for withdrawal count
            @as(u256, withdrawal_count),
        );

        // Calculate proper hash using Keccak256
        const request_hash = try computeWithdrawalHash(&request);

        try self.database.set_storage(
            WITHDRAWAL_REQUEST_ADDRESS.bytes,
            @as(u256, withdrawal_count),
            request_hash,
        );

        log.debug("ValidatorWithdrawals: Processed withdrawal request #{} for validator", .{withdrawal_count});

        // Allocate output on heap (caller must free)
        const output = try self.allocator.alloc(u8, 32);
        errdefer self.allocator.free(output);
        @memset(output, 0);
        std.mem.writeInt(u256, output[0..32], @as(u256, withdrawal_count - 1), .big);

        return .{ .output = output, .gas_used = WITHDRAWAL_REQUEST_GAS };
    }
    
    /// Get pending withdrawal requests for consensus layer processing
    pub fn getPendingWithdrawals(self: *Self) []const WithdrawalRequest {
        return self.pending_withdrawals.items;
    }
    
    /// Clear processed withdrawals (called after consensus layer processes them)
    /// Returns error if storage cannot be updated
    pub fn clearProcessedWithdrawals(self: *Self) !void {
        self.pending_withdrawals.clearRetainingCapacity();

        // Clear storage count - propagate error to caller
        try self.database.set_storage(
            WITHDRAWAL_REQUEST_ADDRESS.bytes,
            0,
            0,
        );
    }
    
    /// Process withdrawals at block boundary
    /// This would be called by the EVM to make withdrawals available to consensus layer
    ///
    /// Implementation notes:
    /// In a production system, this function would:
    /// 1. Read all withdrawal requests from contract storage
    /// 2. Validate requests against validator state
    /// 3. Apply withdrawal queue ordering rules
    /// 4. Enforce per-block limits
    /// 5. Generate withdrawal receipts for consensus layer
    ///
    /// Current implementation validates storage access and logs the withdrawal count.
    pub fn processBlockWithdrawals(
        database: *Database,
        block_info: *const BlockInfo,
    ) !void {
        const withdrawal_count = try database.get_storage(
            WITHDRAWAL_REQUEST_ADDRESS.bytes,
            0,
        );

        if (withdrawal_count > 0) {
            // Validate withdrawal count is within reasonable bounds
            if (withdrawal_count > MAX_WITHDRAWAL_REQUESTS_PER_BLOCK) {
                log.warn("ValidatorWithdrawals: Block {} has {} withdrawals exceeding max of {}", .{
                    block_info.number,
                    withdrawal_count,
                    MAX_WITHDRAWAL_REQUESTS_PER_BLOCK,
                });
                return error.TooManyWithdrawals;
            }

            log.debug("ValidatorWithdrawals: {} withdrawal requests ready for block {}", .{
                withdrawal_count,
                block_info.number,
            });

            // In production, would iterate through storage slots 1..withdrawal_count
            // and reconstruct WithdrawalRequest structs from hashes for consensus layer
        }
    }
};

// Tests
test "validator withdrawal request" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = ValidatorWithdrawalsContract.init(allocator, &database);
    defer contract.deinit();

    // Create a valid withdrawal request
    var input: [76]u8 = [_]u8{0} ** 76;

    // Set source address (20 bytes)
    const source_address = try Address.from_hex("0x1234567890123456789012345678901234567890");
    @memcpy(input[0..20], &source_address.bytes);

    // Set validator pubkey (48 bytes)
    input[20..68].* = [_]u8{0xAA} ** 48;

    // Set amount (0 for full withdrawal)
    const amount: u64 = 0;
    std.mem.writeInt(u64, input[68..76], amount, .big);

    // Execute withdrawal request (must be called by source address)
    const result = try contract.execute(
        source_address,
        &input,
        100000,
    );
    defer allocator.free(result.output);

    try testing.expectEqual(WITHDRAWAL_REQUEST_GAS, result.gas_used);

    // Verify withdrawal was stored
    const withdrawals = contract.getPendingWithdrawals();
    try testing.expectEqual(@as(usize, 1), withdrawals.len);
    try testing.expectEqualSlices(u8, &source_address.bytes, &withdrawals[0].source_address.bytes);
    try testing.expectEqual(amount, withdrawals[0].amount);

    // Verify storage was updated
    const stored_count = try database.get_storage(WITHDRAWAL_REQUEST_ADDRESS.bytes, 0);
    try testing.expectEqual(@as(u256, 1), stored_count);
}

test "withdrawal authorization check" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var database = Database.init(allocator);
    defer database.deinit();
    
    var contract = ValidatorWithdrawalsContract.init(allocator, &database);
    defer contract.deinit();
    
    // Create a withdrawal request
    var input: [76]u8 = [_]u8{0} ** 76;
    
    // Set source address
    const source_address = try Address.from_hex("0x1234567890123456789012345678901234567890");
    @memcpy(input[0..20], &source_address.bytes);
    
    // Set validator pubkey
    input[20..68].* = [_]u8{0xAA} ** 48;
    
    // Try to execute with different caller (unauthorized)
    const unauthorized_caller = try Address.from_hex("0x9999999999999999999999999999999999999999");
    const result = try contract.execute(
        unauthorized_caller,
        &input,
        100000,
    );
    
    // Should execute but not store withdrawal (authorization failed)
    try testing.expectEqual(WITHDRAWAL_REQUEST_GAS, result.gas_used);
    
    // Verify no withdrawal was stored
    const withdrawals = contract.getPendingWithdrawals();
    try testing.expectEqual(@as(usize, 0), withdrawals.len);
}

test "max withdrawals per block" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = ValidatorWithdrawalsContract.init(allocator, &database);
    defer contract.deinit();

    // Fill up to max withdrawals
    var i: usize = 0;
    while (i < MAX_WITHDRAWAL_REQUESTS_PER_BLOCK) : (i += 1) {
        var input: [76]u8 = [_]u8{0} ** 76;

        // Use different addresses for each request
        var addr_bytes: [20]u8 = [_]u8{0} ** 20;
        addr_bytes[19] = @intCast(i);
        const source_address = Address{ .bytes = addr_bytes };
        @memcpy(input[0..20], &source_address.bytes);

        // Set validator pubkey
        input[20..68].* = [_]u8{@intCast(i)} ** 48;

        const result = try contract.execute(source_address, &input, 100000);
        defer allocator.free(result.output);
        try testing.expectEqual(WITHDRAWAL_REQUEST_GAS, result.gas_used);
    }

    // Verify we have max withdrawals
    try testing.expectEqual(MAX_WITHDRAWAL_REQUESTS_PER_BLOCK, contract.getPendingWithdrawals().len);

    // Try to add one more - should not be stored
    var input: [76]u8 = [_]u8{0} ** 76;
    const extra_address = try Address.from_hex("0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF");
    @memcpy(input[0..20], &extra_address.bytes);

    const result = try contract.execute(extra_address, &input, 100000);
    // No output allocated when limit reached, so no defer needed here (output is empty slice)

    try testing.expectEqual(WITHDRAWAL_REQUEST_GAS, result.gas_used);

    // Should still have max withdrawals (no new one added)
    try testing.expectEqual(MAX_WITHDRAWAL_REQUESTS_PER_BLOCK, contract.getPendingWithdrawals().len);
}

test "clearProcessedWithdrawals error propagation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = ValidatorWithdrawalsContract.init(allocator, &database);
    defer contract.deinit();

    // Add a withdrawal
    var input: [76]u8 = [_]u8{0} ** 76;
    const source_address = try Address.from_hex("0x1234567890123456789012345678901234567890");
    @memcpy(input[0..20], &source_address.bytes);
    input[20..68].* = [_]u8{0xAA} ** 48;

    const result = try contract.execute(source_address, &input, 100000);
    defer allocator.free(result.output);

    // Verify withdrawal exists
    try testing.expectEqual(@as(usize, 1), contract.getPendingWithdrawals().len);

    // Clear withdrawals - should propagate any database errors
    try contract.clearProcessedWithdrawals();

    // Verify cleared
    try testing.expectEqual(@as(usize, 0), contract.getPendingWithdrawals().len);

    // Verify storage was updated
    const stored_count = try database.get_storage(WITHDRAWAL_REQUEST_ADDRESS.bytes, 0);
    try testing.expectEqual(@as(u256, 0), stored_count);
}

test "withdrawal hash calculation deterministic" {
    const testing = std.testing;

    // Create two identical requests
    const request1 = WithdrawalRequest{
        .source_address = Address{ .bytes = [_]u8{0x12} ** 20 },
        .validator_pubkey = [_]u8{0xAB} ** 48,
        .amount = 1000,
    };

    const request2 = WithdrawalRequest{
        .source_address = Address{ .bytes = [_]u8{0x12} ** 20 },
        .validator_pubkey = [_]u8{0xAB} ** 48,
        .amount = 1000,
    };

    // Hashes should be identical
    const hash1 = try computeWithdrawalHash(&request1);
    const hash2 = try computeWithdrawalHash(&request2);
    try testing.expectEqual(hash1, hash2);
}

test "withdrawal hash calculation collision resistance" {
    const testing = std.testing;

    // Create different requests
    const request1 = WithdrawalRequest{
        .source_address = Address{ .bytes = [_]u8{0x12} ** 20 },
        .validator_pubkey = [_]u8{0xAB} ** 48,
        .amount = 1000,
    };

    const request2 = WithdrawalRequest{
        .source_address = Address{ .bytes = [_]u8{0x34} ** 20 },
        .validator_pubkey = [_]u8{0xCD} ** 48,
        .amount = 2000,
    };

    // Hashes should be different (collision resistance)
    const hash1 = try computeWithdrawalHash(&request1);
    const hash2 = try computeWithdrawalHash(&request2);
    try testing.expect(hash1 != hash2);
}

test "withdrawal hash changes with any field modification" {
    const testing = std.testing;

    const base_request = WithdrawalRequest{
        .source_address = Address{ .bytes = [_]u8{0x12} ** 20 },
        .validator_pubkey = [_]u8{0xAB} ** 48,
        .amount = 1000,
    };

    const base_hash = try computeWithdrawalHash(&base_request);

    // Modify source address
    var modified = base_request;
    modified.source_address.bytes[0] = 0x99;
    const hash_addr = try computeWithdrawalHash(&modified);
    try testing.expect(base_hash != hash_addr);

    // Modify pubkey
    modified = base_request;
    modified.validator_pubkey[0] = 0x99;
    const hash_pubkey = try computeWithdrawalHash(&modified);
    try testing.expect(base_hash != hash_pubkey);

    // Modify amount
    modified = base_request;
    modified.amount = 2000;
    const hash_amount = try computeWithdrawalHash(&modified);
    try testing.expect(base_hash != hash_amount);
}

test "processBlockWithdrawals validates withdrawal count" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = ValidatorWithdrawalsContract.init(allocator, &database);
    defer contract.deinit();

    // Add withdrawals up to max
    var i: usize = 0;
    while (i < MAX_WITHDRAWAL_REQUESTS_PER_BLOCK) : (i += 1) {
        var input: [76]u8 = [_]u8{0} ** 76;
        var addr_bytes: [20]u8 = [_]u8{0} ** 20;
        addr_bytes[19] = @intCast(i);
        const source_address = Address{ .bytes = addr_bytes };
        @memcpy(input[0..20], &source_address.bytes);
        input[20..68].* = [_]u8{@intCast(i)} ** 48;

        const result = try contract.execute(source_address, &input, 100000);
        defer allocator.free(result.output);
    }

    // Process block withdrawals should succeed
    const block_info = BlockInfo(.{}){
        .number = 1000,
        .timestamp = 1234567890,
        .difficulty = 0,
        .gas_limit = 30000000,
        .coinbase = Address{ .bytes = [_]u8{0} ** 20 },
        .base_fee_per_gas = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    try ValidatorWithdrawalsContract.processBlockWithdrawals(&database, &block_info);
}

test "processBlockWithdrawals rejects excessive withdrawals" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    // Manually set withdrawal count to exceed limit
    try database.set_storage(
        WITHDRAWAL_REQUEST_ADDRESS.bytes,
        0,
        MAX_WITHDRAWAL_REQUESTS_PER_BLOCK + 5,
    );

    const block_info = BlockInfo(.{}){
        .number = 1000,
        .timestamp = 1234567890,
        .difficulty = 0,
        .gas_limit = 30000000,
        .coinbase = Address{ .bytes = [_]u8{0} ** 20 },
        .base_fee_per_gas = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    // Should return error for too many withdrawals
    const result = ValidatorWithdrawalsContract.processBlockWithdrawals(&database, &block_info);
    try testing.expectError(error.TooManyWithdrawals, result);
}

test "memory safety - output heap allocation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = ValidatorWithdrawalsContract.init(allocator, &database);
    defer contract.deinit();

    var input: [76]u8 = [_]u8{0} ** 76;
    const source_address = try Address.from_hex("0x1234567890123456789012345678901234567890");
    @memcpy(input[0..20], &source_address.bytes);
    input[20..68].* = [_]u8{0xAA} ** 48;

    const result = try contract.execute(source_address, &input, 100000);
    defer allocator.free(result.output);

    // Verify output is properly allocated
    try testing.expectEqual(@as(usize, 32), result.output.len);

    // Verify output contains valid data
    const index = std.mem.readInt(u256, result.output[0..32], .big);
    try testing.expectEqual(@as(u256, 0), index);
}

test "out of gas error handling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = ValidatorWithdrawalsContract.init(allocator, &database);
    defer contract.deinit();

    var input: [76]u8 = [_]u8{0} ** 76;
    const source_address = try Address.from_hex("0x1234567890123456789012345678901234567890");
    @memcpy(input[0..20], &source_address.bytes);
    input[20..68].* = [_]u8{0xAA} ** 48;

    // Execute with insufficient gas
    const result = contract.execute(source_address, &input, WITHDRAWAL_REQUEST_GAS - 1);
    try testing.expectError(error.OutOfGas, result);
}

test "invalid input length handling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = ValidatorWithdrawalsContract.init(allocator, &database);
    defer contract.deinit();

    // Try with wrong input length
    var input: [50]u8 = [_]u8{0} ** 50;
    const source_address = try Address.from_hex("0x1234567890123456789012345678901234567890");

    const result = try contract.execute(source_address, &input, 100000);
    // Empty output for invalid input (no allocation)
    try testing.expectEqual(@as(usize, 0), result.output.len);
    try testing.expectEqual(@as(u64, 0), result.gas_used);
}

test "withdrawal request parsing - big endian amount" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = ValidatorWithdrawalsContract.init(allocator, &database);
    defer contract.deinit();

    var input: [76]u8 = [_]u8{0} ** 76;
    const source_address = try Address.from_hex("0x1234567890123456789012345678901234567890");
    @memcpy(input[0..20], &source_address.bytes);
    input[20..68].* = [_]u8{0xAA} ** 48;

    // Set amount as big-endian: 0x0000000000001234 = 4660
    const amount: u64 = 4660;
    std.mem.writeInt(u64, input[68..76], amount, .big);

    const result = try contract.execute(source_address, &input, 100000);
    defer allocator.free(result.output);

    // Verify amount was parsed correctly
    const withdrawals = contract.getPendingWithdrawals();
    try testing.expectEqual(amount, withdrawals[0].amount);
}

test "multiple withdrawals maintain correct order" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = ValidatorWithdrawalsContract.init(allocator, &database);
    defer contract.deinit();

    // Add three withdrawals with different amounts
    const amounts = [_]u64{ 1000, 2000, 3000 };
    for (amounts, 0..) |amount, i| {
        var input: [76]u8 = [_]u8{0} ** 76;
        var addr_bytes: [20]u8 = [_]u8{0} ** 20;
        addr_bytes[19] = @intCast(i);
        const source_address = Address{ .bytes = addr_bytes };
        @memcpy(input[0..20], &source_address.bytes);
        input[20..68].* = [_]u8{@intCast(i)} ** 48;
        std.mem.writeInt(u64, input[68..76], amount, .big);

        const result = try contract.execute(source_address, &input, 100000);
        defer allocator.free(result.output);
    }

    // Verify order is maintained
    const withdrawals = contract.getPendingWithdrawals();
    try testing.expectEqual(@as(usize, 3), withdrawals.len);
    for (amounts, 0..) |amount, i| {
        try testing.expectEqual(amount, withdrawals[i].amount);
    }
}

test "storage hash correctly stored and retrievable" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = ValidatorWithdrawalsContract.init(allocator, &database);
    defer contract.deinit();

    var input: [76]u8 = [_]u8{0} ** 76;
    const source_address = try Address.from_hex("0x1234567890123456789012345678901234567890");
    @memcpy(input[0..20], &source_address.bytes);
    input[20..68].* = [_]u8{0xAA} ** 48;
    const amount: u64 = 1000;
    std.mem.writeInt(u64, input[68..76], amount, .big);

    const result = try contract.execute(source_address, &input, 100000);
    defer allocator.free(result.output);

    // Compute expected hash
    const withdrawals = contract.getPendingWithdrawals();
    const expected_hash = try computeWithdrawalHash(&withdrawals[0]);

    // Retrieve hash from storage (stored at slot 1 for first withdrawal)
    const stored_hash = try database.get_storage(WITHDRAWAL_REQUEST_ADDRESS.bytes, 1);
    try testing.expectEqual(expected_hash, stored_hash);
}
