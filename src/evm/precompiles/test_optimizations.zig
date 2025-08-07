/// Comprehensive tests for precompile optimizations
const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const PrecompileOutput = @import("precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("precompile_result.zig").PrecompileError;
const ChainRules = @import("../frame.zig").ChainRules;

// Import both versions for comparison
const precompiles_original = @import("precompiles.zig");
const precompiles_optimized = @import("precompiles_optimized.zig");

test "optimized precompiles produce same results as original" {
    const test_cases = [_]struct {
        address: primitives.Address.Address,
        input: []const u8,
        expected_output_size: usize,
    }{
        // SHA256 test
        .{
            .address = primitives.Address.from_u256(2),
            .input = "hello world",
            .expected_output_size = 32,
        },
        // RIPEMD160 test
        .{
            .address = primitives.Address.from_u256(3),
            .input = "test data",
            .expected_output_size = 32,
        },
        // IDENTITY test
        .{
            .address = primitives.Address.from_u256(4),
            .input = "copy this data",
            .expected_output_size = 14,
        },
    };
    
    const chain_rules = ChainRules.for_hardfork(.ISTANBUL);
    
    for (test_cases) |tc| {
        var output_original: [256]u8 = undefined;
        var output_optimized: [256]u8 = undefined;
        
        // Execute with original implementation
        const result_original = precompiles_original.execute_precompile(
            tc.address,
            tc.input,
            &output_original,
            100000,
            chain_rules
        );
        
        // Execute with optimized implementation
        const result_optimized = precompiles_optimized.execute_precompile(
            tc.address,
            tc.input,
            &output_optimized,
            100000,
            chain_rules
        );
        
        // Both should succeed
        try testing.expect(result_original.is_success());
        try testing.expect(result_optimized.is_success());
        
        // Same gas usage
        try testing.expectEqual(
            result_original.get_gas_used(),
            result_optimized.get_gas_used()
        );
        
        // Same output size
        try testing.expectEqual(
            result_original.get_output_size(),
            result_optimized.get_output_size()
        );
        
        // Same output data
        try testing.expectEqualSlices(
            u8,
            output_original[0..result_original.get_output_size()],
            output_optimized[0..result_optimized.get_output_size()]
        );
    }
}

test "optimized dispatch has no union overhead" {
    // This test verifies that the optimized dispatcher uses direct function calls
    // The PrecompileFn type should be a function pointer, not a union
    const fn_type = precompiles_optimized.PrecompileFn;
    
    // Verify it's a function pointer type
    switch (@typeInfo(fn_type)) {
        .Pointer => |ptr| {
            try testing.expect(@typeInfo(ptr.child) == .Fn);
        },
        else => try testing.expect(false), // Should be a pointer to function
    }
}

test "sha256 optimized eliminates intermediate buffers" {
    const sha256 = @import("sha256_optimized.zig");
    const chain_rules = ChainRules.for_hardfork(.ISTANBUL);
    
    // Test that SHA256 writes directly to output
    var output: [32]u8 = undefined;
    const input = "test input for direct write";
    
    // Fill output with sentinel values
    @memset(&output, 0xAA);
    
    const result = sha256.execute(input, &output, 1000, chain_rules);
    try testing.expect(result.is_success());
    
    // Verify output was written directly (no 0xAA values remain)
    var found_sentinel = false;
    for (output) |byte| {
        if (byte == 0xAA) {
            found_sentinel = true;
            break;
        }
    }
    try testing.expect(!found_sentinel);
}

test "ripemd160 optimized eliminates intermediate buffers" {
    const ripemd160 = @import("ripemd160_optimized.zig");
    const chain_rules = ChainRules.for_hardfork(.ISTANBUL);
    
    // Test that RIPEMD160 writes directly to output
    var output: [32]u8 = undefined;
    const input = "test input for direct write";
    
    // Fill output with sentinel values
    @memset(&output, 0xBB);
    
    const result = ripemd160.execute(input, &output, 10000, chain_rules);
    try testing.expect(result.is_success());
    
    // First 12 bytes should be zeros (padding)
    for (output[0..12]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
    
    // Last 20 bytes should contain hash (no 0xBB values)
    var found_sentinel = false;
    for (output[12..32]) |byte| {
        if (byte == 0xBB) {
            found_sentinel = true;
            break;
        }
    }
    try testing.expect(!found_sentinel);
}

test "uniform interface allows chain rules passthrough" {
    const addresses = [_]primitives.Address.Address{
        primitives.Address.from_u256(1), // ECRECOVER
        primitives.Address.from_u256(2), // SHA256
        primitives.Address.from_u256(3), // RIPEMD160
        primitives.Address.from_u256(4), // IDENTITY
        primitives.Address.from_u256(5), // MODEXP
        primitives.Address.from_u256(6), // ECADD
        primitives.Address.from_u256(7), // ECMUL
        primitives.Address.from_u256(8), // ECPAIRING
        primitives.Address.from_u256(9), // BLAKE2F
    };
    
    const byzantium_rules = ChainRules.for_hardfork(.BYZANTIUM);
    const istanbul_rules = ChainRules.for_hardfork(.ISTANBUL);
    
    // Test that all precompiles accept chain rules without error
    for (addresses) |addr| {
        var output: [256]u8 = undefined;
        const input = &[_]u8{0} ** 32;
        
        // Skip if not available in Byzantium
        if (!precompiles_optimized.is_available(addr, byzantium_rules)) {
            continue;
        }
        
        // Both chain rules should work
        _ = precompiles_optimized.execute_precompile(addr, input, &output, 100000, byzantium_rules);
        _ = precompiles_optimized.execute_precompile(addr, input, &output, 100000, istanbul_rules);
    }
}

test "gas calculation matches between versions" {
    const test_sizes = [_]usize{ 0, 1, 31, 32, 33, 63, 64, 65, 127, 128, 256, 512, 1024 };
    
    for (test_sizes) |size| {
        // SHA256
        {
            const original = @import("sha256.zig");
            const optimized = @import("sha256_optimized.zig");
            
            const gas_original = original.calculate_gas(size);
            const gas_optimized = optimized.calculate_gas(size);
            try testing.expectEqual(gas_original, gas_optimized);
        }
        
        // RIPEMD160
        {
            const original = @import("ripemd160.zig");
            const optimized = @import("ripemd160_optimized.zig");
            
            const gas_original = original.calculate_gas(size);
            const gas_optimized = optimized.calculate_gas(size);
            try testing.expectEqual(gas_original, gas_optimized);
        }
    }
}