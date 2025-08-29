const std = @import("std");
const zbench = @import("zbench");
const database_mod = @import("database.zig");
const primitives = @import("primitives");

const Database = database_mod.Database;
const Address = primitives.Address.Address;

fn benchDatabaseGetAccount(allocator: std.mem.Allocator) void {
    var db = Database.init(allocator);
    defer db.deinit();
    
    // Pre-populate with some accounts
    var i: u8 = 0;
    while (i < 100) : (i += 1) {
        const addr = [_]u8{i} ++ [_]u8{0} ** 19;
        const account = database_mod.Account{
            .balance = @as(u256, i) * 1000000000000000000, // i ETH in wei
            .nonce = i,
            .code_hash = [_]u8{0} ** 32,
            .storage_root = [_]u8{0} ** 32,
        };
        db.set_account(addr, account) catch break;
    }
    
    // Benchmark account retrieval
    i = 0;
    while (i < 1000) : (i += 1) {
        const addr = [_]u8{i % 100} ++ [_]u8{0} ** 19;
        _ = db.get_account(addr) catch break;
    }
}

fn benchDatabaseSetAccount(allocator: std.mem.Allocator) void {
    var db = Database.init(allocator);
    defer db.deinit();
    
    var i: u8 = 0;
    while (i < 200) : (i += 1) {
        const addr = [_]u8{i} ++ [_]u8{0} ** 19;
        const account = database_mod.Account{
            .balance = @as(u256, i) * 1000000000000000000,
            .nonce = i,
            .code_hash = [_]u8{0} ** 32,
            .storage_root = [_]u8{0} ** 32,
        };
        db.set_account(addr, account) catch break;
    }
}

fn benchDatabaseStorage(allocator: std.mem.Allocator) void {
    var db = Database.init(allocator);
    defer db.deinit();
    
    const addr = [_]u8{0x42} ++ [_]u8{0} ** 19;
    
    // Set storage values
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const key: u256 = i;
        const value: u256 = i * 1000;
        db.set_storage(addr, key, value) catch break;
    }
    
    // Get storage values
    i = 0;
    while (i < 200) : (i += 1) {
        const key: u256 = i % 100;
        _ = db.get_storage(addr, key) catch break;
    }
}

fn benchDatabaseTransientStorage(allocator: std.mem.Allocator) void {
    var db = Database.init(allocator);
    defer db.deinit();
    
    const addr = [_]u8{0x43} ++ [_]u8{0} ** 19;
    
    // Set and get transient storage values
    var i: u32 = 0;
    while (i < 150) : (i += 1) {
        const key: u256 = i;
        const value: u256 = i * 2000;
        
        db.set_transient_storage(addr, key, value) catch break;
        _ = db.get_transient_storage(addr, key) catch break;
    }
}

fn benchDatabaseCodeOperations(allocator: std.mem.Allocator) void {
    var db = Database.init(allocator);
    defer db.deinit();
    
    const addr = [_]u8{0x44} ++ [_]u8{0} ** 19;
    
    // Sample contract bytecode
    const bytecode = [_]u8{
        0x60, 0x80, 0x60, 0x40, 0x52, 0x34, 0x80, 0x15,
        0x61, 0x00, 0x10, 0x57, 0x60, 0x00, 0x80, 0xfd,
        0x5b, 0x50, 0x60, 0x40, 0x51, 0x61, 0x02, 0x8f,
        0x38, 0x03, 0x80, 0x61, 0x02, 0x8f, 0x83, 0x39,
    };
    
    // Set and get code multiple times
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        const test_addr = [_]u8{@as(u8, @intCast(i % 256))} ++ [_]u8{0} ** 19;
        
        _ = db.set_code(&bytecode) catch break;
        _ = db.get_code(test_addr) catch break;
        _ = db.get_code_hash(test_addr) catch break;
        _ = db.get_code_size(test_addr) catch break;
    }
}

fn benchDatabaseMixedOperations(allocator: std.mem.Allocator) void {
    var db = Database.init(allocator);
    defer db.deinit();
    
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const addr = [_]u8{@as(u8, @intCast(i % 256))} ++ [_]u8{0} ** 19;
        
        // Mix of operations simulating real EVM usage
        const account = database_mod.Account{
            .balance = @as(u256, i) * 1000000000000000000,
            .nonce = @as(u64, @intCast(i)),
            .code_hash = [_]u8{0} ** 32,
            .storage_root = [_]u8{0} ** 32,
        };
        
        db.set_account(addr, account) catch break;
        _ = db.get_account(addr) catch break;
        
        const storage_key: u256 = i;
        const storage_value: u256 = i * 42;
        db.set_storage(addr, storage_key, storage_value) catch break;
        _ = db.get_storage(addr, storage_key) catch break;
        
        _ = db.account_exists(addr) catch break;
        _ = db.is_empty_account(addr) catch break;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    
    var bench = zbench.Benchmark.init(allocator, .{});
    defer bench.deinit();
    
    try bench.add("Database Get Account", benchDatabaseGetAccount, .{});
    try bench.add("Database Set Account", benchDatabaseSetAccount, .{});
    try bench.add("Database Storage Operations", benchDatabaseStorage, .{});
    try bench.add("Database Transient Storage", benchDatabaseTransientStorage, .{});
    try bench.add("Database Code Operations", benchDatabaseCodeOperations, .{});
    try bench.add("Database Mixed Operations", benchDatabaseMixedOperations, .{});
    
    try stdout.print("Running Database Benchmarks...\n");
    try bench.run(stdout);
}