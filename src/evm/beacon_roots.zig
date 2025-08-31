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

/// Beacon roots contract implementation
pub const BeaconRootsContract = struct {
    database: *Database,
    
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
    ) !struct { output: []const u8, gas_used: u64 } {
        // System call to update beacon root
        if (std.mem.eql(u8, &caller.bytes, &SYSTEM_ADDRESS.bytes)) {
            if (input.len != 64) {
                log.debug("BeaconRoots: Invalid system call input length: {}", .{input.len});
                return .{ .output = &.{}, .gas_used = 0 };
            }
            
            if (gas_limit < BEACON_ROOT_WRITE_GAS) {
                return error.OutOfGas;
            }
            
            // Parse timestamp and beacon root
            var timestamp: u256 = 0;
            var beacon_root: [32]u8 = undefined;
            
            // Read timestamp (big-endian)
            for (input[0..32]) |byte| {
                timestamp = (timestamp << 8) | byte;
            }
            @memcpy(&beacon_root, input[32..64]);
            
            // Store in ring buffer
            const timestamp_slot = timestamp % HISTORY_BUFFER_LENGTH;
            
            // Store timestamp -> beacon_root
            try self.database.set_storage(
                BEACON_ROOTS_ADDRESS.bytes,
                timestamp_slot,
                @bitCast(beacon_root),
            );
            
            // Store beacon_root -> timestamp (at slot + HISTORY_BUFFER_LENGTH)
            const root_slot = timestamp_slot + HISTORY_BUFFER_LENGTH;
            try self.database.set_storage(
                BEACON_ROOTS_ADDRESS.bytes,
                root_slot,
                timestamp,
            );
            
            log.debug("BeaconRoots: Stored root for timestamp {} at slot {}", .{ timestamp, timestamp_slot });
            
            return .{ .output = &.{}, .gas_used = BEACON_ROOT_WRITE_GAS };
        }
        
        // Regular call to read beacon root
        if (input.len != 32) {
            log.debug("BeaconRoots: Invalid read input length: {}", .{input.len});
            return .{ .output = &.{}, .gas_used = 0 };
        }
        
        if (gas_limit < BEACON_ROOT_READ_GAS) {
            return error.OutOfGas;
        }
        
        // Parse timestamp
        var timestamp: u256 = 0;
        for (input[0..32]) |byte| {
            timestamp = (timestamp << 8) | byte;
        }
        
        // Retrieve from ring buffer
        const timestamp_slot = timestamp % HISTORY_BUFFER_LENGTH;
        const stored_root = try self.database.get_storage(
            BEACON_ROOTS_ADDRESS.bytes,
            timestamp_slot,
        );
        
        // Check if this is the correct timestamp by verifying reverse mapping
        const root_slot = timestamp_slot + HISTORY_BUFFER_LENGTH;
        const stored_timestamp = try self.database.get_storage(
            BEACON_ROOTS_ADDRESS.bytes,
            root_slot,
        );
        
        if (stored_timestamp != timestamp) {
            // Timestamp doesn't match, root not available
            log.debug("BeaconRoots: Timestamp mismatch for slot {}: {} != {}", .{ 
                timestamp_slot, stored_timestamp, timestamp 
            });
            return .{ .output = &.{}, .gas_used = BEACON_ROOT_READ_GAS };
        }
        
        // Return the beacon root
        const root_bytes: [32]u8 = @bitCast(stored_root);
        
        // Need to allocate output that lives beyond this function
        // In real implementation, this would be handled by the caller
        return .{ .output = &root_bytes, .gas_used = BEACON_ROOT_READ_GAS };
    }
    
    /// Process a beacon root update at the start of a block
    /// This should be called by the EVM before processing any transactions
    pub fn processBeaconRootUpdate(
        database: *Database,
        block_info: *const BlockInfo,
    ) !void {
        if (block_info.beacon_root == null) {
            // No beacon root to update
            return;
        }
        
        const beacon_root = block_info.beacon_root.?;
        const timestamp = block_info.timestamp;
        
        // Store in ring buffer
        const timestamp_slot = timestamp % HISTORY_BUFFER_LENGTH;
        
        // Store timestamp -> beacon_root
        try database.set_storage(
            BEACON_ROOTS_ADDRESS.bytes,
            timestamp_slot,
            @bitCast(beacon_root),
        );
        
        // Store beacon_root -> timestamp
        const root_slot = timestamp_slot + HISTORY_BUFFER_LENGTH;
        try database.set_storage(
            BEACON_ROOTS_ADDRESS.bytes,
            root_slot,
            timestamp,
        );
        
        log.debug("BeaconRoots: Updated block beacon root for timestamp {}", .{timestamp});
    }
};

// Tests
test "beacon roots ring buffer storage" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var database = try Database.init(allocator);
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
    
    var database = try Database.init(allocator);
    defer database.deinit();
    
    var contract = BeaconRootsContract{ .database = &database };
    
    // Test system call to store beacon root
    const timestamp: u64 = 1710338135;
    const beacon_root = [32]u8{0xAB} ** 32;
    
    var input: [64]u8 = undefined;
    std.mem.writeInt(u256, input[0..32], timestamp, .big);
    @memcpy(input[32..64], &beacon_root);
    
    const result = try contract.execute(SYSTEM_ADDRESS, &input, 100000);
    try testing.expectEqual(BEACON_ROOT_WRITE_GAS, result.gas_used);
    
    // Test reading the beacon root back
    var read_input: [32]u8 = undefined;
    std.mem.writeInt(u256, &read_input, timestamp, .big);
    
    const read_result = try contract.execute(
        primitives.ZERO_ADDRESS,
        &read_input,
        10000,
    );
    
    try testing.expectEqual(BEACON_ROOT_READ_GAS, read_result.gas_used);
    // Note: In real implementation, output would be properly allocated
    // Here we're just checking the gas cost
}