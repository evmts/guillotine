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
const Database = @import("../storage/database.zig").Database;
const BlockInfo = @import("../block/block_info.zig").BlockInfo(.{});
const log = @import("../log.zig");

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

/// Errors that can occur during historical block hashes operations
pub const HistoricalBlockHashesError = error{
    InvalidInputLength,
    InvalidSystemCallInput,
    InvalidReadInput,
    OutOfGas,
    IntegerOverflow,
    HashCollision,
} || Database.Error;

/// Compute storage slots for a given block number
/// Returns: { block_slot, hash_slot }
pub fn computeSlots(block_number: u64) struct { block_slot: u64, hash_slot: u64 } {
    const block_slot = block_number % HISTORY_BUFFER_LENGTH;
    const hash_slot = block_slot + HISTORY_BUFFER_LENGTH;
    return .{ .block_slot = block_slot, .hash_slot = hash_slot };
}

/// Historical block hashes contract implementation
pub const HistoricalBlockHashesContract = struct {
    database: *Database,
    allocator: std.mem.Allocator,

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
    ) HistoricalBlockHashesError!struct { output: []const u8, gas_used: u64 } {
        // System call to update block hash
        if (std.mem.eql(u8, &caller.bytes, &SYSTEM_ADDRESS.bytes)) {
            if (input.len != 64) {
                log.debug("HistoricalBlockHashes: Invalid system call input length: {}", .{input.len});
                return HistoricalBlockHashesError.InvalidSystemCallInput;
            }

            if (gas_limit < BLOCK_HASH_WRITE_GAS) {
                return HistoricalBlockHashesError.OutOfGas;
            }

            // Parse block number and hash using consistent serialization
            const block_number_u256 = std.mem.readInt(u256, input[0..32], .big);

            // Check for overflow when converting to u64
            if (block_number_u256 > std.math.maxInt(u64)) {
                return HistoricalBlockHashesError.IntegerOverflow;
            }
            const block_number: u64 = @intCast(block_number_u256);

            var block_hash: [32]u8 = undefined;
            @memcpy(&block_hash, input[32..64]);

            // Store in ring buffer using helper
            const slots = computeSlots(block_number);

            // Check for hash collision - prevent hash spoofing
            const stored_block_number = try self.database.get_storage(
                HISTORY_CONTRACT_ADDRESS.bytes,
                slots.hash_slot,
            );

            if (stored_block_number != 0 and stored_block_number != block_number) {
                log.debug("HistoricalBlockHashes: Hash collision detected for slot {}: {} != {}", .{ slots.block_slot, stored_block_number, block_number });
                return HistoricalBlockHashesError.HashCollision;
            }

            // Store block_number -> hash
            try self.database.set_storage(
                HISTORY_CONTRACT_ADDRESS.bytes,
                slots.block_slot,
                @bitCast(block_hash),
            );

            // Store hash -> block_number (reverse mapping)
            try self.database.set_storage(
                HISTORY_CONTRACT_ADDRESS.bytes,
                slots.hash_slot,
                block_number,
            );

            log.debug("HistoricalBlockHashes: Stored hash for block {} at slot {}", .{ block_number, slots.block_slot });

            return .{ .output = &.{}, .gas_used = BLOCK_HASH_WRITE_GAS };
        }

        // Regular call to read block hash
        if (input.len != 32) {
            log.debug("HistoricalBlockHashes: Invalid read input length: {}", .{input.len});
            return HistoricalBlockHashesError.InvalidReadInput;
        }

        if (gas_limit < BLOCK_HASH_READ_GAS) {
            return HistoricalBlockHashesError.OutOfGas;
        }

        // Parse block number using consistent serialization
        const block_number_u256 = std.mem.readInt(u256, input[0..32], .big);

        // Check for overflow when converting to u64
        if (block_number_u256 > std.math.maxInt(u64)) {
            return HistoricalBlockHashesError.IntegerOverflow;
        }
        const block_number: u64 = @intCast(block_number_u256);

        // Retrieve from ring buffer using helper
        const slots = computeSlots(block_number);
        const stored_hash = try self.database.get_storage(
            HISTORY_CONTRACT_ADDRESS.bytes,
            slots.block_slot,
        );

        // Check if this is the correct block number by verifying reverse mapping
        const stored_block_number = try self.database.get_storage(
            HISTORY_CONTRACT_ADDRESS.bytes,
            slots.hash_slot,
        );

        if (stored_block_number != block_number) {
            // Block number doesn't match, hash not available - return empty slice
            log.debug("HistoricalBlockHashes: Block number mismatch for slot {}: {} != {}", .{ slots.block_slot, stored_block_number, block_number });
            const empty_output = try self.allocator.alloc(u8, 0);
            return .{ .output = empty_output, .gas_used = BLOCK_HASH_READ_GAS };
        }

        // Allocate output properly to avoid use-after-free
        const output = try self.allocator.alloc(u8, 32);
        const hash_bytes: [32]u8 = @bitCast(stored_hash);
        @memcpy(output, &hash_bytes);

        return .{ .output = output, .gas_used = BLOCK_HASH_READ_GAS };
    }

    /// Process a block hash update at the start of a block
    /// This should be called by the EVM before processing any transactions
    pub fn processBlockHashUpdate(
        database: *Database,
        block_info: *const BlockInfo,
    ) Database.Error!void {
        if (block_info.number == 0) {
            // No parent hash for genesis block
            return;
        }

        const parent_number = block_info.number - 1;
        const parent_hash = block_info.parent_hash;

        // Store in ring buffer using helper
        const slots = computeSlots(parent_number);

        // Store block_number -> hash
        try database.set_storage(
            HISTORY_CONTRACT_ADDRESS.bytes,
            slots.block_slot,
            @bitCast(parent_hash),
        );

        // Store hash -> block_number (reverse mapping)
        try database.set_storage(
            HISTORY_CONTRACT_ADDRESS.bytes,
            slots.hash_slot,
            parent_number,
        );

        log.debug("HistoricalBlockHashes: Updated block hash for block {}", .{parent_number});
    }

    /// Get a block hash from the contract or recent history
    /// This combines EIP-2935 with standard BLOCKHASH semantics
    pub fn getBlockHash(
        database: *Database,
        block_number: u64,
        current_block: u64,
    ) Database.Error!?[32]u8 {
        // Standard BLOCKHASH rules first
        // - Return null for current block and future blocks
        // - Return null for block 0 (genesis)
        if (block_number >= current_block or block_number == 0) {
            return null;
        }

        // Always check the storage first using helper
        const slots = computeSlots(block_number);
        const stored_hash = try database.get_storage(
            HISTORY_CONTRACT_ADDRESS.bytes,
            slots.block_slot,
        );

        // Verify reverse mapping to ensure this is the correct block number
        const stored_block_number = try database.get_storage(
            HISTORY_CONTRACT_ADDRESS.bytes,
            slots.hash_slot,
        );

        // Check if we have a valid hash with matching block number
        if (stored_hash != 0 and stored_block_number == block_number) {
            return @bitCast(stored_hash);
        }

        return null;
    }
};

// Tests
test "historical block hashes ring buffer storage" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
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

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = HistoricalBlockHashesContract{ .database = &database, .allocator = allocator };

    // Test system call to store block hash
    const block_number: u64 = 42;
    const block_hash = [_]u8{0xAB} ** 32;

    var input: [64]u8 = undefined;
    std.mem.writeInt(u256, input[0..32], block_number, .big);
    @memcpy(input[32..64], &block_hash);

    const result = try contract.execute(SYSTEM_ADDRESS, &input, 100000);
    try testing.expectEqual(BLOCK_HASH_WRITE_GAS, result.gas_used);
    try testing.expectEqual(@as(usize, 0), result.output.len);

    // Test reading the block hash back
    var read_input: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input, block_number, .big);

    // Use a non-system address for testing
    const test_caller = Address{ .bytes = [_]u8{0x11} ** 20 };
    const read_result = try contract.execute(
        test_caller,
        &read_input,
        10000,
    );
    defer allocator.free(read_result.output);

    try testing.expectEqual(BLOCK_HASH_READ_GAS, read_result.gas_used);
    try testing.expectEqual(@as(usize, 32), read_result.output.len);
    try testing.expectEqualSlices(u8, &block_hash, read_result.output);
}

test "historical block hashes error cases" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = HistoricalBlockHashesContract{ .database = &database, .allocator = allocator };

    // Test invalid system call input length
    const invalid_input = [_]u8{0x01} ** 63; // Should be 64 bytes
    const result1 = contract.execute(SYSTEM_ADDRESS, &invalid_input, 100000);
    try testing.expectError(HistoricalBlockHashesError.InvalidSystemCallInput, result1);

    // Test invalid read input length
    const invalid_read_input = [_]u8{0x01} ** 31; // Should be 32 bytes
    const result2 = contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &invalid_read_input, 10000);
    try testing.expectError(HistoricalBlockHashesError.InvalidReadInput, result2);

    // Test insufficient gas for write
    var valid_input: [64]u8 = undefined;
    std.mem.writeInt(u256, valid_input[0..32], 12345, .big);
    @memset(valid_input[32..64], 0xCC);

    const result3 = contract.execute(SYSTEM_ADDRESS, &valid_input, BLOCK_HASH_WRITE_GAS - 1);
    try testing.expectError(HistoricalBlockHashesError.OutOfGas, result3);

    // Test insufficient gas for read
    var valid_read_input: [32]u8 = undefined;
    std.mem.writeInt(u256, &valid_read_input, 12345, .big);

    const result4 = contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &valid_read_input, BLOCK_HASH_READ_GAS - 1);
    try testing.expectError(HistoricalBlockHashesError.OutOfGas, result4);
}

test "historical block hashes block number not found" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = HistoricalBlockHashesContract{ .database = &database, .allocator = allocator };

    // Try to read a block number that was never stored
    var read_input: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input, 999999, .big);

    const result = try contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input, 10000);
    defer allocator.free(result.output);

    try testing.expectEqual(BLOCK_HASH_READ_GAS, result.gas_used);
    try testing.expectEqual(@as(usize, 0), result.output.len); // Empty output for not found
}

test "historical block hashes ring buffer wrap around" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = HistoricalBlockHashesContract{ .database = &database, .allocator = allocator };

    // Store a hash at block that will wrap around
    const block1: u64 = 1000;
    const block2: u64 = block1 + HISTORY_BUFFER_LENGTH; // Will map to same slot

    const hash1 = [_]u8{0x11} ** 32;
    const hash2 = [_]u8{0x22} ** 32;

    // Store first hash
    var input1: [64]u8 = undefined;
    std.mem.writeInt(u256, input1[0..32], block1, .big);
    @memcpy(input1[32..64], &hash1);

    _ = try contract.execute(SYSTEM_ADDRESS, &input1, 100000);

    // Store second hash (overwrites first due to ring buffer)
    var input2: [64]u8 = undefined;
    std.mem.writeInt(u256, input2[0..32], block2, .big);
    @memcpy(input2[32..64], &hash2);

    _ = try contract.execute(SYSTEM_ADDRESS, &input2, 100000);

    // Try to read first block number - should not be found due to overwrite
    var read_input1: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input1, block1, .big);

    const result1 = try contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input1, 10000);
    defer allocator.free(result1.output);

    try testing.expectEqual(@as(usize, 0), result1.output.len);

    // Read second block number - should be found
    var read_input2: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input2, block2, .big);

    const result2 = try contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input2, 10000);
    defer allocator.free(result2.output);

    try testing.expectEqual(@as(usize, 32), result2.output.len);
    try testing.expectEqualSlices(u8, &hash2, result2.output);
}

test "historical block hashes integer overflow protection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = HistoricalBlockHashesContract{ .database = &database, .allocator = allocator };

    // Test block number that exceeds u64 max
    const oversized_block_number: u256 = @as(u256, std.math.maxInt(u64)) + 1;
    const hash = [_]u8{0xCC} ** 32;

    var input: [64]u8 = undefined;
    std.mem.writeInt(u256, input[0..32], oversized_block_number, .big);
    @memcpy(input[32..64], &hash);

    const result = contract.execute(SYSTEM_ADDRESS, &input, 100000);
    try testing.expectError(HistoricalBlockHashesError.IntegerOverflow, result);

    // Test reading with overflow
    var read_input: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input, oversized_block_number, .big);

    const read_result = contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input, 10000);
    try testing.expectError(HistoricalBlockHashesError.IntegerOverflow, read_result);
}

test "historical block hashes use-after-free protection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = HistoricalBlockHashesContract{ .database = &database, .allocator = allocator };

    // Store a block hash
    const block_number: u64 = 12345;
    const hash = [_]u8{0xDD} ** 32;

    var input: [64]u8 = undefined;
    std.mem.writeInt(u256, input[0..32], block_number, .big);
    @memcpy(input[32..64], &hash);

    _ = try contract.execute(SYSTEM_ADDRESS, &input, 100000);

    // Read the hash back
    var read_input: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input, block_number, .big);

    const result = try contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input, 10000);
    defer allocator.free(result.output); // This should work without use-after-free

    try testing.expectEqual(@as(usize, 32), result.output.len);
    try testing.expectEqualSlices(u8, &hash, result.output);

    // Verify the output remains valid until we free it
    for (result.output, &hash) |output_byte, hash_byte| {
        try testing.expectEqual(hash_byte, output_byte);
    }
}

test "historical block hashes collision detection prevents spoofing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = HistoricalBlockHashesContract{ .database = &database, .allocator = allocator };

    // Store first block hash
    const block1: u64 = 100;
    const hash1 = [_]u8{0xAA} ** 32;

    var input1: [64]u8 = undefined;
    std.mem.writeInt(u256, input1[0..32], block1, .big);
    @memcpy(input1[32..64], &hash1);

    _ = try contract.execute(SYSTEM_ADDRESS, &input1, 100000);

    // Attempt to store a different block at the same slot (collision)
    const block2: u64 = block1 + HISTORY_BUFFER_LENGTH; // Same slot
    const hash2 = [_]u8{0xBB} ** 32;

    var input2: [64]u8 = undefined;
    std.mem.writeInt(u256, input2[0..32], block2, .big);
    @memcpy(input2[32..64], &hash2);

    // This should fail with HashCollision error
    const result = contract.execute(SYSTEM_ADDRESS, &input2, 100000);
    try testing.expectError(HistoricalBlockHashesError.HashCollision, result);

    // Verify original block hash is still intact
    var read_input: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input, block1, .big);

    const read_result = try contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input, 10000);
    defer allocator.free(read_result.output);

    try testing.expectEqual(@as(usize, 32), read_result.output.len);
    try testing.expectEqualSlices(u8, &hash1, read_result.output);
}

test "historical block hashes allows same block rewrite" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = HistoricalBlockHashesContract{ .database = &database, .allocator = allocator };

    // Store a block hash
    const block_number: u64 = 200;
    const hash1 = [_]u8{0xCC} ** 32;

    var input1: [64]u8 = undefined;
    std.mem.writeInt(u256, input1[0..32], block_number, .big);
    @memcpy(input1[32..64], &hash1);

    _ = try contract.execute(SYSTEM_ADDRESS, &input1, 100000);

    // Update the same block number with a new hash (should succeed)
    const hash2 = [_]u8{0xDD} ** 32;

    var input2: [64]u8 = undefined;
    std.mem.writeInt(u256, input2[0..32], block_number, .big);
    @memcpy(input2[32..64], &hash2);

    const result = try contract.execute(SYSTEM_ADDRESS, &input2, 100000);
    try testing.expectEqual(BLOCK_HASH_WRITE_GAS, result.gas_used);

    // Verify the updated hash
    var read_input: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input, block_number, .big);

    const read_result = try contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input, 10000);
    defer allocator.free(read_result.output);

    try testing.expectEqualSlices(u8, &hash2, read_result.output);
}

test "historical block hashes reverse mapping validation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = HistoricalBlockHashesContract{ .database = &database, .allocator = allocator };

    // Store a block hash
    const block1: u64 = 300;
    const hash1 = [_]u8{0xEE} ** 32;

    var input1: [64]u8 = undefined;
    std.mem.writeInt(u256, input1[0..32], block1, .big);
    @memcpy(input1[32..64], &hash1);

    _ = try contract.execute(SYSTEM_ADDRESS, &input1, 100000);

    // Manually corrupt the reverse mapping to simulate an attack
    const slots = computeSlots(block1);
    const fake_block_number: u64 = 999999;
    try database.set_storage(
        HISTORY_CONTRACT_ADDRESS.bytes,
        slots.hash_slot,
        fake_block_number,
    );

    // Try to read the block - should fail due to mismatch
    var read_input: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input, block1, .big);

    const result = try contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input, 10000);
    defer allocator.free(result.output);

    try testing.expectEqual(@as(usize, 0), result.output.len); // Should return empty
}

test "historical block hashes getBlockHash validation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    // Store blocks with proper reverse mapping
    const block1: u64 = 500;
    const block2: u64 = block1 + HISTORY_BUFFER_LENGTH; // Collides
    const hash1 = [_]u8{0xFF} ** 32;

    const slots = computeSlots(block1);

    // Store block1
    try database.set_storage(HISTORY_CONTRACT_ADDRESS.bytes, slots.block_slot, @bitCast(hash1));
    try database.set_storage(HISTORY_CONTRACT_ADDRESS.bytes, slots.hash_slot, block1);

    // Should find block1
    const result1 = try HistoricalBlockHashesContract.getBlockHash(&database, block1, block1 + 10);
    try testing.expect(result1 != null);
    try testing.expectEqualSlices(u8, &hash1, &result1.?);

    // Should not find block2 (same slot, wrong block number)
    const result2 = try HistoricalBlockHashesContract.getBlockHash(&database, block2, block2 + 10);
    try testing.expect(result2 == null);

    // Should return null for current block
    const result3 = try HistoricalBlockHashesContract.getBlockHash(&database, 600, 600);
    try testing.expect(result3 == null);

    // Should return null for future block
    const result4 = try HistoricalBlockHashesContract.getBlockHash(&database, 700, 600);
    try testing.expect(result4 == null);

    // Should return null for genesis block
    const result5 = try HistoricalBlockHashesContract.getBlockHash(&database, 0, 100);
    try testing.expect(result5 == null);
}
