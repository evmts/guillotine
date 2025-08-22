const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const testing = std.testing;

// Helper function to create EVM execution context with custom bytecode
fn create_evm_context_with_code(allocator: std.mem.Allocator, code: []const u8) !struct {
    db: evm.MemoryDatabase,
    vm: evm.Evm,
    contract: evm.Contract,
    frame: evm.Frame,
} {
    var db = evm.MemoryDatabase.init(allocator);
    var vm = try evm.Evm.init(allocator, db.to_database_interface(), null, null);
    
    var contract = evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        code,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    
    var builder = evm.Frame.builder(allocator);
    var frame = try builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(1000000)
        .withCaller(primitives.Address.ZERO)
        .build();
    
    return .{
        .db = db,
        .vm = vm,
        .contract = contract,
        .frame = frame,
    };
}

fn deinit_evm_context(ctx: anytype, allocator: std.mem.Allocator) void {
    ctx.frame.deinit(std.testing.allocator);
    ctx.contract.deinit(allocator, null);
    ctx.vm.deinit();
    ctx.db.deinit();
}

// Comprehensive LOG0 operation fuzz testing
test "fuzz_log0_operation_edge_cases" {
    const allocator = testing.allocator;
    
    const log0_tests = [_]struct {
        memory_data: []const u8,
        offset: u256,
        length: u256,
        is_static: bool,
        description: []const u8,
        expected_error: ?anyerror,
    }{
        // Basic success cases
        .{
            .memory_data = "",
            .offset = 0,
            .length = 0,
            .is_static = false,
            .description = "Empty LOG0",
            .expected_error = null,
        },
        .{
            .memory_data = &[_]u8{0x42},
            .offset = 0,
            .length = 1,
            .is_static = false,
            .description = "Single byte LOG0",
            .expected_error = null,
        },
        .{
            .memory_data = "Hello, World!",
            .offset = 0,
            .length = 13,
            .is_static = false,
            .description = "Multi-byte string LOG0",
            .expected_error = null,
        },
        .{
            .memory_data = "Hello, World!",
            .offset = 7,
            .length = 6, // "World!"
            .is_static = false,
            .description = "LOG0 with offset",
            .expected_error = null,
        },
        
        // Large data cases
        .{
            .memory_data = &([_]u8{0xAA} ** 256),
            .offset = 0,
            .length = 256,
            .is_static = false,
            .description = "256-byte LOG0",
            .expected_error = null,
        },
        .{
            .memory_data = &([_]u8{0xBB} ** 1000),
            .offset = 500,
            .length = 100,
            .is_static = false,
            .description = "LOG0 subset of large data",
            .expected_error = null,
        },
        .{
            .memory_data = &([_]u8{0xCC} ** 1024),
            .offset = 0,
            .length = 1024,
            .is_static = false,
            .description = "1KB LOG0",
            .expected_error = null,
        },
        
        // Binary data patterns
        .{
            .memory_data = &[_]u8{0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD, 0xFC},
            .offset = 0,
            .length = 8,
            .is_static = false,
            .description = "Binary data LOG0",
            .expected_error = null,
        },
        .{
            .memory_data = &[_]u8{0x00, 0x00, 0x00, 0x00},
            .offset = 0,
            .length = 4,
            .is_static = false,
            .description = "All zeros LOG0",
            .expected_error = null,
        },
        .{
            .memory_data = &[_]u8{0xFF, 0xFF, 0xFF, 0xFF},
            .offset = 0,
            .length = 4,
            .is_static = false,
            .description = "All ones LOG0",
            .expected_error = null,
        },
        
        // Beyond data edge cases
        .{
            .memory_data = &[_]u8{0x11, 0x22},
            .offset = 0,
            .length = 10, // More than available
            .is_static = false,
            .description = "LOG0 beyond available data",
            .expected_error = null,
        },
        .{
            .memory_data = &[_]u8{0x11, 0x22},
            .offset = 1,
            .length = 10, // Beyond available from offset
            .is_static = false,
            .description = "LOG0 beyond available from offset",
            .expected_error = null,
        },
        
        // Static call failures
        .{
            .memory_data = "Test",
            .offset = 0,
            .length = 4,
            .is_static = true,
            .description = "LOG0 in static context",
            .expected_error = error.WriteProtection,
        },
        .{
            .memory_data = "",
            .offset = 0,
            .length = 0,
            .is_static = true,
            .description = "Empty LOG0 in static context",
            .expected_error = error.WriteProtection,
        },
        
        // Memory expansion cases
        .{
            .memory_data = "Expand",
            .offset = 1000,
            .length = 6,
            .is_static = false,
            .description = "LOG0 with memory expansion",
            .expected_error = null,
        },
        .{
            .memory_data = "Far",
            .offset = 10000,
            .length = 3,
            .is_static = false,
            .description = "LOG0 with large memory expansion",
            .expected_error = null,
        },
    };
    
    for (log0_tests) |test_case| {
        const log0_code = [_]u8{0xa0}; // LOG0
        var ctx = try create_evm_context_with_code(allocator, &log0_code);
        defer deinit_evm_context(ctx, allocator);
        
        ctx.frame.is_static = test_case.is_static;
        
        // Store test data in memory
        if (test_case.memory_data.len > 0) {
            try ctx.frame.memory.set_data(@intCast(test_case.offset), test_case.memory_data);
        }
        
        // Setup stack for LOG0 (offset, length)
        try ctx.frame.stack.append(test_case.offset);
        try ctx.frame.stack.append(test_case.length);
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = evm.Operation.State = &ctx.frame;
        
        const result = ctx.vm.table.execute(0, interpreter, state, 0xa0);
        
        if (test_case.expected_error) |expected_err| {
            try testing.expectError(expected_err, result);
        } else {
            _ = try result;
            // Verify log was emitted
            try testing.expect(ctx.vm.state.logs.items.len > 0);
            const log = ctx.vm.state.logs.items[ctx.vm.state.logs.items.len - 1];
            try testing.expectEqual(@as(usize, 0), log.topics.len);
        }
    }
}

// Comprehensive LOG1-LOG4 operations fuzz testing
test "fuzz_log_operations_with_topics" {
    const allocator = testing.allocator;
    
    const log_tests = [_]struct {
        num_topics: u8,
        topics: [4]u256,
        memory_data: []const u8,
        offset: u256,
        length: u256,
        is_static: bool,
        description: []const u8,
        expected_error: ?anyerror,
    }{
        // LOG1 tests
        .{
            .num_topics = 1,
            .topics = .{ 0x1111111111111111111111111111111111111111111111111111111111111111, 0, 0, 0 },
            .memory_data = "LOG1 test",
            .offset = 0,
            .length = 9,
            .is_static = false,
            .description = "Basic LOG1",
            .expected_error = null,
        },
        .{
            .num_topics = 1,
            .topics = .{ std.math.maxInt(u256), 0, 0, 0 },
            .memory_data = "",
            .offset = 0,
            .length = 0,
            .is_static = false,
            .description = "LOG1 with max topic value",
            .expected_error = null,
        },
        
        // LOG2 tests
        .{
            .num_topics = 2,
            .topics = .{ 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA, 0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB, 0, 0 },
            .memory_data = "LOG2 with two topics",
            .offset = 0,
            .length = 20,
            .is_static = false,
            .description = "Basic LOG2",
            .expected_error = null,
        },
        .{
            .num_topics = 2,
            .topics = .{ 0, std.math.maxInt(u256), 0, 0 },
            .memory_data = &([_]u8{0x55} ** 100),
            .offset = 50,
            .length = 50,
            .is_static = false,
            .description = "LOG2 with zero and max topics",
            .expected_error = null,
        },
        
        // LOG3 tests
        .{
            .num_topics = 3,
            .topics = .{ 0x1111, 0x2222, 0x3333, 0 },
            .memory_data = "Three topics test",
            .offset = 0,
            .length = 17,
            .is_static = false,
            .description = "Basic LOG3",
            .expected_error = null,
        },
        .{
            .num_topics = 3,
            .topics = .{ 0xCAFE, 0xBEEF, 0xDEAD, 0 },
            .memory_data = &([_]u8{0x77} ** 256),
            .offset = 128,
            .length = 128,
            .is_static = false,
            .description = "LOG3 with large data",
            .expected_error = null,
        },
        
        // LOG4 tests
        .{
            .num_topics = 4,
            .topics = .{ 0x1111, 0x2222, 0x3333, 0x4444 },
            .memory_data = "Maximum topics",
            .offset = 0,
            .length = 14,
            .is_static = false,
            .description = "Basic LOG4",
            .expected_error = null,
        },
        .{
            .num_topics = 4,
            .topics = .{ std.math.maxInt(u256), std.math.maxInt(u256), std.math.maxInt(u256), std.math.maxInt(u256) },
            .memory_data = &([_]u8{0xFF} ** 512),
            .offset = 0,
            .length = 512,
            .is_static = false,
            .description = "LOG4 with max topics and large data",
            .expected_error = null,
        },
        
        // Static call failures
        .{
            .num_topics = 1,
            .topics = .{ 0x1111, 0, 0, 0 },
            .memory_data = "Should fail",
            .offset = 0,
            .length = 11,
            .is_static = true,
            .description = "LOG1 in static context",
            .expected_error = error.WriteProtection,
        },
        .{
            .num_topics = 4,
            .topics = .{ 0x1111, 0x2222, 0x3333, 0x4444 },
            .memory_data = "Should fail",
            .offset = 0,
            .length = 11,
            .is_static = true,
            .description = "LOG4 in static context",
            .expected_error = error.WriteProtection,
        },
        
        // Edge cases with empty data
        .{
            .num_topics = 1,
            .topics = .{ 0xABCD, 0, 0, 0 },
            .memory_data = "",
            .offset = 0,
            .length = 0,
            .is_static = false,
            .description = "LOG1 with empty data",
            .expected_error = null,
        },
        .{
            .num_topics = 4,
            .topics = .{ 0x1, 0x2, 0x3, 0x4 },
            .memory_data = "",
            .offset = 0,
            .length = 0,
            .is_static = false,
            .description = "LOG4 with empty data",
            .expected_error = null,
        },
        
        // Memory expansion cases
        .{
            .num_topics = 2,
            .topics = .{ 0x1111, 0x2222, 0, 0 },
            .memory_data = "Expansion test",
            .offset = 5000,
            .length = 14,
            .is_static = false,
            .description = "LOG2 with memory expansion",
            .expected_error = null,
        },
    };
    
    for (log_tests) |test_case| {
        const opcode = 0xa0 + test_case.num_topics;
        const log_code = [_]u8{opcode};
        var ctx = try create_evm_context_with_code(allocator, &log_code);
        defer deinit_evm_context(ctx, allocator);
        
        ctx.frame.is_static = test_case.is_static;
        
        // Store test data in memory
        if (test_case.memory_data.len > 0) {
            try ctx.frame.memory.set_data(@intCast(test_case.offset), test_case.memory_data);
        }
        
        // Setup stack for LOG operation (offset, length, topic1, topic2, ...)
        try ctx.frame.stack.append(test_case.offset);
        try ctx.frame.stack.append(test_case.length);
        
        // Push topics in reverse order (stack is LIFO)
        var i: usize = 0;
        while (i < test_case.num_topics) : (i += 1) {
            try ctx.frame.stack.append(test_case.topics[test_case.num_topics - 1 - i]);
        }
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = evm.Operation.State = &ctx.frame;
        
        const result = ctx.vm.table.execute(0, interpreter, state, opcode);
        
        if (test_case.expected_error) |expected_err| {
            try testing.expectError(expected_err, result);
        } else {
            _ = try result;
            // Verify log was emitted
            try testing.expect(ctx.vm.state.logs.items.len > 0);
            const log = ctx.vm.state.logs.items[ctx.vm.state.logs.items.len - 1];
            try testing.expectEqual(@as(usize, test_case.num_topics), log.topics.len);
            
            // Verify topics are correct
            for (0..test_case.num_topics) |topic_idx| {
                try testing.expectEqual(test_case.topics[topic_idx], log.topics[topic_idx]);
            }
        }
    }
}

// Gas consumption patterns for LOG operations
test "fuzz_log_operations_gas_consumption" {
    const allocator = testing.allocator;
    
    const gas_tests = [_]struct {
        num_topics: u8,
        data_size: usize,
        initial_gas: u64,
        description: []const u8,
    }{
        // Different topic counts with fixed data size
        .{ .num_topics = 0, .data_size = 32, .initial_gas = 1000000, .description = "LOG0 32 bytes" },
        .{ .num_topics = 1, .data_size = 32, .initial_gas = 1000000, .description = "LOG1 32 bytes" },
        .{ .num_topics = 2, .data_size = 32, .initial_gas = 1000000, .description = "LOG2 32 bytes" },
        .{ .num_topics = 3, .data_size = 32, .initial_gas = 1000000, .description = "LOG3 32 bytes" },
        .{ .num_topics = 4, .data_size = 32, .initial_gas = 1000000, .description = "LOG4 32 bytes" },
        
        // Different data sizes with fixed topics
        .{ .num_topics = 1, .data_size = 0, .initial_gas = 1000000, .description = "LOG1 empty" },
        .{ .num_topics = 1, .data_size = 1, .initial_gas = 1000000, .description = "LOG1 1 byte" },
        .{ .num_topics = 1, .data_size = 100, .initial_gas = 1000000, .description = "LOG1 100 bytes" },
        .{ .num_topics = 1, .data_size = 1000, .initial_gas = 1000000, .description = "LOG1 1000 bytes" },
        
        // Low gas scenarios
        .{ .num_topics = 0, .data_size = 0, .initial_gas = 400, .description = "LOG0 minimal gas" },
        .{ .num_topics = 1, .data_size = 0, .initial_gas = 800, .description = "LOG1 minimal gas" },
        .{ .num_topics = 4, .data_size = 0, .initial_gas = 2000, .description = "LOG4 minimal gas" },
        
        // Very low gas (should fail)
        .{ .num_topics = 0, .data_size = 100, .initial_gas = 100, .description = "LOG0 insufficient gas" },
        .{ .num_topics = 4, .data_size = 100, .initial_gas = 500, .description = "LOG4 insufficient gas" },
    };
    
    for (gas_tests) |test_case| {
        const opcode = 0xa0 + test_case.num_topics;
        const log_code = [_]u8{opcode};
        var ctx = try create_evm_context_with_code(allocator, &log_code);
        defer deinit_evm_context(ctx, allocator);
        
        ctx.frame.gas_remaining = test_case.initial_gas;
        
        // Create test data
        const test_data = try allocator.alloc(u8, test_case.data_size);
        defer allocator.free(test_data);
        for (test_data, 0..) |*byte, i| {
            byte.* = @intCast(i % 256);
        }
        
        // Store test data in memory
        if (test_data.len > 0) {
            try ctx.frame.memory.set_data(0, test_data);
        }
        
        // Setup stack
        try ctx.frame.stack.append(0); // offset
        try ctx.frame.stack.append(test_case.data_size); // length
        
        // Push dummy topics
        var i: usize = 0;
        while (i < test_case.num_topics) : (i += 1) {
            try ctx.frame.stack.append(@as(u256, i + 1));
        }
        
        const gas_before = ctx.frame.gas_remaining;
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = evm.Operation.State = &ctx.frame;
        
        const result = ctx.vm.table.execute(0, interpreter, state, opcode);
        
        if (result) |_| {
            // Success - verify gas consumption makes sense
            const gas_used = gas_before - ctx.frame.gas_remaining;
            
            // Base gas cost: 375
            // Topic gas cost: 375 * num_topics
            // Data gas cost: 8 * data_size
            // Memory expansion: varies
            const min_expected_gas = 375 + (375 * test_case.num_topics) + (8 * test_case.data_size);
            
            try testing.expect(gas_used >= min_expected_gas);
            try testing.expect(ctx.vm.state.logs.items.len > 0);
        } else |err| {
            // Expected failures for insufficient gas
            switch (err) {
                error.OutOfGas => {
                    try testing.expect(test_case.initial_gas < 1000); // Low gas scenarios
                },
                else => return err,
            }
        }
    }
}

// Memory expansion stress testing for LOG operations
test "fuzz_log_memory_expansion_stress" {
    const allocator = testing.allocator;
    
    const expansion_tests = [_]struct {
        offset: u256,
        length: u256,
        num_topics: u8,
        description: []const u8,
    }{
        // Normal expansions
        .{ .offset = 100, .length = 50, .num_topics = 0, .description = "Small expansion LOG0" },
        .{ .offset = 1000, .length = 100, .num_topics = 1, .description = "Medium expansion LOG1" },
        .{ .offset = 5000, .length = 200, .num_topics = 2, .description = "Large expansion LOG2" },
        
        // Large expansions
        .{ .offset = 10000, .length = 1000, .num_topics = 3, .description = "Very large expansion LOG3" },
        .{ .offset = 50000, .length = 500, .num_topics = 4, .description = "Huge expansion LOG4" },
        
        // Edge cases
        .{ .offset = 0, .length = 10000, .description = "Large contiguous LOG0" },
        .{ .offset = 100000, .length = 1, .num_topics = 1, .description = "Far offset small data LOG1" },
        .{ .offset = 1000000, .length = 10, .num_topics = 2, .description = "Very far offset LOG2" },
    };
    
    for (expansion_tests) |test_case| {
        const opcode = 0xa0 + test_case.num_topics;
        const log_code = [_]u8{opcode};
        var ctx = try create_evm_context_with_code(allocator, &log_code);
        defer deinit_evm_context(ctx, allocator);
        
        // Create test data pattern
        const test_data = try allocator.alloc(u8, @intCast(test_case.length));
        defer allocator.free(test_data);
        for (test_data, 0..) |*byte, i| {
            byte.* = @intCast((i * 7 + 13) % 256); // Pseudo-random pattern
        }
        
        // Store test data at the specified offset
        if (test_data.len > 0) {
            try ctx.frame.memory.set_data(@intCast(test_case.offset), test_data);
        }
        
        const initial_memory_size = ctx.frame.memory.context_size();
        
        // Setup stack
        try ctx.frame.stack.append(test_case.offset);
        try ctx.frame.stack.append(test_case.length);
        
        // Push dummy topics
        var i: usize = 0;
        while (i < test_case.num_topics) : (i += 1) {
            try ctx.frame.stack.append(@as(u256, 0x1000 + i));
        }
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = evm.Operation.State = &ctx.frame;
        
        const result = ctx.vm.table.execute(0, interpreter, state, opcode);
        
        if (result) |_| {
            // Success - verify memory expanded
            if (test_case.offset + test_case.length > initial_memory_size) {
                try testing.expect(ctx.frame.memory.context_size() > initial_memory_size);
            }
            try testing.expect(ctx.vm.state.logs.items.len > 0);
        } else |err| {
            // Handle expected failures
            switch (err) {
                error.OutOfGas, error.MemoryOutOfBounds => {}, // Acceptable for very large expansions
                else => return err,
            }
        }
    }
}

// Random LOG operations stress testing
test "fuzz_log_operations_random_stress" {
    const allocator = testing.allocator;
    
    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const random = prng.random();
    
    // Test many random LOG operations
    for (0..200) |_| {
        const num_topics = random.intRangeAtMost(u8, 0, 4);
        const opcode = 0xa0 + num_topics;
        const log_code = [_]u8{opcode};
        
        var ctx = try create_evm_context_with_code(allocator, &log_code);
        defer deinit_evm_context(ctx, allocator);
        
        // Random parameters
        const data_size = random.intRangeAtMost(usize, 0, 500);
        const offset = random.intRangeAtMost(u256, 0, 1000);
        const is_static = random.boolean();
        
        ctx.frame.is_static = is_static;
        
        // Generate random test data
        const test_data = try allocator.alloc(u8, data_size);
        defer allocator.free(test_data);
        random.bytes(test_data);
        
        // Store test data
        if (test_data.len > 0) {
            try ctx.frame.memory.set_data(@intCast(offset), test_data);
        }
        
        // Generate random topics
        var topics: [4]u256 = undefined;
        for (0..num_topics) |_| {
            topics[i] = random.int(u256);
        }
        
        // Setup stack
        try ctx.frame.stack.append(offset);
        try ctx.frame.stack.append(data_size);
        
        // Push topics in reverse order
        var i: usize = 0;
        while (i < num_topics) : (i += 1) {
            try ctx.frame.stack.append(topics[num_topics - 1 - i]);
        }
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = evm.Operation.State = &ctx.frame;
        
        const result = ctx.vm.table.execute(0, interpreter, state, opcode);
        
        // Validate expected behavior
        if (is_static) {
            try testing.expectError(error.WriteProtection, result);
        } else {
            if (result) |_| {
                // Success - verify log was emitted correctly
                try testing.expect(ctx.vm.state.logs.items.len > 0);
                const log = ctx.vm.state.logs.items[ctx.vm.state.logs.items.len - 1];
                try testing.expectEqual(@as(usize, num_topics), log.topics.len);
                
                // Verify topics match
                for (0..num_topics) |topic_idx| {
                    try testing.expectEqual(topics[topic_idx], log.topics[topic_idx]);
                }
            } else |err| {
                // Handle acceptable failures
                switch (err) {
                    error.OutOfGas, error.MemoryOutOfBounds, error.StackUnderflow => {}, // Expected for edge cases
                    else => return err,
                }
            }
        }
    }
}

// Sequential LOG operations testing
test "fuzz_sequential_log_operations" {
    const allocator = testing.allocator;
    
    // Test multiple LOG operations in sequence
    const log0_code = [_]u8{0xa0}; // LOG0
    var ctx = try create_evm_context_with_code(allocator, &log0_code);
    defer deinit_evm_context(ctx, allocator);
    
    const num_logs = 50;
    var expected_logs: usize = 0;
    
    for (0..num_logs) |_| {
        const num_topics = @as(u8, @intCast(i % 5)); // 0-4 topics
        const opcode = 0xa0 + num_topics;
        
        // Create test data for this log
        const test_data = try std.fmt.allocPrint(allocator, "Log {d} data", .{i});
        defer allocator.free(test_data);
        
        const offset = i * 100; // Space out data
        try ctx.frame.memory.set_data(offset, test_data);
        
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        // Setup stack for this LOG operation
        try ctx.frame.stack.append(offset);
        try ctx.frame.stack.append(test_data.len);
        
        // Push topics
        var topic_idx: usize = 0;
        while (topic_idx < num_topics) : (topic_idx += 1) {
            try ctx.frame.stack.append(@as(u256, (i + 1) * 1000 + topic_idx));
        }
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = evm.Operation.State = &ctx.frame;
        
        const result = ctx.vm.table.execute(0, interpreter, state, opcode);
        
        if (result) |_| {
            expected_logs += 1;
            // Verify this log was added correctly
            try testing.expectEqual(expected_logs, ctx.vm.state.logs.items.len);
            const log = ctx.vm.state.logs.items[expected_logs - 1];
            try testing.expectEqual(@as(usize, num_topics), log.topics.len);
        } else |err| {
            // Handle acceptable failures (gas might run out)
            switch (err) {
                error.OutOfGas => break, // Stop if we run out of gas
                else => return err,
            }
        }
    }
    
    // Verify we emitted at least some logs
    try testing.expect(ctx.vm.state.logs.items.len > 0);
}