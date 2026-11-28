const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address;
const AccessListConfig = @import("access_list_config.zig").AccessListConfig;
const slot_hash = @import("slot_hash.zig");

/// Create an AccessList type with the given configuration
pub fn createAccessList(comptime config: AccessListConfig) type {
    comptime config.validate();

    return struct {
        const Self = @This();
        /// Warm addresses - addresses that have been accessed
        /// Using ArrayHashMap for better cache locality
        ///
        /// The value of an entry is a mark its owner may set (`Access.recorded`).
        /// The EVM sets it once it has recorded the entry for the state dump, so a
        /// later warm access needs no further lookup. A new entry starts unmarked.
        allocator: std.mem.Allocator,
        addresses: std.array_hash_map.Auto(Address, bool),
        /// Warm storage slots - storage slots that have been accessed
        /// Using ArrayHashMap for better cache locality. Values as for `addresses`.
        storage_slots: std.array_hash_map.Custom(StorageKey, bool, StorageKeyContext, false),

        // Gas costs from configuration
        pub const COLD_ACCOUNT_ACCESS_COST: u64 = config.cold_account_access_cost;
        pub const WARM_ACCOUNT_ACCESS_COST: u64 = config.warm_account_access_cost;
        pub const COLD_SLOAD_COST: u64 = config.cold_sload_cost;
        pub const WARM_SLOAD_COST: u64 = config.warm_sload_cost;

        const StorageKey = struct {
            address: Address,
            slot: config.SlotType,
        };

        fn storageKeyEql(a: StorageKey, b: StorageKey) bool {
            return a.slot == b.slot and std.mem.eql(u8, &a.address.bytes, &b.address.bytes);
        }

        /// Hashes a slot with the shared `slot_hash`, so a caller that already has
        /// that hash can pass it in (`accessStorageSlotEntry`).
        const StorageKeyContext = struct {
            pub fn hash(self: @This(), key: StorageKey) u32 {
                _ = self;
                return @truncate(slot_hash.hash(key.address.bytes, key.slot));
            }

            pub fn eql(self: @This(), a: StorageKey, b: StorageKey, b_index: usize) bool {
                _ = self;
                _ = b_index;
                return storageKeyEql(a, b);
            }
        };

        const PrehashedStorageKey = slot_hash.PrehashedIndexed(storageKeyEql);

        /// Result of an access: its gas cost and the entry's mark (see `addresses`).
        /// `recorded` is valid until the next access or pre-warm.
        pub const Access = struct {
            cost: u64,
            recorded: *bool,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .addresses = .empty,
                .storage_slots = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.addresses.deinit(self.allocator);
            self.storage_slots.deinit(self.allocator);
        }

        /// Clear all access lists for a new transaction
        pub fn clear(self: *Self) void {
            self.addresses.clearRetainingCapacity();
            self.storage_slots.clearRetainingCapacity();
        }

        /// Most addresses `clearKeepingAddresses` removes one by one. Past this a
        /// full clear is cheaper than undoing each insertion.
        const max_incremental_clear = 32;

        /// Clear the access list for a new transaction, keeping the first `keep`
        /// addresses warm and unmarked.
        ///
        /// A host passes the number of leading addresses that every transaction
        /// warms anyway (the fork's precompiles). Keeping them saves re-inserting
        /// them, one hash-map insertion each, at the start of every transaction.
        /// When fewer than `keep` addresses are present, everything is cleared.
        pub fn clearKeepingAddresses(self: *Self, keep: usize) void {
            self.storage_slots.clearRetainingCapacity();
            const count = self.addresses.count();
            if (keep == 0 or keep > count or count - keep > max_incremental_clear) {
                self.addresses.clearRetainingCapacity();
                return;
            }
            self.addresses.shrinkRetainingCapacity(keep);
            @memset(self.addresses.values(), false);
        }

        /// Mark an address as accessed and return the gas cost
        /// Returns COLD_ACCOUNT_ACCESS_COST if first access, WARM_ACCOUNT_ACCESS_COST if already accessed
        pub fn access_address(self: *Self, address: Address) !u64 {
            return (try self.accessAddressEntry(address)).cost;
        }

        /// `access_address` that also returns the entry's mark.
        pub fn accessAddressEntry(self: *Self, address: Address) !Access {
            const result = try self.addresses.getOrPut(self.allocator, address);
            if (result.found_existing) {
                return .{ .cost = WARM_ACCOUNT_ACCESS_COST, .recorded = result.value_ptr };
            }
            result.value_ptr.* = false;
            return .{ .cost = COLD_ACCOUNT_ACCESS_COST, .recorded = result.value_ptr };
        }

        /// Mark a storage slot as accessed and return the gas cost
        /// Returns COLD_SLOAD_COST if first access, WARM_SLOAD_COST if already accessed
        pub fn access_storage_slot(self: *Self, address: Address, slot: config.SlotType) !u64 {
            return (try self.accessStorageSlotEntry(address, slot, slot_hash.hash(address.bytes, slot))).cost;
        }

        /// `access_storage_slot` for a caller that already has the slot's
        /// `slot_hash`. Also returns the entry's mark.
        pub fn accessStorageSlotEntry(self: *Self, address: Address, slot: config.SlotType, hash: u64) !Access {
            const key = StorageKey{ .address = address, .slot = slot };
            const result = try self.storage_slots.getOrPutAdapted(self.allocator, key, PrehashedStorageKey{ .value = hash });
            if (result.found_existing) {
                return .{ .cost = WARM_SLOAD_COST, .recorded = result.value_ptr };
            }
            result.key_ptr.* = key;
            result.value_ptr.* = false;
            return .{ .cost = COLD_SLOAD_COST, .recorded = result.value_ptr };
        }

        /// Clear the mark of every entry.
        pub fn clearRecorded(self: *Self) void {
            @memset(self.addresses.values(), false);
            @memset(self.storage_slots.values(), false);
        }

        /// Check if an address is warm (has been accessed)
        pub fn is_address_warm(self: *Self, address: Address) bool {
            return self.addresses.contains(address);
        }

        /// Check if a storage slot is warm (has been accessed)
        pub fn is_storage_slot_warm(self: *Self, address: Address, slot: config.SlotType) bool {
            const key = StorageKey{ .address = address, .slot = slot };
            return self.storage_slots.contains(key);
        }

        /// Pre-warm addresses for transaction initialization
        /// This is used to warm the tx.origin, coinbase, and transaction target
        pub fn pre_warm_addresses(self: *Self, addresses: []const Address) !void {
            for (addresses) |address| {
                const result = try self.addresses.getOrPut(self.allocator, address);
                if (!result.found_existing) result.value_ptr.* = false;
            }
        }

        /// Sizes of the warm sets at one point of execution. Entries are only ever
        /// appended (or all cleared), so the sizes identify everything warmed later.
        pub const Checkpoint = struct {
            addresses: usize,
            storage_slots: usize,
        };

        pub fn checkpoint(self: *const Self) Checkpoint {
            return .{ .addresses = self.addresses.count(), .storage_slots = self.storage_slots.count() };
        }

        /// Forget every address and storage slot warmed since `mark`. execution-specs
        /// merges a child frame's accessed addresses and storage keys into its parent
        /// only when the child succeeds.
        pub fn revert(self: *Self, mark: Checkpoint) void {
            self.addresses.shrinkRetainingCapacity(mark.addresses);
            self.storage_slots.shrinkRetainingCapacity(mark.storage_slots);
        }

        /// Clone the access list
        pub fn clone(self: *const Self) !Self {
            var addresses = try self.addresses.clone(self.allocator);
            errdefer addresses.deinit(self.allocator);
            return Self{
                .allocator = self.allocator,
                .addresses = addresses,
                .storage_slots = try self.storage_slots.clone(self.allocator),
            };
        }
    };
}

/// Default AccessList type using standard EIP-2929 configuration
pub const AccessList = createAccessList(AccessListConfig{});

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const GasConstants = primitives.GasConstants;

test "AccessList - address access tracking" {
    var access_list = AccessList.init(testing.allocator);
    defer access_list.deinit();

    const test_address = Address{ .bytes = @as([20]u8, @splat(1)) };

    // First access should be cold
    const cost1 = try access_list.access_address(test_address);
    try testing.expectEqual(AccessList.COLD_ACCOUNT_ACCESS_COST, cost1);

    // Second access should be warm
    const cost2 = try access_list.access_address(test_address);
    try testing.expectEqual(AccessList.WARM_ACCOUNT_ACCESS_COST, cost2);

    // Check warmth
    try testing.expect(access_list.is_address_warm(test_address));

    const cold_address = Address{ .bytes = @as([20]u8, @splat(2)) };
    try testing.expect(!access_list.is_address_warm(cold_address));
}

test "AccessList - storage slot access tracking" {
    var access_list = AccessList.init(testing.allocator);
    defer access_list.deinit();

    const test_address = Address{ .bytes = @as([20]u8, @splat(1)) };
    const slot1: u256 = 42;
    const slot2: u256 = 100;

    // First access to slot1 should be cold
    const cost1 = try access_list.access_storage_slot(test_address, slot1);
    try testing.expectEqual(AccessList.COLD_SLOAD_COST, cost1);

    // Second access to slot1 should be warm
    const cost2 = try access_list.access_storage_slot(test_address, slot1);
    try testing.expectEqual(AccessList.WARM_SLOAD_COST, cost2);

    // First access to slot2 should be cold
    const cost3 = try access_list.access_storage_slot(test_address, slot2);
    try testing.expectEqual(AccessList.COLD_SLOAD_COST, cost3);

    // Check warmth
    try testing.expect(access_list.is_storage_slot_warm(test_address, slot1));
    try testing.expect(access_list.is_storage_slot_warm(test_address, slot2));
    try testing.expect(!access_list.is_storage_slot_warm(test_address, 999));
}

test "AccessList - pre-warming addresses" {
    var access_list = AccessList.init(testing.allocator);
    defer access_list.deinit();

    const addresses = [_]Address{
        primitives.ZERO_ADDRESS,
        Address{ .bytes = @as([20]u8, @splat(1)) },
        Address{ .bytes = @as([20]u8, @splat(2)) },
    };

    try access_list.pre_warm_addresses(&addresses);

    // All should be warm
    for (addresses) |address| {
        try testing.expect(access_list.is_address_warm(address));
        try testing.expectEqual(AccessList.WARM_ACCOUNT_ACCESS_COST, try access_list.access_address(address));
    }
}

test "AccessList - clear functionality" {
    var access_list = AccessList.init(testing.allocator);
    defer access_list.deinit();

    const test_address = Address{ .bytes = @as([20]u8, @splat(1)) };
    const slot: u256 = 42;

    // Access address and storage slot
    _ = try access_list.access_address(test_address);
    _ = try access_list.access_storage_slot(test_address, slot);

    try testing.expect(access_list.is_address_warm(test_address));
    try testing.expect(access_list.is_storage_slot_warm(test_address, slot));

    // Clear access list
    access_list.clear();

    try testing.expect(!access_list.is_address_warm(test_address));
    try testing.expect(!access_list.is_storage_slot_warm(test_address, slot));
}

test "AccessList - custom configuration" {
    const CustomConfig = AccessListConfig{
        .cold_account_access_cost = 5000,
        .warm_account_access_cost = 200,
        .cold_sload_cost = 4000,
        .warm_sload_cost = 150,
        .SlotType = u128,
    };

    const CustomAccessList = createAccessList(CustomConfig);
    var access_list = CustomAccessList.init(testing.allocator);
    defer access_list.deinit();

    const test_address = Address{ .bytes = @as([20]u8, @splat(1)) };
    const slot: u128 = 42;

    // Test custom gas costs
    try testing.expectEqual(@as(u64, 5000), try access_list.access_address(test_address));
    try testing.expectEqual(@as(u64, 200), try access_list.access_address(test_address));

    try testing.expectEqual(@as(u64, 4000), try access_list.access_storage_slot(test_address, slot));
    try testing.expectEqual(@as(u64, 150), try access_list.access_storage_slot(test_address, slot));
}

test "EIP-2929: correct gas costs" {
    // Verify that gas constants match EIP-2929 specification
    try testing.expectEqual(@as(u64, 2600), GasConstants.ColdAccountAccessCost);
    try testing.expectEqual(@as(u64, 100), GasConstants.WarmStorageReadCost);
    try testing.expectEqual(@as(u64, 2100), GasConstants.ColdSloadCost);
    try testing.expectEqual(@as(u64, 100), GasConstants.WarmStorageReadCost);
}

test "AccessList - memory stress test with many addresses" {
    var access_list = AccessList.init(testing.allocator);
    defer access_list.deinit();

    // Test with many unique addresses to stress hash map
    var addresses: [1000]Address = undefined;
    for (0..1000) |i| {
        std.mem.writeInt(u160, &addresses[i].bytes, @intCast(i + 1), .big);
        const cost = try access_list.access_address(addresses[i]);
        try testing.expectEqual(AccessList.COLD_ACCOUNT_ACCESS_COST, cost);
    }

    // Verify all are warm
    for (addresses) |addr| {
        try testing.expect(access_list.is_address_warm(addr));
        const cost = try access_list.access_address(addr);
        try testing.expectEqual(AccessList.WARM_ACCOUNT_ACCESS_COST, cost);
    }
}

test "AccessList - memory stress test with many storage slots" {
    var access_list = AccessList.init(testing.allocator);
    defer access_list.deinit();

    const test_address = Address{ .bytes = @as([20]u8, @splat(1)) };

    // Test with many unique storage slots
    for (0..1000) |i| {
        const slot: u256 = @intCast(i);
        const cost = try access_list.access_storage_slot(test_address, slot);
        try testing.expectEqual(AccessList.COLD_SLOAD_COST, cost);
    }

    // Verify all slots are warm
    for (0..1000) |i| {
        const slot: u256 = @intCast(i);
        try testing.expect(access_list.is_storage_slot_warm(test_address, slot));
        const cost = try access_list.access_storage_slot(test_address, slot);
        try testing.expectEqual(AccessList.WARM_SLOAD_COST, cost);
    }
}

test "AccessList - boundary values for storage slots" {
    var access_list = AccessList.init(testing.allocator);
    defer access_list.deinit();

    const test_address = Address{ .bytes = @as([20]u8, @splat(1)) };

    // Test boundary values
    const boundary_slots = [_]u256{ 0, 1, std.math.maxInt(u8), std.math.maxInt(u16), std.math.maxInt(u32), std.math.maxInt(u64), std.math.maxInt(u128), std.math.maxInt(u256) };

    for (boundary_slots) |slot| {
        // First access should be cold
        const cold_cost = try access_list.access_storage_slot(test_address, slot);
        try testing.expectEqual(AccessList.COLD_SLOAD_COST, cold_cost);

        // Second access should be warm
        const warm_cost = try access_list.access_storage_slot(test_address, slot);
        try testing.expectEqual(AccessList.WARM_SLOAD_COST, warm_cost);

        try testing.expect(access_list.is_storage_slot_warm(test_address, slot));
    }
}

test "AccessList - duplicate pre-warming should not affect behavior" {
    var access_list = AccessList.init(testing.allocator);
    defer access_list.deinit();

    const addresses = [_]Address{
        Address{ .bytes = @as([20]u8, @splat(1)) },
        Address{ .bytes = @as([20]u8, @splat(2)) },
    };

    // Pre-warm once
    try access_list.pre_warm_addresses(&addresses);

    // All should be warm
    for (addresses) |address| {
        try testing.expect(access_list.is_address_warm(address));
    }

    // Pre-warm again with overlapping addresses
    const overlapping_addresses = [_]Address{
        Address{ .bytes = @as([20]u8, @splat(2)) },
        Address{ .bytes = @as([20]u8, @splat(3)) },
    };

    try access_list.pre_warm_addresses(&overlapping_addresses);

    // Verify behavior is still correct
    try testing.expect(access_list.is_address_warm(Address{ .bytes = @as([20]u8, @splat(1)) }));
    try testing.expect(access_list.is_address_warm(Address{ .bytes = @as([20]u8, @splat(2)) }));
    try testing.expect(access_list.is_address_warm(Address{ .bytes = @as([20]u8, @splat(3)) }));

    // All should return warm access cost
    for ([_]Address{
        Address{ .bytes = @as([20]u8, @splat(1)) },
        Address{ .bytes = @as([20]u8, @splat(2)) },
        Address{ .bytes = @as([20]u8, @splat(3)) },
    }) |address| {
        const cost = try access_list.access_address(address);
        try testing.expectEqual(AccessList.WARM_ACCOUNT_ACCESS_COST, cost);
    }
}

test "AccessList - storage slot collision resistance" {
    var access_list = AccessList.init(testing.allocator);
    defer access_list.deinit();

    const address1 = Address{ .bytes = @as([20]u8, @splat(1)) };
    const address2 = Address{ .bytes = @as([20]u8, @splat(2)) };
    const slot: u256 = 42;

    // Access same slot on different addresses
    const cost1 = try access_list.access_storage_slot(address1, slot);
    try testing.expectEqual(AccessList.COLD_SLOAD_COST, cost1);

    const cost2 = try access_list.access_storage_slot(address2, slot);
    try testing.expectEqual(AccessList.COLD_SLOAD_COST, cost2);

    // Both should be warm for their respective addresses
    try testing.expect(access_list.is_storage_slot_warm(address1, slot));
    try testing.expect(access_list.is_storage_slot_warm(address2, slot));

    // But not warm for different combinations
    try testing.expect(!access_list.is_storage_slot_warm(address1, slot + 1));
    try testing.expect(!access_list.is_storage_slot_warm(address2, slot + 1));
}

test "AccessList - clear preserves capacity" {
    var access_list = AccessList.init(testing.allocator);
    defer access_list.deinit();

    // Fill with many entries to grow internal capacity
    for (0..100) |i| {
        var address = Address{ .bytes = @as([20]u8, @splat(0)) };
        std.mem.writeInt(u160, &address.bytes, @intCast(i + 1), .big);
        _ = try access_list.access_address(address);
        _ = try access_list.access_storage_slot(address, @intCast(i));
    }

    // Check that many entries are warm
    var fiftieth = Address{ .bytes = @as([20]u8, @splat(0)) };
    std.mem.writeInt(u160, &fiftieth.bytes, 50, .big);
    try testing.expect(access_list.is_address_warm(fiftieth));

    // Clear should preserve capacity but remove entries
    access_list.clear();

    // All entries should be cold again
    try testing.expect(!access_list.is_address_warm(fiftieth));

    // But accessing new entries should still work efficiently
    const new_address = Address{ .bytes = @as([20]u8, @splat(0xFF)) };
    const cost = try access_list.access_address(new_address);
    try testing.expectEqual(AccessList.COLD_ACCOUNT_ACCESS_COST, cost);
}

test "AccessList - zero address handling" {
    var access_list = AccessList.init(testing.allocator);
    defer access_list.deinit();

    const zero_address = Address{ .bytes = @as([20]u8, @splat(0)) };

    // Zero address should behave like any other address
    const cost1 = try access_list.access_address(zero_address);
    try testing.expectEqual(AccessList.COLD_ACCOUNT_ACCESS_COST, cost1);

    const cost2 = try access_list.access_address(zero_address);
    try testing.expectEqual(AccessList.WARM_ACCOUNT_ACCESS_COST, cost2);

    try testing.expect(access_list.is_address_warm(zero_address));

    // Storage slots on zero address should also work
    const slot_cost1 = try access_list.access_storage_slot(zero_address, 0);
    try testing.expectEqual(AccessList.COLD_SLOAD_COST, slot_cost1);

    const slot_cost2 = try access_list.access_storage_slot(zero_address, 0);
    try testing.expectEqual(AccessList.WARM_SLOAD_COST, slot_cost2);
}

test "AccessList - custom config validation" {
    // Test configuration with different slot type
    const Config64 = AccessListConfig{
        .cold_account_access_cost = 1000,
        .warm_account_access_cost = 50,
        .cold_sload_cost = 800,
        .warm_sload_cost = 25,
        .SlotType = u64,
    };

    const AccessList64 = createAccessList(Config64);
    var access_list = AccessList64.init(testing.allocator);
    defer access_list.deinit();

    const test_address = Address{ .bytes = @as([20]u8, @splat(1)) };
    const slot: u64 = std.math.maxInt(u64);

    // Test with u64 slot type
    try testing.expectEqual(@as(u64, 1000), try access_list.access_address(test_address));
    try testing.expectEqual(@as(u64, 50), try access_list.access_address(test_address));

    try testing.expectEqual(@as(u64, 800), try access_list.access_storage_slot(test_address, slot));
    try testing.expectEqual(@as(u64, 25), try access_list.access_storage_slot(test_address, slot));
}

test "AccessList - empty pre-warm list" {
    var access_list = AccessList.init(testing.allocator);
    defer access_list.deinit();

    const empty_addresses: []const Address = &.{};

    // Should not crash with empty slice
    try access_list.pre_warm_addresses(empty_addresses);

    // State should remain unchanged
    const test_address = Address{ .bytes = @as([20]u8, @splat(1)) };
    try testing.expect(!access_list.is_address_warm(test_address));

    const cost = try access_list.access_address(test_address);
    try testing.expectEqual(AccessList.COLD_ACCOUNT_ACCESS_COST, cost);
}

test "AccessList - revert forgets only what was warmed after the checkpoint" {
    var access_list = AccessList.init(testing.allocator);
    defer access_list.deinit();

    const kept = Address{ .bytes = @as([20]u8, @splat(1)) };
    const dropped = Address{ .bytes = @as([20]u8, @splat(2)) };
    _ = try access_list.access_address(kept);
    _ = try access_list.access_storage_slot(kept, 7);

    const mark = access_list.checkpoint();
    _ = try access_list.access_address(dropped);
    _ = try access_list.access_storage_slot(kept, 8);
    _ = try access_list.access_storage_slot(dropped, 7);
    access_list.revert(mark);

    try testing.expect(access_list.is_address_warm(kept));
    try testing.expect(access_list.is_storage_slot_warm(kept, 7));
    try testing.expect(!access_list.is_address_warm(dropped));
    try testing.expect(!access_list.is_storage_slot_warm(kept, 8));
    try testing.expect(!access_list.is_storage_slot_warm(dropped, 7));
    // A reverted entry is cold again, and warming it again works.
    try testing.expectEqual(AccessList.COLD_ACCOUNT_ACCESS_COST, try access_list.access_address(dropped));
    try testing.expectEqual(AccessList.WARM_ACCOUNT_ACCESS_COST, try access_list.access_address(dropped));
}
