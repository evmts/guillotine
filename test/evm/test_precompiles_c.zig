// ============================================================================
// PRECOMPILES C API TESTS - Comprehensive test suite for precompiles_c.zig
// ============================================================================

const std = @import("std");
const testing = std.testing;

// Import the C API
const precompiles_c = @import("../../src/evm/precompiles_c.zig");

test "Precompiles C API: Address validation" {
    // Test valid precompile addresses (0x01-0x0A)
    try testing.expectEqual(@as(c_int, 1), precompiles_c.evm_precompiles_is_valid_address(0x01));
    try testing.expectEqual(@as(c_int, 1), precompiles_c.evm_precompiles_is_valid_address(0x02));
    try testing.expectEqual(@as(c_int, 1), precompiles_c.evm_precompiles_is_valid_address(0x05));
    try testing.expectEqual(@as(c_int, 1), precompiles_c.evm_precompiles_is_valid_address(0x09));
    try testing.expectEqual(@as(c_int, 1), precompiles_c.evm_precompiles_is_valid_address(0x0A));
    
    // Test invalid addresses
    try testing.expectEqual(@as(c_int, 0), precompiles_c.evm_precompiles_is_valid_address(0x00));
    try testing.expectEqual(@as(c_int, 0), precompiles_c.evm_precompiles_is_valid_address(0x0B));
    try testing.expectEqual(@as(c_int, 0), precompiles_c.evm_precompiles_is_valid_address(0xFF));
}

test "Precompiles C API: Address enumeration" {
    var addresses: [20]u8 = undefined;
    var count: u32 = 0;
    
    const result = precompiles_c.evm_precompiles_get_all_addresses(&addresses, addresses.len, &count);
    try testing.expectEqual(@as(c_int, 1), result);
    try testing.expectEqual(@as(u32, 10), count); // Should have exactly 10 precompiles
    
    // Verify addresses are in order 0x01-0x0A
    for (0..count) |i| {
        try testing.expectEqual(@as(u8, @intCast(i + 1)), addresses[i]);
    }
}

test "Precompiles C API: ECRecover (0x01)" {
    // Test data for ECRecover: hash + v + r + s
    const input_data = [_]u8{
        // 32-byte hash (keccak256 of "hello world")
        0x47, 0x17, 0x32, 0x85, 0xa8, 0xd7, 0x34, 0x1e,
        0x5e, 0x97, 0x2f, 0xc6, 0x77, 0x28, 0x63, 0x84,
        0xf8, 0x02, 0xf8, 0xef, 0x42, 0xa5, 0xec, 0x5f,
        0x03, 0xbb, 0xfa, 0x25, 0x4c, 0xb0, 0x1f, 0xad,
        // v (recovery parameter) - 32 bytes, right-aligned
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1c,
        // r component (32 bytes)
        0x68, 0xa8, 0xbd, 0x63, 0xf7, 0x68, 0x22, 0xa5,
        0xcc, 0x81, 0x71, 0xd4, 0xc9, 0x3a, 0x27, 0xaa,
        0x2b, 0x7e, 0xd9, 0x93, 0xf0, 0x98, 0xa2, 0xd7,
        0x04, 0xe2, 0x81, 0xf5, 0xfb, 0xde, 0x7e, 0xd0,
        // s component (32 bytes)
        0x2a, 0xac, 0x9f, 0xac, 0x2c, 0xfb, 0x06, 0x12,
        0x35, 0xbb, 0x3f, 0x9f, 0x3f, 0xbb, 0xa0, 0x61,
        0x97, 0x93, 0x0b, 0x69, 0x2c, 0x94, 0x35, 0x23,
        0xd0, 0xc8, 0x93, 0xc3, 0x1b, 0xea, 0x8e, 0x2b,
    };
    
    var output: [32]u8 = undefined;
    var output_len: u32 = 0;
    var gas_cost: u64 = 0;
    
    const result = precompiles_c.evm_precompiles_ecrecover(
        &input_data, input_data.len, 
        &output, output.len, &output_len, &gas_cost
    );
    
    try testing.expectEqual(precompiles_c.EVM_PRECOMPILES_SUCCESS, result);
    try testing.expectEqual(@as(u32, 32), output_len); // Should return 32-byte address
    try testing.expect(gas_cost > 0); // Should consume gas
}

test "Precompiles C API: SHA256 (0x02)" {
    const test_input = "hello world";
    
    var output: [32]u8 = undefined;
    var output_len: u32 = 0;
    var gas_cost: u64 = 0;
    
    const result = precompiles_c.evm_precompiles_sha256(
        test_input.ptr, test_input.len,
        &output, output.len, &output_len, &gas_cost
    );
    
    try testing.expectEqual(precompiles_c.EVM_PRECOMPILES_SUCCESS, result);
    try testing.expectEqual(@as(u32, 32), output_len);
    try testing.expect(gas_cost > 0);
    
    // Verify known SHA256 hash of "hello world"
    const expected = [_]u8{
        0xb9, 0x4d, 0x27, 0xb9, 0x93, 0x4d, 0x3e, 0x08,
        0xa5, 0x2e, 0x52, 0xd7, 0xda, 0x7d, 0xab, 0xfa,
        0xc4, 0x84, 0xef, 0xe3, 0x7a, 0x53, 0x80, 0xee,
        0x90, 0x88, 0xf7, 0xac, 0xe2, 0xef, 0xcd, 0xe9,
    };
    try testing.expectEqualSlices(u8, &expected, output[0..output_len]);
}

test "Precompiles C API: RIPEMD160 (0x03)" {
    const test_input = "hello world";
    
    var output: [32]u8 = undefined; // RIPEMD160 returns 20 bytes, padded to 32
    var output_len: u32 = 0;
    var gas_cost: u64 = 0;
    
    const result = precompiles_c.evm_precompiles_ripemd160(
        test_input.ptr, test_input.len,
        &output, output.len, &output_len, &gas_cost
    );
    
    try testing.expectEqual(precompiles_c.EVM_PRECOMPILES_SUCCESS, result);
    try testing.expectEqual(@as(u32, 32), output_len); // Padded to 32 bytes
    try testing.expect(gas_cost > 0);
    
    // First 12 bytes should be zero (padding)
    for (0..12) |i| {
        try testing.expectEqual(@as(u8, 0), output[i]);
    }
}

test "Precompiles C API: Identity (0x04)" {
    const test_input = "test data for identity function";
    
    var output: [100]u8 = undefined;
    var output_len: u32 = 0;
    var gas_cost: u64 = 0;
    
    const result = precompiles_c.evm_precompiles_identity(
        test_input.ptr, test_input.len,
        &output, output.len, &output_len, &gas_cost
    );
    
    try testing.expectEqual(precompiles_c.EVM_PRECOMPILES_SUCCESS, result);
    try testing.expectEqual(@as(u32, test_input.len), output_len);
    try testing.expect(gas_cost > 0);
    
    // Output should be identical to input
    try testing.expectEqualSlices(u8, test_input, output[0..output_len]);
}

test "Precompiles C API: ModExp (0x05)" {
    // Test data: base=3, exponent=2, modulus=5
    // Expected result: 3^2 mod 5 = 9 mod 5 = 4
    const input_data = [_]u8{
        // Length of base (32 bytes, big-endian 1)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        // Length of exponent (32 bytes, big-endian 1)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        // Length of modulus (32 bytes, big-endian 1)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        // Base (1 byte): 3
        0x03,
        // Exponent (1 byte): 2
        0x02,
        // Modulus (1 byte): 5
        0x05,
    };
    
    var output: [32]u8 = undefined;
    var output_len: u32 = 0;
    var gas_cost: u64 = 0;
    
    const result = precompiles_c.evm_precompiles_modexp(
        &input_data, input_data.len,
        &output, output.len, &output_len, &gas_cost
    );
    
    try testing.expectEqual(precompiles_c.EVM_PRECOMPILES_SUCCESS, result);
    try testing.expectEqual(@as(u32, 1), output_len); // Should return 1 byte result
    try testing.expectEqual(@as(u8, 4), output[0]); // 3^2 mod 5 = 4
    try testing.expect(gas_cost > 0);
}

test "Precompiles C API: ECAdd (0x06)" {
    // Test point addition on elliptic curve (simplified test with zero points)
    const input_data = [_]u8{0} ** 128; // Two zero points (64 bytes each)
    
    var output: [64]u8 = undefined;
    var output_len: u32 = 0;
    var gas_cost: u64 = 0;
    
    const result = precompiles_c.evm_precompiles_ecadd(
        &input_data, input_data.len,
        &output, output.len, &output_len, &gas_cost
    );
    
    try testing.expectEqual(precompiles_c.EVM_PRECOMPILES_SUCCESS, result);
    try testing.expectEqual(@as(u32, 64), output_len);
    try testing.expect(gas_cost > 0);
}

test "Precompiles C API: ECMul (0x07)" {
    // Test point multiplication (simplified test with zero point)
    const input_data = [_]u8{0} ** 96; // Zero point (64 bytes) + scalar (32 bytes)
    
    var output: [64]u8 = undefined;
    var output_len: u32 = 0;
    var gas_cost: u64 = 0;
    
    const result = precompiles_c.evm_precompiles_ecmul(
        &input_data, input_data.len,
        &output, output.len, &output_len, &gas_cost
    );
    
    try testing.expectEqual(precompiles_c.EVM_PRECOMPILES_SUCCESS, result);
    try testing.expectEqual(@as(u32, 64), output_len);
    try testing.expect(gas_cost > 0);
}

test "Precompiles C API: ECPairing (0x08)" {
    // Test pairing check (empty input = successful pairing)
    const input_data = [_]u8{};
    
    var output: [32]u8 = undefined;
    var output_len: u32 = 0;
    var gas_cost: u64 = 0;
    
    const result = precompiles_c.evm_precompiles_ecpairing(
        &input_data, input_data.len,
        &output, output.len, &output_len, &gas_cost
    );
    
    try testing.expectEqual(precompiles_c.EVM_PRECOMPILES_SUCCESS, result);
    try testing.expectEqual(@as(u32, 32), output_len);
    try testing.expect(gas_cost > 0);
    
    // Empty input should return 1 (successful pairing)
    try testing.expectEqual(@as(u8, 1), output[31]); // Right-aligned in 32 bytes
}

test "Precompiles C API: Blake2f (0x09)" {
    // Test Blake2f compression function
    // Input: rounds (4 bytes) + h (64 bytes) + m (128 bytes) + t (16 bytes) + f (1 byte)
    var input_data: [213]u8 = undefined;
    
    // Set rounds to 1
    input_data[0] = 0x00;
    input_data[1] = 0x00;
    input_data[2] = 0x00;
    input_data[3] = 0x01;
    
    // Fill rest with test data
    for (4..213) |i| {
        input_data[i] = @intCast(i % 256);
    }
    
    var output: [64]u8 = undefined;
    var output_len: u32 = 0;
    var gas_cost: u64 = 0;
    
    const result = precompiles_c.evm_precompiles_blake2f(
        &input_data, input_data.len,
        &output, output.len, &output_len, &gas_cost
    );
    
    try testing.expectEqual(precompiles_c.EVM_PRECOMPILES_SUCCESS, result);
    try testing.expectEqual(@as(u32, 64), output_len);
    try testing.expect(gas_cost > 0);
}

test "Precompiles C API: Point Evaluation (0x0A)" {
    // Test KZG point evaluation (simplified test)
    const input_data = [_]u8{0} ** 192; // 192 bytes of zero data
    
    var output: [64]u8 = undefined;
    var output_len: u32 = 0;
    var gas_cost: u64 = 0;
    
    const result = precompiles_c.evm_precompiles_point_evaluation(
        &input_data, input_data.len,
        &output, output.len, &output_len, &gas_cost
    );
    
    try testing.expectEqual(precompiles_c.EVM_PRECOMPILES_SUCCESS, result);
    try testing.expectEqual(@as(u32, 64), output_len);
    try testing.expect(gas_cost > 0);
}

test "Precompiles C API: Gas cost calculations" {
    // Test gas costs for different precompiles
    try testing.expect(precompiles_c.evm_precompiles_gas_cost_ecrecover(128) > 0);
    try testing.expect(precompiles_c.evm_precompiles_gas_cost_sha256(100) > 0);
    try testing.expect(precompiles_c.evm_precompiles_gas_cost_ripemd160(100) > 0);
    try testing.expect(precompiles_c.evm_precompiles_gas_cost_identity(100) > 0);
    try testing.expect(precompiles_c.evm_precompiles_gas_cost_ecadd(128) > 0);
    try testing.expect(precompiles_c.evm_precompiles_gas_cost_ecmul(96) > 0);
    try testing.expect(precompiles_c.evm_precompiles_gas_cost_ecpairing(192) > 0);
    try testing.expect(precompiles_c.evm_precompiles_gas_cost_blake2f(213) > 0);
    try testing.expect(precompiles_c.evm_precompiles_gas_cost_point_evaluation(192) > 0);
    
    // Gas costs should scale with input size for some precompiles
    const small_cost = precompiles_c.evm_precompiles_gas_cost_sha256(32);
    const large_cost = precompiles_c.evm_precompiles_gas_cost_sha256(1000);
    try testing.expect(large_cost > small_cost);
}

test "Precompiles C API: Error handling" {
    var output: [32]u8 = undefined;
    var output_len: u32 = 0;
    var gas_cost: u64 = 0;
    
    // Test null pointer handling
    const null_result = precompiles_c.evm_precompiles_sha256(
        null, 0, &output, output.len, &output_len, &gas_cost
    );
    try testing.expectEqual(precompiles_c.EVM_PRECOMPILES_ERROR_NULL_POINTER, null_result);
    
    // Test insufficient output buffer
    var tiny_output: [1]u8 = undefined;
    var tiny_len: u32 = 0;
    const tiny_result = precompiles_c.evm_precompiles_sha256(
        "test".ptr, 4, &tiny_output, tiny_output.len, &tiny_len, &gas_cost
    );
    try testing.expectEqual(precompiles_c.EVM_PRECOMPILES_ERROR_BUFFER_TOO_SMALL, tiny_result);
    
    // Test invalid input for ECRecover (wrong size)
    const short_input = [_]u8{0x01, 0x02, 0x03};
    const ecrecover_result = precompiles_c.evm_precompiles_ecrecover(
        &short_input, short_input.len, &output, output.len, &output_len, &gas_cost
    );
    try testing.expectEqual(precompiles_c.EVM_PRECOMPILES_ERROR_INVALID_INPUT, ecrecover_result);
    
    // Test error string conversion
    const success_str = precompiles_c.evm_precompiles_error_string(precompiles_c.EVM_PRECOMPILES_SUCCESS);
    try testing.expect(std.mem.eql(u8, std.mem.span(success_str), "Success"));
    
    const null_str = precompiles_c.evm_precompiles_error_string(precompiles_c.EVM_PRECOMPILES_ERROR_NULL_POINTER);
    try testing.expect(std.mem.eql(u8, std.mem.span(null_str), "Null pointer"));
    
    const unknown_str = precompiles_c.evm_precompiles_error_string(-999);
    try testing.expect(std.mem.eql(u8, std.mem.span(unknown_str), "Unknown error"));
}

test "Precompiles C API: Precompile information" {
    var info: precompiles_c.CPrecompileInfo = undefined;
    
    // Test ECRecover info
    const ecrecover_result = precompiles_c.evm_precompiles_get_info(0x01, &info);
    try testing.expectEqual(@as(c_int, 1), ecrecover_result);
    try testing.expectEqual(@as(u8, 0x01), info.address);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(info.name), "ECRecover") != null);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(info.description), "signature recovery") != null);
    
    // Test SHA256 info
    const sha256_result = precompiles_c.evm_precompiles_get_info(0x02, &info);
    try testing.expectEqual(@as(c_int, 1), sha256_result);
    try testing.expectEqual(@as(u8, 0x02), info.address);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(info.name), "SHA256") != null);
    
    // Test invalid address
    const invalid_result = precompiles_c.evm_precompiles_get_info(0xFF, &info);
    try testing.expectEqual(@as(c_int, 0), invalid_result);
}

test "Precompiles C API: Built-in tests" {
    // Test the built-in C API tests
    try testing.expectEqual(@as(c_int, 0), precompiles_c.evm_precompiles_test_basic());
    try testing.expectEqual(@as(c_int, 0), precompiles_c.evm_precompiles_test_gas_costs());
    try testing.expectEqual(@as(c_int, 0), precompiles_c.evm_precompiles_test_all_precompiles());
}

test "Precompiles C API: Edge cases" {
    var output: [100]u8 = undefined;
    var output_len: u32 = 0;
    var gas_cost: u64 = 0;
    
    // Test empty input for identity
    const identity_result = precompiles_c.evm_precompiles_identity(
        null, 0, &output, output.len, &output_len, &gas_cost
    );
    try testing.expectEqual(precompiles_c.EVM_PRECOMPILES_SUCCESS, identity_result);
    try testing.expectEqual(@as(u32, 0), output_len);
    try testing.expect(gas_cost > 0);
    
    // Test large input for SHA256
    const large_input = [_]u8{0xAB} ** 1000;
    const sha256_result = precompiles_c.evm_precompiles_sha256(
        &large_input, large_input.len, &output, output.len, &output_len, &gas_cost
    );
    try testing.expectEqual(precompiles_c.EVM_PRECOMPILES_SUCCESS, sha256_result);
    try testing.expectEqual(@as(u32, 32), output_len);
    try testing.expect(gas_cost > 3000); // Should be expensive for large input
}

test "Precompiles C API: Precompile execution dispatch" {
    var output: [64]u8 = undefined;
    var output_len: u32 = 0;
    var gas_cost: u64 = 0;
    
    // Test dispatch to SHA256
    const test_input = "test";
    const dispatch_result = precompiles_c.evm_precompiles_execute(
        0x02, // SHA256 address
        test_input.ptr, test_input.len,
        &output, output.len, &output_len, &gas_cost
    );
    
    try testing.expectEqual(precompiles_c.EVM_PRECOMPILES_SUCCESS, dispatch_result);
    try testing.expectEqual(@as(u32, 32), output_len);
    try testing.expect(gas_cost > 0);
    
    // Test dispatch to invalid address
    const invalid_dispatch = precompiles_c.evm_precompiles_execute(
        0xFF, // Invalid address
        test_input.ptr, test_input.len,
        &output, output.len, &output_len, &gas_cost
    );
    
    try testing.expectEqual(precompiles_c.EVM_PRECOMPILES_ERROR_INVALID_ADDRESS, invalid_dispatch);
}
