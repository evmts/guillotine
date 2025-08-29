/// Comprehensive benchmarks for journal operations
/// 
/// This file consolidates benchmarks from:
/// - journal_performance_regression.zig (regression testing)
/// - journal_snapshot_bench.zig (core snapshot operations)
/// 
/// Categories:
/// 1. Core Snapshot Operations
/// 2. Performance Regression Tests
/// 3. Complex Scenarios
/// 4. Configuration Comparisons

const std = @import("std");
const zbench = @import("zbench");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const Journal = @import("journal.zig").Journal;
const JournalConfig = @import("journal_config.zig").JournalConfig;

// =============================================================================
// JOURNAL CONFIGURATIONS FOR TESTING
// =============================================================================

const FastJournal = Journal(.{
    .SnapshotIdType = u32,
    .WordType = u256,
    .NonceType = u64,
    .initial_capacity = 1024,
});

const CompactJournal = Journal(.{
    .SnapshotIdType = u16,
    .WordType = u128,
    .NonceType = u32,
    .initial_capacity = 256,
});

const RegressionJournal = Journal(.{
    .SnapshotIdType = u32,
    .WordType = u256, 
    .NonceType = u64,
    .initial_capacity = 512,
});

// Test data
const test_address = [_]u8{0xAB} ** 20;
const benchmark_addresses = [_][20]u8{
    [_]u8{0x01} ** 20,
    [_]u8{0x02} ** 20,
    [_]u8{0x03} ** 20,
    [_]u8{0x04} ** 20,
    [_]u8{0x05} ** 20,
    [_]u8{0x06} ** 20,
    [_]u8{0x07} ** 20,
    [_]u8{0x08} ** 20,
};

// =============================================================================
// CORE SNAPSHOT OPERATIONS BENCHMARKS
// =============================================================================

fn benchmark_snapshot_create(allocator: std.mem.Allocator) void {
    var journal = FastJournal.init(allocator);
    defer journal.deinit();
    
    // Benchmark: Create 1000 snapshots
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        _ = journal.create_snapshot();
    }
}

fn benchmark_snapshot_create_with_entries(allocator: std.mem.Allocator) void {
    var journal = FastJournal.init(allocator);
    defer journal.deinit();
    
    // Create snapshots with journal entries
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const snapshot = journal.create_snapshot();
        
        // Add some entries to this snapshot
        var j: u256 = 0;
        while (j < 10) : (j += 1) {
            const address = benchmark_addresses[j % benchmark_addresses.len];
            journal.record_storage_change(snapshot, address, j, j * 100) catch break;
        }
    }
}

fn benchmark_snapshot_revert_shallow(allocator: std.mem.Allocator) void {
    var journal = FastJournal.init(allocator);
    defer journal.deinit();
    
    // Create snapshots
    var snapshots: [100]FastJournal.SnapshotIdType = undefined;
    for (&snapshots, 0..) |*snapshot, i| {
        snapshot.* = journal.create_snapshot();
        
        // Add an entry to each snapshot
        const addr = benchmark_addresses[i % benchmark_addresses.len];
        journal.record_storage_change(snapshot.*, addr, @intCast(i), @intCast(i * 42)) catch continue;
    }
    
    // Revert all snapshots (shallow - recent first)
    for (snapshots) |snapshot| {
        journal.revert_to_snapshot(snapshot) catch continue;
    }
}

fn benchmark_journal_entries_recording(allocator: std.mem.Allocator) void {
    var journal = FastJournal.init(allocator);
    defer journal.deinit();
    
    const snapshot = journal.create_snapshot();
    
    // Record 1000 storage changes
    var i: u256 = 0;
    while (i < 1000) : (i += 1) {
        const address = benchmark_addresses[i % benchmark_addresses.len];
        journal.record_storage_change(snapshot, address, i, i * 123) catch return;
    }
}

fn benchmark_mixed_journal_operations(allocator: std.mem.Allocator) void {
    var journal = FastJournal.init(allocator);
    defer journal.deinit();
    
    // Mixed workload: create snapshots, record entries, revert some
    var snapshots: [50]FastJournal.SnapshotIdType = undefined;
    
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        snapshots[i] = journal.create_snapshot();
        
        // Record some entries
        var j: u256 = 0;
        while (j < 20) : (j += 1) {
            const addr = benchmark_addresses[(i + @as(usize, @intCast(j))) % benchmark_addresses.len];
            journal.record_storage_change(snapshots[i], addr, j, j * @as(u256, @intCast(i))) catch break;
        }
        
        // Occasionally revert (every 10th snapshot)
        if (i % 10 == 9 and i > 0) {
            journal.revert_to_snapshot(snapshots[i - 5]) catch continue;
        }
    }
}

// =============================================================================
// PERFORMANCE REGRESSION TESTS
// =============================================================================

fn regression_snapshot_create_1000(allocator: std.mem.Allocator) void {
    // BASELINE: Should create 1000 snapshots in <1ms
    var journal = RegressionJournal.init(allocator);
    defer journal.deinit();
    
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        _ = journal.create_snapshot();
    }
}

fn regression_single_entry_record_1000(allocator: std.mem.Allocator) void {
    // BASELINE: Should record 1000 storage entries in <5ms
    var journal = RegressionJournal.init(allocator);
    defer journal.deinit();
    
    const snapshot = journal.create_snapshot();
    
    var i: u256 = 0;
    while (i < 1000) : (i += 1) {
        journal.record_storage_change(snapshot, test_address, i, i * 100) catch return;
    }
}

fn regression_shallow_revert_100(allocator: std.mem.Allocator) void {
    // BASELINE: Should revert 100 recent snapshots in <1ms
    var journal = RegressionJournal.init(allocator);
    defer journal.deinit();
    
    // Create snapshots with entries
    var snapshots: [100]RegressionJournal.SnapshotIdType = undefined;
    for (&snapshots, 0..) |*snapshot, i| {
        snapshot.* = journal.create_snapshot();
        journal.record_storage_change(snapshot.*, test_address, @intCast(i), @intCast(i * 42)) catch continue;
    }
    
    // Revert all (most recent first - shallow revert pattern)
    var i: usize = snapshots.len;
    while (i > 0) {
        i -= 1;
        journal.revert_to_snapshot(snapshots[i]) catch continue;
    }
}

fn regression_deep_revert_chain(allocator: std.mem.Allocator) void {
    // BASELINE: Deep revert chain should complete in reasonable time
    var journal = RegressionJournal.init(allocator);
    defer journal.deinit();
    
    // Create nested snapshot chain
    var snapshots: [20]RegressionJournal.SnapshotIdType = undefined;
    for (&snapshots, 0..) |*snapshot, i| {
        snapshot.* = journal.create_snapshot();
        
        // Add multiple entries per snapshot level
        var j: u256 = 0;
        while (j < 50) : (j += 1) {
            const key = (@as(u256, @intCast(i)) << 8) | j;
            journal.record_storage_change(snapshot.*, test_address, key, key * 789) catch break;
        }
    }
    
    // Deep revert to first snapshot (should revert all others)
    journal.revert_to_snapshot(snapshots[0]) catch return;
}

// =============================================================================
// CONFIGURATION COMPARISON BENCHMARKS
// =============================================================================

fn benchmark_fast_vs_compact_create(allocator: std.mem.Allocator) void {
    // Compare FastJournal vs CompactJournal for snapshot creation
    
    // Fast journal
    {
        var journal = FastJournal.init(allocator);
        defer journal.deinit();
        
        var i: u32 = 0;
        while (i < 500) : (i += 1) {
            _ = journal.create_snapshot();
        }
    }
    
    // Compact journal  
    {
        var journal = CompactJournal.init(allocator);
        defer journal.deinit();
        
        var i: u16 = 0;
        while (i < 500) : (i += 1) {
            _ = journal.create_snapshot();
        }
    }
}

fn benchmark_memory_usage_patterns(allocator: std.mem.Allocator) void {
    var journal = FastJournal.init(allocator);
    defer journal.deinit();
    
    // Test memory usage with different patterns
    const patterns = [_]struct { snapshots: u32, entries_per: u32 }{
        .{ .snapshots = 100, .entries_per = 10 },
        .{ .snapshots = 50, .entries_per = 20 },
        .{ .snapshots = 25, .entries_per = 40 },
        .{ .snapshots = 10, .entries_per = 100 },
    };
    
    for (patterns) |pattern| {
        var snapshots: [100]FastJournal.SnapshotIdType = undefined;
        
        var i: u32 = 0;
        while (i < pattern.snapshots and i < snapshots.len) : (i += 1) {
            snapshots[i] = journal.create_snapshot();
            
            var j: u32 = 0;
            while (j < pattern.entries_per) : (j += 1) {
                const addr = benchmark_addresses[j % benchmark_addresses.len];
                const key = (@as(u256, i) << 16) | @as(u256, j);
                journal.record_storage_change(snapshots[i], addr, key, key * 111) catch break;
            }
        }
        
        // Clean up this pattern's snapshots
        i = 0;
        while (i < pattern.snapshots and i < snapshots.len) : (i += 1) {
            journal.revert_to_snapshot(snapshots[i]) catch continue;
        }
    }
}

// =============================================================================
// MAIN BENCHMARK RUNNER
// =============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    
    var bench = zbench.Benchmark.init(allocator, .{});
    defer bench.deinit();
    
    try stdout.print("\n📚 Journal Operations Benchmarks\n");
    try stdout.print("=================================\n\n");
    
    // Core Operations
    try stdout.print("Core Snapshot Operations:\n");
    try bench.add("Create 1000 Snapshots", benchmark_snapshot_create, .{});
    try bench.add("Create Snapshots + Entries", benchmark_snapshot_create_with_entries, .{});
    try bench.add("Shallow Revert", benchmark_snapshot_revert_shallow, .{});
    try bench.add("Record 1000 Entries", benchmark_journal_entries_recording, .{});
    try bench.add("Mixed Operations", benchmark_mixed_journal_operations, .{});
    
    // Regression Tests  
    try stdout.print("\nRegression Tests:\n");
    try bench.add("Regression: Create 1000", regression_snapshot_create_1000, .{});
    try bench.add("Regression: Record 1000", regression_single_entry_record_1000, .{});
    try bench.add("Regression: Shallow Revert", regression_shallow_revert_100, .{});
    try bench.add("Regression: Deep Revert", regression_deep_revert_chain, .{});
    
    // Configuration Comparisons
    try stdout.print("\nConfiguration Comparisons:\n");
    try bench.add("Fast vs Compact Create", benchmark_fast_vs_compact_create, .{});
    try bench.add("Memory Usage Patterns", benchmark_memory_usage_patterns, .{});
    
    try stdout.print("\nRunning benchmarks...\n\n");
    try bench.run(stdout);
    
    try stdout.print("\n✅ Journal benchmarks completed!\n");
}

test "journal benchmark compilation" {
    const allocator = std.testing.allocator;
    
    // Test that our benchmark functions compile and run without errors
    var journal = FastJournal.init(allocator);
    defer journal.deinit();
    
    const snapshot = journal.create_snapshot();
    try journal.record_storage_change(snapshot, test_address, 42, 100);
    
    // Test revert
    try journal.revert_to_snapshot(snapshot);
}
