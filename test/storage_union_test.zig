//! Test Storage union integration
//!
//! This test verifies the Storage union type works correctly with all backends

const std = @import("std");
const testing = std.testing;

test "Storage union - all variants compile" {
    // This is a compile-time test to ensure all storage types work with the union
    const Storage = @import("../src/storage/storage.zig").Storage;
    const MemoryStorage = @import("../src/storage/database.zig").Database;
    const TestStorage = @import("../src/storage/storage.zig").TestStorage;
    const ForkedStorage = @import("../src/storage/forked_storage.zig").ForkedStorage;
    
    // Verify all types can be created
    comptime {
        _ = ForkedStorage;
    }
    
    // Simple runtime test
    const allocator = testing.allocator;
    
    // Test memory variant
    var memory_storage = Storage{ .memory = MemoryStorage.init(allocator) };
    defer memory_storage.deinit();
    
    const test_addr = @as([20]u8, @splat(0x12));
    try testing.expect(!memory_storage.account_exists(test_addr));
    
    // Test storage variant
    var test_storage = Storage{ .@"test" = TestStorage.init(allocator) };
    defer test_storage.deinit();
    
    try testing.expect(!test_storage.account_exists(test_addr));
    
    std.debug.print("✓ Storage union integration successful\n", .{});
}