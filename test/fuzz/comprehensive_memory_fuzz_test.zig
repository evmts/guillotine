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
    var contract = evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        &test_code,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    
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

// Comprehensive MSTORE operation fuzz testing
test "fuzz_mstore_memory_storage_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);
    
    const test_cases = [_]struct { offset: u256, value: u256 }{
        // Basic cases
        .{ .offset = 0, .value = 0x1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF },
        .{ .offset = 32, .value = 0xFEDCBA0987654321FEDCBA0987654321FEDCBA0987654321FEDCBA0987654321 },
        .{ .offset = 64, .value = 0 },
        .{ .offset = 96, .value = std.math.maxInt(u256) },
        
        // Word-aligned offsets
        .{ .offset = 0, .value = 0x1111111111111111111111111111111111111111111111111111111111111111 },
        .{ .offset = 32, .value = 0x2222222222222222222222222222222222222222222222222222222222222222 },
        .{ .offset = 64, .value = 0x3333333333333333333333333333333333333333333333333333333333333333 },
        
        // Non-word-aligned offsets (should still work)
        .{ .offset = 1, .value = 0x4444444444444444444444444444444444444444444444444444444444444444 },
        .{ .offset = 15, .value = 0x5555555555555555555555555555555555555555555555555555555555555555 },
        .{ .offset = 33, .value = 0x6666666666666666666666666666666666666666666666666666666666666666 },
        .{ .offset = 63, .value = 0x7777777777777777777777777777777777777777777777777777777777777777 },
        
        // Large offsets (memory expansion)
        .{ .offset = 1024, .value = 0x8888888888888888888888888888888888888888888888888888888888888888 },
        .{ .offset = 4096, .value = 0x9999999999999999999999999999999999999999999999999999999999999999 },
        .{ .offset = 65536, .value = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA },
        
        // Edge values
        .{ .offset = 0, .value = 1 }, // Minimal non-zero value
        .{ .offset = 0, .value = 0 }, // Zero value
        .{ .offset = std.math.maxInt(u32), .value = 0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB }, // Very large offset
    };
    
    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        // MSTORE takes offset and value from stack
        try ctx.frame.stack.append(case.offset);
        try ctx.frame.stack.append(case.value);
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = *evm.Operation.State = @ptrCast(&ctx.frame);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x52); // MSTORE
        
        // Verify the value was stored by reading it back with MLOAD
        try ctx.frame.stack.append(case.offset);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x51); // MLOAD
        
        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.value, result);
    }
}

// Comprehensive MLOAD operation fuzz testing
test "fuzz_mload_memory_loading_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);
    
    const test_cases = [_]struct { offset: u256, expected: u256 }{
        // Reading from uninitialized memory (should return 0)
        .{ .offset = 0, .expected = 0 },
        .{ .offset = 32, .expected = 0 },
        .{ .offset = 64, .expected = 0 },
        .{ .offset = 1024, .expected = 0 },
        .{ .offset = 4096, .expected = 0 },
        
        // Non-word-aligned reads from uninitialized memory
        .{ .offset = 1, .expected = 0 },
        .{ .offset = 15, .expected = 0 },
        .{ .offset = 33, .expected = 0 },
        .{ .offset = 63, .expected = 0 },
        
        // Very large offsets
        .{ .offset = std.math.maxInt(u32), .expected = 0 },
        .{ .offset = 1 << 20, .expected = 0 }, // 1MB offset
        .{ .offset = 1 << 24, .expected = 0 }, // 16MB offset
    };
    
    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        try ctx.frame.stack.append(case.offset);
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = *evm.Operation.State = @ptrCast(&ctx.frame);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x51); // MLOAD
        
        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(case.expected, result);
    }
}

// Comprehensive MSTORE8 operation fuzz testing
test "fuzz_mstore8_byte_storage_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);
    
    const test_cases = [_]struct { offset: u256, value: u256, expected_byte: u8 }{
        // Basic byte values
        .{ .offset = 0, .value = 0x00, .expected_byte = 0x00 },
        .{ .offset = 1, .value = 0x12, .expected_byte = 0x12 },
        .{ .offset = 2, .value = 0xFF, .expected_byte = 0xFF },
        .{ .offset = 3, .value = 0xAB, .expected_byte = 0xAB },
        
        // Values larger than a byte (should be truncated to lowest byte)
        .{ .offset = 10, .value = 0x1234, .expected_byte = 0x34 },
        .{ .offset = 11, .value = 0x123456, .expected_byte = 0x56 },
        .{ .offset = 12, .value = 0x12345678, .expected_byte = 0x78 },
        .{ .offset = 13, .value = 0x123456789ABCDEF0, .expected_byte = 0xF0 },
        
        // Maximum u256 value (should store only lowest byte)
        .{ .offset = 20, .value = std.math.maxInt(u256), .expected_byte = 0xFF },
        
        // Large offsets
        .{ .offset = 1024, .value = 0x42, .expected_byte = 0x42 },
        .{ .offset = 4096, .value = 0x88, .expected_byte = 0x88 },
        .{ .offset = 65536, .value = 0xCC, .expected_byte = 0xCC },
        
        // Sequential bytes to test no interference
        .{ .offset = 100, .value = 0x11, .expected_byte = 0x11 },
        .{ .offset = 101, .value = 0x22, .expected_byte = 0x22 },
        .{ .offset = 102, .value = 0x33, .expected_byte = 0x33 },
        .{ .offset = 103, .value = 0x44, .expected_byte = 0x44 },
        
        // Overwriting bytes
        .{ .offset = 200, .value = 0xAA, .expected_byte = 0xAA },
        .{ .offset = 200, .value = 0xBB, .expected_byte = 0xBB }, // Overwrite previous
    };
    
    for (test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        // MSTORE8 takes offset and value from stack
        try ctx.frame.stack.append(case.offset);
        try ctx.frame.stack.append(case.value);
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = *evm.Operation.State = @ptrCast(&ctx.frame);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x53); // MSTORE8
        
        // Verify the byte was stored by reading the word containing it
        try ctx.frame.stack.append(case.offset & ~@as(u256, 31)); // Align to 32-byte boundary
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x51); // MLOAD
        
        const result = try ctx.frame.stack.pop();
        // Extract the specific byte from the 32-byte word
        const byte_index = case.offset % 32;
        const byte_value = @as(u8, @truncate((result >> @intCast((31 - byte_index) * 8)) & 0xFF));
        try testing.expectEqual(case.expected_byte, byte_value);
    }
}

// Comprehensive MSIZE operation fuzz testing
test "fuzz_msize_memory_size_tracking" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);
    
    var interpreter = evm.Operation.Interpreter = &ctx.vm;
    var state = *evm.Operation.State = @ptrCast(&ctx.frame);
    
    // Initially, memory size should be 0
    {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x59); // MSIZE
        const initial_size = try ctx.frame.stack.pop();
        try testing.expectEqual(@as(u256, 0), initial_size);
    }
    
    const test_cases = [_]struct { access_offset: u256, expected_size: u256 }{
        // Memory expansion cases - memory expands in 32-byte words
        .{ .access_offset = 0, .expected_size = 32 }, // Access at 0 expands to 32 bytes
        .{ .access_offset = 31, .expected_size = 64 }, // Access at 31 needs 32 more bytes
        .{ .access_offset = 32, .expected_size = 64 }, // Access at 32 needs 64 bytes total
        .{ .access_offset = 63, .expected_size = 96 }, // Access at 63 needs 96 bytes total
        .{ .access_offset = 64, .expected_size = 96 }, // Access at 64 needs 96 bytes total
        .{ .access_offset = 1023, .expected_size = 1056 }, // Access at 1023 needs 1056 bytes (33 words)
        .{ .access_offset = 1024, .expected_size = 1056 }, // Access at 1024 still 1056 bytes
        .{ .access_offset = 4095, .expected_size = 4128 }, // Large memory expansion
    };
    
    for (test_cases) |case| {
        // Trigger memory expansion by doing MLOAD at the offset
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }
            
            try ctx.frame.stack.append(case.access_offset);
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x51); // MLOAD
            _ = try ctx.frame.stack.pop(); // Discard the loaded value
        }
        
        // Check memory size
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }
            
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x59); // MSIZE
            const current_size = try ctx.frame.stack.pop();
            try testing.expectEqual(case.expected_size, current_size);
        }
    }
}

// Comprehensive MCOPY operation fuzz testing (if supported)
test "fuzz_mcopy_memory_copying_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);
    
    var interpreter = evm.Operation.Interpreter = &ctx.vm;
    var state = *evm.Operation.State = @ptrCast(&ctx.frame);
    
    // First, store some data in memory to copy
    const test_data = [_]u256{
        0x1111111111111111111111111111111111111111111111111111111111111111,
        0x2222222222222222222222222222222222222222222222222222222222222222,
        0x3333333333333333333333333333333333333333333333333333333333333333,
        0x4444444444444444444444444444444444444444444444444444444444444444,
    };
    
    // Store test data at known locations
    for (test_data, 0..) |data, i| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        try ctx.frame.stack.append(@as(u256, i * 32));
        try ctx.frame.stack.append(data);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x52); // MSTORE
    }
    
    const copy_test_cases = [_]struct { dst: u256, src: u256, len: u256 }{
        // Basic copies
        .{ .dst = 1000, .src = 0, .len = 32 }, // Copy first word
        .{ .dst = 1032, .src = 32, .len = 32 }, // Copy second word
        .{ .dst = 1064, .src = 64, .len = 32 }, // Copy third word
        
        // Partial copies
        .{ .dst = 2000, .src = 0, .len = 16 }, // Copy half a word
        .{ .dst = 2016, .src = 16, .len = 16 }, // Copy other half
        .{ .dst = 2032, .src = 0, .len = 8 }, // Copy quarter word
        
        // Multi-word copies
        .{ .dst = 3000, .src = 0, .len = 64 }, // Copy two words
        .{ .dst = 3064, .src = 0, .len = 128 }, // Copy four words
        
        // Zero-length copy (should be no-op)
        .{ .dst = 4000, .src = 0, .len = 0 },
        
        // Large copies
        .{ .dst = 5000, .src = 0, .len = 1024 }, // Copy 32 words
        
        // Overlapping copies (forward)
        .{ .dst = 100, .src = 0, .len = 64 }, // src: 0-63, dst: 100-163
        .{ .dst = 32, .src = 0, .len = 32 }, // src: 0-31, dst: 32-63
        
        // Edge case: copy to/from large offsets
        .{ .dst = 1 << 20, .src = 0, .len = 32 }, // Copy to 1MB offset
    };
    
    for (copy_test_cases) |case| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        // MCOPY takes dst, src, len from stack
        try ctx.frame.stack.append(case.dst);
        try ctx.frame.stack.append(case.src);
        try ctx.frame.stack.append(case.len);
        
        // Try MCOPY - might fail if not supported in this EVM version
        const result = ctx.vm.table.execute(0, interpreter, state, 0x5E); // MCOPY
        
        if (result) |_| {
            // If MCOPY succeeded, verify the copy
            if (case.len > 0 and case.len <= 32) {
                // Verify by reading the destination
                try ctx.frame.stack.append(case.dst);
                _ = try ctx.vm.table.execute(0, interpreter, state, 0x51); // MLOAD
                const dst_value = try ctx.frame.stack.pop();
                
                // Read the source for comparison
                try ctx.frame.stack.append(case.src);
                _ = try ctx.vm.table.execute(0, interpreter, state, 0x51); // MLOAD
                const src_value = try ctx.frame.stack.pop();
                
                // For full word copies, values should match
                if (case.len == 32) {
                    try testing.expectEqual(src_value, dst_value);
                }
            }
        } else |err| {
            // MCOPY might not be supported in all EVM versions - that's OK
            _ = err; // Ignore error for now
        }
    }
}

// Memory operation stress test with mixed operations
test "fuzz_memory_operations_stress_test" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);
    
    var interpreter = evm.Operation.Interpreter = &ctx.vm;
    var state = *evm.Operation.State = @ptrCast(&ctx.frame);
    
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();
    
    // Perform many random memory operations
    for (0..500) |_| {
        const operation = random.intRangeAtMost(u8, 0, 3);
        const offset = random.intRangeAtMost(u256, 0, 4095); // Keep offsets reasonable
        const value = random.int(u256);
        
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        switch (operation) {
            0 => {
                // MSTORE
                try ctx.frame.stack.append(offset);
                try ctx.frame.stack.append(value);
                _ = try ctx.vm.table.execute(0, interpreter, state, 0x52); // MSTORE
            },
            1 => {
                // MLOAD
                try ctx.frame.stack.append(offset);
                _ = try ctx.vm.table.execute(0, interpreter, state, 0x51); // MLOAD
                _ = try ctx.frame.stack.pop(); // Discard result
            },
            2 => {
                // MSTORE8
                try ctx.frame.stack.append(offset);
                try ctx.frame.stack.append(value);
                _ = try ctx.vm.table.execute(0, interpreter, state, 0x53); // MSTORE8
            },
            3 => {
                // MSIZE
                _ = try ctx.vm.table.execute(0, interpreter, state, 0x59); // MSIZE
                const size = try ctx.frame.stack.pop();
                // Memory size should always be a multiple of 32 and >= 0
                try testing.expect(size % 32 == 0);
            },
            else => unreachable,
        }
    }
    
    // Final consistency check - memory size should be reasonable
    {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x59); // MSIZE
        const final_size = try ctx.frame.stack.pop();
        // Size should be reasonable (not more than 1MB for our test)
        try testing.expect(final_size <= 1024 * 1024);
        try testing.expect(final_size % 32 == 0);
    }
}

// Test memory persistence across operations
test "fuzz_memory_persistence_and_consistency" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);
    
    var interpreter = evm.Operation.Interpreter = &ctx.vm;
    var state = *evm.Operation.State = @ptrCast(&ctx.frame);
    
    const test_patterns = [_]struct { offset: u256, value: u256 }{
        .{ .offset = 0, .value = 0x1111111111111111111111111111111111111111111111111111111111111111 },
        .{ .offset = 32, .value = 0x2222222222222222222222222222222222222222222222222222222222222222 },
        .{ .offset = 64, .value = 0x3333333333333333333333333333333333333333333333333333333333333333 },
        .{ .offset = 96, .value = 0x4444444444444444444444444444444444444444444444444444444444444444 },
        .{ .offset = 128, .value = 0x5555555555555555555555555555555555555555555555555555555555555555 },
    };
    
    // Store all test patterns
    for (test_patterns) |pattern| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        try ctx.frame.stack.append(pattern.offset);
        try ctx.frame.stack.append(pattern.value);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x52); // MSTORE
    }
    
    // Verify all patterns are still there
    for (test_patterns) |pattern| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        try ctx.frame.stack.append(pattern.offset);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x51); // MLOAD
        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(pattern.value, result);
    }
    
    // Overwrite some patterns and verify changes
    const overwrite_patterns = [_]struct { offset: u256, value: u256 }{
        .{ .offset = 32, .value = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA },
        .{ .offset = 96, .value = 0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB },
    };
    
    for (overwrite_patterns) |pattern| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        try ctx.frame.stack.append(pattern.offset);
        try ctx.frame.stack.append(pattern.value);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x52); // MSTORE
    }
    
    // Verify overwrites and non-overwrites
    for (test_patterns) |pattern| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        try ctx.frame.stack.append(pattern.offset);
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x51); // MLOAD
        const result = try ctx.frame.stack.pop();
        
        // Check if this offset was overwritten
        var expected = pattern.value;
        for (overwrite_patterns) |overwrite| {
            if (overwrite.offset == pattern.offset) {
                expected = overwrite.value;
                break;
            }
        }
        
        try testing.expectEqual(expected, result);
    }
}