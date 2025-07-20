const std = @import("std");
const testing = std.testing;
const evm_module = @import("evm");
const Evm = evm_module.Evm;
const Contract = evm_module.Contract;
const Address = evm_module.Address;
const MAX_CALL_DEPTH = evm_module.MAX_CALL_DEPTH;

test "Frame pool fuzz test: random call depths" {
    var evm = Evm.init(testing.allocator);
    defer evm.deinit();
    
    const contract = Contract.init(&[_]u8{0x01, 0x02, 0x03}, [_]u8{0} ** 20);
    const caller = [_]u8{0} ** 20;
    
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    
    // Test with random call depths
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const depth = random.intRangeLessThan(u16, 0, MAX_CALL_DEPTH);
        const gas = random.intRangeLessThan(u64, 1000, 10000000);
        
        evm.depth = depth;
        
        const frame = try evm.getPooledFrame(gas, @constCast(&contract), caller, &[_]u8{});
        try testing.expectEqual(gas, frame.gas_remaining);
        
        // Perform random operations
        const operations = random.intRangeLessThan(u8, 1, 10);
        var j: u8 = 0;
        while (j < operations) : (j += 1) {
            if (random.boolean()) {
                const value = random.int(u256);
                try frame.stack.push(value);
            } else if (frame.stack.size() > 0) {
                _ = try frame.stack.pop();
            }
        }
        
        // Verify frame integrity
        try testing.expect(frame.gas_remaining <= gas);
        try testing.expect(frame.contract == &contract);
    }
}

test "Frame pool fuzz test: random gas values" {
    var evm = Evm.init(testing.allocator);
    defer evm.deinit();
    
    const contract = Contract.init(&[_]u8{0x42}, [_]u8{0} ** 20);
    const caller = [_]u8{0} ** 20;
    
    var prng = std.Random.DefaultPrng.init(123);
    const random = prng.random();
    
    // Test with random gas values
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const gas = random.int(u64);
        evm.depth = @intCast(i % MAX_CALL_DEPTH);
        
        const frame = try evm.getPooledFrame(gas, @constCast(&contract), caller, &[_]u8{});
        try testing.expectEqual(gas, frame.gas_remaining);
        
        // Simulate gas consumption
        const gas_to_consume = random.intRangeLessThan(u64, 0, @min(gas, 100000));
        frame.gas_remaining = frame.gas_remaining -| gas_to_consume;
        
        try testing.expect(frame.gas_remaining <= gas);
    }
}

test "Frame pool fuzz test: reuse patterns" {
    var evm = Evm.init(testing.allocator);
    defer evm.deinit();
    
    const contract = Contract.init(&[_]u8{0x99, 0xAA}, [_]u8{0} ** 20);
    const caller = [_]u8{0} ** 20;
    
    var prng = std.Random.DefaultPrng.init(789);
    const random = prng.random();
    
    // Test frame reuse with different patterns
    var depth_history: [100]u16 = undefined;
    var i: usize = 0;
    
    while (i < depth_history.len) : (i += 1) {
        const depth = random.intRangeLessThan(u16, 0, @min(MAX_CALL_DEPTH, 100));
        depth_history[i] = depth;
        evm.depth = depth;
        
        const gas = 1000000 + i * 1000;
        const frame = try evm.getPooledFrame(gas, @constCast(&contract), caller, &[_]u8{});
        
        // Add some state to the frame
        try frame.stack.push(@as(u256, @intCast(i)));
        try frame.stack.push(@as(u256, @intCast(depth)));
        
        frame.gas_remaining = frame.gas_remaining -| @as(u64, @intCast(i));
        
        // Verify frame properties
        try testing.expectEqual(gas, frame.gas_remaining + @as(u64, @intCast(i)));
        try testing.expect(frame.stack.size() >= 2);
    }
    
    // Now revisit the same depths and verify frames are reused correctly
    i = 0;
    while (i < depth_history.len) : (i += 1) {
        const depth = depth_history[i];
        evm.depth = depth;
        
        const gas = 2000000 + i * 500;
        const frame = try evm.getPooledFrame(gas, @constCast(&contract), caller, &[_]u8{});
        
        // Frame should be reset
        try testing.expectEqual(gas, frame.gas_remaining);
        try testing.expectEqual(@as(usize, 0), frame.stack.size()); // Stack should be cleared
    }
}

test "Frame pool fuzz test: memory operations" {
    var evm = Evm.init(testing.allocator);
    defer evm.deinit();
    
    const contract = Contract.init(&[_]u8{0x11, 0x22, 0x33}, [_]u8{0} ** 20);
    const caller = [_]u8{0} ** 20;
    
    var prng = std.Random.DefaultPrng.init(456);
    const random = prng.random();
    
    // Test memory operations with frame pool
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const depth = @as(u16, @intCast(i % 10)); // Use small depth range
        evm.depth = depth;
        
        const frame = try evm.getPooledFrame(1000000, @constCast(&contract), caller, &[_]u8{});
        
        // Perform random memory operations
        const mem_operations = random.intRangeLessThan(u8, 1, 5);
        var j: u8 = 0;
        while (j < mem_operations) : (j += 1) {
            // Memory is simplified in our implementation, but we can test reset
            try frame.memory.reset();
            // Memory should be empty after reset
        }
        
        // Stack operations
        const stack_ops = random.intRangeLessThan(u8, 1, 20);
        var k: u8 = 0;
        while (k < stack_ops) : (k += 1) {
            if (random.boolean() and frame.stack.size() < 100) {
                try frame.stack.push(random.int(u256));
            } else if (frame.stack.size() > 0) {
                _ = try frame.stack.pop();
            }
        }
    }
}

test "Frame pool fuzz test: edge cases" {
    var evm = Evm.init(testing.allocator);
    defer evm.deinit();
    
    const contract = Contract.init(&[_]u8{}, [_]u8{0} ** 20); // Empty contract
    const caller = [_]u8{0} ** 20;
    
    var prng = std.Random.DefaultPrng.init(999);
    const random = prng.random();
    
    // Test edge cases
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        // Test near-maximum depth
        const depth = random.intRangeLessThan(u16, MAX_CALL_DEPTH - 10, MAX_CALL_DEPTH);
        evm.depth = depth;
        
        const frame = try evm.getPooledFrame(random.int(u64), @constCast(&contract), caller, &[_]u8{});
        
        // Test with zero gas
        if (i % 10 == 0) {
            const zero_gas_frame = try evm.getPooledFrame(0, @constCast(&contract), caller, &[_]u8{});
            try testing.expectEqual(@as(u64, 0), zero_gas_frame.gas_remaining);
        }
        
        // Test with maximum gas
        if (i % 15 == 0) {
            const max_gas_frame = try evm.getPooledFrame(std.math.maxInt(u64), @constCast(&contract), caller, &[_]u8{});
            try testing.expectEqual(std.math.maxInt(u64), max_gas_frame.gas_remaining);
        }
        
        // Verify frame is valid
        try testing.expect(frame.contract == &contract);
        try testing.expect(frame.caller.len == 20);
    }
    
    // Test maximum depth limit
    evm.depth = MAX_CALL_DEPTH;
    const result = evm.getPooledFrame(1000000, @constCast(&contract), caller, &[_]u8{});
    try testing.expectError(evm_module.Error.DepthLimit, result);
}

test "Frame pool fuzz test: invariants" {
    var evm = Evm.init(testing.allocator);
    defer evm.deinit();
    
    const contract1 = Contract.init(&[_]u8{0x01}, [_]u8{0} ** 20);
    const contract2 = Contract.init(&[_]u8{0x02}, [_]u8{0x42} ** 20);
    const caller = [_]u8{0} ** 20;
    
    var prng = std.Random.DefaultPrng.init(777);
    const random = prng.random();
    
    // Invariant: frames at different depths are isolated
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const depth1 = random.intRangeLessThan(u16, 0, MAX_CALL_DEPTH / 2);
        const depth2 = random.intRangeLessThan(u16, MAX_CALL_DEPTH / 2, MAX_CALL_DEPTH);
        
        // Get frame at depth1
        evm.depth = depth1;
        const frame1 = try evm.getPooledFrame(1000000, @constCast(&contract1), caller, &[_]u8{0x01});
        try frame1.stack.push(123);
        frame1.gas_remaining = 500000;
        
        // Get frame at depth2
        evm.depth = depth2;
        const frame2 = try evm.getPooledFrame(2000000, @constCast(&contract2), caller, &[_]u8{0x02, 0x03});
        try frame2.stack.push(456);
        
        // Invariant: different depths have different frames
        try testing.expect(frame1 != frame2);
        
        // Invariant: frame1 state is preserved
        try testing.expectEqual(@as(u64, 500000), frame1.gas_remaining);
        try testing.expectEqual(@as(usize, 1), frame1.stack.size());
        
        // Invariant: frame2 has correct initial state
        try testing.expectEqual(@as(u64, 2000000), frame2.gas_remaining);
        try testing.expectEqual(@as(usize, 1), frame2.stack.size());
    }
    
    // Invariant: same depth reuses same frame after reset
    evm.depth = 5;
    const frame_a = try evm.getPooledFrame(100000, @constCast(&contract1), caller, &[_]u8{});
    try frame_a.stack.push(999);
    
    const frame_b = try evm.getPooledFrame(200000, @constCast(&contract2), caller, &[_]u8{});
    
    // Same frame object, but reset state
    try testing.expect(frame_a == frame_b);
    try testing.expectEqual(@as(u64, 200000), frame_b.gas_remaining);
    try testing.expectEqual(@as(usize, 0), frame_b.stack.size()); // Reset
}

test "Frame pool fuzz test: property-based correctness" {
    var evm = Evm.init(testing.allocator);
    defer evm.deinit();
    
    var prng = std.Random.DefaultPrng.init(555);
    const random = prng.random();
    
    // Property: Every getPooledFrame call should return a valid frame
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const depth = random.intRangeLessThan(u16, 0, MAX_CALL_DEPTH);
        const gas = random.int(u64);
        
        const contract_code_len = random.intRangeLessThan(u8, 0, 10);
        const contract_code = try testing.allocator.alloc(u8, contract_code_len);
        defer testing.allocator.free(contract_code);
        
        for (contract_code) |*byte| {
            byte.* = random.int(u8);
        }
        
        const contract = Contract.init(contract_code, [_]u8{0} ** 20);
        const caller = [_]u8{0} ** 20;
        
        evm.depth = depth;
        
        const frame = try evm.getPooledFrame(gas, @constCast(&contract), caller, &[_]u8{});
        
        // Property: Frame has correct initial state
        try testing.expectEqual(gas, frame.gas_remaining);
        try testing.expectEqual(@as(usize, 0), frame.stack.size());
        try testing.expect(frame.contract == &contract);
        
        // Property: Frame operations should not crash
        if (random.boolean()) {
            try frame.stack.push(random.int(u256));
        }
        
        if (random.boolean()) {
            try frame.memory.reset();
        }
        
        // Property: Frame remains valid after operations
        try testing.expect(frame.gas_remaining <= gas);
    }
}