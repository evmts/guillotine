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
const Database = @import("database.zig").Database;
const BlockInfo = @import("block_info.zig").DefaultBlockInfo;
const log = @import("log.zig");

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
} || Database.Error;

/// Compute storage slots for a given timestamp
/// Returns: { timestamp_slot, root_slot }
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
            const timestamp = std.mem.readInt(u256, input[0..32], .big);
            var beacon_root: [32]u8 = undefined;
            @memcpy(&beacon_root, input[32..64]);
            
            // Store in ring buffer using helper
            const slots = computeSlots(@intCast(timestamp));
            
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
        const timestamp = std.mem.readInt(u256, input[0..32], .big);
        
        // Retrieve from ring buffer using helper
        const slots = computeSlots(@intCast(timestamp));
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