const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
const AccessListConfig = @import("access_list_config.zig").AccessListConfig;

/// Create an AccessList type with the given configuration
pub fn createAccessList(comptime config: AccessListConfig) type {
    comptime config.validate();

    return struct {
        const Self = @This();
        /// Warm addresses - addresses that have been accessed
        /// Using ArrayHashMap for better cache locality
        addresses: std.array_hash_map.ArrayHashMap(Address, void, std.array_hash_map.AutoContext(Address), false),
        /// Warm storage slots - storage slots that have been accessed
        /// Using ArrayHashMap for better cache locality
        storage_slots: std.array_hash_map.ArrayHashMap(StorageKey, void, StorageKeyContext, false),

        // Gas costs from configuration
        pub const COLD_ACCOUNT_ACCESS_COST: u64 = config.cold_account_access_cost;
        pub const WARM_ACCOUNT_ACCESS_COST: u64 = config.warm_account_access_cost;
        pub const COLD_SLOAD_COST: u64 = config.cold_sload_cost;
        pub const WARM_SLOAD_COST: u64 = config.warm_sload_cost;

        const StorageKey = struct {
            address: Address,
            slot: config.SlotType,
        };

        const StorageKeyContext = struct {
            pub fn hash(self: @This(), key: StorageKey) u32 {
                _ = self;
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(&key.address.bytes);
                hasher.update(std.mem.asBytes(&key.slot));
                return @truncate(hasher.final());
            }

            pub fn eql(self: @This(), a: StorageKey, b: StorageKey, b_index: usize) bool {
                _ = self;
                _ = b_index;
                return std.mem.eql(u8, &a.address.bytes, &b.address.bytes) and a.slot == b.slot;
            }
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .addresses = std.array_hash_map.ArrayHashMap(Address, void, std.array_hash_map.AutoContext(Address), false).init(allocator),
                .storage_slots = std.array_hash_map.ArrayHashMap(StorageKey, void, StorageKeyContext, false).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.addresses.deinit();
            self.storage_slots.deinit();
        }

        /// Clear all access lists for a new transaction
        pub fn clear(self: *Self) void {
            self.addresses.clearRetainingCapacity();
            self.storage_slots.clearRetainingCapacity();
        }

        /// Mark an address as accessed and return the gas cost
        /// Returns COLD_ACCOUNT_ACCESS_COST if first access, WARM_ACCOUNT_ACCESS_COST if already accessed
        pub fn access_address(self: *Self, address: Address) !u64 {
            const result = try self.addresses.getOrPut(address);
            if (result.found_existing) {
                return WARM_ACCOUNT_ACCESS_COST;
            }
            return COLD_ACCOUNT_ACCESS_COST;
        }

        /// Mark a storage slot as accessed and return the gas cost
        /// Returns COLD_SLOAD_COST if first access, WARM_SLOAD_COST if already accessed
        pub fn access_storage_slot(self: *Self, address: Address, slot: config.SlotType) !u64 {
            const key = StorageKey{ .address = address, .slot = slot };
            const result = try self.storage_slots.getOrPut(key);
            if (result.found_existing) {
                return WARM_SLOAD_COST;
            }
            return COLD_SLOAD_COST;
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
                const result = try self.addresses.getOrPut(address);
                // Ensure the compiler doesn't optimize away the operation
                std.mem.doNotOptimizeAway(&result);
            }
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

    const test_address = Address{ .bytes = [_]u8{1} ** 20 };

    // First access should be cold
    const cost1 = try access_list.access_address(test_address);
    try testing.expectEqual(AccessList.COLD_ACCOUNT_ACCESS_COST, cost1);

    // Second access should be warm
    const cost2 = try access_list.access_address(test_address);
    try testing.expectEqual(AccessList.WARM_ACCOUNT_ACCESS_COST, cost2);

    // Check warmth
    try testing.expect(access_list.is_address_warm(test_address));

    const cold_address = Address{ .bytes = [_]u8{2} ** 20 };
    try testing.expect(!access_list.is_address_warm(cold_address));
}

test "AccessList - storage slot access tracking" {
    var access_list = AccessList.init(testing.allocator);
    defer access_list.deinit();

    const test_address = Address{ .bytes = [_]u8{1} ** 20 };
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
        Address{ .bytes = [_]u8{1} ** 20 },
        Address{ .bytes = [_]u8{2} ** 20 },
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

    const test_address = Address{ .bytes = [_]u8{1} ** 20 };
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

    const test_address = Address{ .bytes = [_]u8{1} ** 20 };
    const slot: u128 = 42;

    // Test custom gas costs
    try testing.expectEqual(@as(u64, 5000), try access_list.access_address(test_address));
    try testing.expectEqual(@as(u64, 200), try access_list.access_address(test_address));

    try testing.expectEqual(@as(u64, 4000), try access_list.access_storage_slot(test_address, slot));
    try testing.expectEqual(@as(u64, 150), try access_list.access_storage_slot(test_address, slot));
}

// Tests from access_list_test.zig
const ZERO_ADDRESS = Address{ .bytes = [_]u8{0} ** 20 };
const TEST_ADDRESS_1 = Address{ .bytes = [_]u8{1} ** 20 };
const TEST_ADDRESS_2 = Address{ .bytes = [_]u8{2} ** 20 };
const TEST_ADDRESS_3 = Address{ .bytes = [_]u8{3} ** 20 };

test "EIP-2929: warm/cold access - BALANCE opcode gas costs" {
    const allocator = testing.allocator;

    var db = @import("database.zig").Database.init(allocator);
    defer db.deinit();

    const block_info = @import("../block/block_info.zig").DefaultBlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .base_fee = 10,
        .coinbase = ZERO_ADDRESS,
        .prev_randao = [_]u8{1} ** 32,
    };

    const tx_context = @import("../block/transaction_context.zig").TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
        .blob_versioned_hashes = &.{},
        .blob_base_fee = 0,
    };

    var evm = try @import("../evm.zig").Evm(.{}).init(allocator, &db, block_info, tx_context, 20, TEST_ADDRESS_1, .BERLIN);
    defer evm.deinit();

    // Set up test accounts with balances
    const account1: @import("database_interface_account.zig").Account = .{
        .nonce = 0,
        .balance = 1000,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(TEST_ADDRESS_2.bytes, account1);

    // Test first access (cold) to an address
    const cold_cost = try evm.access_address(TEST_ADDRESS_2);
    try testing.expectEqual(GasConstants.ColdAccountAccessCost, cold_cost);

    // Test second access (warm) to the same address
    const warm_cost = try evm.access_address(TEST_ADDRESS_2);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, warm_cost);
}

test "EIP-2929: warm/cold access - SLOAD opcode gas costs" {
    const allocator = testing.allocator;

    var db = @import("database.zig").Database.init(allocator);
    defer db.deinit();

    const block_info = @import("../block/block_info.zig").DefaultBlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .base_fee = 10,
        .coinbase = ZERO_ADDRESS,
        .prev_randao = [_]u8{1} ** 32,
    };

    const tx_context = @import("../block/transaction_context.zig").TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
        .blob_versioned_hashes = &.{},
        .blob_base_fee = 0,
    };

    var evm = try @import("../evm.zig").Evm(.{}).init(allocator, &db, block_info, tx_context, 20, TEST_ADDRESS_1, .BERLIN);
    defer evm.deinit();

    const slot: u256 = 42;

    // Test first access (cold) to a storage slot
    const cold_cost = try evm.access_storage_slot(TEST_ADDRESS_2, slot);
    try testing.expectEqual(GasConstants.ColdSloadCost, cold_cost);

    // Test second access (warm) to the same storage slot
    const warm_cost = try evm.access_storage_slot(TEST_ADDRESS_2, slot);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, warm_cost);
}

test "EIP-2929: transaction pre-warming" {
    const allocator = testing.allocator;

    var db = @import("database.zig").Database.init(allocator);
    defer db.deinit();

    const block_info = @import("../block/block_info.zig").DefaultBlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .base_fee = 10,
        .coinbase = TEST_ADDRESS_3,
        .prev_randao = [_]u8{1} ** 32,
    };

    const tx_context = @import("../block/transaction_context.zig").TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
        .blob_versioned_hashes = &.{},
        .blob_base_fee = 0,
    };

    var evm = try @import("../evm.zig").Evm(.{}).init(allocator, &db, block_info, tx_context, 20, TEST_ADDRESS_1, .BERLIN);
    defer evm.deinit();

    // Pre-warm addresses as per EIP-2929
    try evm.access_list.pre_warm_addresses(&[_]Address{
        TEST_ADDRESS_1, // tx.origin
        TEST_ADDRESS_2, // target
        TEST_ADDRESS_3, // coinbase
    });

    // All pre-warmed addresses should have warm access cost
    const origin_cost = try evm.access_address(TEST_ADDRESS_1);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, origin_cost);

    const target_cost = try evm.access_address(TEST_ADDRESS_2);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, target_cost);

    const coinbase_cost = try evm.access_address(TEST_ADDRESS_3);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, coinbase_cost);
}

test "EIP-2929: SELFBALANCE always warm" {
    const allocator = testing.allocator;

    var db = @import("database.zig").Database.init(allocator);
    defer db.deinit();

    const block_info = @import("../block/block_info.zig").DefaultBlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .base_fee = 10,
        .coinbase = ZERO_ADDRESS,
        .prev_randao = [_]u8{1} ** 32,
    };

    const tx_context = @import("../block/transaction_context.zig").TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
        .blob_versioned_hashes = &.{},
        .blob_base_fee = 0,
    };

    var evm = try @import("../evm.zig").Evm(.{}).init(allocator, &db, block_info, tx_context, 20, TEST_ADDRESS_1, .BERLIN);
    defer evm.deinit();

    // Deploy contract
    const contract_address = TEST_ADDRESS_2;
    const bytecode = [_]u8{ 0x47, 0x00 }; // SELFBALANCE, STOP
    const code_hash = try db.set_code(&bytecode);
    const Account = @import("database_interface_account.zig").Account;
    const acct = Account{
        .nonce = 0,
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    try db.set_account(contract_address.bytes, acct);

    // Pre-warm the contract address (as would happen during CALL)
    try evm.access_list.pre_warm_addresses(&[_]Address{contract_address});

    // Contract's own address should always be warm
    const self_cost = try evm.access_address(contract_address);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, self_cost);
}

test "EIP-2929: access list cleared between transactions" {
    const allocator = testing.allocator;

    var db = @import("database.zig").Database.init(allocator);
    defer db.deinit();

    const block_info = @import("../block/block_info.zig").DefaultBlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .base_fee = 10,
        .coinbase = ZERO_ADDRESS,
        .prev_randao = [_]u8{1} ** 32,
    };

    const tx_context = @import("../block/transaction_context.zig").TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
        .blob_versioned_hashes = &.{},
        .blob_base_fee = 0,
    };

    var evm = try @import("../evm.zig").Evm(.{}).init(allocator, &db, block_info, tx_context, 20, TEST_ADDRESS_1, .BERLIN);
    defer evm.deinit();

    // Access an address to warm it
    _ = try evm.access_address(TEST_ADDRESS_2);
    try testing.expect(evm.access_list.is_address_warm(TEST_ADDRESS_2));

    // Clear access list (simulating new transaction)
    evm.access_list.clear();

    // Address should be cold again
    try testing.expect(!evm.access_list.is_address_warm(TEST_ADDRESS_2));
    const cost = try evm.access_address(TEST_ADDRESS_2);
    try testing.expectEqual(GasConstants.ColdAccountAccessCost, cost);
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
        addresses[i] = Address{ .bytes = std.mem.toBytes(@as(u160, @intCast(i + 1))) };
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

    const test_address = Address{ .bytes = [_]u8{1} ** 20 };

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

    const test_address = Address{ .bytes = [_]u8{1} ** 20 };

    // Test boundary values
    const boundary_slots = [_]u256{ 
        0, 
        1, 
        std.math.maxInt(u8),
        std.math.maxInt(u16), 
        std.math.maxInt(u32),
        std.math.maxInt(u64),
        std.math.maxInt(u128),
        std.math.maxInt(u256) 
    };

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
        Address{ .bytes = [_]u8{1} ** 20 },
        Address{ .bytes = [_]u8{2} ** 20 },
    };

    // Pre-warm once
    try access_list.pre_warm_addresses(&addresses);

    // All should be warm
    for (addresses) |address| {
        try testing.expect(access_list.is_address_warm(address));
    }

    // Pre-warm again with overlapping addresses
    const overlapping_addresses = [_]Address{
        Address{ .bytes = [_]u8{2} ** 20 },
        Address{ .bytes = [_]u8{3} ** 20 },
    };

    try access_list.pre_warm_addresses(&overlapping_addresses);

    // Verify behavior is still correct
    try testing.expect(access_list.is_address_warm(Address{ .bytes = [_]u8{1} ** 20 }));
    try testing.expect(access_list.is_address_warm(Address{ .bytes = [_]u8{2} ** 20 }));
    try testing.expect(access_list.is_address_warm(Address{ .bytes = [_]u8{3} ** 20 }));

    // All should return warm access cost
    for ([_]Address{
        Address{ .bytes = [_]u8{1} ** 20 },
        Address{ .bytes = [_]u8{2} ** 20 },
        Address{ .bytes = [_]u8{3} ** 20 },
    }) |address| {
        const cost = try access_list.access_address(address);
        try testing.expectEqual(AccessList.WARM_ACCOUNT_ACCESS_COST, cost);
    }
}

test "AccessList - storage slot collision resistance" {
    var access_list = AccessList.init(testing.allocator);
    defer access_list.deinit();

    const address1 = Address{ .bytes = [_]u8{1} ** 20 };
    const address2 = Address{ .bytes = [_]u8{2} ** 20 };
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
        const address = Address{ .bytes = std.mem.toBytes(@as(u160, @intCast(i + 1))) };
        _ = try access_list.access_address(address);
        _ = try access_list.access_storage_slot(address, @intCast(i));
    }

    // Check that many entries are warm
    try testing.expect(access_list.is_address_warm(Address{ .bytes = std.mem.toBytes(@as(u160, 50)) ++ [_]u8{0} ** 12 }));

    // Clear should preserve capacity but remove entries
    access_list.clear();

    // All entries should be cold again
    try testing.expect(!access_list.is_address_warm(Address{ .bytes = std.mem.toBytes(@as(u160, 50)) ++ [_]u8{0} ** 12 }));

    // But accessing new entries should still work efficiently
    const new_address = Address{ .bytes = [_]u8{0xFF} ** 20 };
    const cost = try access_list.access_address(new_address);
    try testing.expectEqual(AccessList.COLD_ACCOUNT_ACCESS_COST, cost);
}

test "AccessList - zero address handling" {
    var access_list = AccessList.init(testing.allocator);
    defer access_list.deinit();

    const zero_address = Address{ .bytes = [_]u8{0} ** 20 };

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

    const test_address = Address{ .bytes = [_]u8{1} ** 20 };
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
    const test_address = Address{ .bytes = [_]u8{1} ** 20 };
    try testing.expect(!access_list.is_address_warm(test_address));
    
    const cost = try access_list.access_address(test_address);
    try testing.expectEqual(AccessList.COLD_ACCOUNT_ACCESS_COST, cost);
}

// Tests from eip_2929_test.zig
const Evm = @import("../evm.zig").Evm;
const Database = @import("database.zig").Database;
const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
const BlockInfo = @import("../block/block_info.zig").DefaultBlockInfo;
const TransactionContext = @import("../block/transaction_context.zig").TransactionContext;
const Hardfork = @import("../eips_and_hardforks/hardfork.zig").Hardfork;
// const FrameInterpreter = @import("../evm/frame_interpreter.zig").FrameInterpreter;

test "EIP-2929 - SLOAD multiple slots warm/cold pattern" {
    return error.SkipZigTest; // TODO: Update to use new architecture

    //     return error.SkipZigTest; // TODO: Update this test to use the new architecture
    //     const allocator = testing.allocator;

    //     var db = Database.init(allocator);
    //     defer db.deinit();

    //     const block_info = BlockInfo.init();
    //     const context = TransactionContext{
    //         .gas_limit = 1_000_000,
    //         .coinbase = ZERO_ADDRESS,
    //         .chain_id = 1,
    //     };

    //     var evm = try Evm(.{}).init(allocator, &db, block_info, context, 0, ZERO_ADDRESS, Hardfork.BERLIN);
    //     defer evm.deinit();

    //     const contract_address = Address{ .bytes = [_]u8{0x12} ** 20 };

    //     // Test multiple slots
    //     const slots = [_]u256{ 0, 1, 100, 0xFFFF, std.math.maxInt(u256) };

    //     // First access to each slot should be cold
    //     for (slots) |slot| {
    //         const cost = try evm.access_storage_slot(contract_address, slot);
    //         try testing.expectEqual(GasConstants.ColdSloadCost, cost);
    //     }

    //     // Second access to each slot should be warm
    //     for (slots) |slot| {
    //         const cost = try evm.access_storage_slot(contract_address, slot);
    //         try testing.expectEqual(GasConstants.WarmStorageReadCost, cost);
    //     }

    //     // Access a new slot - should be cold
    //     const new_slot_cost = try evm.access_storage_slot(contract_address, 0xDEADBEEF);
    //     try testing.expectEqual(GasConstants.ColdSloadCost, new_slot_cost);
}

test "EIP-2929 - SSTORE warm/cold access patterns" {
    // TODO: Update to use new architecture
    return error.SkipZigTest;
}

test "EIP-2929 - Cross-opcode warm address sharing" {
    const allocator = testing.allocator;

    var db = Database.init(allocator);
    defer db.deinit();

    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(allocator, &db, block_info, context, 0, ZERO_ADDRESS, Hardfork.BERLIN);
    defer evm.deinit();

    const test_address = Address{ .bytes = [_]u8{0xAB} ** 20 };

    // BALANCE accesses the address - should be cold
    const balance_cost = try evm.access_address(test_address);
    try testing.expectEqual(GasConstants.ColdAccountAccessCost, balance_cost);

    // EXTCODESIZE on same address - should be warm
    const codesize_cost = try evm.access_address(test_address);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, codesize_cost);

    // EXTCODECOPY on same address - should still be warm
    const codecopy_cost = try evm.access_address(test_address);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, codecopy_cost);

    // EXTCODEHASH on same address - should still be warm
    const codehash_cost = try evm.access_address(test_address);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, codehash_cost);
}

test "EIP-2929 - CALL warm/cold recipient costs" {
    const allocator = testing.allocator;

    var db = Database.init(allocator);
    defer db.deinit();

    // Set up accounts with balance for calls
    const caller_address = Address{ .bytes = [_]u8{0x01} ** 20 };
    const recipient1 = Address{ .bytes = [_]u8{0x02} ** 20 };
    const recipient2 = Address{ .bytes = [_]u8{0x03} ** 20 };

    try db.set_account(caller_address.bytes, .{
        .nonce = 0,
        .balance = 1_000_000_000_000_000_000, // 1 ETH
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    try db.set_account(recipient1.bytes, .{
        .nonce = 0,
        .balance = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 10_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(allocator, &db, block_info, context, 0, caller_address, Hardfork.BERLIN);
    defer evm.deinit();

    // First CALL to recipient1 - should include cold access cost
    const cold_call_cost = try evm.access_address(recipient1);
    try testing.expectEqual(GasConstants.ColdAccountAccessCost, cold_call_cost);

    // Second CALL to recipient1 - should be warm
    const warm_call_cost = try evm.access_address(recipient1);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, warm_call_cost);

    // CALL to new recipient2 - should be cold
    const new_call_cost = try evm.access_address(recipient2);
    try testing.expectEqual(GasConstants.ColdAccountAccessCost, new_call_cost);
}

test "EIP-2929 - Self-referential operations (BALANCE on self)" {
    const allocator = testing.allocator;

    var db = Database.init(allocator);
    defer db.deinit();

    const contract_address = Address{ .bytes = [_]u8{0x42} ** 20 };
    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(allocator, &db, block_info, context, 0, contract_address, Hardfork.BERLIN);
    defer evm.deinit();

    // Contract accessing its own address - first access should still be cold
    const self_access_cost = try evm.access_address(contract_address);
    try testing.expectEqual(GasConstants.ColdAccountAccessCost, self_access_cost);

    // Second self-access should be warm
    const self_access_warm = try evm.access_address(contract_address);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, self_access_warm);
}

test "EIP-2929 - Precompiled contract access costs" {
    const allocator = testing.allocator;

    var db = Database.init(allocator);
    defer db.deinit();

    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(allocator, &db, block_info, context, 0, ZERO_ADDRESS, Hardfork.BERLIN);
    defer evm.deinit();

    // Precompiled contracts are at addresses 0x01 through 0x09
    const precompile_addresses = [_]Address{
        Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x01} }, // ecrecover
        Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x02} }, // sha256
        Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x03} }, // ripemd160
        Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x04} }, // identity
        Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x05} }, // modexp
        Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x06} }, // ecadd
        Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x07} }, // ecmul
        Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x08} }, // ecpairing
        Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x09} }, // blake2f
    };

    // Precompiles should follow same warm/cold rules
    for (precompile_addresses) |addr| {
        const cold_cost = try evm.access_address(addr);
        try testing.expectEqual(GasConstants.ColdAccountAccessCost, cold_cost);

        const warm_cost = try evm.access_address(addr);
        try testing.expectEqual(GasConstants.WarmStorageReadCost, warm_cost);
    }
}

test "EIP-2929 - Storage slots with maximum values" {
    const allocator = testing.allocator;

    var db = Database.init(allocator);
    defer db.deinit();

    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm = try Evm(.{}).init(allocator, &db, block_info, context, 0, ZERO_ADDRESS, Hardfork.BERLIN);
    defer evm.deinit();

    const contract_address = Address{ .bytes = [_]u8{0xEE} ** 20 };

    // Test with maximum u256 slot
    const max_slot = std.math.maxInt(u256);
    const max_slot_cold = try evm.access_storage_slot(contract_address, max_slot);
    try testing.expectEqual(GasConstants.ColdSloadCost, max_slot_cold);

    const max_slot_warm = try evm.access_storage_slot(contract_address, max_slot);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, max_slot_warm);

    // Test adjacent slot is still cold
    const adjacent_slot = max_slot - 1;
    const adjacent_cold = try evm.access_storage_slot(contract_address, adjacent_slot);
    try testing.expectEqual(GasConstants.ColdSloadCost, adjacent_cold);
}
