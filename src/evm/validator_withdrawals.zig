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
const Database = @import("database.zig").Database;
const BlockInfo = @import("block_info.zig").DefaultBlockInfo;
const log = @import("log.zig");

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

/// Validator withdrawals contract implementation
pub const ValidatorWithdrawalsContract = struct {
    database: *Database,
    pending_withdrawals: std.ArrayList(WithdrawalRequest),
    
    const Self = @This();
    
    /// Initialize the withdrawals contract
    pub fn init(allocator: std.mem.Allocator, database: *Database) Self {
        return .{
            .database = database,
            .pending_withdrawals = std.ArrayList(WithdrawalRequest).init(allocator),
        };
    }
    
    /// Deinitialize the withdrawals contract
    pub fn deinit(self: *Self) void {
        self.pending_withdrawals.deinit();
    }
    
    /// Execute the validator withdrawals contract
    /// 
    /// Input format (76 bytes):
    /// - 20 bytes: source address
    /// - 48 bytes: validator pubkey
    /// - 8 bytes: amount (0 for full withdrawal)
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
            log.debug("ValidatorWithdrawals: Unauthorized - caller {} != source {}", .{ caller, request.source_address });
            return .{ .output = &.{}, .gas_used = WITHDRAWAL_REQUEST_GAS };
        }
        
        // Copy validator pubkey
        @memcpy(&request.validator_pubkey, input[20..68]);
        
        // Parse amount (8 bytes, big-endian)
        for (input[68..76]) |byte| {
            request.amount = (request.amount << 8) | byte;
        }
        
        // Store withdrawal request
        try self.pending_withdrawals.append(request);
        
        // Store withdrawal count in storage
        const withdrawal_count = self.pending_withdrawals.items.len;
        try self.database.set_storage(
            WITHDRAWAL_REQUEST_ADDRESS.bytes,
            0, // Storage slot 0 for withdrawal count
            withdrawal_count,
        );
        
        // Store withdrawal request hash at slot = count
        var request_hash: u256 = 0;
        // Simple hash: XOR all bytes (in production, use proper hashing)
        for (request.source_address.bytes) |byte| {
            request_hash ^= byte;
        }
        for (request.validator_pubkey) |byte| {
            request_hash ^= (@as(u256, byte) << 8);
        }
        request_hash ^= request.amount;
        
        try self.database.set_storage(
            WITHDRAWAL_REQUEST_ADDRESS.bytes,
            withdrawal_count,
            request_hash,
        );
        
        log.debug("ValidatorWithdrawals: Processed withdrawal request #{} for validator", .{withdrawal_count});
        
        // Return success (32 bytes with request index)
        var output: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &output, withdrawal_count - 1, .big);
        
        return .{ .output = &output, .gas_used = WITHDRAWAL_REQUEST_GAS };
    }
    
    /// Get pending withdrawal requests for consensus layer processing
    pub fn getPendingWithdrawals(self: *Self) []const WithdrawalRequest {
        return self.pending_withdrawals.items;
    }
    
    /// Clear processed withdrawals (called after consensus layer processes them)
    pub fn clearProcessedWithdrawals(self: *Self) void {
        self.pending_withdrawals.clearRetainingCapacity();
        
        // Clear storage count
        self.database.set_storage(
            WITHDRAWAL_REQUEST_ADDRESS.bytes,
            0,
            0,
        ) catch |err| {
            log.err("Failed to clear withdrawal count: {}", .{err});
        };
    }
    
    /// Process withdrawals at block boundary
    /// This would be called by the EVM to make withdrawals available to consensus layer
    pub fn processBlockWithdrawals(
        database: *Database,
        block_info: *const BlockInfo,
    ) !void {
        // In a real implementation, this would:
        // 1. Collect all withdrawal requests from the current block
        // 2. Validate the requests against validator state
        // 3. Make the withdrawal requests available to the consensus layer
        
        const withdrawal_count = try database.get_storage(
            WITHDRAWAL_REQUEST_ADDRESS.bytes,
            0,
        );
        
        if (withdrawal_count > 0) {
            log.debug("ValidatorWithdrawals: {} withdrawal requests ready for block {}", .{ withdrawal_count, block_info.number });
        }
    }
};

// Tests
test "validator withdrawal request" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var database = try Database.init(allocator);
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
    
    var database = try Database.init(allocator);
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
    
    var database = try Database.init(allocator);
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
        try testing.expectEqual(WITHDRAWAL_REQUEST_GAS, result.gas_used);
    }
    
    // Verify we have max withdrawals
    try testing.expectEqual(MAX_WITHDRAWAL_REQUESTS_PER_BLOCK, contract.getPendingWithdrawals().len);
    
    // Try to add one more - should not be stored
    var input: [76]u8 = [_]u8{0} ** 76;
    const extra_address = try Address.from_hex("0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF");
    @memcpy(input[0..20], &extra_address.bytes);
    
    const result = try contract.execute(extra_address, &input, 100000);
    try testing.expectEqual(WITHDRAWAL_REQUEST_GAS, result.gas_used);
    
    // Should still have max withdrawals (no new one added)
    try testing.expectEqual(MAX_WITHDRAWAL_REQUESTS_PER_BLOCK, contract.getPendingWithdrawals().len);
}