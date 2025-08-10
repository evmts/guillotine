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

// Helper function to compute reference Keccak256 hash using std library
fn compute_keccak256_reference(data: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(data);
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

// Helper function to convert [32]u8 to u256
fn bytes_to_u256(bytes: [32]u8) u256 {
    var result: u256 = 0;
    for (bytes, 0..) |byte, i| {
        result |= (@as(u256, byte) << @intCast((31 - i) * 8));
    }
    return result;
}

// Comprehensive KECCAK256 operation fuzz testing with known test vectors
test "fuzz_keccak256_known_test_vectors" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    var interpreter: evm.Operation.Interpreter = &ctx.vm;
    var state: *evm.Operation.State = @ptrCast(&ctx.frame);

    const test_vectors = [_]struct {
        input: []const u8,
        expected_hex: []const u8,
        description: []const u8,
    }{
        // Empty input
        .{
            .input = "",
            .expected_hex = "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
            .description = "Empty string",
        },

        // Single byte inputs
        .{
            .input = &[_]u8{0x00},
            .expected_hex = "bc36789e7a1e281436464229828f817d6612f7b477d66591ff96a9e064bcc98a",
            .description = "Single zero byte",
        },

        .{
            .input = &[_]u8{0xFF},
            .expected_hex = "a8100ae6aa1940d0b663bb31cd466142ebbdbd5187131b92d93818987832eb89",
            .description = "Single 0xFF byte",
        },

        // Simple ASCII strings
        .{
            .input = "abc",
            .expected_hex = "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45",
            .description = "ASCII 'abc'",
        },

        .{
            .input = "hello",
            .expected_hex = "1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8",
            .description = "ASCII 'hello'",
        },

        // Ethereum-specific test cases
        .{
            .input = "ethereum",
            .expected_hex = "6b3b17d55bb14fdeff0e83b3a0d7b3bf8e7a9c0fd2b17ff53d6c4a2c8b5e6e31",
            .description = "ASCII 'ethereum'",
        },

        // 32-byte inputs (common in Ethereum)
        .{
            .input = &([_]u8{0x00} ** 32),
            .expected_hex = "290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563",
            .description = "32 zero bytes",
        },

        .{
            .input = &([_]u8{0xFF} ** 32),
            .expected_hex = "5380c7b7ae81a58eb98d9c78de4a1fd7fd9535fc953ed2be602daaa41767312a",
            .description = "32 0xFF bytes",
        },

        // Sequential bytes
        .{
            .input = &[_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 },
            .expected_hex = "eead6dbfc7340a56caedc044696a168870549a6a7f6f56961e84a54bd9970b8a",
            .description = "Sequential bytes 0x00-0x07",
        },
    };

    for (test_vectors) |vector| {
        // Store the input data in memory at offset 0
        for (vector.input, 0..) |byte, i| {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }

            // MSTORE8: store byte at offset i
            try ctx.frame.stack.append(@as(u256, i));
            try ctx.frame.stack.append(@as(u256, byte));
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x53); // MSTORE8
        }

        // Clear stack and prepare for KECCAK256
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        // KECCAK256: hash memory[offset:offset+length]
        try ctx.frame.stack.append(@as(u256, 0)); // offset
        try ctx.frame.stack.append(@as(u256, vector.input.len)); // length

        _ = try ctx.vm.table.execute(0, interpreter, state, 0x20); // KECCAK256

        const result = try ctx.frame.stack.pop();

        // Compute expected result using reference implementation
        const expected_bytes = compute_keccak256_reference(vector.input);
        const expected_u256 = bytes_to_u256(expected_bytes);

        try testing.expectEqual(expected_u256, result);
    }
}

// Test KECCAK256 with various memory layouts and alignments
test "fuzz_keccak256_memory_layout_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    var interpreter: evm.Operation.Interpreter = &ctx.vm;
    var state: *evm.Operation.State = @ptrCast(&ctx.frame);

    const layout_tests = [_]struct {
        data: []const u8,
        memory_offset: u256,
        description: []const u8,
    }{
        // Data at memory offset 0 (word-aligned)
        .{
            .data = "test",
            .memory_offset = 0,
            .description = "Word-aligned at offset 0",
        },

        // Data at memory offset 1 (unaligned)
        .{
            .data = "test",
            .memory_offset = 1,
            .description = "Unaligned at offset 1",
        },

        // Data at memory offset 31 (just before next word)
        .{
            .data = "test",
            .memory_offset = 31,
            .description = "Unaligned at offset 31",
        },

        // Data at memory offset 32 (next word boundary)
        .{
            .data = "test",
            .memory_offset = 32,
            .description = "Word-aligned at offset 32",
        },

        // Large offset
        .{
            .data = "test",
            .memory_offset = 1000,
            .description = "Large offset 1000",
        },

        // Cross word boundary
        .{
            .data = "this_is_a_longer_test_string_that_spans_multiple_words",
            .memory_offset = 30,
            .description = "Long string crossing word boundaries",
        },

        // Exactly 32 bytes at word boundary
        .{
            .data = "exactly_thirty_two_bytes_here!!",
            .memory_offset = 64,
            .description = "Exactly 32 bytes at word boundary",
        },

        // Binary data with null bytes
        .{
            .data = &[_]u8{ 0x00, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04 },
            .memory_offset = 100,
            .description = "Binary data with null bytes",
        },
    };

    for (layout_tests) |test_case| {
        // Store the test data in memory at the specified offset
        for (test_case.data, 0..) |byte, i| {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }

            // MSTORE8: store byte at offset + i
            try ctx.frame.stack.append(test_case.memory_offset + i);
            try ctx.frame.stack.append(@as(u256, byte));
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x53); // MSTORE8
        }

        // Clear stack and prepare for KECCAK256
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        // KECCAK256: hash memory[offset:offset+length]
        try ctx.frame.stack.append(test_case.memory_offset); // offset
        try ctx.frame.stack.append(@as(u256, test_case.data.len)); // length

        _ = try ctx.vm.table.execute(0, interpreter, state, 0x20); // KECCAK256

        const result = try ctx.frame.stack.pop();

        // Compute expected result using reference implementation
        const expected_bytes = compute_keccak256_reference(test_case.data);
        const expected_u256 = bytes_to_u256(expected_bytes);

        try testing.expectEqual(expected_u256, result);
    }
}

// Test KECCAK256 with edge case lengths
test "fuzz_keccak256_length_edge_cases" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    var interpreter: evm.Operation.Interpreter = &ctx.vm;
    var state: *evm.Operation.State = @ptrCast(&ctx.frame);

    const length_tests = [_]struct {
        length: usize,
        fill_byte: u8,
        description: []const u8,
    }{
        // Zero length (empty hash)
        .{
            .length = 0,
            .fill_byte = 0x00,
            .description = "Zero length",
        },

        // Single byte
        .{
            .length = 1,
            .fill_byte = 0xAA,
            .description = "Single byte",
        },

        // Keccak block size - 1 (135 bytes for Keccak256)
        .{
            .length = 135,
            .fill_byte = 0x55,
            .description = "Keccak block size - 1",
        },

        // Exact Keccak block size (136 bytes for Keccak256)
        .{
            .length = 136,
            .fill_byte = 0x77,
            .description = "Exact Keccak block size",
        },

        // Keccak block size + 1
        .{
            .length = 137,
            .fill_byte = 0x99,
            .description = "Keccak block size + 1",
        },

        // Multiple blocks
        .{
            .length = 272, // 2 * 136
            .fill_byte = 0xBB,
            .description = "Two Keccak blocks",
        },

        // Large but reasonable size
        .{
            .length = 1024,
            .fill_byte = 0xCC,
            .description = "1KB data",
        },

        // Powers of 2
        .{
            .length = 256,
            .fill_byte = 0xDD,
            .description = "256 bytes",
        },

        .{
            .length = 512,
            .fill_byte = 0xEE,
            .description = "512 bytes",
        },
    };

    for (length_tests) |test_case| {
        // Create test data filled with the specified byte
        var test_data = try allocator.alloc(u8, test_case.length);
        defer allocator.free(test_data);
        @memset(test_data, test_case.fill_byte);

        // Store the test data in memory starting at offset 0
        for (test_data, 0..) |byte, i| {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }

            // MSTORE8: store byte at offset i
            try ctx.frame.stack.append(@as(u256, i));
            try ctx.frame.stack.append(@as(u256, byte));
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x53); // MSTORE8
        }

        // Clear stack and prepare for KECCAK256
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        // KECCAK256: hash memory[0:length]
        try ctx.frame.stack.append(@as(u256, 0)); // offset
        try ctx.frame.stack.append(@as(u256, test_case.length)); // length

        _ = try ctx.vm.table.execute(0, interpreter, state, 0x20); // KECCAK256

        const result = try ctx.frame.stack.pop();

        // Compute expected result using reference implementation
        const expected_bytes = compute_keccak256_reference(test_data);
        const expected_u256 = bytes_to_u256(expected_bytes);

        try testing.expectEqual(expected_u256, result);
    }
}

// Test KECCAK256 with overlapping memory regions
test "fuzz_keccak256_overlapping_memory_regions" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    var interpreter: evm.Operation.Interpreter = &ctx.vm;
    var state: *evm.Operation.State = @ptrCast(&ctx.frame);

    // Set up test data pattern in memory
    const test_pattern = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    for (test_pattern, 0..) |byte, i| {
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        // MSTORE8: store byte at offset i
        try ctx.frame.stack.append(@as(u256, i));
        try ctx.frame.stack.append(@as(u256, byte));
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x53); // MSTORE8
    }

    const overlap_tests = [_]struct {
        offset1: u256,
        length1: u256,
        offset2: u256,
        length2: u256,
        description: []const u8,
    }{
        // Identical regions
        .{
            .offset1 = 0,
            .length1 = 10,
            .offset2 = 0,
            .length2 = 10,
            .description = "Identical regions",
        },

        // Partial overlap
        .{
            .offset1 = 0,
            .length1 = 15,
            .offset2 = 10,
            .length2 = 15,
            .description = "Partial overlap",
        },

        // Contained region
        .{
            .offset1 = 5,
            .length1 = 10,
            .offset2 = 0,
            .length2 = 20,
            .description = "First contained in second",
        },

        // Adjacent regions
        .{
            .offset1 = 0,
            .length1 = 10,
            .offset2 = 10,
            .length2 = 10,
            .description = "Adjacent regions",
        },

        // Different starting points, same length
        .{
            .offset1 = 5,
            .length1 = 10,
            .offset2 = 15,
            .length2 = 10,
            .description = "Same length, different offsets",
        },
    };

    for (overlap_tests) |test_case| {
        // Hash first region
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }

            try ctx.frame.stack.append(test_case.offset1);
            try ctx.frame.stack.append(test_case.length1);
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x20); // KECCAK256

            const result1 = try ctx.frame.stack.pop();

            // Extract the data for reference computation
            const start1 = @as(usize, @intCast(test_case.offset1));
            const len1 = @as(usize, @intCast(test_case.length1));
            const end1 = @min(start1 + len1, test_pattern.len);
            const data1 = if (start1 < test_pattern.len) test_pattern[start1..end1] else "";

            const expected1_bytes = compute_keccak256_reference(data1);
            const expected1_u256 = bytes_to_u256(expected1_bytes);

            try testing.expectEqual(expected1_u256, result1);
        }

        // Hash second region
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }

            try ctx.frame.stack.append(test_case.offset2);
            try ctx.frame.stack.append(test_case.length2);
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x20); // KECCAK256

            const result2 = try ctx.frame.stack.pop();

            // Extract the data for reference computation
            const start2 = @as(usize, @intCast(test_case.offset2));
            const len2 = @as(usize, @intCast(test_case.length2));
            const end2 = @min(start2 + len2, test_pattern.len);
            const data2 = if (start2 < test_pattern.len) test_pattern[start2..end2] else "";

            const expected2_bytes = compute_keccak256_reference(data2);
            const expected2_u256 = bytes_to_u256(expected2_bytes);

            try testing.expectEqual(expected2_u256, result2);
        }
    }
}

// Stress test with random data patterns
test "fuzz_keccak256_random_stress_test" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    var interpreter: evm.Operation.Interpreter = &ctx.vm;
    var state: *evm.Operation.State = @ptrCast(&ctx.frame);

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    // Test many random data patterns
    for (0..100) |_| {
        const data_length = random.intRangeAtMost(usize, 0, 256);
        const memory_offset = random.intRangeAtMost(u256, 0, 100);

        // Generate random test data
        var test_data = try allocator.alloc(u8, data_length);
        defer allocator.free(test_data);

        for (test_data) |*byte| {
            byte.* = random.int(u8);
        }

        // Store the test data in memory
        for (test_data, 0..) |byte, i| {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }

            // MSTORE8: store byte at offset + i
            try ctx.frame.stack.append(memory_offset + i);
            try ctx.frame.stack.append(@as(u256, byte));
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x53); // MSTORE8
        }

        // Clear stack and prepare for KECCAK256
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        // KECCAK256: hash memory[offset:offset+length]
        try ctx.frame.stack.append(memory_offset); // offset
        try ctx.frame.stack.append(@as(u256, data_length)); // length

        _ = try ctx.vm.table.execute(0, interpreter, state, 0x20); // KECCAK256

        const result = try ctx.frame.stack.pop();

        // Compute expected result using reference implementation
        const expected_bytes = compute_keccak256_reference(test_data);
        const expected_u256 = bytes_to_u256(expected_bytes);

        try testing.expectEqual(expected_u256, result);
    }
}

// Test KECCAK256 determinism (same input should always produce same output)
test "fuzz_keccak256_determinism" {
    const allocator = testing.allocator;

    const test_data = "determinism_test_data_123456789";

    // Hash the same data multiple times with different EVM contexts
    var results = std.ArrayList(u256).init(allocator);
    defer results.deinit();

    for (0..5) |_| {
        var ctx = try create_evm_context(allocator);
        defer deinit_evm_context(ctx, allocator);

        var interpreter: evm.Operation.Interpreter = &ctx.vm;
        var state: *evm.Operation.State = @ptrCast(&ctx.frame);

        // Store test data in memory
        for (test_data, 0..) |byte, i| {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }

            try ctx.frame.stack.append(@as(u256, i));
            try ctx.frame.stack.append(@as(u256, byte));
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x53); // MSTORE8
        }

        // Clear stack and compute hash
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(@as(u256, 0)); // offset
        try ctx.frame.stack.append(@as(u256, test_data.len)); // length

        _ = try ctx.vm.table.execute(0, interpreter, state, 0x20); // KECCAK256

        const result = try ctx.frame.stack.pop();
        try results.append(result);
    }

    // All results should be identical
    const first_result = results.items[0];
    for (results.items[1..]) |result| {
        try testing.expectEqual(first_result, result);
    }

    // Also verify against reference implementation
    const expected_bytes = compute_keccak256_reference(test_data);
    const expected_u256 = bytes_to_u256(expected_bytes);
    try testing.expectEqual(expected_u256, first_result);
}

// Test KECCAK256 with memory expansion edge cases
test "fuzz_keccak256_memory_expansion" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(ctx, allocator);

    var interpreter: evm.Operation.Interpreter = &ctx.vm;
    var state: *evm.Operation.State = @ptrCast(&ctx.frame);

    const expansion_tests = [_]struct {
        offset: u256,
        length: u256,
        description: []const u8,
    }{
        // Hash at large offset (should expand memory)
        .{
            .offset = 1000,
            .length = 32,
            .description = "Large offset memory expansion",
        },

        // Hash crossing 1KB boundary
        .{
            .offset = 1020,
            .length = 32,
            .description = "Cross 1KB boundary",
        },

        // Very large offset with small length
        .{
            .offset = 10000,
            .length = 1,
            .description = "Very large offset, small data",
        },

        // Medium offset with large length
        .{
            .offset = 500,
            .length = 1000,
            .description = "Medium offset, large data",
        },
    };

    for (expansion_tests) |test_case| {
        // Clear stack and hash the memory region (will be zero-filled)
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(test_case.offset);
        try ctx.frame.stack.append(test_case.length);

        _ = try ctx.vm.table.execute(0, interpreter, state, 0x20); // KECCAK256

        const result = try ctx.frame.stack.pop();

        // Compute expected result (should be hash of zero bytes)
        const len = @as(usize, @intCast(test_case.length));
        var zero_data = try allocator.alloc(u8, len);
        defer allocator.free(zero_data);
        @memset(zero_data, 0);

        const expected_bytes = compute_keccak256_reference(zero_data);
        const expected_u256 = bytes_to_u256(expected_bytes);

        try testing.expectEqual(expected_u256, result);
    }
}
