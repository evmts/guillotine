/// EIP-4788: Beacon block root in the EVM
///
/// This module implements the beacon roots contract that provides trust-minimized
/// access to the consensus layer (beacon chain) from within the EVM.
///
/// The beacon roots are stored in a ring buffer with HISTORY_BUFFER_LENGTH entries.
/// This allows accessing recent beacon block roots without unbounded storage growth.
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const Database = @import("../storage/database.zig").Database;
const BlockInfo = @import("../block/block_info.zig").BlockInfo(.{});
const log = @import("../log.zig");

/// EIP-4788 beacon roots contract address
/// Deployed at 0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02
pub const BEACON_ROOTS_ADDRESS = Address{
    .bytes = [_]u8{
        0x00, 0x0F, 0x3d, 0xf6, 0xD7, 0x32, 0x80, 0x7E,
        0xf1, 0x31, 0x9f, 0xB7, 0xB8, 0xbB, 0x85, 0x22,
        0xd0, 0xBe, 0xac, 0x02,
    },
};

/// System address that can update beacon roots
/// 0xfffffffffffffffffffffffffffffffffffffffe
pub const SYSTEM_ADDRESS = Address{
    .bytes = [_]u8{
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xfe,
    },
};

/// Length of the beacon roots ring buffer
pub const HISTORY_BUFFER_LENGTH: u64 = 8191;

/// Gas cost for reading a beacon root
pub const BEACON_ROOT_READ_GAS: u64 = 4200;

/// Gas cost for writing a beacon root (system call only)
pub const BEACON_ROOT_WRITE_GAS: u64 = 20000;

/// Errors that can occur during beacon roots operations
pub const BeaconRootsError = error{
    InvalidInputLength,
    InvalidSystemCallInput,
    InvalidReadInput,
    OutOfGas,
    TimestampOverflow,
} || Database.Error;

/// Compute storage slots for a given timestamp
/// Returns: { timestamp_slot, root_slot }
///
/// Memory safety: All values computed on stack, no heap allocation.
/// Overflow safety: u64 modulo and addition operations are bounds-checked.
pub fn computeSlots(timestamp: u64) struct { timestamp_slot: u64, root_slot: u64 } {
    const timestamp_slot = timestamp % HISTORY_BUFFER_LENGTH;
    const root_slot = timestamp_slot + HISTORY_BUFFER_LENGTH;
    return .{ .timestamp_slot = timestamp_slot, .root_slot = root_slot };
}

/// Beacon roots contract implementation
pub const BeaconRootsContract = struct {
    database: *Database,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    /// Execute the beacon roots contract
    ///
    /// If called by the system address with 64 bytes input:
    /// - First 32 bytes: timestamp
    /// - Second 32 bytes: beacon root
    /// Stores the beacon root in the ring buffer
    ///
    /// If called with 32 bytes input (timestamp):
    /// Returns the beacon root for that timestamp if available
    ///
    /// MEMORY OWNERSHIP:
    /// - Caller must free result.output using the same allocator passed to BeaconRootsContract
    /// - Empty output (len=0) still requires freeing
    /// - Output is heap-allocated and owned by caller
    /// - Use: defer allocator.free(result.output);
    ///
    /// SAFETY:
    /// - Timestamp overflow protection: u256 values > u64::MAX rejected
    /// - Ring buffer collision detection via bidirectional timestamp verification
    /// - All memory allocations use provided allocator
    pub fn execute(
        self: *Self,
        caller: Address,
        input: []const u8,
        gas_limit: u64,
    ) BeaconRootsError!struct { output: []const u8, gas_used: u64 } {
        // System call to update beacon root
        if (std.mem.eql(u8, &caller.bytes, &SYSTEM_ADDRESS.bytes)) {
            if (input.len != 64) {
                log.debug("BeaconRoots: Invalid system call input length: {}", .{input.len});
                return BeaconRootsError.InvalidSystemCallInput;
            }
            
            if (gas_limit < BEACON_ROOT_WRITE_GAS) {
                return BeaconRootsError.OutOfGas;
            }
            
            // Parse timestamp and beacon root using consistent serialization
            const timestamp_u256 = std.mem.readInt(u256, input[0..32], .big);

            // CRITICAL: Validate timestamp fits in u64 to prevent overflow
            if (timestamp_u256 > std.math.maxInt(u64)) {
                log.debug("BeaconRoots: Timestamp overflow: {}", .{timestamp_u256});
                return BeaconRootsError.TimestampOverflow;
            }
            const timestamp: u64 = @intCast(timestamp_u256);

            var beacon_root: [32]u8 = undefined;
            @memcpy(&beacon_root, input[32..64]);

            // Store in ring buffer using helper
            const slots = computeSlots(timestamp);
            
            // Store timestamp -> beacon_root
            try self.database.set_storage(
                BEACON_ROOTS_ADDRESS.bytes,
                slots.timestamp_slot,
                @bitCast(beacon_root),
            );
            
            // Store beacon_root -> timestamp
            try self.database.set_storage(
                BEACON_ROOTS_ADDRESS.bytes,
                slots.root_slot,
                timestamp,
            );
            
            log.debug("BeaconRoots: Stored root for timestamp {} at slot {}", .{ timestamp, slots.timestamp_slot });
            
            return .{ .output = &.{}, .gas_used = BEACON_ROOT_WRITE_GAS };
        }
        
        // Regular call to read beacon root
        if (input.len != 32) {
            log.debug("BeaconRoots: Invalid read input length: {}", .{input.len});
            return BeaconRootsError.InvalidReadInput;
        }
        
        if (gas_limit < BEACON_ROOT_READ_GAS) {
            return BeaconRootsError.OutOfGas;
        }
        
        // Parse timestamp using consistent serialization
        const timestamp_u256 = std.mem.readInt(u256, input[0..32], .big);

        // CRITICAL: Validate timestamp fits in u64 to prevent overflow
        if (timestamp_u256 > std.math.maxInt(u64)) {
            log.debug("BeaconRoots: Timestamp overflow in read: {}", .{timestamp_u256});
            return BeaconRootsError.TimestampOverflow;
        }
        const timestamp: u64 = @intCast(timestamp_u256);

        // Retrieve from ring buffer using helper
        const slots = computeSlots(timestamp);
        const stored_root = try self.database.get_storage(
            BEACON_ROOTS_ADDRESS.bytes,
            slots.timestamp_slot,
        );
        
        // Check if this is the correct timestamp by verifying reverse mapping
        const stored_timestamp = try self.database.get_storage(
            BEACON_ROOTS_ADDRESS.bytes,
            slots.root_slot,
        );
        
        if (stored_timestamp != timestamp) {
            // Timestamp doesn't match, root not available - return empty slice
            log.debug("BeaconRoots: Timestamp mismatch for slot {}: {} != {}", .{ 
                slots.timestamp_slot, stored_timestamp, timestamp 
            });
            const empty_output = try self.allocator.alloc(u8, 0);
            return .{ .output = empty_output, .gas_used = BEACON_ROOT_READ_GAS };
        }
        
        // Allocate output properly
        const output = try self.allocator.alloc(u8, 32);
        const root_bytes: [32]u8 = @bitCast(stored_root);
        @memcpy(output, &root_bytes);
        
        return .{ .output = output, .gas_used = BEACON_ROOT_READ_GAS };
    }
    
    /// Process a beacon root update at the start of a block
    /// This should be called by the EVM before processing any transactions
    pub fn processBeaconRootUpdate(
        database: *Database,
        block_info: *const BlockInfo,
    ) Database.Error!void {
        if (block_info.beacon_root == null) {
            // No beacon root to update
            return;
        }
        
        const beacon_root = block_info.beacon_root.?;
        const timestamp = block_info.timestamp;
        
        // Store in ring buffer using helper
        const slots = computeSlots(timestamp);
        
        // Store timestamp -> beacon_root
        try database.set_storage(
            BEACON_ROOTS_ADDRESS.bytes,
            slots.timestamp_slot,
            @bitCast(beacon_root),
        );
        
        // Store beacon_root -> timestamp
        try database.set_storage(
            BEACON_ROOTS_ADDRESS.bytes,
            slots.root_slot,
            timestamp,
        );
        
        log.debug("BeaconRoots: Updated block beacon root for timestamp {}", .{timestamp});
    }
};

// Tests
test "beacon roots ring buffer storage" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var database = Database.init(allocator);
    defer database.deinit();
    
    // Test storing and retrieving beacon roots
    const timestamps = [_]u64{ 1000, 2000, 3000, 8192000 };
    const roots = [_][32]u8{
        [_]u8{0x01} ** 32,
        [_]u8{0x02} ** 32,
        [_]u8{0x03} ** 32,
        [_]u8{0x04} ** 32,
    };
    
    for (timestamps, roots) |timestamp, root| {
        const slot = timestamp % HISTORY_BUFFER_LENGTH;
        
        // Store timestamp -> root
        try database.set_storage(BEACON_ROOTS_ADDRESS.bytes, slot, @bitCast(root));
        
        // Store root -> timestamp
        const root_slot = slot + HISTORY_BUFFER_LENGTH;
        try database.set_storage(BEACON_ROOTS_ADDRESS.bytes, root_slot, timestamp);
    }
    
    // Verify retrieval
    for (timestamps, roots) |timestamp, expected_root| {
        const slot = timestamp % HISTORY_BUFFER_LENGTH;
        const stored = try database.get_storage(BEACON_ROOTS_ADDRESS.bytes, slot);
        const stored_bytes: [32]u8 = @bitCast(stored);
        try testing.expectEqualSlices(u8, &expected_root, &stored_bytes);
    }
}

test "beacon roots contract execution" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var database = Database.init(allocator);
    defer database.deinit();
    
    var contract = BeaconRootsContract{ .database = &database, .allocator = allocator };
    
    // Test system call to store beacon root
    const timestamp: u64 = 1710338135;
    const beacon_root = [_]u8{0xAB} ** 32;
    
    var input: [64]u8 = undefined;
    std.mem.writeInt(u256, input[0..32], timestamp, .big);
    @memcpy(input[32..64], &beacon_root);
    
    const result = try contract.execute(SYSTEM_ADDRESS, &input, 100000);
    try testing.expectEqual(BEACON_ROOT_WRITE_GAS, result.gas_used);
    try testing.expectEqual(@as(usize, 0), result.output.len);
    
    // Test reading the beacon root back
    var read_input: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input, timestamp, .big);
    
    // Use a non-system address for testing
    const test_caller = Address{ .bytes = [_]u8{0x11} ** 20 };
    const read_result = try contract.execute(
        test_caller,
        &read_input,
        10000,
    );
    defer allocator.free(read_result.output);
    
    try testing.expectEqual(BEACON_ROOT_READ_GAS, read_result.gas_used);
    try testing.expectEqual(@as(usize, 32), read_result.output.len);
    try testing.expectEqualSlices(u8, &beacon_root, read_result.output);
}

test "beacon roots error cases" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var database = Database.init(allocator);
    defer database.deinit();
    
    var contract = BeaconRootsContract{ .database = &database, .allocator = allocator };
    
    // Test invalid system call input length
    const invalid_input = [_]u8{0x01} ** 63; // Should be 64 bytes
    const result1 = contract.execute(SYSTEM_ADDRESS, &invalid_input, 100000);
    try testing.expectError(BeaconRootsError.InvalidSystemCallInput, result1);
    
    // Test invalid read input length  
    const invalid_read_input = [_]u8{0x01} ** 31; // Should be 32 bytes
    const result2 = contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &invalid_read_input, 10000);
    try testing.expectError(BeaconRootsError.InvalidReadInput, result2);
    
    // Test insufficient gas for write
    var valid_input: [64]u8 = undefined;
    std.mem.writeInt(u256, valid_input[0..32], 12345, .big);
    @memset(valid_input[32..64], 0xCC);
    
    const result3 = contract.execute(SYSTEM_ADDRESS, &valid_input, BEACON_ROOT_WRITE_GAS - 1);
    try testing.expectError(BeaconRootsError.OutOfGas, result3);
    
    // Test insufficient gas for read
    var valid_read_input: [32]u8 = undefined;
    std.mem.writeInt(u256, &valid_read_input, 12345, .big);
    
    const result4 = contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &valid_read_input, BEACON_ROOT_READ_GAS - 1);
    try testing.expectError(BeaconRootsError.OutOfGas, result4);
}

test "beacon roots timestamp not found" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var database = Database.init(allocator);
    defer database.deinit();
    
    var contract = BeaconRootsContract{ .database = &database, .allocator = allocator };
    
    // Try to read a timestamp that was never stored
    var read_input: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input, 999999, .big);
    
    const result = try contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input, 10000);
    defer allocator.free(result.output);
    
    try testing.expectEqual(BEACON_ROOT_READ_GAS, result.gas_used);
    try testing.expectEqual(@as(usize, 0), result.output.len); // Empty output for not found
}

test "beacon roots ring buffer wrap around" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = BeaconRootsContract{ .database = &database, .allocator = allocator };

    // Store a root at timestamp that will wrap around
    const timestamp1: u64 = 1000;
    const timestamp2: u64 = timestamp1 + HISTORY_BUFFER_LENGTH; // Will map to same slot

    const root1 = [_]u8{0x11} ** 32;
    const root2 = [_]u8{0x22} ** 32;

    // Store first root
    var input1: [64]u8 = undefined;
    std.mem.writeInt(u256, input1[0..32], timestamp1, .big);
    @memcpy(input1[32..64], &root1);

    _ = try contract.execute(SYSTEM_ADDRESS, &input1, 100000);

    // Store second root (overwrites first due to ring buffer)
    var input2: [64]u8 = undefined;
    std.mem.writeInt(u256, input2[0..32], timestamp2, .big);
    @memcpy(input2[32..64], &root2);

    _ = try contract.execute(SYSTEM_ADDRESS, &input2, 100000);

    // Try to read first timestamp - should not be found due to overwrite
    var read_input1: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input1, timestamp1, .big);

    const result1 = try contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input1, 10000);
    defer allocator.free(result1.output);

    try testing.expectEqual(@as(usize, 0), result1.output.len);

    // Read second timestamp - should be found
    var read_input2: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input2, timestamp2, .big);

    const result2 = try contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input2, 10000);
    defer allocator.free(result2.output);

    try testing.expectEqual(@as(usize, 32), result2.output.len);
    try testing.expectEqualSlices(u8, &root2, result2.output);
}

// ============================================================================
// CRITICAL SAFETY TESTS
// ============================================================================

test "beacon roots memory safety - use after free detection" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = BeaconRootsContract{ .database = &database, .allocator = allocator };

    // Store a beacon root
    const timestamp: u64 = 12345;
    const beacon_root = [_]u8{0xDE} ** 32;

    var input: [64]u8 = undefined;
    std.mem.writeInt(u256, input[0..32], timestamp, .big);
    @memcpy(input[32..64], &beacon_root);

    _ = try contract.execute(SYSTEM_ADDRESS, &input, 100000);

    // Read it back
    var read_input: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input, timestamp, .big);

    const result = try contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input, 10000);

    // CRITICAL: Verify the output pointer is valid and contains correct data
    try testing.expectEqual(@as(usize, 32), result.output.len);
    try testing.expectEqualSlices(u8, &beacon_root, result.output);

    // Free the output - this must not cause issues
    allocator.free(result.output);

    // Read again to ensure database state is still valid
    const result2 = try contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input, 10000);
    defer allocator.free(result2.output);

    try testing.expectEqual(@as(usize, 32), result2.output.len);
    try testing.expectEqualSlices(u8, &beacon_root, result2.output);
}

test "beacon roots collision detection - same slot different timestamps" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = BeaconRootsContract{ .database = &database, .allocator = allocator };

    // Two timestamps that map to the same slot in the ring buffer
    const timestamp1: u64 = 100;
    const timestamp2: u64 = 100 + HISTORY_BUFFER_LENGTH;

    // Verify they map to the same slot
    const slots1 = computeSlots(timestamp1);
    const slots2 = computeSlots(timestamp2);
    try testing.expectEqual(slots1.timestamp_slot, slots2.timestamp_slot);

    const root1 = [_]u8{0xAA} ** 32;
    const root2 = [_]u8{0xBB} ** 32;

    // Store first root
    var input1: [64]u8 = undefined;
    std.mem.writeInt(u256, input1[0..32], timestamp1, .big);
    @memcpy(input1[32..64], &root1);
    _ = try contract.execute(SYSTEM_ADDRESS, &input1, 100000);

    // Verify first root is readable
    var read_input1: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input1, timestamp1, .big);
    const result1 = try contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input1, 10000);
    defer allocator.free(result1.output);

    try testing.expectEqual(@as(usize, 32), result1.output.len);
    try testing.expectEqualSlices(u8, &root1, result1.output);

    // Store second root (collision)
    var input2: [64]u8 = undefined;
    std.mem.writeInt(u256, input2[0..32], timestamp2, .big);
    @memcpy(input2[32..64], &root2);
    _ = try contract.execute(SYSTEM_ADDRESS, &input2, 100000);

    // CRITICAL: First timestamp should now be unreadable (collision detected)
    const result1_after = try contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input1, 10000);
    defer allocator.free(result1_after.output);

    try testing.expectEqual(@as(usize, 0), result1_after.output.len);

    // Second timestamp should be readable
    var read_input2: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input2, timestamp2, .big);
    const result2 = try contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input2, 10000);
    defer allocator.free(result2.output);

    try testing.expectEqual(@as(usize, 32), result2.output.len);
    try testing.expectEqualSlices(u8, &root2, result2.output);
}

test "beacon roots overflow protection - write timestamp" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = BeaconRootsContract{ .database = &database, .allocator = allocator };

    // Timestamp that exceeds u64::MAX
    const overflow_timestamp: u256 = @as(u256, std.math.maxInt(u64)) + 1;
    const beacon_root = [_]u8{0xFF} ** 32;

    var input: [64]u8 = undefined;
    std.mem.writeInt(u256, input[0..32], overflow_timestamp, .big);
    @memcpy(input[32..64], &beacon_root);

    // CRITICAL: Must reject overflow timestamp
    const result = contract.execute(SYSTEM_ADDRESS, &input, 100000);
    try testing.expectError(BeaconRootsError.TimestampOverflow, result);
}

test "beacon roots overflow protection - read timestamp" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = BeaconRootsContract{ .database = &database, .allocator = allocator };

    // Timestamp that exceeds u64::MAX
    const overflow_timestamp: u256 = @as(u256, std.math.maxInt(u64)) + 1;

    var read_input: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input, overflow_timestamp, .big);

    // CRITICAL: Must reject overflow timestamp
    const result = contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input, 10000);
    try testing.expectError(BeaconRootsError.TimestampOverflow, result);
}

test "beacon roots ring buffer boundaries" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = BeaconRootsContract{ .database = &database, .allocator = allocator };

    // Test boundary values
    const boundary_timestamps = [_]u64{
        0,                           // Minimum
        HISTORY_BUFFER_LENGTH - 1,   // Just before wrap
        HISTORY_BUFFER_LENGTH,       // Exact wrap point
        HISTORY_BUFFER_LENGTH + 1,   // Just after wrap
        std.math.maxInt(u64) - 1,    // Near maximum
        std.math.maxInt(u64),        // Maximum u64
    };

    for (boundary_timestamps, 0..) |timestamp, i| {
        const root = [_]u8{@as(u8, @intCast(i))} ** 32;

        var input: [64]u8 = undefined;
        std.mem.writeInt(u256, input[0..32], timestamp, .big);
        @memcpy(input[32..64], &root);

        _ = try contract.execute(SYSTEM_ADDRESS, &input, 100000);

        // Verify it can be read back
        var read_input: [32]u8 = undefined;
        std.mem.writeInt(u256, &read_input, timestamp, .big);

        const result = try contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input, 10000);
        defer allocator.free(result.output);

        try testing.expectEqual(@as(usize, 32), result.output.len);
        try testing.expectEqualSlices(u8, &root, result.output);
    }
}

test "beacon roots multiple sequential reads" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = BeaconRootsContract{ .database = &database, .allocator = allocator };

    // Store a root
    const timestamp: u64 = 7777;
    const beacon_root = [_]u8{0x77} ** 32;

    var input: [64]u8 = undefined;
    std.mem.writeInt(u256, input[0..32], timestamp, .big);
    @memcpy(input[32..64], &beacon_root);

    _ = try contract.execute(SYSTEM_ADDRESS, &input, 100000);

    var read_input: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input, timestamp, .big);

    // Read multiple times to ensure no memory corruption
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const result = try contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input, 10000);
        defer allocator.free(result.output);

        try testing.expectEqual(@as(usize, 32), result.output.len);
        try testing.expectEqualSlices(u8, &beacon_root, result.output);
    }
}

test "beacon roots empty output memory ownership" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = BeaconRootsContract{ .database = &database, .allocator = allocator };

    // Try to read a non-existent timestamp
    var read_input: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input, 99999, .big);

    const result = try contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input, 10000);

    // CRITICAL: Even empty output must be freed
    try testing.expectEqual(@as(usize, 0), result.output.len);
    allocator.free(result.output);
}

test "beacon roots slot computation consistency" {
    const testing = std.testing;

    // Verify slot computation is deterministic
    const timestamp: u64 = 12345;
    const slots1 = computeSlots(timestamp);
    const slots2 = computeSlots(timestamp);

    try testing.expectEqual(slots1.timestamp_slot, slots2.timestamp_slot);
    try testing.expectEqual(slots1.root_slot, slots2.root_slot);

    // Verify root_slot is always timestamp_slot + HISTORY_BUFFER_LENGTH
    try testing.expectEqual(slots1.root_slot, slots1.timestamp_slot + HISTORY_BUFFER_LENGTH);

    // Verify timestamp_slot is always < HISTORY_BUFFER_LENGTH
    try testing.expect(slots1.timestamp_slot < HISTORY_BUFFER_LENGTH);
}

test "beacon roots full ring buffer cycle" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var contract = BeaconRootsContract{ .database = &database, .allocator = allocator };

    // Fill the entire ring buffer
    var timestamp: u64 = 0;
    while (timestamp < HISTORY_BUFFER_LENGTH) : (timestamp += 1) {
        const root = [_]u8{@as(u8, @intCast(timestamp % 256))} ** 32;

        var input: [64]u8 = undefined;
        std.mem.writeInt(u256, input[0..32], timestamp, .big);
        @memcpy(input[32..64], &root);

        _ = try contract.execute(SYSTEM_ADDRESS, &input, 100000);
    }

    // Verify all entries are readable
    timestamp = 0;
    while (timestamp < HISTORY_BUFFER_LENGTH) : (timestamp += 1) {
        const expected_root = [_]u8{@as(u8, @intCast(timestamp % 256))} ** 32;

        var read_input: [32]u8 = undefined;
        std.mem.writeInt(u256, &read_input, timestamp, .big);

        const result = try contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input, 10000);
        defer allocator.free(result.output);

        try testing.expectEqual(@as(usize, 32), result.output.len);
        try testing.expectEqualSlices(u8, &expected_root, result.output);
    }

    // Now write one more entry to trigger a wrap
    const wrap_timestamp: u64 = HISTORY_BUFFER_LENGTH;
    const wrap_root = [_]u8{0xFF} ** 32;

    var wrap_input: [64]u8 = undefined;
    std.mem.writeInt(u256, wrap_input[0..32], wrap_timestamp, .big);
    @memcpy(wrap_input[32..64], &wrap_root);

    _ = try contract.execute(SYSTEM_ADDRESS, &wrap_input, 100000);

    // First entry (timestamp 0) should now be overwritten
    var read_input: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input, 0, .big);

    const result = try contract.execute(Address{ .bytes = [_]u8{0x11} ** 20 }, &read_input, 10000);
    defer allocator.free(result.output);

    // Should be empty because timestamp mismatch
    try testing.expectEqual(@as(usize, 0), result.output.len);
}