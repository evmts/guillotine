/// EIP-2929 Access List implementation for gas cost optimization
/// Tracks warm/cold access to addresses and storage slots for accurate gas accounting
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

/// Error type for AccessList operations
pub const AccessError = error{OutOfMemory};

/// AccessList tracks accessed addresses for EIP-2929 gas cost optimization
/// Cold access: 2600 gas, Warm access: 100 gas
pub const AccessList = struct {
    /// HashMap tracking accessed addresses (true = warm, false/missing = cold)
    accessed_addresses: std.HashMap(Address, void, AddressContext, std.hash_map.default_max_load_percentage),
    /// HashMap tracking accessed storage slots (key = address + slot hash)
    accessed_storage: std.HashMap(StorageKey, void, StorageKeyContext, std.hash_map.default_max_load_percentage),
    /// Allocator for HashMap operations
    allocator: std.mem.Allocator,

    /// Storage key for address + slot combination
    const StorageKey = struct {
        address: Address,
        slot: [32]u8,

        pub fn hash(self: StorageKey) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(&self.address);
            hasher.update(&self.slot);
            return hasher.final();
        }

        pub fn eql(self: StorageKey, other: StorageKey) bool {
            return std.mem.eql(u8, &self.address, &other.address) and
                   std.mem.eql(u8, &self.slot, &other.slot);
        }
    };

    /// Context for Address HashMap
    const AddressContext = struct {
        pub fn hash(self: @This(), address: Address) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(&address);
            return hasher.final();
        }

        pub fn eql(self: @This(), a: Address, b: Address) bool {
            _ = self;
            return std.mem.eql(u8, &a, &b);
        }
    };

    /// Context for StorageKey HashMap
    const StorageKeyContext = struct {
        pub fn hash(self: @This(), key: StorageKey) u64 {
            _ = self;
            return key.hash();
        }

        pub fn eql(self: @This(), a: StorageKey, b: StorageKey) bool {
            _ = self;
            return a.eql(b);
        }
    };

    /// Initialize new AccessList with given allocator
    pub fn init(allocator: std.mem.Allocator) AccessList {
        return AccessList{
            .accessed_addresses = std.HashMap(Address, void, AddressContext, std.hash_map.default_max_load_percentage).init(allocator),
            .accessed_storage = std.HashMap(StorageKey, void, StorageKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *AccessList) void {
        self.accessed_addresses.deinit();
        self.accessed_storage.deinit();
    }

    /// Access an address and return the gas cost (EIP-2929)
    /// Returns 2600 for cold access (first time), 100 for warm access (subsequent times)
    pub fn access_address(self: *AccessList, address: Address) AccessError!u64 {
        const result = try self.accessed_addresses.getOrPut(address);
        if (result.found_existing) {
            return 100; // Warm access
        } else {
            return 2600; // Cold access
        }
    }

    /// Access a storage slot and return the gas cost (EIP-2929)
    /// Returns 2100 for cold access (first time), 100 for warm access (subsequent times)
    pub fn access_storage(self: *AccessList, address: Address, slot: [32]u8) AccessError!u64 {
        const key = StorageKey{ .address = address, .slot = slot };
        const result = try self.accessed_storage.getOrPut(key);
        if (result.found_existing) {
            return 100; // Warm access
        } else {
            return 2100; // Cold access
        }
    }

    /// Check if an address is warm (already accessed)
    pub fn is_address_warm(self: *AccessList, address: Address) bool {
        return self.accessed_addresses.contains(address);
    }

    /// Check if a storage slot is warm (already accessed)
    pub fn is_storage_warm(self: *AccessList, address: Address, slot: [32]u8) bool {
        const key = StorageKey{ .address = address, .slot = slot };
        return self.accessed_storage.contains(key);
    }

    /// Warm up an address (mark as accessed without returning gas cost)
    /// Used for precompiles and other special cases
    pub fn warm_address(self: *AccessList, address: Address) AccessError!void {
        _ = try self.accessed_addresses.getOrPut(address);
    }

    /// Warm up a storage slot (mark as accessed without returning gas cost)
    pub fn warm_storage(self: *AccessList, address: Address, slot: [32]u8) AccessError!void {
        const key = StorageKey{ .address = address, .slot = slot };
        _ = try self.accessed_storage.getOrPut(key);
    }
};

test "AccessList - address access tracking" {
    const allocator = std.testing.allocator;
    var access_list = AccessList.init(allocator);
    defer access_list.deinit();

    const addr = primitives.Address.ZERO_ADDRESS;

    // First access should be cold (2600 gas)
    const cold_cost = try access_list.access_address(addr);
    try std.testing.expectEqual(@as(u64, 2600), cold_cost);

    // Second access should be warm (100 gas)
    const warm_cost = try access_list.access_address(addr);
    try std.testing.expectEqual(@as(u64, 100), warm_cost);

    // Verify warmth check
    try std.testing.expect(access_list.is_address_warm(addr));
}

test "AccessList - storage access tracking" {
    const allocator = std.testing.allocator;
    var access_list = AccessList.init(allocator);
    defer access_list.deinit();

    const addr = primitives.Address.ZERO_ADDRESS;
    const slot = [_]u8{0x01} ++ [_]u8{0} ** 31;

    // First storage access should be cold (2100 gas)
    const cold_cost = try access_list.access_storage(addr, slot);
    try std.testing.expectEqual(@as(u64, 2100), cold_cost);

    // Second storage access should be warm (100 gas)
    const warm_cost = try access_list.access_storage(addr, slot);
    try std.testing.expectEqual(@as(u64, 100), warm_cost);

    // Verify warmth check
    try std.testing.expect(access_list.is_storage_warm(addr, slot));
}

test "AccessList - warming functions" {
    const allocator = std.testing.allocator;
    var access_list = AccessList.init(allocator);
    defer access_list.deinit();

    const addr = primitives.Address.ZERO_ADDRESS;
    const slot = [_]u8{0x02} ++ [_]u8{0} ** 31;

    // Warm address without cost
    try access_list.warm_address(addr);
    try std.testing.expect(access_list.is_address_warm(addr));

    // Warm storage without cost
    try access_list.warm_storage(addr, slot);
    try std.testing.expect(access_list.is_storage_warm(addr, slot));

    // Subsequent accesses should be warm
    const addr_cost = try access_list.access_address(addr);
    try std.testing.expectEqual(@as(u64, 100), addr_cost);

    const storage_cost = try access_list.access_storage(addr, slot);
    try std.testing.expectEqual(@as(u64, 100), storage_cost);
}