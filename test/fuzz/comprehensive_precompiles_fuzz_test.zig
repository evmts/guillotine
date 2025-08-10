const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const testing = std.testing;

// Helper function to create EVM execution context for precompile calls
fn create_evm_context_for_precompiles(allocator: std.mem.Allocator) !struct {
    db: evm.MemoryDatabase,
    vm: evm.Evm,
    contract: evm.Contract,
    frame: evm.Frame,
} {
    var db = evm.MemoryDatabase.init(allocator);
    const config = evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.Evm(config);
    var vm = try EvmType.init(allocator, db.to_database_interface(), null, 0, false, null);
    
    // Create a contract that calls precompiles
    const call_precompile_code = [_]u8{0xF1}; // CALL opcode
    var contract = evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        10000000, // High gas limit for precompile calls
        &call_precompile_code,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    
    var builder = evm.Frame.builder(allocator);
    var frame = try builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(10000000)
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
    ctx.frame.deinit();
    ctx.contract.deinit(allocator, null);
    ctx.vm.deinit();
    ctx.db.deinit();
}

// Comprehensive ECRECOVER (0x01) precompile fuzz testing
test "fuzz_ecrecover_precompile_edge_cases" {
    const allocator = testing.allocator;
    
    const ecrecover_tests = [_]struct {
        input_data: []const u8,
        expected_gas: u64,
        expected_success: bool,
        description: []const u8,
    }{
        // Valid signature test cases (these should succeed)
        .{
            .input_data = &([_]u8{0} ** 128), // All zeros (invalid but defined behavior)
            .expected_gas = 3000,
            .expected_success = false,
            .description = "All zeros input returns empty",
        },
        
        // Invalid input sizes
        .{
            .input_data = &([_]u8{0} ** 32), // Too short
            .expected_gas = 3000,
            .expected_success = false,
            .description = "Too short input (32 bytes)",
        },
        .{
            .input_data = &([_]u8{0} ** 64), // Too short
            .expected_gas = 3000,
            .expected_success = false,
            .description = "Too short input (64 bytes)",
        },
        .{
            .input_data = &([_]u8{0} ** 96), // Too short
            .expected_gas = 3000,
            .expected_success = false,
            .description = "Too short input (96 bytes)",
        },
        .{
            .input_data = &([_]u8{0} ** 160), // Too long
            .expected_gas = 3000,
            .expected_success = false,
            .description = "Too long input (160 bytes)",
        },
        
        // Invalid recovery ID (v parameter)
        .{
            .input_data = &(([_]u8{0} ** 32) ++ ([_]u8{0} ** 31) ++ [_]u8{26} ++ ([_]u8{1} ** 64)), // v = 26 (invalid)
            .expected_gas = 3000,
            .expected_success = false,
            .description = "Invalid recovery ID v=26",
        },
        .{
            .input_data = &(([_]u8{0} ** 32) ++ ([_]u8{0} ** 31) ++ [_]u8{29} ++ ([_]u8{1} ** 64)), // v = 29 (invalid)
            .expected_gas = 3000,
            .expected_success = false,
            .description = "Invalid recovery ID v=29",
        },
        .{
            .input_data = &(([_]u8{0} ** 32) ++ ([_]u8{0xFF} ** 32) ++ ([_]u8{1} ** 64)), // v = max
            .expected_gas = 3000,
            .expected_success = false,
            .description = "Invalid recovery ID v=max",
        },
        
        // Valid recovery IDs but invalid signature components
        .{
            .input_data = &(([_]u8{0} ** 32) ++ ([_]u8{0} ** 31) ++ [_]u8{27} ++ ([_]u8{0} ** 64)), // v=27, r=0, s=0
            .expected_gas = 3000,
            .expected_success = false,
            .description = "Valid v=27 but r=0, s=0",
        },
        .{
            .input_data = &(([_]u8{0} ** 32) ++ ([_]u8{0} ** 31) ++ [_]u8{28} ++ ([_]u8{0} ** 64)), // v=28, r=0, s=0
            .expected_gas = 3000,
            .expected_success = false,
            .description = "Valid v=28 but r=0, s=0",
        },
        
        // Invalid signature components (r >= curve order)
        .{
            .input_data = &(([_]u8{0} ** 32) ++ ([_]u8{0} ** 31) ++ [_]u8{27} ++ ([_]u8{0xFF} ** 32) ++ ([_]u8{1} ** 32)), // r = max
            .expected_gas = 3000,
            .expected_success = false,
            .description = "r component at maximum value",
        },
        
        // Invalid signature components (s >= curve order)
        .{
            .input_data = &(([_]u8{0} ** 32) ++ ([_]u8{0} ** 31) ++ [_]u8{27} ++ ([_]u8{1} ** 32) ++ ([_]u8{0xFF} ** 32)), // s = max
            .expected_gas = 3000,
            .expected_success = false,
            .description = "s component at maximum value",
        },
        
        // Empty input
        .{
            .input_data = &[_]u8{},
            .expected_gas = 3000,
            .expected_success = false,
            .description = "Empty input",
        },
        
        // Pattern tests
        .{
            .input_data = &([_]u8{0xAA} ** 128),
            .expected_gas = 3000,
            .expected_success = false,
            .description = "All 0xAA pattern",
        },
        .{
            .input_data = &([_]u8{0x55} ** 128),
            .expected_gas = 3000,
            .expected_success = false,
            .description = "All 0x55 pattern",
        },
        .{
            .input_data = &([_]u8{0xFF} ** 128),
            .expected_gas = 3000,
            .expected_success = false,
            .description = "All 0xFF pattern",
        },
    };
    
    for (ecrecover_tests) |test_case| {
        // Test ECRECOVER directly through precompile interface
        var output_buffer: [32]u8 = undefined;
        
        const result = evm.precompiles.ecrecover.execute(
            test_case.input_data,
            &output_buffer,
            test_case.expected_gas + 1000 // Provide enough gas
        );
        
        if (test_case.expected_success) {
            try testing.expect(result.is_success());
            if (result == .success) {
                try testing.expect(result.success.output_size == 32);
            }
        } else {
            // Most ECRECOVER failures result in empty output rather than error
            if (result == .success) {
                try testing.expect(result.success.output_size == 0 or result.success.output_size == 32);
            }
        }
        
        // Gas cost should always be the fixed amount
        if (result == .success) {
            try testing.expectEqual(test_case.expected_gas, result.success.gas_used);
        } else if (result == .out_of_gas) {
            // This shouldn't happen with our gas provision
            return error.UnexpectedOutOfGas;
        }
    }
}

// Comprehensive IDENTITY (0x04) precompile fuzz testing
test "fuzz_identity_precompile_edge_cases" {
    const allocator = testing.allocator;
    
    const identity_tests = [_]struct {
        input_size: usize,
        expected_gas: u64,
        description: []const u8,
    }{
        // Gas cost formula: 15 + 3 * ceil(input_size / 32)
        .{ .input_size = 0, .expected_gas = 15, .description = "Empty input" },
        .{ .input_size = 1, .expected_gas = 18, .description = "1 byte input" },
        .{ .input_size = 31, .expected_gas = 18, .description = "31 bytes input" },
        .{ .input_size = 32, .expected_gas = 18, .description = "32 bytes input (1 word)" },
        .{ .input_size = 33, .expected_gas = 21, .description = "33 bytes input (2 words)" },
        .{ .input_size = 64, .expected_gas = 21, .description = "64 bytes input (2 words)" },
        .{ .input_size = 65, .expected_gas = 24, .description = "65 bytes input (3 words)" },
        .{ .input_size = 100, .expected_gas = 24, .description = "100 bytes input (3 words)" },
        .{ .input_size = 128, .expected_gas = 27, .description = "128 bytes input (4 words)" },
        .{ .input_size = 256, .expected_gas = 39, .description = "256 bytes input (8 words)" },
        .{ .input_size = 1000, .expected_gas = 15 + 3 * 32, .description = "1000 bytes input (32 words)" },
        .{ .input_size = 1024, .expected_gas = 15 + 3 * 32, .description = "1024 bytes input (32 words)" },
        .{ .input_size = 2048, .expected_gas = 15 + 3 * 64, .description = "2048 bytes input (64 words)" },
        .{ .input_size = 4096, .expected_gas = 15 + 3 * 128, .description = "4096 bytes input (128 words)" },
    };
    
    for (identity_tests) |test_case| {
        // Create input data with pattern
        const input_data = try allocator.alloc(u8, test_case.input_size);
        defer allocator.free(input_data);
        
        for (input_data, 0..) |*byte, i| {
            byte.* = @intCast((i * 7 + 13) % 256); // Pseudo-random pattern
        }
        
        // Create output buffer (should be same size as input)
        const output_buffer = try allocator.alloc(u8, test_case.input_size);
        defer allocator.free(output_buffer);
        
        const result = evm.precompiles.identity.execute(
            input_data,
            output_buffer,
            test_case.expected_gas + 100 // Provide enough gas
        );
        
        try testing.expect(result.is_success());
        if (result == .success) {
            try testing.expectEqual(test_case.expected_gas, result.success.gas_used);
            try testing.expectEqual(test_case.input_size, result.success.output_size);
            
            // Verify output matches input exactly
            if (test_case.input_size > 0) {
                try testing.expectEqualSlices(u8, input_data, output_buffer[0..result.success.output_size]);
            }
        }
    }
}

// Comprehensive SHA256 (0x02) precompile fuzz testing
test "fuzz_sha256_precompile_edge_cases" {
    const allocator = testing.allocator;
    
    const sha256_tests = [_]struct {
        input_size: usize,
        expected_gas: u64,
        description: []const u8,
    }{
        // Gas cost formula: 60 + 12 * ceil(input_size / 32)
        .{ .input_size = 0, .expected_gas = 60, .description = "Empty input" },
        .{ .input_size = 1, .expected_gas = 72, .description = "1 byte input" },
        .{ .input_size = 31, .expected_gas = 72, .description = "31 bytes input" },
        .{ .input_size = 32, .expected_gas = 72, .description = "32 bytes input (1 word)" },
        .{ .input_size = 33, .expected_gas = 84, .description = "33 bytes input (2 words)" },
        .{ .input_size = 64, .expected_gas = 84, .description = "64 bytes input (2 words)" },
        .{ .input_size = 65, .expected_gas = 96, .description = "65 bytes input (3 words)" },
        .{ .input_size = 100, .expected_gas = 96, .description = "100 bytes input (3 words)" },
        .{ .input_size = 128, .expected_gas = 108, .description = "128 bytes input (4 words)" },
        .{ .input_size = 256, .expected_gas = 156, .description = "256 bytes input (8 words)" },
        .{ .input_size = 1000, .expected_gas = 60 + 12 * 32, .description = "1000 bytes input (32 words)" },
        .{ .input_size = 1024, .expected_gas = 60 + 12 * 32, .description = "1024 bytes input (32 words)" },
    };
    
    for (sha256_tests) |test_case| {
        // Create input data with different patterns
        const patterns = [_]u8{ 0x00, 0xFF, 0xAA, 0x55, 0x01 };
        for (patterns) |pattern| {
            const input_data = try allocator.alloc(u8, test_case.input_size);
            defer allocator.free(input_data);
            
            if (pattern == 0x01) {
                // Incremental pattern
                for (input_data, 0..) |*byte, i| {
                    byte.* = @intCast(i % 256);
                }
            } else {
                // Fill with pattern
                @memset(input_data, pattern);
            }
            
            var output_buffer: [32]u8 = undefined; // SHA256 always outputs 32 bytes
            
            const result = evm.precompiles.sha256.execute(
                input_data,
                &output_buffer,
                test_case.expected_gas + 100 // Provide enough gas
            );
            
            try testing.expect(result.is_success());
            if (result == .success) {
                try testing.expectEqual(test_case.expected_gas, result.success.gas_used);
                try testing.expectEqual(@as(usize, 32), result.success.output_size);
                
                // Verify output is deterministic for same input
                var second_output: [32]u8 = undefined;
                const second_result = evm.precompiles.sha256.execute(
                    input_data,
                    &second_output,
                    test_case.expected_gas + 100
                );
                try testing.expect(second_result.is_success());
                try testing.expectEqualSlices(u8, &output_buffer, &second_output);
                
                // For non-empty inputs, hash should not be all zeros
                if (test_case.input_size > 0) {
                    const all_zeros = [_]u8{0} ** 32;
                    try testing.expect(!std.mem.eql(u8, &output_buffer, &all_zeros));
                }
            }
        }
    }
}

// Comprehensive RIPEMD160 (0x03) precompile fuzz testing
test "fuzz_ripemd160_precompile_edge_cases" {
    const allocator = testing.allocator;
    
    const ripemd160_tests = [_]struct {
        input_size: usize,
        expected_gas: u64,
        description: []const u8,
    }{
        // Gas cost formula: 600 + 120 * ceil(input_size / 32)
        .{ .input_size = 0, .expected_gas = 600, .description = "Empty input" },
        .{ .input_size = 1, .expected_gas = 720, .description = "1 byte input" },
        .{ .input_size = 31, .expected_gas = 720, .description = "31 bytes input" },
        .{ .input_size = 32, .expected_gas = 720, .description = "32 bytes input (1 word)" },
        .{ .input_size = 33, .expected_gas = 840, .description = "33 bytes input (2 words)" },
        .{ .input_size = 64, .expected_gas = 840, .description = "64 bytes input (2 words)" },
        .{ .input_size = 128, .expected_gas = 1080, .description = "128 bytes input (4 words)" },
        .{ .input_size = 256, .expected_gas = 1560, .description = "256 bytes input (8 words)" },
    };
    
    for (ripemd160_tests) |test_case| {
        const input_data = try allocator.alloc(u8, test_case.input_size);
        defer allocator.free(input_data);
        
        // Fill with incremental pattern
        for (input_data, 0..) |*byte, i| {
            byte.* = @intCast((i * 3 + 7) % 256);
        }
        
        var output_buffer: [32]u8 = undefined; // RIPEMD160 outputs 20 bytes, left-padded to 32
        
        const result = evm.precompiles.ripemd160.execute(
            input_data,
            &output_buffer,
            test_case.expected_gas + 100 // Provide enough gas
        );
        
        try testing.expect(result.is_success());
        if (result == .success) {
            try testing.expectEqual(test_case.expected_gas, result.success.gas_used);
            try testing.expectEqual(@as(usize, 32), result.success.output_size);
            
            // First 12 bytes should be zeros (left padding)
            const zero_padding = [_]u8{0} ** 12;
            try testing.expectEqualSlices(u8, &zero_padding, output_buffer[0..12]);
            
            // Verify deterministic output
            var second_output: [32]u8 = undefined;
            const second_result = evm.precompiles.ripemd160.execute(
                input_data,
                &second_output,
                test_case.expected_gas + 100
            );
            try testing.expect(second_result.is_success());
            try testing.expectEqualSlices(u8, &output_buffer, &second_output);
        }
    }
}

// Gas exhaustion testing for precompiles
test "fuzz_precompiles_gas_exhaustion" {
    const allocator = testing.allocator;
    
    const gas_exhaustion_tests = [_]struct {
        precompile_name: []const u8,
        input_size: usize,
        provided_gas: u64,
        should_succeed: bool,
    }{
        // ECRECOVER
        .{ .precompile_name = "ECRECOVER", .input_size = 128, .provided_gas = 3000, .should_succeed = true },
        .{ .precompile_name = "ECRECOVER", .input_size = 128, .provided_gas = 2999, .should_succeed = false },
        .{ .precompile_name = "ECRECOVER", .input_size = 128, .provided_gas = 0, .should_succeed = false },
        
        // SHA256
        .{ .precompile_name = "SHA256", .input_size = 32, .provided_gas = 72, .should_succeed = true },
        .{ .precompile_name = "SHA256", .input_size = 32, .provided_gas = 71, .should_succeed = false },
        .{ .precompile_name = "SHA256", .input_size = 64, .provided_gas = 84, .should_succeed = true },
        .{ .precompile_name = "SHA256", .input_size = 64, .provided_gas = 83, .should_succeed = false },
        
        // RIPEMD160
        .{ .precompile_name = "RIPEMD160", .input_size = 32, .provided_gas = 720, .should_succeed = true },
        .{ .precompile_name = "RIPEMD160", .input_size = 32, .provided_gas = 719, .should_succeed = false },
        
        // IDENTITY
        .{ .precompile_name = "IDENTITY", .input_size = 32, .provided_gas = 18, .should_succeed = true },
        .{ .precompile_name = "IDENTITY", .input_size = 32, .provided_gas = 17, .should_succeed = false },
        .{ .precompile_name = "IDENTITY", .input_size = 64, .provided_gas = 21, .should_succeed = true },
        .{ .precompile_name = "IDENTITY", .input_size = 64, .provided_gas = 20, .should_succeed = false },
    };
    
    for (gas_exhaustion_tests) |test_case| {
        const input_data = try allocator.alloc(u8, test_case.input_size);
        defer allocator.free(input_data);
        
        // Fill with test pattern
        for (input_data, 0..) |*byte, i| {
            byte.* = @intCast(i % 256);
        }
        
        var output_buffer: [1024]u8 = undefined; // Large enough for any precompile output
        
        if (std.mem.eql(u8, test_case.precompile_name, "ECRECOVER")) {
            const result = evm.precompiles.ecrecover.execute(input_data, &output_buffer, test_case.provided_gas);
            if (test_case.should_succeed) {
                try testing.expect(result.is_success() or result == .success);
            } else {
                try testing.expect(result == .out_of_gas);
            }
        } else if (std.mem.eql(u8, test_case.precompile_name, "SHA256")) {
            const result = evm.precompiles.sha256.execute(input_data, &output_buffer, test_case.provided_gas);
            if (test_case.should_succeed) {
                try testing.expect(result.is_success());
            } else {
                try testing.expect(result == .out_of_gas);
            }
        } else if (std.mem.eql(u8, test_case.precompile_name, "RIPEMD160")) {
            const result = evm.precompiles.ripemd160.execute(input_data, &output_buffer, test_case.provided_gas);
            if (test_case.should_succeed) {
                try testing.expect(result.is_success());
            } else {
                try testing.expect(result == .out_of_gas);
            }
        } else if (std.mem.eql(u8, test_case.precompile_name, "IDENTITY")) {
            const result = evm.precompiles.identity.execute(input_data, &output_buffer, test_case.provided_gas);
            if (test_case.should_succeed) {
                try testing.expect(result.is_success());
            } else {
                try testing.expect(result == .out_of_gas);
            }
        }
    }
}

// Random precompile stress testing
test "fuzz_precompiles_random_stress" {
    const allocator = testing.allocator;
    
    var prng = std.Random.DefaultPrng.init(0xPRECOMPILE);
    const random = prng.random();
    
    // Test many random inputs for each precompile
    for (0..50) |_| {
        const input_size = random.intRangeAtMost(usize, 0, 500);
        
        const input_data = try allocator.alloc(u8, input_size);
        defer allocator.free(input_data);
        random.bytes(input_data);
        
        var output_buffer: [1024]u8 = undefined;
        
        // Test IDENTITY with random data
        {
            const expected_gas = 15 + 3 * ((input_size + 31) / 32);
            const result = evm.precompiles.identity.execute(input_data, &output_buffer, expected_gas + 100);
            
            try testing.expect(result.is_success());
            if (result == .success) {
                try testing.expectEqual(expected_gas, result.success.gas_used);
                try testing.expectEqual(input_size, result.success.output_size);
                if (input_size > 0) {
                    try testing.expectEqualSlices(u8, input_data, output_buffer[0..input_size]);
                }
            }
        }
        
        // Test SHA256 with random data
        {
            const expected_gas = 60 + 12 * ((input_size + 31) / 32);
            const result = evm.precompiles.sha256.execute(input_data, &output_buffer, expected_gas + 100);
            
            try testing.expect(result.is_success());
            if (result == .success) {
                try testing.expectEqual(expected_gas, result.success.gas_used);
                try testing.expectEqual(@as(usize, 32), result.success.output_size);
            }
        }
        
        // Test RIPEMD160 with random data
        {
            const expected_gas = 600 + 120 * ((input_size + 31) / 32);
            const result = evm.precompiles.ripemd160.execute(input_data, &output_buffer, expected_gas + 100);
            
            try testing.expect(result.is_success());
            if (result == .success) {
                try testing.expectEqual(expected_gas, result.success.gas_used);
                try testing.expectEqual(@as(usize, 32), result.success.output_size);
            }
        }
        
        // Test ECRECOVER with random data (most will fail, but should handle gracefully)
        if (input_size >= 128) {
            const result = evm.precompiles.ecrecover.execute(input_data[0..128], &output_buffer, 3100);
            
            // ECRECOVER should always return a result, either success with 0 or 32 bytes output
            try testing.expect(result.is_success() or result == .success);
            if (result == .success) {
                try testing.expectEqual(@as(u64, 3000), result.success.gas_used);
                try testing.expect(result.success.output_size == 0 or result.success.output_size == 32);
            }
        }
    }
}

// Input validation stress testing
test "fuzz_precompiles_input_validation" {
    const allocator = testing.allocator;
    
    const validation_tests = [_]struct {
        input_sizes: []const usize,
        precompile_name: []const u8,
        description: []const u8,
    }{
        .{
            .input_sizes = &[_]usize{ 0, 1, 31, 32, 33, 63, 64, 65, 127, 128, 129, 255, 256, 257, 1023, 1024, 1025 },
            .precompile_name = "IDENTITY",
            .description = "IDENTITY input size validation",
        },
        .{
            .input_sizes = &[_]usize{ 0, 1, 31, 32, 33, 63, 64, 65, 127, 128, 129, 255, 256, 257 },
            .precompile_name = "SHA256",
            .description = "SHA256 input size validation",
        },
        .{
            .input_sizes = &[_]usize{ 0, 1, 31, 32, 33, 63, 64, 65, 127, 128, 129, 255, 256 },
            .precompile_name = "RIPEMD160",
            .description = "RIPEMD160 input size validation",
        },
        .{
            .input_sizes = &[_]usize{ 0, 1, 31, 32, 63, 64, 95, 96, 127, 128, 129, 160, 200 },
            .precompile_name = "ECRECOVER",
            .description = "ECRECOVER input size validation",
        },
    };
    
    for (validation_tests) |test_case| {
        for (test_case.input_sizes) |input_size| {
            const input_data = try allocator.alloc(u8, input_size);
            defer allocator.free(input_data);
            
            // Fill with pattern
            for (input_data, 0..) |*byte, i| {
                byte.* = @intCast(i % 256);
            }
            
            var output_buffer: [1024]u8 = undefined;
            const high_gas = 10000; // Always provide enough gas
            
            if (std.mem.eql(u8, test_case.precompile_name, "IDENTITY")) {
                const result = evm.precompiles.identity.execute(input_data, &output_buffer, high_gas);
                try testing.expect(result.is_success());
                if (result == .success) {
                    try testing.expectEqual(input_size, result.success.output_size);
                }
            } else if (std.mem.eql(u8, test_case.precompile_name, "SHA256")) {
                const result = evm.precompiles.sha256.execute(input_data, &output_buffer, high_gas);
                try testing.expect(result.is_success());
                if (result == .success) {
                    try testing.expectEqual(@as(usize, 32), result.success.output_size);
                }
            } else if (std.mem.eql(u8, test_case.precompile_name, "RIPEMD160")) {
                const result = evm.precompiles.ripemd160.execute(input_data, &output_buffer, high_gas);
                try testing.expect(result.is_success());
                if (result == .success) {
                    try testing.expectEqual(@as(usize, 32), result.success.output_size);
                }
            } else if (std.mem.eql(u8, test_case.precompile_name, "ECRECOVER")) {
                const result = evm.precompiles.ecrecover.execute(input_data, &output_buffer, high_gas);
                // ECRECOVER handles all input sizes gracefully
                try testing.expect(result.is_success() or result == .success);
                if (result == .success) {
                    try testing.expect(result.success.output_size == 0 or result.success.output_size == 32);
                }
            }
        }
    }
}

// Deterministic output testing
test "fuzz_precompiles_deterministic_output" {
    const allocator = testing.allocator;
    
    const deterministic_tests = [_]struct {
        input_data: []const u8,
        precompile_name: []const u8,
        description: []const u8,
    }{
        .{ .input_data = "", .precompile_name = "IDENTITY", .description = "Empty IDENTITY" },
        .{ .input_data = "Hello, World!", .precompile_name = "IDENTITY", .description = "String IDENTITY" },
        .{ .input_data = "", .precompile_name = "SHA256", .description = "Empty SHA256" },
        .{ .input_data = "Hello, World!", .precompile_name = "SHA256", .description = "String SHA256" },
        .{ .input_data = "a", .precompile_name = "SHA256", .description = "Single char SHA256" },
        .{ .input_data = "", .precompile_name = "RIPEMD160", .description = "Empty RIPEMD160" },
        .{ .input_data = "Hello, World!", .precompile_name = "RIPEMD160", .description = "String RIPEMD160" },
    };
    
    for (deterministic_tests) |test_case| {
        var output1: [1024]u8 = undefined;
        var output2: [1024]u8 = undefined;
        const high_gas = 10000;
        
        // Call precompile twice with same input
        if (std.mem.eql(u8, test_case.precompile_name, "IDENTITY")) {
            const result1 = evm.precompiles.identity.execute(test_case.input_data, &output1, high_gas);
            const result2 = evm.precompiles.identity.execute(test_case.input_data, &output2, high_gas);
            
            try testing.expect(result1.is_success() and result2.is_success());
            if (result1 == .success and result2 == .success) {
                try testing.expectEqual(result1.success.output_size, result2.success.output_size);
                try testing.expectEqual(result1.success.gas_used, result2.success.gas_used);
                try testing.expectEqualSlices(u8, 
                    output1[0..result1.success.output_size], 
                    output2[0..result2.success.output_size]);
            }
        } else if (std.mem.eql(u8, test_case.precompile_name, "SHA256")) {
            const result1 = evm.precompiles.sha256.execute(test_case.input_data, &output1, high_gas);
            const result2 = evm.precompiles.sha256.execute(test_case.input_data, &output2, high_gas);
            
            try testing.expect(result1.is_success() and result2.is_success());
            if (result1 == .success and result2 == .success) {
                try testing.expectEqual(result1.success.output_size, result2.success.output_size);
                try testing.expectEqual(result1.success.gas_used, result2.success.gas_used);
                try testing.expectEqualSlices(u8, 
                    output1[0..result1.success.output_size], 
                    output2[0..result2.success.output_size]);
            }
        } else if (std.mem.eql(u8, test_case.precompile_name, "RIPEMD160")) {
            const result1 = evm.precompiles.ripemd160.execute(test_case.input_data, &output1, high_gas);
            const result2 = evm.precompiles.ripemd160.execute(test_case.input_data, &output2, high_gas);
            
            try testing.expect(result1.is_success() and result2.is_success());
            if (result1 == .success and result2 == .success) {
                try testing.expectEqual(result1.success.output_size, result2.success.output_size);
                try testing.expectEqual(result1.success.gas_used, result2.success.gas_used);
                try testing.expectEqualSlices(u8, 
                    output1[0..result1.success.output_size], 
                    output2[0..result2.success.output_size]);
            }
        }
    }
}