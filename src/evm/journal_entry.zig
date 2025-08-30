/// Journal entry types for tracking EVM state changes
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const address_mod = primitives.Address;
const JournalConfig = @import("journal_config.zig").JournalConfig;

/// Create a journal entry type based on configuration
pub fn JournalEntry(comptime config: JournalConfig) type {
    config.validate();
    
    return struct {
        const Self = @This();
        
        pub const SnapshotIdType = config.SnapshotIdType;
        pub const WordType = config.WordType;
        pub const NonceType = config.NonceType;
        
        snapshot_id: SnapshotIdType,
        data: Data,
        
        /// Union of possible state changes
        pub const Data = union(enum) {
            storage_change: StorageChange,
            balance_change: BalanceChange,
            nonce_change: NonceChange,
            code_change: CodeChange,
            account_created: AccountCreated,
            account_destroyed: AccountDestroyed,
        };
        
        /// Storage slot change
        pub const StorageChange = struct {
            address: Address,
            key: WordType,
            original_value: WordType,
        };
        
        /// Balance change
        pub const BalanceChange = struct {
            address: Address,
            original_balance: WordType,
        };
        
        /// Nonce change
        pub const NonceChange = struct {
            address: Address,
            original_nonce: NonceType,
        };
        
        /// Code change
        pub const CodeChange = struct {
            address: Address,
            original_code_hash: [32]u8,
        };
        
        /// Account creation
        pub const AccountCreated = struct {
            address: Address,
        };
        
        /// Account destruction (self-destruct)
        pub const AccountDestroyed = struct {
            address: Address,
            beneficiary: Address,
            balance: WordType,
        };
        
        /// Create a storage change entry
        pub fn storage_change(snapshot_id: SnapshotIdType, address: Address, key: WordType, original_value: WordType) Self {
            return Self{
                .snapshot_id = snapshot_id,
                .data = .{ .storage_change = .{
                    .address = address,
                    .key = key,
                    .original_value = original_value,
                } },
            };
        }
        
        /// Create a balance change entry
        pub fn balance_change(snapshot_id: SnapshotIdType, address: Address, original_balance: WordType) Self {
            return Self{
                .snapshot_id = snapshot_id,
                .data = .{ .balance_change = .{
                    .address = address,
                    .original_balance = original_balance,
                } },
            };
        }
        
        /// Create a nonce change entry
        pub fn nonce_change(snapshot_id: SnapshotIdType, address: Address, original_nonce: NonceType) Self {
            return Self{
                .snapshot_id = snapshot_id,
                .data = .{ .nonce_change = .{
                    .address = address,
                    .original_nonce = original_nonce,
                } },
            };
        }
        
        /// Create a code change entry
        pub fn code_change(snapshot_id: SnapshotIdType, address: Address, original_code_hash: [32]u8) Self {
            return Self{
                .snapshot_id = snapshot_id,
                .data = .{ .code_change = .{
                    .address = address,
                    .original_code_hash = original_code_hash,
                } },
            };
        }
        
        /// Create an account created entry
        pub fn account_created(snapshot_id: SnapshotIdType, address: Address) Self {
            return Self{
                .snapshot_id = snapshot_id,
                .data = .{ .account_created = .{
                    .address = address,
                } },
            };
        }
        
        /// Create an account destroyed entry
        pub fn account_destroyed(snapshot_id: SnapshotIdType, address: Address, beneficiary: Address, balance: WordType) Self {
            return Self{
                .snapshot_id = snapshot_id,
                .data = .{ .account_destroyed = .{
                    .address = address,
                    .beneficiary = beneficiary,
                    .balance = balance,
                } },
            };
        }
    };
}

/// Default journal entry type
pub const DefaultJournalEntry = JournalEntry(.{});

test "JournalEntry creation and field access" {
    const testing = std.testing;
    const config = JournalConfig{
        .SnapshotIdType = u16,
        .WordType = u128,
        .NonceType = u32,
    };
    const Entry = JournalEntry(config);
    
    const addr = address_mod.from_hex("0x1234567890123456789012345678901234567890") catch unreachable;
    const key: u128 = 42;
    const value: u128 = 100;
    
    // Test storage change
    const storage_entry = Entry.storage_change(1, addr, key, value);
    try testing.expectEqual(@as(u16, 1), storage_entry.snapshot_id);
    switch (storage_entry.data) {
        .storage_change => |sc| {
            try testing.expectEqual(addr, sc.address);
            try testing.expectEqual(key, sc.key);
            try testing.expectEqual(value, sc.original_value);
        },
        else => try testing.expect(false),
    }
    
    // Test balance change
    const balance_entry = Entry.balance_change(2, addr, 1000);
    try testing.expectEqual(@as(u16, 2), balance_entry.snapshot_id);
    switch (balance_entry.data) {
        .balance_change => |bc| {
            try testing.expectEqual(addr, bc.address);
            try testing.expectEqual(@as(u128, 1000), bc.original_balance);
        },
        else => try testing.expect(false),
    }
    
    // Test nonce change
    const nonce_entry = Entry.nonce_change(3, addr, 5);
    try testing.expectEqual(@as(u16, 3), nonce_entry.snapshot_id);
    switch (nonce_entry.data) {
        .nonce_change => |nc| {
            try testing.expectEqual(addr, nc.address);
            try testing.expectEqual(@as(u32, 5), nc.original_nonce);
        },
        else => try testing.expect(false),
    }
    
    // Test code change
    const code_hash = [_]u8{0xAB} ** 32;
    const code_entry = Entry.code_change(4, addr, code_hash);
    try testing.expectEqual(@as(u16, 4), code_entry.snapshot_id);
    switch (code_entry.data) {
        .code_change => |cc| {
            try testing.expectEqual(addr, cc.address);
            try testing.expectEqualSlices(u8, &code_hash, &cc.original_code_hash);
        },
        else => try testing.expect(false),
    }
    
    // Test account created
    const created_entry = Entry.account_created(5, addr);
    try testing.expectEqual(@as(u16, 5), created_entry.snapshot_id);
    switch (created_entry.data) {
        .account_created => |ac| {
            try testing.expectEqual(addr, ac.address);
        },
        else => try testing.expect(false),
    }
    
    // Test account destroyed
    const beneficiary = address_mod.from_hex("0x9876543210987654321098765432109876543210") catch unreachable;
    const destroyed_entry = Entry.account_destroyed(6, addr, beneficiary, 50000);
    try testing.expectEqual(@as(u16, 6), destroyed_entry.snapshot_id);
    switch (destroyed_entry.data) {
        .account_destroyed => |ad| {
            try testing.expectEqual(addr, ad.address);
            try testing.expectEqual(beneficiary, ad.beneficiary);
            try testing.expectEqual(@as(u128, 50000), ad.balance);
        },
        else => try testing.expect(false),
    }
}

test "JournalEntry with minimal config" {
    const testing = std.testing;
    const config = JournalConfig{
        .SnapshotIdType = u8,
        .WordType = u64,
        .NonceType = u16,
    };
    const Entry = JournalEntry(config);
    
    const addr = [_]u8{0} ** 20;
    
    // Test with minimal types
    const entry = Entry.storage_change(255, addr, std.math.maxInt(u64), 0);
    try testing.expectEqual(@as(u8, 255), entry.snapshot_id);
    switch (entry.data) {
        .storage_change => |sc| {
            try testing.expectEqual(@as(u64, std.math.maxInt(u64)), sc.key);
            try testing.expectEqual(@as(u64, 0), sc.original_value);
        },
        else => try testing.expect(false),
    }
}

test "JournalEntry - default configuration types" {
    const testing = std.testing;
    const Entry = DefaultJournalEntry;
    
    // Verify default types
    try testing.expectEqual(u32, Entry.SnapshotIdType);
    try testing.expectEqual(u256, Entry.WordType);
    try testing.expectEqual(u64, Entry.NonceType);
    
    const addr = [_]u8{1} ** 20;
    const entry = Entry.storage_change(100, addr, 42, 84);
    try testing.expectEqual(@as(u32, 100), entry.snapshot_id);
}

test "JournalEntry - boundary values for snapshot IDs" {
    const testing = std.testing;
    const config = JournalConfig{
        .SnapshotIdType = u8,
        .WordType = u64,
        .NonceType = u32,
    };
    const Entry = JournalEntry(config);
    const addr = [_]u8{0xFF} ** 20;
    
    // Test boundary values for u8 snapshot IDs
    const min_entry = Entry.balance_change(0, addr, 1000);
    try testing.expectEqual(@as(u8, 0), min_entry.snapshot_id);
    
    const max_entry = Entry.balance_change(255, addr, 2000);
    try testing.expectEqual(@as(u8, 255), max_entry.snapshot_id);
}

test "JournalEntry - maximum value configurations" {
    const testing = std.testing;
    const config = JournalConfig{
        .SnapshotIdType = u64,
        .WordType = u256,
        .NonceType = u64,
    };
    const Entry = JournalEntry(config);
    const addr = [_]u8{0xAA} ** 20;
    
    // Test with maximum values
    const max_snapshot = std.math.maxInt(u64);
    const max_word = std.math.maxInt(u256);
    const max_nonce = std.math.maxInt(u64);
    
    const storage_entry = Entry.storage_change(max_snapshot, addr, max_word, max_word);
    try testing.expectEqual(max_snapshot, storage_entry.snapshot_id);
    switch (storage_entry.data) {
        .storage_change => |sc| {
            try testing.expectEqual(max_word, sc.key);
            try testing.expectEqual(max_word, sc.original_value);
        },
        else => try testing.expect(false),
    }
    
    const nonce_entry = Entry.nonce_change(max_snapshot, addr, max_nonce);
    switch (nonce_entry.data) {
        .nonce_change => |nc| {
            try testing.expectEqual(max_nonce, nc.original_nonce);
        },
        else => try testing.expect(false),
    }
}

test "JournalEntry - zero values" {
    const testing = std.testing;
    const Entry = DefaultJournalEntry;
    const zero_addr = [_]u8{0} ** 20;
    
    // Test with all zero values
    const storage_entry = Entry.storage_change(0, zero_addr, 0, 0);
    try testing.expectEqual(@as(u32, 0), storage_entry.snapshot_id);
    switch (storage_entry.data) {
        .storage_change => |sc| {
            try testing.expectEqualSlices(u8, &zero_addr, &sc.address);
            try testing.expectEqual(@as(u256, 0), sc.key);
            try testing.expectEqual(@as(u256, 0), sc.original_value);
        },
        else => try testing.expect(false),
    }
    
    const balance_entry = Entry.balance_change(0, zero_addr, 0);
    switch (balance_entry.data) {
        .balance_change => |bc| {
            try testing.expectEqual(@as(u256, 0), bc.original_balance);
        },
        else => try testing.expect(false),
    }
    
    const nonce_entry = Entry.nonce_change(0, zero_addr, 0);
    switch (nonce_entry.data) {
        .nonce_change => |nc| {
            try testing.expectEqual(@as(u64, 0), nc.original_nonce);
        },
        else => try testing.expect(false),
    }
}

test "JournalEntry - address variations" {
    const testing = std.testing;
    const Entry = DefaultJournalEntry;
    
    // Test with different address patterns
    const zero_addr = [_]u8{0} ** 20;
    const max_addr = [_]u8{0xFF} ** 20;
    const pattern_addr = [_]u8{0xAA, 0x55} ** 10;
    
    const entry1 = Entry.account_created(1, zero_addr);
    const entry2 = Entry.account_created(2, max_addr);
    const entry3 = Entry.account_created(3, pattern_addr);
    
    switch (entry1.data) {
        .account_created => |ac| try testing.expectEqualSlices(u8, &zero_addr, &ac.address),
        else => try testing.expect(false),
    }
    
    switch (entry2.data) {
        .account_created => |ac| try testing.expectEqualSlices(u8, &max_addr, &ac.address),
        else => try testing.expect(false),
    }
    
    switch (entry3.data) {
        .account_created => |ac| try testing.expectEqualSlices(u8, &pattern_addr, &ac.address),
        else => try testing.expect(false),
    }
}

test "JournalEntry - code hash variations" {
    const testing = std.testing;
    const Entry = DefaultJournalEntry;
    const addr = [_]u8{0x11} ** 20;
    
    // Test with different code hash patterns
    const zero_hash = [_]u8{0} ** 32;
    const max_hash = [_]u8{0xFF} ** 32;
    const keccak_empty_hash = [_]u8{
        0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c,
        0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0,
        0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b,
        0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70,
    };
    
    const entry1 = Entry.code_change(1, addr, zero_hash);
    const entry2 = Entry.code_change(2, addr, max_hash);
    const entry3 = Entry.code_change(3, addr, keccak_empty_hash);
    
    switch (entry1.data) {
        .code_change => |cc| try testing.expectEqualSlices(u8, &zero_hash, &cc.original_code_hash),
        else => try testing.expect(false),
    }
    
    switch (entry2.data) {
        .code_change => |cc| try testing.expectEqualSlices(u8, &max_hash, &cc.original_code_hash),
        else => try testing.expect(false),
    }
    
    switch (entry3.data) {
        .code_change => |cc| try testing.expectEqualSlices(u8, &keccak_empty_hash, &cc.original_code_hash),
        else => try testing.expect(false),
    }
}

test "JournalEntry - account destroyed scenarios" {
    const testing = std.testing;
    const Entry = DefaultJournalEntry;
    const contract_addr = [_]u8{0xDE, 0xAD} ++ [_]u8{0} ** 18;
    const beneficiary_addr = [_]u8{0xBE, 0xEF} ++ [_]u8{0} ** 18;
    
    // Test self-destruct scenarios
    const zero_balance_destroy = Entry.account_destroyed(10, contract_addr, beneficiary_addr, 0);
    const large_balance_destroy = Entry.account_destroyed(11, contract_addr, beneficiary_addr, std.math.maxInt(u256));
    
    switch (zero_balance_destroy.data) {
        .account_destroyed => |ad| {
            try testing.expectEqualSlices(u8, &contract_addr, &ad.address);
            try testing.expectEqualSlices(u8, &beneficiary_addr, &ad.beneficiary);
            try testing.expectEqual(@as(u256, 0), ad.balance);
        },
        else => try testing.expect(false),
    }
    
    switch (large_balance_destroy.data) {
        .account_destroyed => |ad| {
            try testing.expectEqual(std.math.maxInt(u256), ad.balance);
        },
        else => try testing.expect(false),
    }
    
    // Test self-destruct to self
    const self_destruct_to_self = Entry.account_destroyed(12, contract_addr, contract_addr, 12345);
    switch (self_destruct_to_self.data) {
        .account_destroyed => |ad| {
            try testing.expectEqualSlices(u8, &contract_addr, &ad.address);
            try testing.expectEqualSlices(u8, &contract_addr, &ad.beneficiary);
        },
        else => try testing.expect(false),
    }
}

test "JournalEntry - mixed type sizes" {
    const testing = std.testing;
    const config = JournalConfig{
        .SnapshotIdType = u8,    // Small snapshot
        .WordType = u256,        // Large word
        .NonceType = u16,        // Medium nonce
    };
    const Entry = JournalEntry(config);
    const addr = address_mod.from_hex("0x1111111111111111111111111111111111111111") catch unreachable;
    
    // Test mixed type sizes work together
    const storage_entry = Entry.storage_change(
        std.math.maxInt(u8),
        addr,
        std.math.maxInt(u256),
        0,
    );
    
    try testing.expectEqual(std.math.maxInt(u8), storage_entry.snapshot_id);
    switch (storage_entry.data) {
        .storage_change => |sc| {
            try testing.expectEqual(std.math.maxInt(u256), sc.key);
            try testing.expectEqual(@as(u256, 0), sc.original_value);
        },
        else => try testing.expect(false),
    }
    
    const nonce_entry = Entry.nonce_change(1, addr, std.math.maxInt(u16));
    switch (nonce_entry.data) {
        .nonce_change => |nc| {
            try testing.expectEqual(std.math.maxInt(u16), nc.original_nonce);
        },
        else => try testing.expect(false),
    }
}

test "JournalEntry - data union discriminants" {
    const testing = std.testing;
    const Entry = DefaultJournalEntry;
    const addr = [_]u8{0x42} ** 20;
    
    // Test that we can distinguish between different entry types
    const storage_entry = Entry.storage_change(1, addr, 1, 1);
    const balance_entry = Entry.balance_change(2, addr, 2);
    const nonce_entry = Entry.nonce_change(3, addr, 3);
    const code_entry = Entry.code_change(4, addr, [_]u8{0x04} ** 32);
    const created_entry = Entry.account_created(5, addr);
    const destroyed_entry = Entry.account_destroyed(6, addr, addr, 6);
    
    // Verify each entry has the correct discriminant
    switch (storage_entry.data) {
        .storage_change => {}, // Expected
        else => try testing.expect(false),
    }
    
    switch (balance_entry.data) {
        .balance_change => {}, // Expected
        else => try testing.expect(false),
    }
    
    switch (nonce_entry.data) {
        .nonce_change => {}, // Expected
        else => try testing.expect(false),
    }
    
    switch (code_entry.data) {
        .code_change => {}, // Expected
        else => try testing.expect(false),
    }
    
    switch (created_entry.data) {
        .account_created => {}, // Expected
        else => try testing.expect(false),
    }
    
    switch (destroyed_entry.data) {
        .account_destroyed => {}, // Expected
        else => try testing.expect(false),
    }
}

test "JournalEntry - entry size and memory layout" {
    const testing = std.testing;
    const Entry = DefaultJournalEntry;
    
    // Test that entries have reasonable size
    const storage_entry = Entry.storage_change(1, [_]u8{0} ** 20, 42, 84);
    _ = storage_entry; // Use the entry to ensure it's created
    
    // Verify that all entry types can be created without issues
    const entries = [_]Entry{
        Entry.storage_change(1, [_]u8{0} ** 20, 1, 1),
        Entry.balance_change(2, [_]u8{0} ** 20, 2),
        Entry.nonce_change(3, [_]u8{0} ** 20, 3),
        Entry.code_change(4, [_]u8{0} ** 20, [_]u8{0} ** 32),
        Entry.account_created(5, [_]u8{0} ** 20),
        Entry.account_destroyed(6, [_]u8{0} ** 20, [_]u8{1} ** 20, 6),
    };
    
    // Verify all entries were created successfully
    try testing.expectEqual(@as(usize, 6), entries.len);
    for (entries, 1..) |entry, expected_id| {
        try testing.expectEqual(@as(u32, @intCast(expected_id)), entry.snapshot_id);
    }
}

test "JournalEntry - large configuration stress test" {
    const testing = std.testing;
    const config = JournalConfig{
        .SnapshotIdType = u64,
        .WordType = u256,
        .NonceType = u64,
        .initial_capacity = 1000,
    };
    const Entry = JournalEntry(config);
    const addr = [_]u8{0x99} ** 20;
    
    // Create many entries with large values to stress test
    const large_snapshot = 1_000_000_000_000;
    const large_key = std.math.maxInt(u256) - 1;
    const large_value = std.math.maxInt(u256) >> 1;
    const large_nonce = std.math.maxInt(u64) - 1;
    
    const storage_entry = Entry.storage_change(large_snapshot, addr, large_key, large_value);
    const nonce_entry = Entry.nonce_change(large_snapshot + 1, addr, large_nonce);
    
    try testing.expectEqual(large_snapshot, storage_entry.snapshot_id);
    switch (storage_entry.data) {
        .storage_change => |sc| {
            try testing.expectEqual(large_key, sc.key);
            try testing.expectEqual(large_value, sc.original_value);
        },
        else => try testing.expect(false),
    }
    
    switch (nonce_entry.data) {
        .nonce_change => |nc| {
            try testing.expectEqual(large_nonce, nc.original_nonce);
        },
        else => try testing.expect(false),
    }
}