/// EIP-2929 Warm/Cold Access Tracking
///
/// This module manages the warm/cold access state for addresses and storage slots
/// according to EIP-2929. It's EVM-specific logic, not a primitive type.
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const StorageKey = primitives.State.StorageKey;
const AccessList = primitives.AccessList.AccessList;
const Hash = primitives.Hash.Hash;
const gas_constants = primitives.GasConstants;
const Allocator = std.mem.Allocator;

/// Context for hashing Address in hash maps
const AddressContext = struct {
    pub fn hash(_: @This(), addr: Address) u32 {
        return @truncate(std.hash.Wyhash.hash(0, &addr.bytes));
    }
    pub fn eql(_: @This(), a: Address, b: Address, _: usize) bool {
        return a.eql(b);
    }
};

/// Context for hashing StorageKey in hash maps
const StorageKeyContext = struct {
    pub fn hash(_: @This(), key: StorageKey) u32 {
        var hasher = std.hash.Wyhash.init(0);
        key.hash(&hasher);
        return @truncate(hasher.final());
    }
    pub fn eql(_: @This(), a: StorageKey, b: StorageKey, _: usize) bool {
        return StorageKey.eql(a, b);
    }
};

/// Manages warm/cold access state for EIP-2929
pub const AccessListManager = struct {
    allocator: Allocator,
    warm_addresses: std.AutoHashMap(Address, void),
    warm_storage_slots: std.ArrayHashMap(StorageKey, void, StorageKeyContext, false),

    /// Initialize empty access list manager
    pub fn init(allocator: Allocator) AccessListManager {
        return .{
            .allocator = allocator,
            .warm_addresses = std.AutoHashMap(Address, void).init(allocator),
            .warm_storage_slots = std.ArrayHashMap(StorageKey, void, StorageKeyContext, false).init(allocator),
        };
    }

    /// Clean up resources
    pub fn deinit(self: *AccessListManager) void {
        self.warm_addresses.deinit();
        self.warm_storage_slots.deinit();
    }

    /// Access an address and return gas cost (warm=100, cold=2600)
    /// EIP-2929: First access is cold, subsequent accesses are warm
    pub fn accessAddress(self: *AccessListManager, addr: Address) !u64 {
        const entry = try self.warm_addresses.getOrPut(addr);
        return if (entry.found_existing)
            gas_constants.WarmStorageReadCost
        else
            gas_constants.ColdAccountAccessCost;
    }

    /// Access a storage slot and return gas cost (warm=100, cold=2100)
    /// EIP-2929: First access is cold, subsequent accesses are warm
    pub fn accessStorageSlot(self: *AccessListManager, addr: Address, slot: u256) !u64 {
        const key = StorageKey{ .address = addr.bytes, .slot = slot };
        const entry = try self.warm_storage_slots.getOrPut(key);
        return if (entry.found_existing)
            gas_constants.WarmStorageReadCost
        else
            gas_constants.ColdSloadCost;
    }

    /// Pre-warm multiple addresses (marks them as already accessed)
    pub fn preWarmAddresses(self: *AccessListManager, addresses: []const Address) !void {
        for (addresses) |addr| {
            _ = try self.warm_addresses.getOrPut(addr);
        }
    }

    /// Pre-warm multiple storage slots (marks them as already accessed)
    pub fn preWarmStorageSlots(self: *AccessListManager, slots: []const StorageKey) !void {
        for (slots) |slot| {
            _ = try self.warm_storage_slots.getOrPut(slot);
        }
    }

    /// Pre-warm from EIP-2930 access list
    pub fn preWarmFromAccessList(self: *AccessListManager, access_list: AccessList) !void {
        for (access_list) |entry| {
            // Pre-warm address
            _ = try self.warm_addresses.getOrPut(entry.address);

            // Pre-warm storage keys (convert Hash to u256)
            for (entry.storage_keys) |key_hash| {
                const slot = std.mem.readInt(u256, &key_hash, .big);
                const key = StorageKey{ .address = entry.address.bytes, .slot = slot };
                _ = try self.warm_storage_slots.getOrPut(key);
            }
        }
    }

    /// Check if address is warm
    pub fn isAddressWarm(self: *const AccessListManager, addr: Address) bool {
        return self.warm_addresses.contains(addr);
    }

    /// Check if storage slot is warm
    pub fn isStorageSlotWarm(self: *const AccessListManager, addr: Address, slot: u256) bool {
        const key = StorageKey{ .address = addr.bytes, .slot = slot };
        return self.warm_storage_slots.contains(key);
    }

    /// Clear all warm sets (used at transaction boundaries)
    pub fn clear(self: *AccessListManager) void {
        self.warm_addresses.clearRetainingCapacity();
        self.warm_storage_slots.clearRetainingCapacity();
    }

    /// Create snapshot for nested call revert handling
    pub fn snapshot(self: *const AccessListManager) !AccessListSnapshot {
        var addr_snapshot = std.AutoHashMap(Address, void).init(self.allocator);
        var addr_it = self.warm_addresses.iterator();
        while (addr_it.next()) |entry| {
            try addr_snapshot.put(entry.key_ptr.*, {});
        }

        var slot_snapshot = std.ArrayHashMap(StorageKey, void, StorageKeyContext, false).init(self.allocator);
        var slot_it = self.warm_storage_slots.iterator();
        while (slot_it.next()) |entry| {
            _ = try slot_snapshot.put(entry.key_ptr.*, {});
        }

        return .{
            .addresses = addr_snapshot,
            .slots = slot_snapshot,
        };
    }

    /// Restore from snapshot (for nested call reverts)
    pub fn restore(self: *AccessListManager, snap: AccessListSnapshot) !void {
        self.warm_addresses.clearRetainingCapacity();
        var addr_it = snap.addresses.iterator();
        while (addr_it.next()) |entry| {
            try self.warm_addresses.put(entry.key_ptr.*, {});
        }

        self.warm_storage_slots.clearRetainingCapacity();
        var slot_it = snap.slots.iterator();
        while (slot_it.next()) |entry| {
            _ = try self.warm_storage_slots.put(entry.key_ptr.*, {});
        }
    }
};

/// Snapshot of warm sets for nested call revert handling
pub const AccessListSnapshot = struct {
    addresses: std.AutoHashMap(Address, void),
    slots: std.ArrayHashMap(StorageKey, void, StorageKeyContext, false),

    pub fn deinit(self: *AccessListSnapshot) void {
        self.addresses.deinit();
        self.slots.deinit();
    }
};
