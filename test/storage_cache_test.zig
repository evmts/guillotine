const std = @import("std");
const testing = std.testing;
const cache_storage = @import("../src/storage/cache_storage.zig");
const lru_cache = @import("../src/storage/lru_cache.zig");
const Account = @import("../src/storage/database_interface_account.zig").Account;

test "LRU cache and HotStorage integration" {
    const allocator = testing.allocator;
    
    // Test LRU cache
    const Cache = lru_cache.LruCache(u32, u32, .{ .capacity = 3 });
    var cache = try Cache.init(allocator);
    defer cache.deinit();
    
    _ = try cache.put(1, 100);
    _ = try cache.put(2, 200);
    _ = try cache.put(3, 300);
    
    // Should evict 1
    const evicted = try cache.put(4, 400);
    try testing.expect(evicted != null);
    try testing.expectEqual(@as(u32, 1), evicted.?.key);
    
    // Test HotStorage
    var hot = cache_storage.HotStorage.init(allocator);
    defer hot.deinit();
    
    const addr = @as([20]u8, @splat(0x12));
    const account = Account{
        .balance = 1000,
        .nonce = 5,
        .code_hash = @as([32]u8, @splat(0xAB)),
        .storage_root = @as([32]u8, @splat(0xCD)),
    };
    
    try hot.putAccount(addr, account);
    const retrieved = hot.getAccount(addr).?;
    try testing.expectEqual(account.balance, retrieved.balance);
    
    // Test storage operations
    const slot: u256 = 42;
    const value: u256 = 999;
    try hot.putStorage(addr, slot, value);
    try testing.expectEqual(value, hot.getStorage(addr, slot).?);
    
    std.debug.print("✓ Cache storage tests passed\n", .{});
}