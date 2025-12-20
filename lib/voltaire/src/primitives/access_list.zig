const std = @import("std");
const testing = std.testing;
const address = @import("address.zig");
const crypto_pkg = @import("crypto");
const hash = crypto_pkg.Hash;
const rlp = @import("rlp.zig");
const Address = address.Address;
const Hash = hash.Hash;
const Allocator = std.mem.Allocator;

// EIP-2930 Access List
pub const AccessListEntry = struct {
    address: Address,
    storage_keys: []const Hash,
};

pub const AccessList = []const AccessListEntry;

// Access list gas costs
pub const ACCESS_LIST_ADDRESS_COST = 2400;
pub const ACCESS_LIST_STORAGE_KEY_COST = 1900;
pub const COLD_ACCOUNT_ACCESS_COST = 2600;
pub const COLD_STORAGE_ACCESS_COST = 2100;
pub const WARM_STORAGE_ACCESS_COST = 100;

// Access list error types
pub const AccessListError = error{
    OutOfMemory,
};

// Calculate total gas cost for access list
pub fn calculateAccessListGasCost(accessList: AccessList) u64 {
    var totalCost: u64 = 0;

    for (accessList) |entry| {
        // Cost per address
        totalCost += ACCESS_LIST_ADDRESS_COST;

        // Cost per storage key
        totalCost += ACCESS_LIST_STORAGE_KEY_COST * entry.storage_keys.len;
    }

    return totalCost;
}

// Check if address is in access list
pub fn isAddressInAccessList(accessList: AccessList, addr: Address) bool {
    for (accessList) |entry| {
        if (entry.address.eql(addr)) {
            return true;
        }
    }
    return false;
}

// Check if storage key is in access list
pub fn isStorageKeyInAccessList(
    accessList: AccessList,
    addr: Address,
    storage_key: Hash,
) bool {
    for (accessList) |entry| {
        if (entry.address.eql(addr)) {
            for (entry.storage_keys) |key| {
                if (key.eql(storage_key)) {
                    return true;
                }
            }
        }
    }
    return false;
}

// RLP encode access list
pub fn encodeAccessList(allocator: Allocator, accessList: AccessList) ![]u8 {
    // First, encode each entry as a list of [address, [storageKeys...]]
    var entries = std.array_list.AlignedManaged([]const u8, null).init(allocator);
    defer {
        for (entries.items) |item| {
            allocator.free(item);
        }
        entries.deinit();
    }

    for (accessList) |entry| {
        // Encode the address
        const encodedAddress = try rlp.encodeBytes(allocator, &entry.address.bytes);
        defer allocator.free(encodedAddress);

        // Encode storage keys
        var encodedKeys = std.array_list.AlignedManaged([]const u8, null).init(allocator);
        defer {
            for (encodedKeys.items) |item| {
                allocator.free(item);
            }
            encodedKeys.deinit();
        }

        for (entry.storage_keys) |key| {
            const encodedKey = try rlp.encodeBytes(allocator, &key.bytes);
            try encodedKeys.append(encodedKey);
        }

        // Encode the list of storage keys
        const keysListEncoded = try rlp.encode(allocator, encodedKeys.items);
        defer allocator.free(keysListEncoded);

        // Create entry as [address, storageKeysList]
        var entryItems = [_][]const u8{ encodedAddress, keysListEncoded };
        const entryEncoded = try rlp.encode(allocator, &entryItems);
        try entries.append(entryEncoded);
    }

    // Encode the entire access list
    return try rlp.encode(allocator, entries.items);
}

// Calculate gas savings from access list
pub fn calculateGasSavings(accessList: AccessList) u64 {
    var savings: u64 = 0;

    for (accessList) |entry| {
        // Save on cold account access
        savings += COLD_ACCOUNT_ACCESS_COST - ACCESS_LIST_ADDRESS_COST;

        // Save on cold storage access
        for (entry.storage_keys) |_| {
            savings += COLD_STORAGE_ACCESS_COST - ACCESS_LIST_STORAGE_KEY_COST;
        }
    }

    return savings;
}

// Deduplicate access list entries
pub fn deduplicateAccessList(
    allocator: Allocator,
    accessList: AccessList,
) ![]AccessListEntry {
    var result = std.array_list.AlignedManaged(AccessListEntry, null).init(allocator);
    defer result.deinit();

    for (accessList) |entry| {
        // Check if address already exists
        var found = false;
        for (result.items) |*existing| {
            if (existing.address.eql(entry.address)) {
                // Merge storage keys
                var keys = std.array_list.AlignedManaged(Hash, null).init(allocator);
                defer keys.deinit();

                // Add existing keys
                try keys.appendSlice(existing.storage_keys);

                // Add new keys if not duplicate
                for (entry.storage_keys) |newKey| {
                    var isDuplicate = false;
                    for (existing.storage_keys) |existingKey| {
                        if (newKey.eql(existingKey)) {
                            isDuplicate = true;
                            break;
                        }
                    }
                    if (!isDuplicate) {
                        try keys.append(newKey);
                    }
                }

                existing.storage_keys = try keys.toOwnedSlice();
                found = true;
                break;
            }
        }

        if (!found) {
            try result.append(.{
                .address = entry.address,
                .storage_keys = try allocator.dupe(Hash, entry.storage_keys),
            });
        }
    }

    return result.toOwnedSlice();
}

// Tests

test "access list gas calculation" {
    _ = testing.allocator;

    const storage_keys = [_]Hash{
        try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000001"),
        try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000002"),
    };

    const accessList = [_]AccessListEntry{
        .{
            .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
            .storage_keys = &storage_keys,
        },
        .{
            .address = try Address.fromHex("0x2222222222222222222222222222222222222222"),
            .storage_keys = &.{},
        },
    };

    const gasCost = calculateAccessListGasCost(&accessList);

    // Expected: 2 addresses * 2400 + 2 storage keys * 1900 = 8600
    try testing.expectEqual(@as(u64, 8600), gasCost);
}

test "access list membership checks" {
    const storage_keys = [_]Hash{
        try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000001"),
        try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000002"),
    };

    const accessList = [_]AccessListEntry{
        .{
            .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
            .storage_keys = &storage_keys,
        },
    };

    // Test address membership
    const addr1 = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const addr2 = try Address.fromHex("0x2222222222222222222222222222222222222222");

    try testing.expect(isAddressInAccessList(&accessList, addr1));
    try testing.expect(!isAddressInAccessList(&accessList, addr2));

    // Test storage key membership
    const key1 = try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000001");
    const key3 = try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000003");

    try testing.expect(isStorageKeyInAccessList(&accessList, addr1, key1));
    try testing.expect(!isStorageKeyInAccessList(&accessList, addr1, key3));
    try testing.expect(!isStorageKeyInAccessList(&accessList, addr2, key1));
}

test "empty access list" {
    const accessList: AccessList = &.{};

    const gasCost = calculateAccessListGasCost(accessList);
    try testing.expectEqual(@as(u64, 0), gasCost);

    const addr = try Address.fromHex("0x1111111111111111111111111111111111111111");
    try testing.expect(!isAddressInAccessList(accessList, addr));
}

test "access list RLP encoding" {
    const allocator = testing.allocator;

    const storage_keys = [_]Hash{
        try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000001"),
    };

    const accessList = [_]AccessListEntry{
        .{
            .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
            .storage_keys = &storage_keys,
        },
    };

    const encoded = try encodeAccessList(allocator, &accessList);
    defer allocator.free(encoded);

    // Should produce valid RLP
    try testing.expect(encoded.len > 0);
    try testing.expect(encoded[0] >= 0xc0); // RLP list prefix
}

test "access list gas savings" {
    const storage_keys = [_]Hash{
        try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000001"),
        try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000002"),
    };

    const accessList = [_]AccessListEntry{
        .{
            .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
            .storage_keys = &storage_keys,
        },
    };

    const savings = calculateGasSavings(&accessList);

    // Expected savings:
    // Account: 2600 - 2400 = 200
    // Storage keys: 2 * (2100 - 1900) = 400
    // Total: 600
    try testing.expectEqual(@as(u64, 600), savings);
}

test "complex access list" {
    const allocator = testing.allocator;

    // Multiple addresses with varying storage keys
    const keys1 = [_]Hash{
        try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000001"),
        try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000002"),
        try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000003"),
    };

    const keys2 = [_]Hash{
        try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000004"),
    };

    const accessList = [_]AccessListEntry{
        .{
            .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
            .storage_keys = &keys1,
        },
        .{
            .address = try Address.fromHex("0x2222222222222222222222222222222222222222"),
            .storage_keys = &keys2,
        },
        .{
            .address = try Address.fromHex("0x3333333333333333333333333333333333333333"),
            .storage_keys = &.{}, // No storage keys
        },
    };

    const gasCost = calculateAccessListGasCost(&accessList);

    // Expected:
    // 3 addresses * 2400 = 7200
    // 4 storage keys * 1900 = 7600
    // Total: 14800
    try testing.expectEqual(@as(u64, 14800), gasCost);

    // Test encoding
    const encoded = try encodeAccessList(allocator, &accessList);
    defer allocator.free(encoded);

    try testing.expect(encoded.len > 0);
}

test "deduplicate access list" {
    const allocator = testing.allocator;

    const keys1 = [_]Hash{
        try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000001"),
        try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000002"),
    };

    const keys2 = [_]Hash{
        try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000002"), // Duplicate
        try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000003"),
    };

    const accessList = [_]AccessListEntry{
        .{
            .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
            .storage_keys = &keys1,
        },
        .{
            .address = try Address.fromHex("0x1111111111111111111111111111111111111111"), // Same address
            .storage_keys = &keys2,
        },
    };

    const deduped = try deduplicateAccessList(allocator, &accessList);
    defer {
        for (deduped) |entry| {
            allocator.free(entry.storage_keys);
        }
        allocator.free(deduped);
    }

    // Should have one entry with three unique keys
    try testing.expectEqual(@as(usize, 1), deduped.len);
    try testing.expectEqual(@as(usize, 3), deduped[0].storage_keys.len);
}

// Additional edge case tests for access list

test "access list with single address no storage keys" {
    const allocator = testing.allocator;

    const accessList = [_]AccessListEntry{
        .{
            .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
            .storage_keys = &.{},
        },
    };

    // Gas cost should only include address cost
    const gasCost = calculateAccessListGasCost(&accessList);
    try testing.expectEqual(@as(u64, ACCESS_LIST_ADDRESS_COST), gasCost);

    // Should still encode properly
    const encoded = try encodeAccessList(allocator, &accessList);
    defer allocator.free(encoded);
    try testing.expect(encoded.len > 0);
}

test "access list membership with non-existent address" {
    const storage_keys = [_]Hash{
        try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000001"),
    };

    const accessList = [_]AccessListEntry{
        .{
            .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
            .storage_keys = &storage_keys,
        },
    };

    const non_existent = try Address.fromHex("0x9999999999999999999999999999999999999999");
    const key = try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000001");

    // Address not in list
    try testing.expect(!isAddressInAccessList(&accessList, non_existent));

    // Storage key should not be found for non-existent address
    try testing.expect(!isStorageKeyInAccessList(&accessList, non_existent, key));
}

test "access list with maximum practical size" {
    const allocator = testing.allocator;

    // Create a large access list (100 addresses with 10 keys each)
    var entries = try allocator.alloc(AccessListEntry, 100);
    defer allocator.free(entries);

    var all_keys = try allocator.alloc([10]Hash, 100);
    defer allocator.free(all_keys);

    for (0..100) |i| {
        for (0..10) |j| {
            all_keys[i][j] = try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000001");
        }

        var addr_bytes: [20]u8 = undefined;
        @memset(&addr_bytes, @intCast(i));

        entries[i] = .{
            .address = Address{ .bytes = addr_bytes },
            .storage_keys = &all_keys[i],
        };
    }

    const gasCost = calculateAccessListGasCost(entries);

    // Expected: 100 addresses * 2400 + 1000 keys * 1900
    try testing.expectEqual(@as(u64, 100 * ACCESS_LIST_ADDRESS_COST + 1000 * ACCESS_LIST_STORAGE_KEY_COST), gasCost);
}

test "deduplicate access list with no duplicates" {
    const allocator = testing.allocator;

    const keys1 = [_]Hash{
        try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000001"),
    };

    const keys2 = [_]Hash{
        try Hash.fromHex("0x0000000000000000000000000000000000000000000000000000000000000002"),
    };

    const accessList = [_]AccessListEntry{
        .{
            .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
            .storage_keys = &keys1,
        },
        .{
            .address = try Address.fromHex("0x2222222222222222222222222222222222222222"),
            .storage_keys = &keys2,
        },
    };

    const deduped = try deduplicateAccessList(allocator, &accessList);
    defer {
        for (deduped) |entry| {
            allocator.free(entry.storage_keys);
        }
        allocator.free(deduped);
    }

    // Should have two entries since addresses are different
    try testing.expectEqual(@as(usize, 2), deduped.len);
    try testing.expectEqual(@as(usize, 1), deduped[0].storage_keys.len);
    try testing.expectEqual(@as(usize, 1), deduped[1].storage_keys.len);
}

test "gas savings calculation edge cases" {
    // Empty access list
    const empty: AccessList = &.{};
    try testing.expectEqual(@as(u64, 0), calculateGasSavings(empty));

    // Single address, no keys
    const single_addr = [_]AccessListEntry{
        .{
            .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
            .storage_keys = &.{},
        },
    };

    const savings = calculateGasSavings(&single_addr);
    // Account savings only: 2600 - 2400 = 200
    try testing.expectEqual(@as(u64, COLD_ACCOUNT_ACCESS_COST - ACCESS_LIST_ADDRESS_COST), savings);
}

test "access list RLP encoding with large storage keys" {
    const allocator = testing.allocator;

    // Create an entry with many storage keys
    var storage_keys: [50]Hash = undefined;
    for (0..50) |i| {
        var key_bytes: [32]u8 = undefined;
        @memset(&key_bytes, @intCast(i));
        storage_keys[i] = Hash{ .bytes = key_bytes };
    }

    const accessList = [_]AccessListEntry{
        .{
            .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
            .storage_keys = &storage_keys,
        },
    };

    const encoded = try encodeAccessList(allocator, &accessList);
    defer allocator.free(encoded);

    // Should be a large encoding
    try testing.expect(encoded.len > 1600); // At least 50 * 32 bytes for keys
    try testing.expect(encoded[0] >= 0xc0); // RLP list prefix
}
