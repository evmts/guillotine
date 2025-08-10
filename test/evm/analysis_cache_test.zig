const std = @import("std");
const Evm = @import("evm");
const AnalysisCache = @import("evm").AnalysisCache;
const MemoryDatabase = @import("evm").MemoryDatabase;
const primitives = @import("primitives");
const Address = primitives.Address;

test "analysis cache reduces redundant analysis in nested calls" {
    const allocator = std.testing.allocator;

    // Create a memory database with some test contracts
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Simple contract bytecode that just returns
    const simple_contract = &[_]u8{
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Contract that calls another contract multiple times
    // This simulates nested calls to the same address
    const caller_contract = &[_]u8{
        // Call the same contract 3 times
        // First call
        0x60, 0x00, // PUSH1 0 (ret_size)
        0x60, 0x00, // PUSH1 0 (ret_offset)
        0x60, 0x00, // PUSH1 0 (args_size)
        0x60, 0x00, // PUSH1 0 (args_offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x73, // PUSH20 (address)
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, // address 0x02
        0x62, 0x10, 0x00, 0x00, // PUSH3 gas (0x100000)
        0xF1, // CALL
        0x50, // POP result

        // Second call to same address
        0x60, 0x00, // PUSH1 0 (ret_size)
        0x60, 0x00, // PUSH1 0 (ret_offset)
        0x60, 0x00, // PUSH1 0 (args_size)
        0x60, 0x00, // PUSH1 0 (args_offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x73, // PUSH20 (address)
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, // address 0x02
        0x62, 0x10, 0x00, 0x00, // PUSH3 gas
        0xF1, // CALL
        0x50, // POP result

        // Third call to same address
        0x60, 0x00, // PUSH1 0 (ret_size)
        0x60, 0x00, // PUSH1 0 (ret_offset)
        0x60, 0x00, // PUSH1 0 (args_size)
        0x60, 0x00, // PUSH1 0 (args_offset)
        0x60, 0x00, // PUSH1 0 (value)
        0x73, // PUSH20 (address)
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, // address 0x02
        0x62, 0x10, 0x00, 0x00, // PUSH3 gas
        0xF1, // CALL
        0x50, // POP result
        0x00, // STOP
    };

    // Set up contracts in the database
    const callee_address = Address.from_hex("0x0000000000000000000000000000000000000002") catch unreachable;
    const caller_address = Address.from_hex("0x0000000000000000000000000000000000000001") catch unreachable;

    try memory_db.set_code(callee_address, simple_contract);
    try memory_db.set_code(caller_address, caller_contract);

    // Create EVM with analysis cache enabled
    var evm = try Evm.init(
        allocator,
        memory_db.to_database_interface(),
        null, // default jump table
        null, // default chain rules
        null, // default context
        0, // depth
        false, // not read_only
        null, // no tracer
    );
    defer evm.deinit();

    // Execute the caller contract which will make 3 calls to the same address
    const call_params = Evm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = caller_address,
            .value = 0,
            .input = &.{},
            .gas = 1000000,
        },
    };

    const result = try evm.call(call_params);

    // Verify execution succeeded
    try std.testing.expect(result.success);

    // Check cache statistics
    if (evm.analysis_cache) |*cache| {
        const stats = cache.getStats();

        // We should have cache hits for repeated calls to the same contract
        // First call to address 0x02 is a miss, next 2 calls should be hits
        std.debug.print("\nCache statistics:\n", .{});
        std.debug.print("  Hits: {}\n", .{stats.hits});
        std.debug.print("  Misses: {}\n", .{stats.misses});
        std.debug.print("  Hit rate: {d:.2}%\n", .{stats.hit_rate() * 100});
        std.debug.print("  Evictions: {}\n", .{stats.evictions});

        // We expect at least 2 hits (2nd and 3rd calls to same contract)
        try std.testing.expect(stats.hits >= 2);

        // Hit rate should be positive
        try std.testing.expect(stats.hit_rate() > 0.0);
    } else {
        // Cache should exist
        try std.testing.expect(false);
    }
}

test "analysis cache handles different contracts correctly" {
    const allocator = std.testing.allocator;

    // Create a standalone cache for testing
    var cache = AnalysisCache.init(allocator, 5);
    defer cache.deinit();

    // Create different contracts with different bytecode
    const contract1 = &[_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 }; // PUSH1 1, PUSH1 2, ADD, STOP
    const contract2 = &[_]u8{ 0x60, 0x03, 0x60, 0x04, 0x02, 0x00 }; // PUSH1 3, PUSH1 4, MUL, STOP
    const contract3 = &[_]u8{ 0x60, 0x05, 0x60, 0x06, 0x03, 0x00 }; // PUSH1 5, PUSH1 6, SUB, STOP

    var jump_table = @import("evm").JumpTable{};

    // First access to each contract should be a miss
    _ = try cache.getOrAnalyze(contract1, &jump_table);
    _ = try cache.getOrAnalyze(contract2, &jump_table);
    _ = try cache.getOrAnalyze(contract3, &jump_table);

    var stats = cache.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.hits);
    try std.testing.expectEqual(@as(u64, 3), stats.misses);

    // Second access to same contracts should be hits
    _ = try cache.getOrAnalyze(contract1, &jump_table);
    _ = try cache.getOrAnalyze(contract2, &jump_table);
    _ = try cache.getOrAnalyze(contract3, &jump_table);

    stats = cache.getStats();
    try std.testing.expectEqual(@as(u64, 3), stats.hits);
    try std.testing.expectEqual(@as(u64, 3), stats.misses);

    // Verify hit rate is 50% (3 hits out of 6 total accesses)
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), stats.hit_rate(), 0.001);
}

test "analysis cache performance improvement" {
    const allocator = std.testing.allocator;

    // Create a reasonably complex contract for analysis
    var contract_code = std.ArrayList(u8).init(allocator);
    defer contract_code.deinit();

    // Build a contract with many instructions
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        // PUSH1, value, DUP1, ADD pattern repeated
        try contract_code.appendSlice(&[_]u8{
            0x60, @intCast(i), // PUSH1 i
            0x80, // DUP1
            0x01, // ADD
        });
    }
    try contract_code.append(0x00); // STOP

    var jump_table = @import("evm").JumpTable{};

    // Test without cache (simulate by creating new cache each time)
    var timer = try std.time.Timer.start();
    const iterations = 100;

    // Measure time without cache (new analysis each time)
    const start_no_cache = timer.read();
    i = 0;
    while (i < iterations) : (i += 1) {
        var temp_cache = AnalysisCache.init(allocator, 1);
        defer temp_cache.deinit();
        _ = try temp_cache.getOrAnalyze(contract_code.items, &jump_table);
    }
    const time_no_cache = timer.read() - start_no_cache;

    // Measure time with cache
    var cache = AnalysisCache.init(allocator, 10);
    defer cache.deinit();

    const start_with_cache = timer.read();
    i = 0;
    while (i < iterations) : (i += 1) {
        _ = try cache.getOrAnalyze(contract_code.items, &jump_table);
    }
    const time_with_cache = timer.read() - start_with_cache;

    std.debug.print("\nPerformance comparison ({} iterations):\n", .{iterations});
    std.debug.print("  Without cache: {} ns\n", .{time_no_cache});
    std.debug.print("  With cache: {} ns\n", .{time_with_cache});
    std.debug.print("  Speedup: {d:.2}x\n", .{@as(f64, @floatFromInt(time_no_cache)) / @as(f64, @floatFromInt(time_with_cache))});

    // Cache should be significantly faster (at least 2x)
    try std.testing.expect(time_with_cache < time_no_cache / 2);

    // Verify cache was actually used
    const stats = cache.getStats();
    try std.testing.expectEqual(@as(u64, iterations - 1), stats.hits); // First is miss, rest are hits
    try std.testing.expectEqual(@as(u64, 1), stats.misses);
}
