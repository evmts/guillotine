/// Tracks contracts created during transaction execution
/// Used for EIP-6780 SELFDESTRUCT behavior in Cancun+
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

pub const CreatedContracts = struct {
    created: std.AutoHashMap(Address, void),
    allocator: std.mem.Allocator,

    pub inline fn init(allocator: std.mem.Allocator) CreatedContracts {
        return CreatedContracts{
            .created = std.AutoHashMap(Address, void).init(allocator),
            .allocator = allocator,
        };
    }

    pub inline fn deinit(self: *CreatedContracts) void {
        self.created.deinit();
    }

    pub inline fn mark_created(self: *CreatedContracts, address: Address) !void {
        try self.created.put(address, {});
    }

    pub inline fn was_created_in_tx(self: *const CreatedContracts, address: Address) bool {
        return self.created.contains(address);
    }
    
    pub inline fn count(self: *const CreatedContracts) u32 {
        return @intCast(self.created.count());
    }
    
    pub inline fn clear(self: *CreatedContracts) void {
        self.created.clearAndFree();
    }
    
    pub inline fn remove(self: *CreatedContracts, address: Address) bool {
        return self.created.remove(address);
    }
};

test "created contracts initialization" {
    const allocator = std.testing.allocator;
    var created = CreatedContracts.init(allocator);
    defer created.deinit();
    
    try std.testing.expectEqual(@as(u32, 0), created.count());
}

test "created contracts mark and check" {
    const allocator = std.testing.allocator;
    var created = CreatedContracts.init(allocator);
    defer created.deinit();
    
    const addr1: Address = [_]u8{1} ++ [_]u8{0} ** 19;
    const addr2: Address = [_]u8{2} ++ [_]u8{0} ** 19;
    const addr3: Address = [_]u8{3} ++ [_]u8{0} ** 19;
    
    // Initially no contracts
    try std.testing.expect(!created.was_created_in_tx(addr1));
    try std.testing.expect(!created.was_created_in_tx(addr2));
    try std.testing.expectEqual(@as(u32, 0), created.count());
    
    // Mark one contract as created
    try created.mark_created(addr1);
    try std.testing.expect(created.was_created_in_tx(addr1));
    try std.testing.expect(!created.was_created_in_tx(addr2));
    try std.testing.expectEqual(@as(u32, 1), created.count());
    
    // Mark another contract
    try created.mark_created(addr2);
    try std.testing.expect(created.was_created_in_tx(addr1));
    try std.testing.expect(created.was_created_in_tx(addr2));
    try std.testing.expect(!created.was_created_in_tx(addr3));
    try std.testing.expectEqual(@as(u32, 2), created.count());
}

test "created contracts duplicate marking" {
    const allocator = std.testing.allocator;
    var created = CreatedContracts.init(allocator);
    defer created.deinit();
    
    const addr: Address = [_]u8{0xaa} ++ [_]u8{0} ** 19;
    
    // Mark same contract multiple times
    try created.mark_created(addr);
    try std.testing.expectEqual(@as(u32, 1), created.count());
    
    try created.mark_created(addr); // Should not increase count
    try std.testing.expectEqual(@as(u32, 1), created.count());
    try std.testing.expect(created.was_created_in_tx(addr));
}

test "created contracts removal" {
    const allocator = std.testing.allocator;
    var created = CreatedContracts.init(allocator);
    defer created.deinit();
    
    const addr1: Address = [_]u8{1} ++ [_]u8{0} ** 19;
    const addr2: Address = [_]u8{2} ++ [_]u8{0} ** 19;
    
    // Add contracts
    try created.mark_created(addr1);
    try created.mark_created(addr2);
    try std.testing.expectEqual(@as(u32, 2), created.count());
    
    // Remove existing contract
    try std.testing.expect(created.remove(addr1));
    try std.testing.expect(!created.was_created_in_tx(addr1));
    try std.testing.expect(created.was_created_in_tx(addr2));
    try std.testing.expectEqual(@as(u32, 1), created.count());
    
    // Try to remove non-existing contract
    try std.testing.expect(!created.remove(addr1)); // Should return false
    try std.testing.expectEqual(@as(u32, 1), created.count());
    
    // Remove last contract
    try std.testing.expect(created.remove(addr2));
    try std.testing.expectEqual(@as(u32, 0), created.count());
}

test "created contracts clear" {
    const allocator = std.testing.allocator;
    var created = CreatedContracts.init(allocator);
    defer created.deinit();
    
    // Add multiple contracts
    for (1..11) |i| {
        const addr: Address = [_]u8{@intCast(i)} ++ [_]u8{0} ** 19;
        try created.mark_created(addr);
    }
    try std.testing.expectEqual(@as(u32, 10), created.count());
    
    // Clear all
    created.clear();
    try std.testing.expectEqual(@as(u32, 0), created.count());
    
    // Verify all were removed
    for (1..11) |i| {
        const addr: Address = [_]u8{@intCast(i)} ++ [_]u8{0} ** 19;
        try std.testing.expect(!created.was_created_in_tx(addr));
    }
}

test "created contracts zero address" {
    const allocator = std.testing.allocator;
    var created = CreatedContracts.init(allocator);
    defer created.deinit();
    
    // Test with zero address
    try created.mark_created(primitives.ZERO_ADDRESS);
    try std.testing.expect(created.was_created_in_tx(primitives.ZERO_ADDRESS));
    try std.testing.expectEqual(@as(u32, 1), created.count());
    
    try std.testing.expect(created.remove(primitives.ZERO_ADDRESS));
    try std.testing.expect(!created.was_created_in_tx(primitives.ZERO_ADDRESS));
    try std.testing.expectEqual(@as(u32, 0), created.count());
}

test "created contracts edge case addresses" {
    const allocator = std.testing.allocator;
    var created = CreatedContracts.init(allocator);
    defer created.deinit();
    
    // Maximum address (all 0xFF)
    const max_addr: Address = [_]u8{0xff} ** 20;
    try created.mark_created(max_addr);
    try std.testing.expect(created.was_created_in_tx(max_addr));
    
    // Minimum non-zero address
    const min_addr: Address = [_]u8{0} ** 19 ++ [_]u8{1};
    try created.mark_created(min_addr);
    try std.testing.expect(created.was_created_in_tx(min_addr));
    
    try std.testing.expectEqual(@as(u32, 2), created.count());
    
    // Verify specific addresses
    try std.testing.expect(created.was_created_in_tx(max_addr));
    try std.testing.expect(created.was_created_in_tx(min_addr));
    try std.testing.expect(!created.was_created_in_tx(primitives.ZERO_ADDRESS));
}

test "created contracts large number of addresses" {
    const allocator = std.testing.allocator;
    var created = CreatedContracts.init(allocator);
    defer created.deinit();
    
    // Add 1000 unique addresses
    const count = 1000;
    for (0..count) |i| {
        var addr: Address = [_]u8{0} ** 20;
        const i_bytes = std.mem.toBytes(@as(u160, i));
        // Copy the lower 20 bytes to address
        @memcpy(addr[0..20], i_bytes[0..20]);
        try created.mark_created(addr);
    }
    
    try std.testing.expectEqual(@as(u32, count), created.count());
    
    // Verify all addresses are tracked
    for (0..count) |i| {
        var addr: Address = [_]u8{0} ** 20;
        const i_bytes = std.mem.toBytes(@as(u160, i));
        @memcpy(addr[0..20], i_bytes[0..20]);
        try std.testing.expect(created.was_created_in_tx(addr));
    }
    
    // Verify an address not added is not found
    var not_added: Address = [_]u8{0} ** 20;
    const count_bytes = std.mem.toBytes(@as(u160, count));
    @memcpy(not_added[0..20], count_bytes[0..20]);
    try std.testing.expect(!created.was_created_in_tx(not_added));
}

test "created contracts alternating patterns" {
    const allocator = std.testing.allocator;
    var created = CreatedContracts.init(allocator);
    defer created.deinit();
    
    // Addresses with alternating bit patterns
    const pattern1: Address = [_]u8{0xAA} ** 20; // 10101010...
    const pattern2: Address = [_]u8{0x55} ** 20; // 01010101...
    const pattern3: Address = [_]u8{0xF0} ** 20; // 11110000...
    const pattern4: Address = [_]u8{0x0F} ** 20; // 00001111...
    
    try created.mark_created(pattern1);
    try created.mark_created(pattern2);
    try created.mark_created(pattern3);
    try created.mark_created(pattern4);
    
    try std.testing.expectEqual(@as(u32, 4), created.count());
    try std.testing.expect(created.was_created_in_tx(pattern1));
    try std.testing.expect(created.was_created_in_tx(pattern2));
    try std.testing.expect(created.was_created_in_tx(pattern3));
    try std.testing.expect(created.was_created_in_tx(pattern4));
}

test "created contracts partial address patterns" {
    const allocator = std.testing.allocator;
    var created = CreatedContracts.init(allocator);
    defer created.deinit();
    
    // Address where only first byte differs
    const addr1: Address = [_]u8{0x01} ++ [_]u8{0xAB} ** 19;
    const addr2: Address = [_]u8{0x02} ++ [_]u8{0xAB} ** 19;
    const addr3: Address = [_]u8{0x01} ++ [_]u8{0xAB} ** 18 ++ [_]u8{0xCD}; // Last byte differs
    
    try created.mark_created(addr1);
    try created.mark_created(addr2);
    try created.mark_created(addr3);
    
    try std.testing.expectEqual(@as(u32, 3), created.count());
    try std.testing.expect(created.was_created_in_tx(addr1));
    try std.testing.expect(created.was_created_in_tx(addr2));
    try std.testing.expect(created.was_created_in_tx(addr3));
    
    // Verify similar but different address is not found
    const addr_similar: Address = [_]u8{0x01} ++ [_]u8{0xAB} ** 18 ++ [_]u8{0xFF};
    try std.testing.expect(!created.was_created_in_tx(addr_similar));
}

test "created contracts mixed operations" {
    const allocator = std.testing.allocator;
    var created = CreatedContracts.init(allocator);
    defer created.deinit();
    
    // Mix of add, check, remove operations
    const addr1: Address = [_]u8{0x11} ++ [_]u8{0} ** 19;
    const addr2: Address = [_]u8{0x22} ++ [_]u8{0} ** 19;
    const addr3: Address = [_]u8{0x33} ++ [_]u8{0} ** 19;
    
    // Add some contracts
    try created.mark_created(addr1);
    try created.mark_created(addr2);
    try std.testing.expectEqual(@as(u32, 2), created.count());
    
    // Remove one
    try std.testing.expect(created.remove(addr1));
    try std.testing.expectEqual(@as(u32, 1), created.count());
    
    // Add another
    try created.mark_created(addr3);
    try std.testing.expectEqual(@as(u32, 2), created.count());
    
    // Re-add the removed one
    try created.mark_created(addr1);
    try std.testing.expectEqual(@as(u32, 3), created.count());
    
    // Verify final state
    try std.testing.expect(created.was_created_in_tx(addr1));
    try std.testing.expect(created.was_created_in_tx(addr2));
    try std.testing.expect(created.was_created_in_tx(addr3));
    
    // Clear and verify empty
    created.clear();
    try std.testing.expectEqual(@as(u32, 0), created.count());
    try std.testing.expect(!created.was_created_in_tx(addr1));
    try std.testing.expect(!created.was_created_in_tx(addr2));
    try std.testing.expect(!created.was_created_in_tx(addr3));
}

test "created contracts hash collisions resistance" {
    const allocator = std.testing.allocator;
    var created = CreatedContracts.init(allocator);
    defer created.deinit();
    
    // Create addresses that might cause hash collisions
    // These are designed to stress the hash map implementation
    const collision_prone_addresses = [_]Address{
        [_]u8{0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01},
        [_]u8{0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
        [_]u8{0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
        [_]u8{0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01},
        [_]u8{0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00},
    };
    
    // Add all addresses
    for (collision_prone_addresses) |addr| {
        try created.mark_created(addr);
    }
    
    try std.testing.expectEqual(@as(u32, collision_prone_addresses.len), created.count());
    
    // Verify each address is tracked correctly
    for (collision_prone_addresses) |addr| {
        try std.testing.expect(created.was_created_in_tx(addr));
    }
    
    // Verify similar but different addresses are not found
    const not_added1: Address = [_]u8{0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02};
    const not_added2: Address = [_]u8{0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
    
    try std.testing.expect(!created.was_created_in_tx(not_added1));
    try std.testing.expect(!created.was_created_in_tx(not_added2));
}

test "created contracts memory stress test" {
    const allocator = std.testing.allocator;
    var created = CreatedContracts.init(allocator);
    defer created.deinit();
    
    // Add, remove, and re-add addresses to stress memory management
    const base_count = 100;
    
    // Phase 1: Add addresses
    for (0..base_count) |i| {
        var addr: Address = [_]u8{0} ** 20;
        addr[19] = @intCast(i);
        try created.mark_created(addr);
    }
    try std.testing.expectEqual(@as(u32, base_count), created.count());
    
    // Phase 2: Remove every other address
    var removed_count: u32 = 0;
    for (0..base_count) |i| {
        if (i % 2 == 0) {
            var addr: Address = [_]u8{0} ** 20;
            addr[19] = @intCast(i);
            try std.testing.expect(created.remove(addr));
            removed_count += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, base_count - removed_count), created.count());
    
    // Phase 3: Re-add the removed addresses with different pattern
    for (0..base_count) |i| {
        if (i % 2 == 0) {
            var addr: Address = [_]u8{0} ** 20;
            addr[18] = @intCast(i); // Different position
            try created.mark_created(addr);
        }
    }
    try std.testing.expectEqual(@as(u32, base_count), created.count());
    
    // Phase 4: Clear and verify
    created.clear();
    try std.testing.expectEqual(@as(u32, 0), created.count());
    
    // Verify all addresses are gone
    for (0..base_count) |i| {
        var addr1: Address = [_]u8{0} ** 20;
        addr1[19] = @intCast(i);
        var addr2: Address = [_]u8{0} ** 20;
        addr2[18] = @intCast(i);
        
        try std.testing.expect(!created.was_created_in_tx(addr1));
        try std.testing.expect(!created.was_created_in_tx(addr2));
    }
}

test "created contracts boundary values" {
    const allocator = std.testing.allocator;
    var created = CreatedContracts.init(allocator);
    defer created.deinit();
    
    // Test with maximum u32 address patterns (for count testing)
    const max_addresses_to_test = 1000; // Reasonable for unit test
    
    // Create sequential addresses starting from different positions
    for (0..max_addresses_to_test) |i| {
        var addr: Address = [_]u8{0} ** 20;
        // Distribute the index across multiple bytes to avoid overflow
        const idx = @as(u32, @intCast(i));
        addr[16] = @intCast(idx >> 24);
        addr[17] = @intCast((idx >> 16) & 0xFF);
        addr[18] = @intCast((idx >> 8) & 0xFF);
        addr[19] = @intCast(idx & 0xFF);
        
        try created.mark_created(addr);
    }
    
    try std.testing.expectEqual(@as(u32, max_addresses_to_test), created.count());
    
    // Verify count is accurate
    var manual_count: u32 = 0;
    for (0..max_addresses_to_test) |i| {
        var addr: Address = [_]u8{0} ** 20;
        const idx = @as(u32, @intCast(i));
        addr[16] = @intCast(idx >> 24);
        addr[17] = @intCast((idx >> 16) & 0xFF);
        addr[18] = @intCast((idx >> 8) & 0xFF);
        addr[19] = @intCast(idx & 0xFF);
        
        if (created.was_created_in_tx(addr)) {
            manual_count += 1;
        }
    }
    
    try std.testing.expectEqual(created.count(), manual_count);
}

test "created contracts EIP-6780 scenario simulation" {
    const allocator = std.testing.allocator;
    var created = CreatedContracts.init(allocator);
    defer created.deinit();
    
    // Simulate EIP-6780 SELFDESTRUCT scenario
    // Contract addresses that might be created and then self-destructed
    const contract1: Address = Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    const contract2: Address = Address.fromHex("0xABCDEF123456789012345678901234567890ABCD") catch unreachable;
    const contract3: Address = Address.fromHex("0xFEDCBA987654321098765432109876543210FEDC") catch unreachable;
    
    // Initially no contracts created
    try std.testing.expect(!created.was_created_in_tx(contract1));
    try std.testing.expect(!created.was_created_in_tx(contract2));
    try std.testing.expect(!created.was_created_in_tx(contract3));
    try std.testing.expectEqual(@as(u32, 0), created.count());
    
    // CREATE operation - mark contracts as created
    try created.mark_created(contract1);
    try created.mark_created(contract2);
    try std.testing.expectEqual(@as(u32, 2), created.count());
    
    // Verify contracts are tracked as created in this transaction
    try std.testing.expect(created.was_created_in_tx(contract1));
    try std.testing.expect(created.was_created_in_tx(contract2));
    try std.testing.expect(!created.was_created_in_tx(contract3)); // Not created yet
    
    // CREATE2 operation - mark another contract
    try created.mark_created(contract3);
    try std.testing.expectEqual(@as(u32, 3), created.count());
    try std.testing.expect(created.was_created_in_tx(contract3));
    
    // SELFDESTRUCT of contract1 (EIP-6780 allows this since it was created in same tx)
    try std.testing.expect(created.remove(contract1));
    try std.testing.expectEqual(@as(u32, 2), created.count());
    try std.testing.expect(!created.was_created_in_tx(contract1));
    try std.testing.expect(created.was_created_in_tx(contract2));
    try std.testing.expect(created.was_created_in_tx(contract3));
    
    // End of transaction - clear created contracts for next transaction
    created.clear();
    try std.testing.expectEqual(@as(u32, 0), created.count());
    try std.testing.expect(!created.was_created_in_tx(contract1));
    try std.testing.expect(!created.was_created_in_tx(contract2));
    try std.testing.expect(!created.was_created_in_tx(contract3));
}
