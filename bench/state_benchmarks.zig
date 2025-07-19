/// State Management Benchmarks for GitHub Issue #61
///
/// Comprehensive performance benchmarks for EVM state management operations
/// including database read/write, state root calculations, journal operations,
/// and cache efficiency patterns.
const std = @import("std");
const Evm = @import("evm");
const primitives = @import("primitives");
const zbench = @import("zbench");

/// Benchmark database account read operations
pub fn zbench_account_read(allocator: std.mem.Allocator) void {
    // Initialize memory database
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    // Prepare test account data
    const test_address = primitives.Address.zero();
    var account = Evm.Account{ .balance = primitives.Numeric.U256.ZERO, .nonce = 0, .code_hash = primitives.Numeric.B256.ZERO, .storage_root = primitives.Numeric.B256.ZERO };
    account.balance = primitives.Numeric.U256.from_u64(1000000);
    account.nonce = 42;

    // Pre-populate database
    db_interface.set_account(test_address, account) catch unreachable;

    // Benchmark account reads
    const iterations = 1000;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        _ = db_interface.get_account(test_address) catch unreachable;
    }
}

/// Benchmark database account write operations
pub fn zbench_account_write(allocator: std.mem.Allocator) void {
    // Initialize memory database
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    // Prepare test data
    const test_address = primitives.Address.zero();
    var account = Evm.Account{ .balance = primitives.Numeric.U256.ZERO, .nonce = 0, .code_hash = primitives.Numeric.B256.ZERO, .storage_root = primitives.Numeric.B256.ZERO };

    // Benchmark account writes
    const iterations = 1000;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        account.nonce = i;
        account.balance = primitives.Numeric.U256.from_u64(i * 1000);
        db_interface.set_account(test_address, account) catch unreachable;
    }
}

/// Benchmark storage read/write operations
pub fn zbench_storage_ops(allocator: std.mem.Allocator) void {
    // Initialize memory database
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    // Prepare test data
    const test_address = primitives.Address.zero();
    const iterations = 1000;

    // Benchmark storage operations
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const key = primitives.Numeric.U256.from_u64(i);
        const value = primitives.Numeric.U256.from_u64(i * 2);
        
        // Write storage
        db_interface.set_storage(test_address, key, value) catch unreachable;
        
        // Read storage
        _ = db_interface.get_storage(test_address, key) catch unreachable;
    }
}

/// Benchmark state root calculation performance
pub fn zbench_state_root(allocator: std.mem.Allocator) void {
    // Initialize EVM state
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = Evm.EvmState.init(db_interface, allocator) catch unreachable;
    defer state.deinit();

    // Pre-populate state with test data
    const num_accounts = 100;
    var i: usize = 0;
    while (i < num_accounts) : (i += 1) {
        var address = primitives.Address.zero();
        address.bytes[19] = @intCast(i); // Modify last byte for unique addresses
        
        const balance = primitives.Numeric.U256.from_u64(i * 1000);
        state.set_balance(address, balance) catch unreachable;
        
        // Add some storage entries
        const key = primitives.Numeric.U256.from_u64(i);
        const value = primitives.Numeric.U256.from_u64(i * 2);
        state.set_storage(address, key, value) catch unreachable;
    }

    // Benchmark state root calculation
    const iterations = 10;
    var j: usize = 0;
    while (j < iterations) : (j += 1) {
        _ = state.state_root() catch unreachable;
    }
}

/// Benchmark journal operations for transaction tracking
pub fn zbench_journal_ops(allocator: std.mem.Allocator) void {
    _ = allocator;
    // TODO: Implement journal benchmarks when journal functionality is available
    // For now, this is a placeholder benchmark
    const iterations = 1000;
    var i: usize = 0;
    var sum: u64 = 0;
    
    while (i < iterations) : (i += 1) {
        sum += i;
    }
    
    // Prevent compiler from optimizing away the work
    std.debug.assert(sum > 0);
}

/// Benchmark full EVM state operations
pub fn zbench_evm_state_full(allocator: std.mem.Allocator) void {
    // Initialize complete EVM state
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = Evm.EvmState.init(db_interface, allocator) catch unreachable;
    defer state.deinit();

    // Simulate complex transaction processing
    const num_transactions = 50;
    var tx: usize = 0;
    while (tx < num_transactions) : (tx += 1) {
        // Create snapshot for transaction
        const snapshot = state.snapshot();
        
        var address = primitives.Address.zero();
        address.bytes[19] = @intCast(tx % 256);
        
        // Account operations
        const balance = primitives.Numeric.U256.from_u64(tx * 1000);
        state.set_balance(address, balance) catch unreachable;
        _ = state.get_balance(address) catch unreachable;
        
        // Storage operations
        var slot: usize = 0;
        while (slot < 10) : (slot += 1) {
            const key = primitives.Numeric.U256.from_u64(slot);
            const value = primitives.Numeric.U256.from_u64(tx * 100 + slot);
            state.set_storage(address, key, value) catch unreachable;
            _ = state.get_storage(address, key) catch unreachable;
        }
        
        // Log operations
        const log_data = [_]u8{0x01, 0x02, 0x03, 0x04};
        const topics = [_]primitives.Numeric.B256{primitives.Numeric.B256.ZERO};
        state.emit_log(address, &topics, &log_data) catch unreachable;
        
        // Simulate transaction success/failure (revert some transactions)
        if (tx % 7 == 0) {
            state.revert(snapshot) catch unreachable;
        }
    }
    
    // Final state root calculation
    _ = state.state_root() catch unreachable;
}

test "state benchmarks compile and run" {
    const allocator = std.testing.allocator;
    
    // Test that all benchmark functions can be called without panicking
    zbench_account_read(allocator);
    zbench_account_write(allocator);
    zbench_storage_ops(allocator);
    zbench_state_root(allocator);
    zbench_journal_ops(allocator);
    zbench_evm_state_full(allocator);
    
    // If we reach here, all benchmarks executed successfully
    try std.testing.expect(true);
}