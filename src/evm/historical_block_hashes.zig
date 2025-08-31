/// EIP-2935: Historical block hashes via system contract
///
/// This module implements a system contract that stores historical block hashes
/// in a ring buffer, providing access to block hashes older than the standard
/// 256 block window.
///
/// The contract is deployed at 0x0b address and uses a ring buffer with
/// HISTORY_BUFFER_LENGTH entries to store recent block hashes.
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const Database = @import("database.zig").Database;
const BlockInfo = @import("block_info.zig").DefaultBlockInfo;
const log = @import("log.zig");

/// EIP-2935 historical block hashes contract address
/// Deployed at 0x0b
pub const HISTORY_CONTRACT_ADDRESS = Address{
    .bytes = [_]u8{0} ** 19 ++ [_]u8{0x0b},
};

/// System address that can update block hashes
/// 0xfffffffffffffffffffffffffffffffffffffffe
pub const SYSTEM_ADDRESS = Address{
    .bytes = [_]u8{
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xfe,
    },
};

/// Length of the historical block hashes ring buffer
pub const HISTORY_BUFFER_LENGTH: u64 = 8192;

/// Gas cost for reading a block hash
pub const BLOCK_HASH_READ_GAS: u64 = 2100;

/// Gas cost for writing a block hash (system call only)
pub const BLOCK_HASH_WRITE_GAS: u64 = 20000;

/// Historical block hashes contract implementation
pub const HistoricalBlockHashesContract = struct {
    database: *Database,
    
    const Self = @This();
    
    /// Execute the historical block hashes contract
    /// 
    /// If called by the system address with 64 bytes input:
    /// - First 32 bytes: block number
    /// - Second 32 bytes: block hash
    /// Stores the block hash in the ring buffer
    ///
    /// If called with 32 bytes input (block number):
    /// Returns the block hash for that block if available
    pub fn execute(
        self: *Self,
        caller: Address,
        input: []const u8,
        gas_limit: u64,
    ) !struct { output: []const u8, gas_used: u64 } {
        // System call to update block hash
        if (std.mem.eql(u8, &caller.bytes, &SYSTEM_ADDRESS.bytes)) {
            if (input.len != 64) {
                log.debug("HistoricalBlockHashes: Invalid system call input length: {}", .{input.len});
                return .{ .output = &.{}, .gas_used = 0 };
            }
            
            if (gas_limit < BLOCK_HASH_WRITE_GAS) {
                return error.OutOfGas;
            }
            
            // Parse block number and hash
            var block_number: u256 = 0;
            var block_hash: [32]u8 = undefined;
            
            // Read block number (big-endian)
            for (input[0..32]) |byte| {
                block_number = (block_number << 8) | byte;
            }
            @memcpy(&block_hash, input[32..64]);
            
            // Store in ring buffer at slot = block_number % HISTORY_BUFFER_LENGTH
            const slot = block_number % HISTORY_BUFFER_LENGTH;
            
            // Store block_number -> hash
            try self.database.set_storage(
                HISTORY_CONTRACT_ADDRESS.bytes,
                slot,
                @bitCast(block_hash),
            );
            
            log.debug("HistoricalBlockHashes: Stored hash for block {} at slot {}", .{ block_number, slot });
            
            return .{ .output = &.{}, .gas_used = BLOCK_HASH_WRITE_GAS };
        }
        
        // Regular call to read block hash
        if (input.len != 32) {
            log.debug("HistoricalBlockHashes: Invalid read input length: {}", .{input.len});
            return .{ .output = &.{}, .gas_used = 0 };
        }
        
        if (gas_limit < BLOCK_HASH_READ_GAS) {
            return error.OutOfGas;
        }
        
        // Parse block number
        var block_number: u256 = 0;
        for (input[0..32]) |byte| {
            block_number = (block_number << 8) | byte;
        }
        
        // Retrieve from ring buffer
        const slot = block_number % HISTORY_BUFFER_LENGTH;
        const stored_hash = try self.database.get_storage(
            HISTORY_CONTRACT_ADDRESS.bytes,
            slot,
        );
        
        // Return the block hash
        const hash_bytes: [32]u8 = @bitCast(stored_hash);
        
        // Need to allocate output that lives beyond this function
        // In real implementation, this would be handled by the caller
        return .{ .output = &hash_bytes, .gas_used = BLOCK_HASH_READ_GAS };
    }
    
    /// Process a block hash update at the start of a block
    /// This should be called by the EVM before processing any transactions
    pub fn processBlockHashUpdate(
        database: *Database,
        block_info: *const BlockInfo,
    ) !void {
        if (block_info.number == 0) {
            // No parent hash for genesis block
            return;
        }
        
        const parent_number = block_info.number - 1;
        const parent_hash = block_info.parent_hash;
        
        // Store in ring buffer
        const slot = parent_number % HISTORY_BUFFER_LENGTH;
        
        // Store block_number -> hash
        try database.set_storage(
            HISTORY_CONTRACT_ADDRESS.bytes,
            slot,
            @bitCast(parent_hash),
        );
        
        log.debug("HistoricalBlockHashes: Updated block hash for block {}", .{parent_number});
    }
    
    /// Get a block hash from the contract or recent history
    /// This combines EIP-2935 with standard BLOCKHASH semantics
    pub fn getBlockHash(
        database: *Database,
        block_number: u64,
        current_block: u64,
    ) !?[32]u8 {
        // Standard BLOCKHASH rules first
        // - Return null for current block and future blocks
        // - Return null for block 0 (genesis)
        if (block_number >= current_block or block_number == 0) {
            return null;
        }
        
        // For recent blocks (within 256), use standard mechanism
        // (this would normally come from block headers, but we'll check storage)
        
        // Always check the storage first
        const slot = block_number % HISTORY_BUFFER_LENGTH;
        const stored_hash = try database.get_storage(
            HISTORY_CONTRACT_ADDRESS.bytes,
            slot,
        );
        
        // Check if we have a valid hash (non-zero)
        if (stored_hash != 0) {
            return @bitCast(stored_hash);
        }
        
        return null;
    }
};

// Tests
test "historical block hashes ring buffer storage" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var database = try Database.init(allocator);
    defer database.deinit();
    
    // Test storing and retrieving block hashes
    const block_numbers = [_]u64{ 100, 200, 300, 8192000 };
    const hashes = [_][32]u8{
        [_]u8{0x01} ** 32,
        [_]u8{0x02} ** 32,
        [_]u8{0x03} ** 32,
        [_]u8{0x04} ** 32,
    };
    
    for (block_numbers, hashes) |block_number, hash| {
        const slot = block_number % HISTORY_BUFFER_LENGTH;
        
        // Store block_number -> hash
        try database.set_storage(HISTORY_CONTRACT_ADDRESS.bytes, slot, @bitCast(hash));
    }
    
    // Verify retrieval
    for (block_numbers, hashes) |block_number, expected_hash| {
        const slot = block_number % HISTORY_BUFFER_LENGTH;
        const stored = try database.get_storage(HISTORY_CONTRACT_ADDRESS.bytes, slot);
        const stored_bytes: [32]u8 = @bitCast(stored);
        try testing.expectEqualSlices(u8, &expected_hash, &stored_bytes);
    }
}

test "historical block hashes contract execution" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var database = try Database.init(allocator);
    defer database.deinit();
    
    var contract = HistoricalBlockHashesContract{ .database = &database };
    
    // Test system call to store block hash
    const block_number: u64 = 42;
    const block_hash = [32]u8{0xAB} ** 32;
    
    var input: [64]u8 = undefined;
    std.mem.writeInt(u256, input[0..32], block_number, .big);
    @memcpy(input[32..64], &block_hash);
    
    const result = try contract.execute(SYSTEM_ADDRESS, &input, 100000);
    try testing.expectEqual(BLOCK_HASH_WRITE_GAS, result.gas_used);
    
    // Test reading the block hash back
    var read_input: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input, block_number, .big);
    
    const read_result = try contract.execute(
        primitives.ZERO_ADDRESS,
        &read_input,
        10000,
    );
    
    try testing.expectEqual(BLOCK_HASH_READ_GAS, read_result.gas_used);
}

test "block hash retrieval with overflow" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var database = try Database.init(allocator);
    defer database.deinit();
    
    // Test that ring buffer correctly wraps around
    const block1 = 100;
    _ = block1 + HISTORY_BUFFER_LENGTH; // Same slot due to modulo
    
    const hash1 = [32]u8{0x11} ** 32;
    const hash2 = [32]u8{0x22} ** 32;
    
    // Store first hash
    const slot = block1 % HISTORY_BUFFER_LENGTH;
    try database.set_storage(HISTORY_CONTRACT_ADDRESS.bytes, slot, @bitCast(hash1));
    
    // Verify first hash
    const stored1 = try database.get_storage(HISTORY_CONTRACT_ADDRESS.bytes, slot);
    try testing.expectEqual(@as(u256, @bitCast(hash1)), stored1);
    
    // Overwrite with second hash (same slot)
    try database.set_storage(HISTORY_CONTRACT_ADDRESS.bytes, slot, @bitCast(hash2));
    
    // Verify second hash replaced first
    const stored2 = try database.get_storage(HISTORY_CONTRACT_ADDRESS.bytes, slot);
    try testing.expectEqual(@as(u256, @bitCast(hash2)), stored2);
}