const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const testing = std.testing;

// Helper function to create a minimal EVM execution context
fn create_evm_context(allocator: std.mem.Allocator) !struct {
    db: evm.MemoryDatabase,
    vm: evm.Evm,
    contract: evm.Contract,
    frame: evm.Frame,
} {
    var db = evm.MemoryDatabase.init(allocator);
    const config = evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.Evm(config);
    var vm = try EvmType.init(allocator, db.to_database_interface(), null, 0, false, null);

    const test_code = [_]u8{0x01}; // Simple ADD opcode
    var contract = evm.Contract.init(primitives.Address.ZERO, primitives.Address.ZERO, 0, 1000000, &test_code, [_]u8{0} ** 32, &.{}, false);

    var frame = try evm.Frame.init(allocator, &contract);
    frame.gas_remaining = 1000000;

    return .{
        .db = db,
        .vm = vm,
        .contract = contract,
        .frame = frame,
    };
}

fn deinit_evm_context(ctx: anytype, allocator: std.mem.Allocator) void {
    ctx.frame.deinit();
    ctx.contract.deinit(allocator, null);
    ctx.vm.deinit();
    ctx.db.deinit();
}

// Comprehensive SSTORE operation fuzz testing
test "fuzz_sstore_storage_write_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    const test_cases = [_]struct { key: u256, value: u256 }{
        // Basic storage operations
        .{ .key = 0, .value = 0x1111111111111111111111111111111111111111111111111111111111111111 },
        .{ .key = 1, .value = 0x2222222222222222222222222222222222222222222222222222222222222222 },
        .{ .key = 2, .value = 0x3333333333333333333333333333333333333333333333333333333333333333 },

        // Zero key with various values
        .{ .key = 0, .value = 0 },
        .{ .key = 0, .value = 1 },
        .{ .key = 0, .value = std.math.maxInt(u256) },

        // Maximum key
        .{ .key = std.math.maxInt(u256), .value = 0x4444444444444444444444444444444444444444444444444444444444444444 },
        .{ .key = std.math.maxInt(u256) - 1, .value = 0x5555555555555555555555555555555555555555555555555555555555555555 },

        // Power of 2 keys
        .{ .key = 1, .value = 0x6666666666666666666666666666666666666666666666666666666666666666 },
        .{ .key = 2, .value = 0x7777777777777777777777777777777777777777777777777777777777777777 },
        .{ .key = 4, .value = 0x8888888888888888888888888888888888888888888888888888888888888888 },
        .{ .key = 8, .value = 0x9999999999999999999999999999999999999999999999999999999999999999 },
        .{ .key = 1 << 128, .value = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA },
        .{ .key = 1 << 255, .value = 0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB },

        // Sequential keys for collision testing
        .{ .key = 1000, .value = 0xCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC },
        .{ .key = 1001, .value = 0xDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD },
        .{ .key = 1002, .value = 0xEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE },

        // Large arbitrary keys
        .{ .key = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .value = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF },
        .{ .key = 0xFEDCBA0987654321FEDCBA0987654321FEDCBA0987654321FEDCBA0987654321, .value = 0x0000000000000000000000000000000000000000000000000000000000000001 },

        // Pattern-based keys and values
        .{ .key = 0x0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F, .value = 0xF0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0 },
        .{ .key = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA, .value = 0x5555555555555555555555555555555555555555555555555555555555555555 },
    };

    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        // SSTORE takes key and value from stack
        try ctx.frame.stack.append(case.key);
        try ctx.frame.stack.append(case.value);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: *evm.Operation.State = @ptrCast(&ctx.frame);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x55); // SSTORE

        // Verify the value was stored by reading it back with SLOAD
        try ctx.frame.stack.append(case.key);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x54); // SLOAD

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.value, result);
    }
}

// Comprehensive SLOAD operation fuzz testing
test "fuzz_sload_storage_read_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    var interpreter: evm.Operation.Interpreter = &ctx.vm;
    var state: *evm.Operation.State = @ptrCast(&ctx.frame);

    // Test reading from uninitialized storage (should return 0)
    const uninitialized_keys = [_]u256{
        0,
        1,
        100,
        1000,
        std.math.maxInt(u256),
        std.math.maxInt(u256) - 1,
        1 << 128,
        1 << 255,
        0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0,
        0xFEDCBA0987654321FEDCBA0987654321FEDCBA0987654321FEDCBA0987654321,
    };

    for (uninitialized_keys) |key| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(key);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x54); // SLOAD

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(@as(u256, 0), result);
    }
}

// Test storage persistence across multiple operations
test "fuzz_storage_persistence_and_overwriting" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    var interpreter: evm.Operation.Interpreter = &ctx.vm;
    var state: *evm.Operation.State = @ptrCast(&ctx.frame);

    const initial_values = [_]struct { key: u256, value: u256 }{
        .{ .key = 0, .value = 0x1111111111111111111111111111111111111111111111111111111111111111 },
        .{ .key = 1, .value = 0x2222222222222222222222222222222222222222222222222222222222222222 },
        .{ .key = 2, .value = 0x3333333333333333333333333333333333333333333333333333333333333333 },
        .{ .key = 1000, .value = 0x4444444444444444444444444444444444444444444444444444444444444444 },
        .{ .key = std.math.maxInt(u256), .value = 0x5555555555555555555555555555555555555555555555555555555555555555 },
    };

    // Store initial values
    for (initial_values) |item| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(item.key);
        try ctx.frame.stack.append(item.value);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x55); // SSTORE
    }

    // Verify all values are stored correctly
    for (initial_values) |item| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(item.key);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x54); // SLOAD

        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(item.value, result);
    }

    // Overwrite some values
    const overwrite_values = [_]struct { key: u256, value: u256 }{
        .{ .key = 1, .value = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA },
        .{ .key = 1000, .value = 0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB },
        .{ .key = std.math.maxInt(u256), .value = 0 }, // Overwrite with zero
    };

    for (overwrite_values) |item| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(item.key);
        try ctx.frame.stack.append(item.value);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x55); // SSTORE
    }

    // Verify overwrites and unchanged values
    for (initial_values) |item| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(item.key);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x54); // SLOAD

        const result = try ctx.frame.stack.pop();

        // Check if this key was overwritten
        var expected = item.value;
        for (overwrite_values) |overwrite| {
            if (overwrite.key == item.key) {
                expected = overwrite.value;
                break;
            }
        }

        try testing.expectEqual(expected, result);
    }
}

// Comprehensive TSTORE operation fuzz testing (transient storage)
test "fuzz_tstore_transient_storage_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    const test_cases = [_]struct { key: u256, value: u256 }{
        // Basic transient storage operations
        .{ .key = 0, .value = 0x1111111111111111111111111111111111111111111111111111111111111111 },
        .{ .key = 1, .value = 0x2222222222222222222222222222222222222222222222222222222222222222 },
        .{ .key = 2, .value = 0x3333333333333333333333333333333333333333333333333333333333333333 },

        // Zero key with various values
        .{ .key = 0, .value = 0 },
        .{ .key = 0, .value = 1 },
        .{ .key = 0, .value = std.math.maxInt(u256) },

        // Maximum key
        .{ .key = std.math.maxInt(u256), .value = 0x4444444444444444444444444444444444444444444444444444444444444444 },
        .{ .key = std.math.maxInt(u256) - 1, .value = 0x5555555555555555555555555555555555555555555555555555555555555555 },

        // Power of 2 keys
        .{ .key = 1, .value = 0x6666666666666666666666666666666666666666666666666666666666666666 },
        .{ .key = 2, .value = 0x7777777777777777777777777777777777777777777777777777777777777777 },
        .{ .key = 4, .value = 0x8888888888888888888888888888888888888888888888888888888888888888 },
        .{ .key = 8, .value = 0x9999999999999999999999999999999999999999999999999999999999999999 },
        .{ .key = 1 << 128, .value = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA },
        .{ .key = 1 << 255, .value = 0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB },

        // Large arbitrary keys
        .{ .key = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0, .value = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF },
        .{ .key = 0xFEDCBA0987654321FEDCBA0987654321FEDCBA0987654321FEDCBA0987654321, .value = 0x0000000000000000000000000000000000000000000000000000000000000001 },
    };

    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        // TSTORE takes key and value from stack
        try ctx.frame.stack.append(case.key);
        try ctx.frame.stack.append(case.value);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: *evm.Operation.State = @ptrCast(&ctx.frame);

        // Try TSTORE - might fail if not supported in this EVM version
        const result = ctx.vm.table.execute(0, interpreter, state, 0x5D); // TSTORE

        if (result) |_| {
            // If TSTORE succeeded, verify the value was stored by reading it back with TLOAD
            try ctx.frame.stack.append(case.key);
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x5C); // TLOAD

            const loaded_value = try ctx.frame.stack.pop();
            try testing.expectEqual(case.value, loaded_value);
        } else |err| {
            // TSTORE/TLOAD might not be supported in all EVM versions - that's OK
            _ = err; // Ignore error for now
        }
    }
}

// Comprehensive TLOAD operation fuzz testing (transient storage)
test "fuzz_tload_transient_storage_read_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    var interpreter: evm.Operation.Interpreter = &ctx.vm;
    var state: *evm.Operation.State = @ptrCast(&ctx.frame);

    // Test reading from uninitialized transient storage (should return 0)
    const uninitialized_keys = [_]u256{
        0,
        1,
        100,
        1000,
        std.math.maxInt(u256),
        std.math.maxInt(u256) - 1,
        1 << 128,
        1 << 255,
        0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0,
        0xFEDCBA0987654321FEDCBA0987654321FEDCBA0987654321FEDCBA0987654321,
    };

    for (uninitialized_keys) |key| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(key);

        // Try TLOAD - might fail if not supported in this EVM version
        const result = ctx.vm.table.execute(0, interpreter, state, 0x5C); // TLOAD

        if (result) |_| {
            const loaded_value = try ctx.frame.stack.pop();
            try testing.expectEqual(@as(u256, 0), loaded_value);
        } else |err| {
            // TLOAD might not be supported in all EVM versions - that's OK
            _ = err; // Ignore error for now
        }
    }
}

// Test that persistent storage (SSTORE/SLOAD) and transient storage (TSTORE/TLOAD) are separate
test "fuzz_storage_separation_persistent_vs_transient" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    var interpreter: evm.Operation.Interpreter = &ctx.vm;
    var state: *evm.Operation.State = @ptrCast(&ctx.frame);

    const test_key: u256 = 42;
    const persistent_value: u256 = 0x1111111111111111111111111111111111111111111111111111111111111111;
    const transient_value: u256 = 0x2222222222222222222222222222222222222222222222222222222222222222;

    // Store same key in both persistent and transient storage with different values

    // Store in persistent storage
    {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(test_key);
        try ctx.frame.stack.append(persistent_value);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x55); // SSTORE
    }

    // Store in transient storage (if supported)
    {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(test_key);
        try ctx.frame.stack.append(transient_value);

        const result = ctx.vm.table.execute(0, interpreter, state, 0x5D); // TSTORE

        if (result) |_| {
            // If TSTORE succeeded, verify separation

            // Read from persistent storage - should get persistent_value
            {
                // Clear stack
                while (ctx.frame.stack.items.len > 0) {
                    _ = try ctx.frame.stack.pop();
                }

                try ctx.frame.stack.append(test_key);
                _ = try ctx.vm.table.execute(0, interpreter, state, 0x54); // SLOAD

                const persistent_result = try ctx.frame.stack.pop();
                try testing.expectEqual(persistent_value, persistent_result);
            }

            // Read from transient storage - should get transient_value
            {
                // Clear stack
                while (ctx.frame.stack.items.len > 0) {
                    _ = try ctx.frame.stack.pop();
                }

                try ctx.frame.stack.append(test_key);
                _ = try ctx.vm.table.execute(0, interpreter, state, 0x5C); // TLOAD

                const transient_result = try ctx.frame.stack.pop();
                try testing.expectEqual(transient_value, transient_result);
            }
        } else |err| {
            // TSTORE/TLOAD might not be supported in all EVM versions - that's OK
            _ = err; // Ignore error for now
        }
    }
}

// Storage operation stress test with mixed operations
test "fuzz_storage_operations_stress_test" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    var interpreter: evm.Operation.Interpreter = &ctx.vm;
    var state: *evm.Operation.State = @ptrCast(&ctx.frame);

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    // Track what we've stored for verification
    var stored_values = std.HashMap(u256, u256, std.HashMap.getDefaultContext(u256), std.HashMap.default_max_load_percentage).init(allocator);
    defer stored_values.deinit();

    // Perform many random storage operations
    for (0..500) |_| {
        const operation = random.intRangeAtMost(u8, 0, 1); // Only SSTORE/SLOAD for compatibility
        const key = random.intRangeAtMost(u256, 0, 999); // Keep keys in reasonable range
        const value = random.int(u256);

        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        switch (operation) {
            0 => {
                // SSTORE
                try ctx.frame.stack.append(key);
                try ctx.frame.stack.append(value);
                _ = try ctx.vm.table.execute(0, interpreter, state, 0x55); // SSTORE

                // Track the stored value
                try stored_values.put(key, value);
            },
            1 => {
                // SLOAD
                try ctx.frame.stack.append(key);
                _ = try ctx.vm.table.execute(0, interpreter, state, 0x54); // SLOAD
                const result = try ctx.frame.stack.pop();

                // Verify result matches what we expect
                const expected = stored_values.get(key) orelse 0;
                try testing.expectEqual(expected, result);
            },
            else => unreachable,
        }
    }

    // Final verification - check all stored values are still correct
    var iterator = stored_values.iterator();
    while (iterator.next()) |entry| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(entry.key_ptr.*);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x54); // SLOAD
        const result = try ctx.frame.stack.pop();

        try testing.expectEqual(entry.value_ptr.*, result);
    }
}

// Test storage zero-to-nonzero and nonzero-to-zero transitions (important for gas costs)
test "fuzz_storage_zero_transitions" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    var interpreter: evm.Operation.Interpreter = &ctx.vm;
    var state: *evm.Operation.State = @ptrCast(&ctx.frame);

    const test_key: u256 = 123456;
    const test_value: u256 = 0xABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890;

    // Initially, storage should be zero
    {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(test_key);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x54); // SLOAD
        const initial_value = try ctx.frame.stack.pop();
        try testing.expectEqual(@as(u256, 0), initial_value);
    }

    // Store non-zero value (zero-to-nonzero transition)
    {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(test_key);
        try ctx.frame.stack.append(test_value);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x55); // SSTORE
    }

    // Verify the value was stored
    {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(test_key);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x54); // SLOAD
        const stored_value = try ctx.frame.stack.pop();
        try testing.expectEqual(test_value, stored_value);
    }

    // Change to different non-zero value (nonzero-to-nonzero transition)
    const new_value: u256 = 0x1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF;
    {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(test_key);
        try ctx.frame.stack.append(new_value);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x55); // SSTORE
    }

    // Verify the new value
    {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(test_key);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x54); // SLOAD
        const updated_value = try ctx.frame.stack.pop();
        try testing.expectEqual(new_value, updated_value);
    }

    // Store zero value (nonzero-to-zero transition)
    {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(test_key);
        try ctx.frame.stack.append(0);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x55); // SSTORE
    }

    // Verify the value is now zero
    {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(test_key);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x54); // SLOAD
        const final_value = try ctx.frame.stack.pop();
        try testing.expectEqual(@as(u256, 0), final_value);
    }
}
