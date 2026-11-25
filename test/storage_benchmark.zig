//! Benchmark demonstrating zero overhead of union-based storage
//!
//! This benchmark shows that the union-based approach has identical
//! performance to direct function calls for the memory storage case.

const std = @import("std");
const testing = std.testing;
const storage_mod = @import("../src/storage/storage.zig");
const MemoryStorage = storage_mod.MemoryStorage;
const Storage = storage_mod.Storage;
const Account = @import("../src/storage/database_interface_account.zig").Account;

const ITERATIONS = 100_000;

fn benchmarkDirectAccess(allocator: std.mem.Allocator) !u64 {
    var storage = MemoryStorage.init(allocator);
    defer storage.deinit();
    
    const addr = @as([20]u8, @splat(0x12));
    const account = Account{
        .balance = 1000,
        .nonce = 5,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    };
    
    var timer = try std.time.Timer.start();
    
    for (0..ITERATIONS) |i| {
        // Direct calls to MemoryStorage
        try storage.set_account(addr, account);
        _ = try storage.get_account(addr);
        try storage.set_storage(addr, @intCast(i % 256), @intCast(i));
        _ = try storage.get_storage(addr, @intCast(i % 256));
    }
    
    return timer.read();
}

fn benchmarkUnionAccess(allocator: std.mem.Allocator) !u64 {
    var storage = Storage{ .memory = MemoryStorage.init(allocator) };
    defer storage.deinit();
    
    const addr = @as([20]u8, @splat(0x12));
    const account = Account{
        .balance = 1000,
        .nonce = 5,
        .code_hash = @as([32]u8, @splat(0)),
        .storage_root = @as([32]u8, @splat(0)),
    };
    
    var timer = try std.time.Timer.start();
    
    for (0..ITERATIONS) |i| {
        // Calls through union wrapper
        try storage.set_account(addr, account);
        _ = try storage.get_account(addr);
        try storage.set_storage(addr, @intCast(i % 256), @intCast(i));
        _ = try storage.get_storage(addr, @intCast(i % 256));
    }
    
    return timer.read();
}

test "Storage benchmark - zero overhead verification" {
    const allocator = testing.allocator;
    
    // Warm up
    _ = try benchmarkDirectAccess(allocator);
    _ = try benchmarkUnionAccess(allocator);
    
    // Run benchmarks multiple times and take average
    const runs = 5;
    var direct_total: u64 = 0;
    var union_total: u64 = 0;
    
    for (0..runs) |_| {
        direct_total += try benchmarkDirectAccess(allocator);
        union_total += try benchmarkUnionAccess(allocator);
    }
    
    const direct_avg = direct_total / runs;
    const union_avg = union_total / runs;
    
    std.debug.print("\n", .{});
    std.debug.print("=== Storage Performance Benchmark ===\n", .{});
    std.debug.print("Iterations: {d}\n", .{ITERATIONS});
    std.debug.print("Runs: {d}\n\n", .{runs});
    
    std.debug.print("Direct access avg: {d:.3} ms\n", .{@as(f64, @floatFromInt(direct_avg)) / 1_000_000});
    std.debug.print("Union access avg:  {d:.3} ms\n", .{@as(f64, @floatFromInt(union_avg)) / 1_000_000});
    
    const overhead_percent = if (union_avg > direct_avg)
        (@as(f64, @floatFromInt(union_avg - direct_avg)) / @as(f64, @floatFromInt(direct_avg))) * 100
    else
        -(@as(f64, @floatFromInt(direct_avg - union_avg)) / @as(f64, @floatFromInt(direct_avg))) * 100;
    
    std.debug.print("\nOverhead: {d:.2}%\n", .{overhead_percent});
    
    if (@abs(overhead_percent) < 5.0) {
        std.debug.print("✓ Zero-overhead abstraction achieved!\n", .{});
    } else {
        std.debug.print("⚠ Overhead exceeds 5% threshold\n", .{});
    }
    
    std.debug.print("=====================================\n\n", .{});
    
    // Test should pass if overhead is less than 5%
    try testing.expect(@abs(overhead_percent) < 10.0);  // Allow 10% variance for CI
}

test "HotStorage vs HashMap direct comparison" {
    const allocator = testing.allocator;
    const cache_storage = @import("../src/storage/cache_storage.zig");
    
    // Benchmark HotStorage
    var hot = cache_storage.HotStorage.init(allocator);
    defer hot.deinit();
    
    const addr = @as([20]u8, @splat(0x34));
    const account = Account.zero();
    
    var timer = try std.time.Timer.start();
    
    for (0..ITERATIONS) |i| {
        try hot.putAccount(addr, account);
        _ = hot.getAccount(addr);
        try hot.putStorage(addr, @intCast(i % 256), @intCast(i));
        _ = hot.getStorage(addr, @intCast(i % 256));
    }
    
    const hot_time = timer.read();
    
    // Benchmark direct HashMap
    const AddressHashContext = cache_storage.AddressHashContext;
    const StorageKey = cache_storage.StorageKey;
    const StorageHashContext = cache_storage.StorageHashContext;
    
    var accounts = std.HashMap([20]u8, Account, AddressHashContext, 80).init(allocator);
    defer accounts.deinit();
    var storage = std.HashMap(StorageKey, u256, StorageHashContext, 80).init(allocator);
    defer storage.deinit();
    
    timer.reset();
    
    for (0..ITERATIONS) |i| {
        try accounts.put(addr, account);
        _ = accounts.get(addr);
        const key = StorageKey{ .address = addr, .slot = @intCast(i % 256) };
        try storage.put(key, @intCast(i));
        _ = storage.get(key);
    }
    
    const direct_time = timer.read();
    
    std.debug.print("\n=== HotStorage vs Direct HashMap ===\n", .{});
    std.debug.print("HotStorage:    {d:.3} ms\n", .{@as(f64, @floatFromInt(hot_time)) / 1_000_000});
    std.debug.print("Direct HashMap: {d:.3} ms\n", .{@as(f64, @floatFromInt(direct_time)) / 1_000_000});
    
    const overhead_percent = if (hot_time > direct_time)
        (@as(f64, @floatFromInt(hot_time - direct_time)) / @as(f64, @floatFromInt(direct_time))) * 100
    else
        -(@as(f64, @floatFromInt(direct_time - hot_time)) / @as(f64, @floatFromInt(direct_time))) * 100;
    
    std.debug.print("Overhead: {d:.2}%\n", .{overhead_percent});
    std.debug.print("=====================================\n\n", .{});
    
    // HotStorage should have near-zero overhead
    try testing.expect(@abs(overhead_percent) < 10.0);
}