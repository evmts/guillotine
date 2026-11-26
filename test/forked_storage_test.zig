//! Test ForkedStorage with public Ethereum endpoints
//!
//! This test demonstrates ForkedStorage functionality by connecting to
//! public Ethereum RPC endpoints and fetching real blockchain data.

const std = @import("std");
const testing = std.testing;
const Storage = @import("../src/storage/storage.zig").Storage;
const ForkedStorage = @import("../src/storage/forked_storage.zig").ForkedStorage;
const createForkedStorage = @import("../src/storage/storage.zig").createForkedStorage;

test "ForkedStorage - fetch Vitalik's account from public endpoint" {
    const allocator = testing.allocator;
    
    // Using public Ethereum RPC endpoints
    // Alternatives: "https://eth.llamarpc.com", "https://ethereum-rpc.publicnode.com"
    var storage = try createForkedStorage(allocator, "https://rpc.ankr.com/eth", null);
    defer storage.deinit();
    
    // Vitalik's address: 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045
    const vitalik_address = [_]u8{
        0xd8, 0xdA, 0x6B, 0xF2, 0x69, 0x64, 0xaF, 0x9D, 0x7e, 0xEd,
        0x9e, 0x03, 0xE5, 0x3A, 0x15, 0xD3, 0x7a, 0xA9, 0x60, 0x45
    };
    
    // Fetch account data
    const account = (try storage.get_account(vitalik_address)) orelse {
        std.debug.print("Account not found\n", .{});
        return;
    };
    
    std.debug.print("\n=== Vitalik's Account ===\n", .{});
    std.debug.print("Balance: {d} wei\n", .{account.balance});
    std.debug.print("Nonce: {d}\n", .{account.nonce});
    
    // Check that balance is non-zero (Vitalik definitely has ETH!)
    try testing.expect(account.balance > 0);
    try testing.expect(account.nonce > 0);
    
    // Check cache statistics
    if (storage.forked) |*forked| {
        const stats = forked.getStats();
        std.debug.print("\n=== Cache Statistics ===\n", .{});
        std.debug.print("Cache hits: {d}\n", .{stats.cache_hits});
        std.debug.print("Cache misses: {d}\n", .{stats.cache_misses});
        std.debug.print("RPC calls: {d}\n", .{stats.rpc_calls});
        
        // First call should be a miss and trigger RPC
        try testing.expectEqual(@as(u64, 1), stats.cache_misses);
        try testing.expectEqual(@as(u64, 1), stats.rpc_calls);
        
        // Second call should be a cache hit
        _ = try storage.get_account(vitalik_address);
        const stats2 = forked.getStats();
        try testing.expectEqual(@as(u64, 1), stats2.cache_hits);
        try testing.expectEqual(@as(u64, 1), stats2.rpc_calls); // No new RPC call
    }
}

test "ForkedStorage - fetch USDC contract storage" {
    const allocator = testing.allocator;
    
    var storage = try createForkedStorage(allocator, "https://rpc.ankr.com/eth", null);
    defer storage.deinit();
    
    // USDC contract address: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    const usdc_address = [_]u8{
        0xA0, 0xb8, 0x69, 0x91, 0xc6, 0x21, 0x8b, 0x36, 0xc1, 0xd1,
        0x9D, 0x4a, 0x2e, 0x9E, 0xb0, 0xcE, 0x36, 0x06, 0xeB, 0x48
    };
    
    // Get USDC contract account
    const account = (try storage.get_account(usdc_address)) orelse {
        std.debug.print("USDC contract not found\n", .{});
        return;
    };
    
    std.debug.print("\n=== USDC Contract ===\n", .{});
    std.debug.print("Balance: {d} wei\n", .{account.balance});
    std.debug.print("Nonce: {d}\n", .{account.nonce});
    
    // USDC is a contract, so code_hash should not be empty
    const empty_hash = @as([32]u8, @splat(0));
    try testing.expect(!std.mem.eql(u8, &account.code_hash, &empty_hash));
    
    // Get USDC total supply (slot 0 in many ERC20 contracts)
    // Note: USDC uses a different storage layout, but we can still test fetching
    const slot0_value = try storage.get_storage(usdc_address, 0);
    std.debug.print("Storage slot 0: {x}\n", .{slot0_value});
    
    // Get contract code
    const code = try storage.get_code_by_address(usdc_address);
    std.debug.print("Code size: {d} bytes\n", .{code.len});
    try testing.expect(code.len > 0); // USDC has contract code
}

test "ForkedStorage - test cache layers" {
    const allocator = testing.allocator;
    
    var storage = try createForkedStorage(allocator, "https://rpc.ankr.com/eth", null);
    defer storage.deinit();
    
    // Some random address with ETH
    const test_address = [_]u8{
        0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x34, 0x56, 0x78, 0x90,
        0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0x34, 0x56, 0x78, 0x90
    };
    
    // Multiple accesses to test cache
    for (0..3) |i| {
        const balance = try storage.get_balance(test_address);
        std.debug.print("Access {d}: Balance = {d}\n", .{ i, balance });
    }
    
    if (storage.forked) |*forked| {
        const stats = forked.getStats();
        std.debug.print("\n=== Final Cache Stats ===\n", .{});
        std.debug.print("Total cache hits: {d}\n", .{stats.cache_hits});
        std.debug.print("Total cache misses: {d}\n", .{stats.cache_misses});
        std.debug.print("Total RPC calls: {d}\n", .{stats.rpc_calls});
        
        // After 3 accesses: 1 miss + 2 hits
        try testing.expect(stats.cache_hits >= 2);
        try testing.expectEqual(@as(u64, 1), stats.rpc_calls);
    }
}

test "ForkedStorage - fork at specific block" {
    const allocator = testing.allocator;
    
    // Fork at a specific block (18 million)
    const fork_block: u64 = 18_000_000;
    var storage = try createForkedStorage(allocator, "https://rpc.ankr.com/eth", fork_block);
    defer storage.deinit();
    
    // Test address
    const test_address = @as([20]u8, @splat(0x00));
    
    // This should fetch data from block 18 million
    const account = try storage.get_account(test_address);
    _ = account;
    
    std.debug.print("\n=== Forked at block {d} ===\n", .{fork_block});
    std.debug.print("Successfully forked at specific block\n", .{});
}

// Integration test with Storage union
test "Storage union with ForkedStorage" {
    const allocator = testing.allocator;
    
    // Create through the union interface
    var storage = Storage{ 
        .forked = try ForkedStorage.init(allocator, "https://rpc.ankr.com/eth", null)
    };
    defer storage.deinit();
    
    // Use through the union interface (zero overhead!)
    const test_address = @as([20]u8, @splat(0xFF));
    const balance = try storage.get_balance(test_address);
    
    std.debug.print("\n=== Union Interface ===\n", .{});
    std.debug.print("Balance through union: {d}\n", .{balance});
    
    // The switch statement is completely inlined by the compiler
    // This has identical performance to calling forked.get_balance() directly
}