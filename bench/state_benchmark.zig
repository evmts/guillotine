//! Comprehensive benchmarks for EVM state management and database operations
//!
//! This module provides benchmarks for all state management components including:
//! - State operations (get/set/delete)
//! - Database interface operations
//! - Memory database performance
//! - Journal operations (state change tracking)
//! - Large-scale state operations

const std = @import("std");
const testing = std.testing;
const print = std.debug.print;
const primitives = @import("primitives");
const evm = @import("evm");

const EvmState = evm.state.EvmState;
const MemoryDatabase = evm.state.MemoryDatabase;
const DatabaseInterface = evm.state.DatabaseInterface;
const Journal = evm.state.Journal;
const JournalEntry = evm.state.JournalEntry;
const Address = primitives.Address.Address;

// Helper function to create test addresses
fn testAddress(value: u160) Address {
    return primitives.Address.from_u256(@as(u256, value));
}

// Benchmark runner for state operations
pub fn runStateOperationsBenchmarks(allocator: std.mem.Allocator) !void {
    print("\n=== State Operations Benchmarks ===\n");

    try benchmarkBalanceOperations(allocator);
    try benchmarkStorageOperations(allocator);
    try benchmarkTransientStorageOperations(allocator);
    try benchmarkNonceOperations(allocator);
    try benchmarkCodeOperations(allocator);
    try benchmarkLogOperations(allocator);
}

// Benchmark runner for database interface operations
pub fn runDatabaseInterfaceBenchmarks(allocator: std.mem.Allocator) !void {
    print("\n=== Database Interface Benchmarks ===\n");

    try benchmarkDatabaseAccountOps(allocator);
    try benchmarkDatabaseStorageOps(allocator);
    try benchmarkDatabaseCodeOps(allocator);
    try benchmarkDatabaseSnapshotOps(allocator);
    try benchmarkDatabaseBatchOps(allocator);
}

// Benchmark runner for memory database performance
pub fn runMemoryDatabaseBenchmarks(allocator: std.mem.Allocator) !void {
    print("\n=== Memory Database Benchmarks ===\n");

    try benchmarkMemoryDatabaseDirect(allocator);
    try benchmarkMemoryDatabaseStorage(allocator);
    try benchmarkMemoryDatabaseSnapshots(allocator);
    try benchmarkMemoryDatabaseLargeScale(allocator);
}

// Benchmark runner for journal operations
pub fn runJournalBenchmarks(allocator: std.mem.Allocator) !void {
    print("\n=== Journal Operations Benchmarks ===\n");

    try benchmarkJournalEntryManagement(allocator);
    try benchmarkJournalSnapshots(allocator);
    try benchmarkJournalReverts(allocator);
    try benchmarkJournalNestedOperations(allocator);
}

// Benchmark runner for large-scale operations
pub fn runLargeScaleBenchmarks(allocator: std.mem.Allocator) !void {
    print("\n=== Large-Scale State Operations Benchmarks ===\n");

    try benchmarkMixedOperations(allocator);
    try benchmarkBlockchainSimulation(allocator);
}

// Run all state management benchmarks
pub fn runAllStateManagementBenchmarks(allocator: std.mem.Allocator) !void {
    print("\n🚀 Running Comprehensive State Management Benchmarks\n");
    
    try runStateOperationsBenchmarks(allocator);
    try runDatabaseInterfaceBenchmarks(allocator);
    try runMemoryDatabaseBenchmarks(allocator);
    try runJournalBenchmarks(allocator);
    try runLargeScaleBenchmarks(allocator);
    
    print("\n✅ All state management benchmarks completed!\n");
}

// Individual benchmark implementations

fn benchmarkBalanceOperations(allocator: std.mem.Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    const num_accounts = 1000;
    const accounts = try allocator.alloc(Address, num_accounts);
    defer allocator.free(accounts);

    // Initialize accounts
    for (accounts, 0..) |*addr, i| {
        addr.* = testAddress(@intCast(i));
        try state.set_balance(addr.*, @as(u256, i) * 1000);
    }

    const iterations = 10000;
    var timer = try std.time.Timer.start();
    var rng = std.Random.DefaultPrng.init(0);
    var rand = rng.random();

    // Benchmark balance reads
    const read_start = timer.read();
    for (0..iterations) |_| {
        const idx = rand.uintLessThan(usize, num_accounts);
        _ = state.get_balance(accounts[idx]);
    }
    const read_end = timer.read();

    // Benchmark balance writes
    const write_start = timer.read();
    for (0..iterations) |_| {
        const idx = rand.uintLessThan(usize, num_accounts);
        const balance = rand.int(u256);
        try state.set_balance(accounts[idx], balance);
    }
    const write_end = timer.read();

    const read_avg_ns = (read_end - read_start) / iterations;
    const write_avg_ns = (write_end - write_start) / iterations;
    
    print("Balance Operations:\n");
    print("  - Read: {d:.2} ns/op\n", .{@as(f64, @floatFromInt(read_avg_ns))});
    print("  - Write: {d:.2} ns/op\n", .{@as(f64, @floatFromInt(write_avg_ns))});
}

fn benchmarkStorageOperations(allocator: std.mem.Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    const num_addresses = 100;
    const slots_per_address = 100;
    const addresses = try allocator.alloc(Address, num_addresses);
    defer allocator.free(addresses);

    // Initialize addresses and pre-populate storage
    for (addresses, 0..) |*addr, i| {
        addr.* = testAddress(@intCast(i));
        for (0..slots_per_address) |j| {
            try state.set_storage(addr.*, @as(u256, j), @as(u256, i * 1000 + j));
        }
    }

    const iterations = 10000;
    var timer = try std.time.Timer.start();
    var rng = std.Random.DefaultPrng.init(0);
    var rand = rng.random();

    // Benchmark storage reads
    const read_start = timer.read();
    for (0..iterations) |_| {
        const addr_idx = rand.uintLessThan(usize, num_addresses);
        const slot = rand.uintLessThan(u256, slots_per_address);
        _ = state.get_storage(addresses[addr_idx], slot);
    }
    const read_end = timer.read();

    // Benchmark storage writes
    const write_start = timer.read();
    for (0..iterations) |_| {
        const addr_idx = rand.uintLessThan(usize, num_addresses);
        const slot = rand.uintLessThan(u256, slots_per_address);
        const value = rand.int(u256);
        try state.set_storage(addresses[addr_idx], slot, value);
    }
    const write_end = timer.read();

    const read_avg_ns = (read_end - read_start) / iterations;
    const write_avg_ns = (write_end - write_start) / iterations;
    
    print("Storage Operations:\n");
    print("  - Read: {d:.2} ns/op\n", .{@as(f64, @floatFromInt(read_avg_ns))});
    print("  - Write: {d:.2} ns/op\n", .{@as(f64, @floatFromInt(write_avg_ns))});
}

fn benchmarkTransientStorageOperations(allocator: std.mem.Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    const num_addresses = 100;
    const addresses = try allocator.alloc(Address, num_addresses);
    defer allocator.free(addresses);

    for (addresses, 0..) |*addr, i| {
        addr.* = testAddress(@intCast(i));
    }

    const iterations = 10000;
    var timer = try std.time.Timer.start();
    var rng = std.Random.DefaultPrng.init(0);
    var rand = rng.random();

    // Benchmark transient storage writes
    const write_start = timer.read();
    for (0..iterations) |_| {
        const addr_idx = rand.uintLessThan(usize, num_addresses);
        const slot = rand.int(u256);
        const value = rand.int(u256);
        try state.set_transient_storage(addresses[addr_idx], slot, value);
    }
    const write_end = timer.read();

    // Benchmark transient storage reads
    const read_start = timer.read();
    for (0..iterations) |_| {
        const addr_idx = rand.uintLessThan(usize, num_addresses);
        const slot = rand.int(u256);
        _ = state.get_transient_storage(addresses[addr_idx], slot);
    }
    const read_end = timer.read();

    const write_avg_ns = (write_end - write_start) / iterations;
    const read_avg_ns = (read_end - read_start) / iterations;
    
    print("Transient Storage Operations:\n");
    print("  - Read: {d:.2} ns/op\n", .{@as(f64, @floatFromInt(read_avg_ns))});
    print("  - Write: {d:.2} ns/op\n", .{@as(f64, @floatFromInt(write_avg_ns))});
}

fn benchmarkNonceOperations(allocator: std.mem.Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    const num_accounts = 1000;
    const accounts = try allocator.alloc(Address, num_accounts);
    defer allocator.free(accounts);

    for (accounts, 0..) |*addr, i| {
        addr.* = testAddress(@intCast(i));
        try state.set_nonce(addr.*, @intCast(i));
    }

    const iterations = 10000;
    var timer = try std.time.Timer.start();
    var rng = std.Random.DefaultPrng.init(0);
    var rand = rng.random();

    // Benchmark nonce reads
    const read_start = timer.read();
    for (0..iterations) |_| {
        const idx = rand.uintLessThan(usize, num_accounts);
        _ = state.get_nonce(accounts[idx]);
    }
    const read_end = timer.read();

    // Benchmark nonce increments
    const inc_start = timer.read();
    for (0..iterations) |_| {
        const idx = rand.uintLessThan(usize, num_accounts);
        _ = try state.increment_nonce(accounts[idx]);
    }
    const inc_end = timer.read();

    const read_avg_ns = (read_end - read_start) / iterations;
    const inc_avg_ns = (inc_end - inc_start) / iterations;
    
    print("Nonce Operations:\n");
    print("  - Read: {d:.2} ns/op\n", .{@as(f64, @floatFromInt(read_avg_ns))});
    print("  - Increment: {d:.2} ns/op\n", .{@as(f64, @floatFromInt(inc_avg_ns))});
}

fn benchmarkCodeOperations(allocator: std.mem.Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    const num_contracts = 100;
    const contracts = try allocator.alloc(Address, num_contracts);
    defer allocator.free(contracts);

    // Create different code sizes
    const code_sizes = [_]usize{ 100, 1000, 10000, 24000 };
    var code_samples = try allocator.alloc([]u8, code_sizes.len);
    defer {
        for (code_samples) |code| {
            allocator.free(code);
        }
        allocator.free(code_samples);
    }

    // Generate code samples
    for (code_sizes, 0..) |size, i| {
        code_samples[i] = try allocator.alloc(u8, size);
        for (code_samples[i], 0..) |*byte, j| {
            byte.* = @intCast((i + j) % 256);
        }
    }

    // Deploy code to contracts
    for (contracts, 0..) |*addr, i| {
        addr.* = testAddress(@intCast(i));
        const code_idx = i % code_samples.len;
        try state.set_code(addr.*, code_samples[code_idx]);
    }

    const iterations = 1000;
    var timer = try std.time.Timer.start();
    var rng = std.Random.DefaultPrng.init(0);
    var rand = rng.random();

    // Benchmark code reads
    const read_start = timer.read();
    for (0..iterations) |_| {
        const idx = rand.uintLessThan(usize, num_contracts);
        _ = state.get_code(contracts[idx]);
    }
    const read_end = timer.read();

    // Benchmark code writes
    const write_start = timer.read();
    for (0..iterations) |_| {
        const idx = rand.uintLessThan(usize, num_contracts);
        const code_idx = rand.uintLessThan(usize, code_samples.len);
        try state.set_code(contracts[idx], code_samples[code_idx]);
    }
    const write_end = timer.read();

    const read_avg_ns = (read_end - read_start) / iterations;
    const write_avg_ns = (write_end - write_start) / iterations;
    
    print("Code Operations:\n");
    print("  - Read: {d:.2} ns/op\n", .{@as(f64, @floatFromInt(read_avg_ns))});
    print("  - Write: {d:.2} ns/op\n", .{@as(f64, @floatFromInt(write_avg_ns))});
}

fn benchmarkLogOperations(allocator: std.mem.Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    const num_contracts = 100;
    const contracts = try allocator.alloc(Address, num_contracts);
    defer allocator.free(contracts);

    for (contracts, 0..) |*addr, i| {
        addr.* = testAddress(@intCast(i));
    }

    // Prepare different log configurations
    const topic_configs = [_][]u256{
        &[_]u256{},
        &[_]u256{0x1234},
        &[_]u256{ 0x1234, 0x5678 },
        &[_]u256{ 0x1234, 0x5678, 0x9abc },
        &[_]u256{ 0x1234, 0x5678, 0x9abc, 0xdef0 },
    };

    const data_samples = [_][]const u8{
        &[_]u8{},
        &[_]u8{0xFF},
        &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF },
        &([_]u8{0} ** 256),
    };

    const iterations = 5000;
    var timer = try std.time.Timer.start();
    var rng = std.Random.DefaultPrng.init(0);
    var rand = rng.random();

    // Benchmark log emission
    const start = timer.read();
    for (0..iterations) |_| {
        const contract_idx = rand.uintLessThan(usize, num_contracts);
        const topic_idx = rand.uintLessThan(usize, topic_configs.len);
        const data_idx = rand.uintLessThan(usize, data_samples.len);

        try state.emit_log(contracts[contract_idx], topic_configs[topic_idx], data_samples[data_idx]);
    }
    const end = timer.read();

    const avg_ns = (end - start) / iterations;
    print("Log Operations:\n");
    print("  - Emit: {d:.2} ns/op\n", .{@as(f64, @floatFromInt(avg_ns))});
    print("  - Total logs created: {}\n", .{state.logs.items.len});
}

// Database interface benchmarks
fn benchmarkDatabaseAccountOps(allocator: std.mem.Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const num_accounts = 1000;

    var timer = try std.time.Timer.start();

    // Benchmark account creation
    const create_start = timer.read();
    for (0..num_accounts) |i| {
        const addr = primitives.Address.from_u256(@as(u256, i));
        const account = DatabaseInterface.Account{
            .balance = @as(u256, i) * 1000,
            .nonce = @intCast(i),
            .code_hash = [_]u8{0} ** 32,
            .storage_root = [_]u8{0} ** 32,
        };
        try db_interface.set_account(primitives.Address.to_bytes(addr), account);
    }
    const create_end = timer.read();

    const create_avg_ns = (create_end - create_start) / num_accounts;
    print("Database Account Operations:\n");
    print("  - Create: {d:.2} ns/op\n", .{@as(f64, @floatFromInt(create_avg_ns))});
}

fn benchmarkDatabaseStorageOps(allocator: std.mem.Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const num_operations = 10000;

    var timer = try std.time.Timer.start();
    var rng = std.Random.DefaultPrng.init(0);
    var rand = rng.random();

    // Benchmark storage operations
    const start = timer.read();
    for (0..num_operations) |_| {
        const addr = primitives.Address.to_bytes(primitives.Address.from_u256(rand.int(u256)));
        const slot = rand.int(u256);
        const value = rand.int(u256);
        try db_interface.set_storage(addr, slot, value);
    }
    const end = timer.read();

    const avg_ns = (end - start) / num_operations;
    print("Database Storage Operations:\n");
    print("  - Set: {d:.2} ns/op\n", .{@as(f64, @floatFromInt(avg_ns))});
}

fn benchmarkDatabaseCodeOps(allocator: std.mem.Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    // Create code samples of different sizes
    const code_sizes = [_]usize{ 100, 1000, 10000 };
    var code_samples = try allocator.alloc([]u8, code_sizes.len);
    defer {
        for (code_samples) |code| {
            allocator.free(code);
        }
        allocator.free(code_samples);
    }

    for (code_sizes, 0..) |size, i| {
        code_samples[i] = try allocator.alloc(u8, size);
        for (code_samples[i], 0..) |*byte, j| {
            byte.* = @intCast((i + j) % 256);
        }
    }

    var timer = try std.time.Timer.start();

    // Benchmark code storage
    const start = timer.read();
    for (code_samples) |code| {
        _ = try db_interface.set_code(code);
    }
    const end = timer.read();

    const avg_ns = (end - start) / code_samples.len;
    print("Database Code Operations:\n");
    print("  - Set: {d:.2} ns/op\n", .{@as(f64, @floatFromInt(avg_ns))});
}

fn benchmarkDatabaseSnapshotOps(allocator: std.mem.Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    // Populate some state first
    for (0..100) |i| {
        const addr = primitives.Address.to_bytes(primitives.Address.from_u256(@as(u256, i)));
        const account = DatabaseInterface.Account{
            .balance = @as(u256, i) * 1000,
            .nonce = @intCast(i),
            .code_hash = [_]u8{0} ** 32,
            .storage_root = [_]u8{0} ** 32,
        };
        try db_interface.set_account(addr, account);
    }

    const num_snapshots = 50;
    var snapshots = try allocator.alloc(u64, num_snapshots);
    defer allocator.free(snapshots);

    var timer = try std.time.Timer.start();

    // Benchmark snapshot creation
    const create_start = timer.read();
    for (0..num_snapshots) |i| {
        snapshots[i] = try db_interface.create_snapshot();
        // Make a small change
        const addr = primitives.Address.to_bytes(primitives.Address.from_u256(@as(u256, i)));
        try db_interface.set_storage(addr, @as(u256, i), @as(u256, i) * 999);
    }
    const create_end = timer.read();

    const create_avg_ns = (create_end - create_start) / num_snapshots;
    print("Database Snapshot Operations:\n");
    print("  - Create: {d:.2} ns/op\n", .{@as(f64, @floatFromInt(create_avg_ns))});
}

fn benchmarkDatabaseBatchOps(allocator: std.mem.Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    const num_batches = 100;
    const ops_per_batch = 100;

    var timer = try std.time.Timer.start();

    // Benchmark batch operations
    const start = timer.read();
    for (0..num_batches) |batch_idx| {
        try db_interface.begin_batch();

        for (0..ops_per_batch) |op_idx| {
            const i = batch_idx * ops_per_batch + op_idx;
            const addr = primitives.Address.to_bytes(primitives.Address.from_u256(@as(u256, i)));
            const account = DatabaseInterface.Account{
                .balance = @as(u256, i) * 1000,
                .nonce = @intCast(i),
                .code_hash = [_]u8{0} ** 32,
                .storage_root = [_]u8{0} ** 32,
            };
            try db_interface.set_account(addr, account);
        }

        try db_interface.commit_batch();
    }
    const end = timer.read();

    const total_ops = num_batches * ops_per_batch;
    const avg_ns = (end - start) / total_ops;
    print("Database Batch Operations:\n");
    print("  - Batched: {d:.2} ns/op\n", .{@as(f64, @floatFromInt(avg_ns))});
}

// Memory database benchmarks
fn benchmarkMemoryDatabaseDirect(allocator: std.mem.Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const num_accounts = 10000;
    var timer = try std.time.Timer.start();

    // Benchmark direct account operations
    const start = timer.read();
    for (0..num_accounts) |i| {
        const addr = primitives.Address.to_bytes(primitives.Address.from_u256(@as(u256, i)));
        const account = DatabaseInterface.Account{
            .balance = @as(u256, i) * 1000,
            .nonce = @intCast(i),
            .code_hash = [_]u8{0} ** 32,
            .storage_root = [_]u8{0} ** 32,
        };
        try memory_db.set_account(addr, account);
    }
    const end = timer.read();

    const avg_ns = (end - start) / num_accounts;
    print("Memory Database Direct Operations:\n");
    print("  - Account Set: {d:.2} ns/op\n", .{@as(f64, @floatFromInt(avg_ns))});
}

fn benchmarkMemoryDatabaseStorage(allocator: std.mem.Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const num_operations = 100000;
    var timer = try std.time.Timer.start();
    var rng = std.Random.DefaultPrng.init(0);
    var rand = rng.random();

    // Benchmark storage operations
    const start = timer.read();
    for (0..num_operations) |_| {
        const addr = primitives.Address.to_bytes(primitives.Address.from_u256(rand.int(u128))); // Use smaller range for better cache behavior
        const slot = rand.int(u256);
        const value = rand.int(u256);
        try memory_db.set_storage(addr, slot, value);
    }
    const end = timer.read();

    const avg_ns = (end - start) / num_operations;
    print("Memory Database Storage:\n");
    print("  - Storage Set: {d:.2} ns/op\n", .{@as(f64, @floatFromInt(avg_ns))});
    print("  - Total storage entries: {}\n", .{memory_db.storage.count()});
}

fn benchmarkMemoryDatabaseSnapshots(allocator: std.mem.Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create substantial state
    for (0..500) |i| {
        const addr = primitives.Address.to_bytes(primitives.Address.from_u256(@as(u256, i)));
        const account = DatabaseInterface.Account{
            .balance = @as(u256, i) * 1000000,
            .nonce = @intCast(i),
            .code_hash = [_]u8{0} ** 32,
            .storage_root = [_]u8{0} ** 32,
        };
        try memory_db.set_account(addr, account);

        // Add storage
        for (0..50) |j| {
            try memory_db.set_storage(addr, @as(u256, j), @as(u256, i * 10000 + j));
        }
    }

    const num_snapshots = 100;
    var snapshots = try allocator.alloc(u64, num_snapshots);
    defer allocator.free(snapshots);

    var timer = try std.time.Timer.start();

    // Benchmark snapshot creation
    const create_start = timer.read();
    for (0..num_snapshots) |i| {
        snapshots[i] = try memory_db.create_snapshot();
        
        // Make modifications
        const addr = primitives.Address.to_bytes(primitives.Address.from_u256(@as(u256, i % 500)));
        try memory_db.set_storage(addr, @as(u256, i + 1000), @as(u256, i * 9999));
    }
    const create_end = timer.read();

    const create_avg_ns = (create_end - create_start) / num_snapshots;
    print("Memory Database Snapshots:\n");
    print("  - Create: {d:.2} ns/snapshot\n", .{@as(f64, @floatFromInt(create_avg_ns))});
}

fn benchmarkMemoryDatabaseLargeScale(allocator: std.mem.Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const num_accounts = 50000;
    var timer = try std.time.Timer.start();
    var rng = std.Random.DefaultPrng.init(12345);
    var rand = rng.random();

    const start = timer.read();

    // Create large-scale state
    for (0..num_accounts) |i| {
        const addr = primitives.Address.to_bytes(primitives.Address.from_u256(@as(u256, i)));
        
        const account = DatabaseInterface.Account{
            .balance = rand.int(u128),
            .nonce = rand.int(u32),
            .code_hash = [_]u8{0} ** 32,
            .storage_root = [_]u8{0} ** 32,
        };
        try memory_db.set_account(addr, account);

        // Add variable storage
        const num_slots = rand.uintLessThan(usize, 40);
        for (0..num_slots) |_| {
            const slot = rand.int(u256);
            const value = rand.int(u256);
            try memory_db.set_storage(addr, slot, value);
        }
    }

    const creation_end = timer.read();
    const creation_time_ms = (creation_end - start) / 1_000_000;
    
    print("Memory Database Large Scale:\n");
    print("  - Created {} accounts in {} ms\n", .{ num_accounts, creation_time_ms });
    print("  - Database size: {} accounts, {} storage entries\n", .{ memory_db.accounts.count(), memory_db.storage.count() });
}

// Journal benchmarks
fn benchmarkJournalEntryManagement(allocator: std.mem.Allocator) !void {
    var journal = Journal.init(allocator);
    defer journal.deinit();

    const num_entries = 100000;
    var timer = try std.time.Timer.start();
    var rng = std.Random.DefaultPrng.init(0);
    var rand = rng.random();

    // Benchmark adding entries
    const start = timer.read();
    for (0..num_entries) |i| {
        const addr = testAddress(@intCast(i % 1000));
        const entry_type = rand.uintLessThan(u8, 4);

        const entry: JournalEntry = switch (entry_type) {
            0 => .{ .balance_changed = .{
                .address = addr,
                .previous_balance = rand.int(u256),
            } },
            1 => .{ .nonce_changed = .{
                .address = addr,
                .previous_nonce = rand.int(u64),
            } },
            2 => .{ .storage_changed = .{
                .address = addr,
                .slot = rand.int(u256),
                .previous_value = rand.int(u256),
            } },
            3 => .{ .account_created = .{
                .address = addr,
            } },
            else => unreachable,
        };

        try journal.add_entry(entry);
    }
    const end = timer.read();

    const avg_ns = (end - start) / num_entries;
    print("Journal Entry Management:\n");
    print("  - Add Entry: {d:.2} ns/entry\n", .{@as(f64, @floatFromInt(avg_ns))});
    print("  - Final journal size: {} entries\n", .{journal.entry_count()});
}

fn benchmarkJournalSnapshots(allocator: std.mem.Allocator) !void {
    var journal = Journal.init(allocator);
    defer journal.deinit();

    // Pre-populate with entries
    for (0..10000) |i| {
        const addr = testAddress(@intCast(i % 1000));
        try journal.add_entry(.{ .balance_changed = .{
            .address = addr,
            .previous_balance = @as(u256, i) * 1000,
        } });
    }

    const num_snapshots = 10000;
    var timer = try std.time.Timer.start();

    // Benchmark snapshot creation
    const start = timer.read();
    for (0..num_snapshots) |i| {
        _ = try journal.snapshot();
        
        // Add entry between snapshots
        const addr = testAddress(@intCast(i % 100));
        try journal.add_entry(.{ .storage_changed = .{
            .address = addr,
            .slot = @as(u256, i),
            .previous_value = @as(u256, i) * 999,
        } });
    }
    const end = timer.read();

    const avg_ns = (end - start) / num_snapshots;
    print("Journal Snapshots:\n");
    print("  - Create: {d:.2} ns/snapshot\n", .{@as(f64, @floatFromInt(avg_ns))});
}

// Mock state for journal benchmarks
const MockState = struct {
    operation_count: usize = 0,

    pub fn set_balance_direct(self: *MockState, address: Address, balance: u256) !void {
        _ = address;
        _ = balance;
        self.operation_count += 1;
    }

    pub fn set_nonce_direct(self: *MockState, address: Address, nonce: u64) !void {
        _ = address;
        _ = nonce;
        self.operation_count += 1;
    }

    pub fn set_storage_direct(self: *MockState, address: Address, slot: u256, value: u256) !void {
        _ = address;
        _ = slot;
        _ = value;
        self.operation_count += 1;
    }

    pub fn set_transient_storage_direct(self: *MockState, address: Address, slot: u256, value: u256) !void {
        _ = address;
        _ = slot;
        _ = value;
        self.operation_count += 1;
    }

    pub fn set_code_direct(self: *MockState, address: Address, code: []const u8) !void {
        _ = address;
        _ = code;
        self.operation_count += 1;
    }

    pub fn remove_balance(self: *MockState, address: Address) void {
        _ = address;
        self.operation_count += 1;
    }

    pub fn remove_nonce(self: *MockState, address: Address) void {
        _ = address;
        self.operation_count += 1;
    }

    pub fn remove_code(self: *MockState, address: Address) void {
        _ = address;
        self.operation_count += 1;
    }

    pub fn remove_log(self: *MockState, log_index: usize) !void {
        _ = log_index;
        self.operation_count += 1;
    }
};

fn benchmarkJournalReverts(allocator: std.mem.Allocator) !void {
    var journal = Journal.init(allocator);
    defer journal.deinit();

    var mock_state = MockState{};
    var timer = try std.time.Timer.start();

    // Test different revert sizes
    const revert_sizes = [_]usize{ 10, 100, 1000, 5000 };
    
    print("Journal Reverts:\n");
    for (revert_sizes) |revert_size| {
        journal.clear();
        
        const snapshot = try journal.snapshot();

        // Add entries to revert
        for (0..revert_size) |i| {
            const addr = testAddress(@intCast(i % 100));
            try journal.add_entry(.{ .balance_changed = .{
                .address = addr,
                .previous_balance = @as(u256, i) * 1000,
            } });
        }

        const revert_start = timer.read();
        try journal.revert(snapshot, &mock_state);
        const revert_end = timer.read();

        const revert_time_ns = revert_end - revert_start;
        const avg_ns_per_entry = revert_time_ns / revert_size;
        print("  - {} entries: {d:.2} ns/entry\n", .{ revert_size, @as(f64, @floatFromInt(avg_ns_per_entry)) });
    }
}

fn benchmarkJournalNestedOperations(allocator: std.mem.Allocator) !void {
    var journal = Journal.init(allocator);
    defer journal.deinit();

    var mock_state = MockState{};
    const depth = 100;
    const entries_per_level = 50;

    var timer = try std.time.Timer.start();

    // Benchmark nested snapshot creation
    const create_start = timer.read();
    for (0..depth) |level| {
        _ = try journal.snapshot();
        
        for (0..entries_per_level) |i| {
            const addr = testAddress(@intCast((level * 1000 + i) % 5000));
            try journal.add_entry(.{ .balance_changed = .{
                .address = addr,
                .previous_balance = @as(u256, level * 10000 + i),
            } });
        }
    }
    const create_end = timer.read();

    const create_avg_ns = (create_end - create_start) / depth;
    print("Journal Nested Operations:\n");
    print("  - Nested snapshot creation: {d:.2} ns/snapshot\n", .{@as(f64, @floatFromInt(create_avg_ns))});
    print("  - Total entries: {}\n", .{journal.entry_count()});
}

// Large-scale benchmarks
fn benchmarkMixedOperations(allocator: std.mem.Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    const num_addresses = 1000;
    const addresses = try allocator.alloc(Address, num_addresses);
    defer allocator.free(addresses);

    for (addresses, 0..) |*addr, i| {
        addr.* = testAddress(@intCast(i));
    }

    const iterations = 50000;
    var timer = try std.time.Timer.start();
    var rng = std.Random.DefaultPrng.init(0);
    var rand = rng.random();

    const start = timer.read();
    for (0..iterations) |_| {
        const addr_idx = rand.uintLessThan(usize, num_addresses);
        const addr = addresses[addr_idx];
        const operation = rand.uintLessThan(u8, 5);

        switch (operation) {
            0 => {
                // Balance operation
                const balance = rand.int(u256);
                try state.set_balance(addr, balance);
                _ = state.get_balance(addr);
            },
            1 => {
                // Nonce operation
                _ = try state.increment_nonce(addr);
            },
            2 => {
                // Storage operation
                const slot = rand.int(u256);
                const value = rand.int(u256);
                try state.set_storage(addr, slot, value);
                _ = state.get_storage(addr, slot);
            },
            3 => {
                // Transient storage operation
                const slot = rand.int(u256);
                const value = rand.int(u256);
                try state.set_transient_storage(addr, slot, value);
                _ = state.get_transient_storage(addr, slot);
            },
            4 => {
                // Log operation
                const topics = [_]u256{rand.int(u256)};
                const data = [_]u8{@intCast(rand.uintLessThan(u8, 256))};
                try state.emit_log(addr, &topics, &data);
            },
            else => unreachable,
        }
    }
    const end = timer.read();

    const avg_ns = (end - start) / iterations;
    print("Mixed Operations:\n");
    print("  - Mixed ops: {d:.2} ns/op\n", .{@as(f64, @floatFromInt(avg_ns))});
    print("  - Final logs: {}\n", .{state.logs.items.len});
}

fn benchmarkBlockchainSimulation(allocator: std.mem.Allocator) !void {
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    // Simulate realistic blockchain state
    const num_accounts = 10000;
    const transactions_per_block = 100;
    const num_blocks = 10;

    var timer = try std.time.Timer.start();
    var rng = std.Random.DefaultPrng.init(42);
    var rand = rng.random();

    // Create initial accounts
    for (0..num_accounts) |i| {
        const addr = testAddress(@intCast(i));
        try state.set_balance(addr, rand.int(u128));
        try state.set_nonce(addr, rand.int(u32));
    }

    print("Blockchain Simulation:\n");
    print("  - Initial state: {} accounts\n", .{num_accounts});

    const simulation_start = timer.read();

    // Simulate blocks
    for (0..num_blocks) |block_num| {
        const block_start = timer.read();
        
        // Simulate transactions in this block
        for (0..transactions_per_block) |_| {
            const from_idx = rand.uintLessThan(usize, num_accounts);
            const to_idx = rand.uintLessThan(usize, num_accounts);
            
            if (from_idx == to_idx) continue;
            
            const from_addr = testAddress(@intCast(from_idx));
            const to_addr = testAddress(@intCast(to_idx));
            
            // Simulate transaction
            const from_balance = state.get_balance(from_addr);
            const transfer_amount = rand.uintLessThan(u256, @min(from_balance, 1000000));
            
            if (transfer_amount > 0) {
                try state.set_balance(from_addr, from_balance - transfer_amount);
                try state.set_balance(to_addr, state.get_balance(to_addr) + transfer_amount);
                _ = try state.increment_nonce(from_addr);
                
                // Occasionally emit logs
                if (rand.uintLessThan(u8, 10) == 0) {
                    const topics = [_]u256{0x1234567890abcdef};
                    const data = std.mem.asBytes(&transfer_amount);
                    try state.emit_log(from_addr, &topics, data);
                }
            }
        }
        
        const block_end = timer.read();
        const block_time_ms = (block_end - block_start) / 1_000_000;
        print("  - Block {}: {} ms\n", .{ block_num, block_time_ms });
    }

    const simulation_end = timer.read();
    const total_time_ms = (simulation_end - simulation_start) / 1_000_000;
    
    print("  - Total simulation: {} ms\n", .{total_time_ms});
    print("  - Total transactions: {}\n", .{num_blocks * transactions_per_block});
    print("  - Final logs: {}\n", .{state.logs.items.len});
}