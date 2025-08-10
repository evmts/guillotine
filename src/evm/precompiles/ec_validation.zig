/// Shared elliptic curve validation logic for EC precompiles
///
/// This module contains common validation functions used by EC precompiles:
/// - ECADD (0x06): Point addition
/// - ECMUL (0x07): Scalar multiplication
/// - ECPAIRING (0x08): Pairing check
///
/// By centralizing validation logic, we reduce code duplication and ensure
/// consistent error handling across all EC precompiles.
const std = @import("std");
const bn254 = @import("bn254.zig");
const PrecompileOutput = @import("precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("precompile_result.zig").PrecompileError;

/// Validates gas cost requirement for precompile execution
///
/// This is the standard pattern used by all precompiles to check if
/// sufficient gas is available before execution.
///
/// @param gas_cost Required gas for the operation
/// @param gas_limit Maximum gas available
/// @return PrecompileOutput failure if insufficient gas, null if valid
pub fn validate_gas_requirement(gas_cost: u64, gas_limit: u64) ?PrecompileOutput {
    if (gas_cost > gas_limit) {
        @branchHint(.cold);
        return PrecompileOutput.failure_result(PrecompileError.OutOfGas);
    }
    return null;
}

/// Validates output buffer size for precompile execution
///
/// Ensures the output buffer is large enough to hold the expected result.
///
/// @param output Output buffer to validate
/// @param required_size Minimum required size
/// @return PrecompileOutput failure if buffer too small, null if valid
pub fn validate_output_buffer_size(output: []u8, required_size: usize) ?PrecompileOutput {
    if (output.len < required_size) {
        @branchHint(.cold);
        return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
    }
    return null;
}

/// Pads input data to specified size with zero bytes
///
/// This is the standard input padding used by ECADD and ECMUL precompiles.
/// Shorter inputs are zero-padded, longer inputs are truncated.
///
/// @param input Original input data
/// @param comptime padded_size Target size for padding
/// @return Array of padded_size bytes with input data (zero-padded/truncated)
pub fn pad_input(input: []const u8, comptime padded_size: usize) [padded_size]u8 {
    var padded_input: [padded_size]u8 = [_]u8{0} ** padded_size;
    const copy_len = @min(input.len, padded_size);
    @memcpy(padded_input[0..copy_len], input[0..copy_len]);
    return padded_input;
}

/// Parses and validates a G1 point from byte data
///
/// This is the standard point parsing pattern used by ECADD and ECMUL.
/// On invalid points, it handles the error by returning point at infinity
/// and setting the output buffer appropriately.
///
/// @param point_bytes 64-byte buffer containing point coordinates
/// @param output Output buffer to clear on failure
/// @param gas_cost Gas cost to include in success result
/// @return Either a valid G1Point or PrecompileOutput for early return
pub fn parse_and_validate_point(
    point_bytes: []const u8,
    output: []u8,
    gas_cost: u64,
) union(enum) {
    point: bn254.G1Point,
    early_return: PrecompileOutput,
} {
    const point = bn254.G1Point.from_bytes(point_bytes) catch {
        @branchHint(.cold);
        // Invalid points result in point at infinity (0, 0)
        @memset(output[0..64], 0);
        return .{ .early_return = PrecompileOutput.success_result(gas_cost, 64) };
    };
    return .{ .point = point };
}

/// Validates input size must be multiple of specified chunk size
///
/// This validation is used by ECPAIRING to ensure input length
/// is a valid multiple of 192 bytes (one G1+G2 pair).
///
/// @param input_size Size of input data
/// @param chunk_size Required chunk size for validation
/// @return PrecompileOutput failure if invalid size, null if valid
pub fn validate_input_size_multiple(input_size: usize, chunk_size: usize) ?PrecompileOutput {
    if (input_size % chunk_size != 0) {
        @branchHint(.cold);
        return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
    }
    return null;
}

/// Formats G1 point result to output buffer
///
/// This is the standard result formatting used by ECADD and ECMUL.
/// Converts the point to 64 bytes and returns success result.
///
/// @param result_point Point to format
/// @param output Output buffer (must be >= 64 bytes)
/// @param gas_cost Gas cost for the operation
/// @return PrecompileOutput success result
pub fn format_g1_point_result(
    result_point: bn254.G1Point,
    output: []u8,
    gas_cost: u64,
) PrecompileOutput {
    result_point.to_bytes(output[0..64]);
    return PrecompileOutput.success_result(gas_cost, 64);
}

/// Sets output buffer to point at infinity (all zeros)
///
/// Used when operations result in invalid input or point at infinity.
///
/// @param output Output buffer to clear (first 64 bytes)
/// @param gas_cost Gas cost for the operation
/// @return PrecompileOutput success result with cleared output
pub fn return_point_at_infinity(output: []u8, gas_cost: u64) PrecompileOutput {
    @memset(output[0..64], 0);
    return PrecompileOutput.success_result(gas_cost, 64);
}

// Tests
const testing = std.testing;

test "gas requirement validation" {
    // Test sufficient gas
    const result1 = validate_gas_requirement(100, 200);
    try testing.expect(result1 == null);

    // Test insufficient gas
    const result2 = validate_gas_requirement(200, 100);
    try testing.expect(result2 != null);
    try testing.expect(result2.?.is_failure());
    try testing.expectEqual(PrecompileError.OutOfGas, result2.?.get_error().?);
}

test "output buffer size validation" {
    var buffer = [_]u8{0} ** 64;

    // Test sufficient buffer size
    const result1 = validate_output_buffer_size(&buffer, 32);
    try testing.expect(result1 == null);

    // Test insufficient buffer size
    const result2 = validate_output_buffer_size(&buffer, 128);
    try testing.expect(result2 != null);
    try testing.expect(result2.?.is_failure());
    try testing.expectEqual(PrecompileError.ExecutionFailed, result2.?.get_error().?);
}

test "input padding" {
    // Test padding short input
    const short_input = [_]u8{ 1, 2, 3 };
    const padded = pad_input(&short_input, 8);
    try testing.expectEqual(@as(u8, 1), padded[0]);
    try testing.expectEqual(@as(u8, 2), padded[1]);
    try testing.expectEqual(@as(u8, 3), padded[2]);
    try testing.expectEqual(@as(u8, 0), padded[3]);
    try testing.expectEqual(@as(u8, 0), padded[7]);

    // Test truncating long input
    const long_input = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const truncated = pad_input(&long_input, 5);
    try testing.expectEqual(@as(u8, 1), truncated[0]);
    try testing.expectEqual(@as(u8, 5), truncated[4]);
}

test "input size multiple validation" {
    // Test valid multiple
    const result1 = validate_input_size_multiple(384, 192); // 384 = 2 * 192
    try testing.expect(result1 == null);

    // Test invalid multiple
    const result2 = validate_input_size_multiple(100, 192); // 100 is not multiple of 192
    try testing.expect(result2 != null);
    try testing.expect(result2.?.is_failure());
    try testing.expectEqual(PrecompileError.ExecutionFailed, result2.?.get_error().?);
}

test "point parsing and validation" {
    var output = [_]u8{0} ** 64;

    // Test parsing valid point (point at infinity)
    var point_data = [_]u8{0} ** 64;
    const result1 = parse_and_validate_point(&point_data, &output, 150);
    switch (result1) {
        .point => |p| {
            try testing.expect(p.is_zero());
            try testing.expect(p.is_valid());
        },
        .early_return => try testing.expect(false), // Should not early return for valid point
    }

    // Test parsing invalid point (1, 1) - not on curve
    point_data[31] = 1; // x = 1
    point_data[63] = 1; // y = 1 (invalid)
    const result2 = parse_and_validate_point(&point_data, &output, 150);
    switch (result2) {
        .point => try testing.expect(false), // Should not return valid point
        .early_return => |r| {
            try testing.expect(r.is_success());
            try testing.expectEqual(@as(u64, 150), r.get_gas_used());
            // Output should be cleared (point at infinity)
            for (output) |byte| {
                try testing.expectEqual(@as(u8, 0), byte);
            }
        },
    }
}

test "G1 point result formatting" {
    const point = bn254.G1Point{ .x = 1, .y = 2 };
    var output = [_]u8{0} ** 64;

    const result = format_g1_point_result(point, &output, 150);
    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 150), result.get_gas_used());
    try testing.expectEqual(@as(usize, 64), result.get_output_size());

    // Check point was correctly formatted
    try testing.expectEqual(@as(u8, 1), output[31]); // x = 1
    try testing.expectEqual(@as(u8, 2), output[63]); // y = 2
}

test "point at infinity result" {
    var output = [_]u8{1} ** 64; // Start with non-zero data

    const result = return_point_at_infinity(&output, 150);
    try testing.expect(result.is_success());
    try testing.expectEqual(@as(u64, 150), result.get_gas_used());
    try testing.expectEqual(@as(usize, 64), result.get_output_size());

    // All bytes should be cleared
    for (output) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}
