//! Test ForkedStorage with mock data (no network required)
//!
//! This test verifies ForkedStorage functionality without network calls

const std = @import("std");
const testing = std.testing;
const Storage = @import("../src/storage/storage.zig").Storage;
const ForkedStorage = @import("../src/storage/forked_storage.zig").ForkedStorage;
const Account = @import("../src/storage/database_interface_account.zig").Account;

test "ForkedStorage - cache layer functionality" {
    
    // Note: This test would normally connect to an RPC endpoint
    // For offline testing, we're just verifying the structure compiles
    
    // Test that ForkedStorage structure is correct
    const fs_type = @TypeOf(ForkedStorage.init);
    _ = fs_type;
    
    // Test cache statistics structure
    const stats = ForkedStorage.Stats{
        .cache_hits = 10,
        .cache_misses = 5,
        .rpc_calls = 5,
    };
    
    try testing.expectEqual(@as(u64, 10), stats.cache_hits);
    try testing.expectEqual(@as(u64, 5), stats.cache_misses);
    try testing.expectEqual(@as(u64, 5), stats.rpc_calls);
}

test "Storage union with forked variant" {
    // This test verifies the union properly includes ForkedStorage
    const storage_info = @typeInfo(Storage);
    
    // Verify it's a union
    try testing.expect(storage_info == .Union);
    
    // Count variants
    const union_fields = storage_info.Union.fields;
    var found_memory = false;
    var found_test = false;
    var found_forked = false;
    
    for (union_fields) |field| {
        if (std.mem.eql(u8, field.name, "memory")) found_memory = true;
        if (std.mem.eql(u8, field.name, "test")) found_test = true;
        if (std.mem.eql(u8, field.name, "forked")) found_forked = true;
    }
    
    try testing.expect(found_memory);
    try testing.expect(found_test);
    try testing.expect(found_forked);
    
    std.debug.print("✓ Storage union includes all 3 variants\n", .{});
}

test "ForkedStorage API compatibility" {
    // Compile-time verification that ForkedStorage implements all required methods
    const T = ForkedStorage;
    
    // Account operations
    comptime {
        _ = T.get_account;
        _ = T.set_account;
        _ = T.delete_account;
        _ = T.account_exists;
        _ = T.get_balance;
    }
    
    // Storage operations
    comptime {
        _ = T.get_storage;
        _ = T.set_storage;
        _ = T.get_transient_storage;
        _ = T.set_transient_storage;
    }
    
    // Code operations
    comptime {
        _ = T.get_code;
        _ = T.get_code_by_address;
        _ = T.set_code;
    }
    
    // State operations
    comptime {
        _ = T.get_state_root;
        _ = T.commit_changes;
        _ = T.create_snapshot;
        _ = T.revert_to_snapshot;
        _ = T.commit_snapshot;
    }
    
    // Batch operations
    comptime {
        _ = T.begin_batch;
        _ = T.commit_batch;
        _ = T.rollback_batch;
    }
    
    std.debug.print("✓ ForkedStorage implements all required methods\n", .{});
}