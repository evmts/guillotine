const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const EvmState = evm.EvmState;
const MemoryDatabase = evm.MemoryDatabase;
const primitives = @import("primitives");

// Helper function to create test addresses
fn testAddress(value: u160) primitives.Address.Address {
    return primitives.Address.from_u256(@as(u256, value));
}

test "Memory leak prevention: EvmState transaction clearing" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    // Simulate 1000 transactions
    for (0..1000) |tx_num| {
        const addr = testAddress(@as(u160, @intCast(tx_num % 256)));

        // Each transaction emits logs
        for (0..10) |i| {
            const topics = [_]u256{ tx_num, i };
            const data = try allocator.alloc(u8, 100);
            defer allocator.free(data);
            @memset(data, @as(u8, @intCast(i)));

            try state.emit_log(addr, &topics, data);
        }

        // Set transient storage
        try state.set_transient_storage(addr, 0, tx_num);

        // Mark selfdestructs
        if (tx_num % 100 == 0) {
            const recipient = testAddress(@as(u160, @intCast(tx_num + 1)));
            try state.mark_selfdestruct(addr, recipient);
        }

        // CRITICAL: Clear transaction state to prevent memory leaks
        state.clear_transaction_state();
    }

    // Verify all transaction data was cleared
    try testing.expectEqual(@as(usize, 0), state.logs.items.len);
    try testing.expectEqual(@as(usize, 0), state.transient_storage.count());
    try testing.expectEqual(@as(usize, 0), state.selfdestructs.count());
}

test "Memory leak stress test: logs allocation pattern" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    // Run many iterations to stress test memory management
    for (0..500) |iter| {
        const base_addr = @as(u160, @intCast(iter * 1000));

        // State operations
        for (0..20) |i| {
            const addr = testAddress(base_addr + i);

            // Emit log with allocated data
            const data_size = (i + 1) * 10;
            const data = try allocator.alloc(u8, data_size);
            defer allocator.free(data);
            @memset(data, @as(u8, @intCast(i)));

            const topics = [_]u256{ iter, i };
            try state.emit_log(addr, &topics, data);

            // Set transient storage
            try state.set_transient_storage(addr, i, iter * i);
        }

        // Mark some selfdestructs
        if (iter % 50 == 0) {
            const addr = testAddress(base_addr);
            const recipient = testAddress(base_addr + 999);
            try state.mark_selfdestruct(addr, recipient);
        }

        // Clear all transaction data
        state.clear_transaction_state();
    }

    // Final verification
    try testing.expectEqual(@as(usize, 0), state.logs.items.len);
    try testing.expectEqual(@as(usize, 0), state.transient_storage.count());
    try testing.expectEqual(@as(usize, 0), state.selfdestructs.count());
}
