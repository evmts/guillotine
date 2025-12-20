const std = @import("std");
const crypto = @import("crypto");
const c_kzg = crypto.c_kzg;
const kzg_setup = crypto.kzg_setup;
const PrecompileError = @import("common.zig").PrecompileError;
const PrecompileResult = @import("common.zig").PrecompileResult;

/// Gas cost for point evaluation
pub const GAS: u64 = 50000;

/// 0x0A: POINT_EVALUATION - KZG point evaluation (EIP-4844)
pub fn execute(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) PrecompileError!PrecompileResult {
    if (gas_limit < GAS) {
        return error.OutOfGas;
    }

    // Input format (192 bytes):
    // - versioned_hash (32 bytes)
    // - z (32 bytes) - evaluation point
    // - y (32 bytes) - claimed evaluation
    // - commitment (48 bytes) - KZG commitment
    // - proof (48 bytes) - KZG proof
    if (input.len != 192) {
        return error.InvalidInput;
    }

    const versioned_hash = input[0..32];
    const z = input[32..64];
    const y = input[64..96];
    const commitment = input[96..144];
    const proof = input[144..192];

    // Verify versioned hash matches commitment
    var computed_hash: [32]u8 = undefined;
    try crypto.keccak_asm.keccak256(commitment, &computed_hash);
    computed_hash[0] = 0x01; // Version byte for EIP-4844

    // Check if versioned hash matches
    for (versioned_hash, computed_hash) |a, b| {
        if (a != b) {
            return error.InvalidInput;
        }
    }

    // Verify KZG proof
    const commitment_ptr: *const c_kzg.KZGCommitment = @ptrCast(@alignCast(commitment));
    const z_ptr: *const c_kzg.Bytes32 = @ptrCast(@alignCast(z));
    const y_ptr: *const c_kzg.Bytes32 = @ptrCast(@alignCast(y));
    const proof_ptr: *const c_kzg.KZGProof = @ptrCast(@alignCast(proof));

    const valid = kzg_setup.verifyKZGProofThreadSafe(
        commitment_ptr,
        z_ptr,
        y_ptr,
        proof_ptr,
    ) catch {
        return error.InvalidInput;
    };

    const output = try allocator.alloc(u8, 64);
    @memset(output, 0);

    if (valid) {
        // Return the precompile return value: FIELD_ELEMENTS_PER_BLOB, BLS_MODULUS
        // FIELD_ELEMENTS_PER_BLOB = 4096
        output[30] = 0x10;
        output[31] = 0x00;

        // BLS_MODULUS (last 32 bytes) = 0x73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001
        const bls_modulus = [_]u8{
            0x73, 0xed, 0xa7, 0x53, 0x29, 0x9d, 0x7d, 0x48,
            0x33, 0x39, 0xd8, 0x08, 0x09, 0xa1, 0xd8, 0x05,
            0x53, 0xbd, 0xa4, 0x02, 0xff, 0xfe, 0x5b, 0xfe,
            0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01,
        };
        @memcpy(output[32..64], &bls_modulus);
    }

    return PrecompileResult{
        .output = output,
        .gas_used = GAS,
    };
}

// Tests

test "point_evaluation - gas cost constant" {
    const testing = std.testing;
    try testing.expectEqual(50000, GAS);
}

test "point_evaluation - out of gas" {
    const testing = std.testing;

    // Initialize KZG trusted setup
    try kzg_setup.init();
    defer kzg_setup.deinit(testing.allocator);

    // Create valid 192-byte input
    const input = [_]u8{0} ** 192;

    // Try to execute with insufficient gas
    const result = execute(testing.allocator, &input, GAS - 1);
    try testing.expectError(error.OutOfGas, result);
}

test "point_evaluation - invalid input length too short" {
    const testing = std.testing;

    // Initialize KZG trusted setup
    try kzg_setup.init();
    defer kzg_setup.deinit(testing.allocator);

    // Input too short (191 bytes instead of 192)
    const input = [_]u8{0} ** 191;

    const result = execute(testing.allocator, &input, GAS);
    try testing.expectError(error.InvalidInput, result);
}

test "point_evaluation - invalid input length too long" {
    const testing = std.testing;

    // Initialize KZG trusted setup
    try kzg_setup.init();
    defer kzg_setup.deinit(testing.allocator);

    // Input too long (193 bytes instead of 192)
    const input = [_]u8{0} ** 193;

    const result = execute(testing.allocator, &input, GAS);
    try testing.expectError(error.InvalidInput, result);
}

test "point_evaluation - invalid input length zero" {
    const testing = std.testing;

    // Initialize KZG trusted setup
    try kzg_setup.init();
    defer kzg_setup.deinit(testing.allocator);

    const input = [_]u8{};

    const result = execute(testing.allocator, &input, GAS);
    try testing.expectError(error.InvalidInput, result);
}

test "point_evaluation - versioned hash mismatch" {
    const testing = std.testing;

    // Initialize KZG trusted setup
    try kzg_setup.init();
    defer kzg_setup.deinit(testing.allocator);

    // Create input with valid commitment but wrong versioned hash
    var input = [_]u8{0} ** 192;

    // Set versioned hash to something that won't match
    input[0] = 0xFF;

    // Set commitment to point at infinity
    input[96] = 0xc0;

    const result = execute(testing.allocator, &input, GAS);
    try testing.expectError(error.InvalidInput, result);
}

test "point_evaluation - correct proof case 0 (point at infinity)" {
    const testing = std.testing;

    // Initialize KZG trusted setup
    try kzg_setup.init();
    defer kzg_setup.deinit(testing.allocator);

    // Test vector from EIP-4844: verify_kzg_proof_case_correct_proof_0_0
    // commitment: 0xc00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
    // z: 0x0000000000000000000000000000000000000000000000000000000000000000
    // y: 0x0000000000000000000000000000000000000000000000000000000000000000
    // proof: 0xc00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000

    var input = [_]u8{0} ** 192;

    // Commitment (48 bytes) - point at infinity
    input[96] = 0xc0;

    // Proof (48 bytes) - point at infinity
    input[144] = 0xc0;

    // Compute versioned hash
    var computed_hash: [32]u8 = undefined;
    try crypto.keccak_asm.keccak256(input[96..144], &computed_hash);
    computed_hash[0] = 0x01;

    // Set versioned hash
    @memcpy(input[0..32], &computed_hash);

    const result = try execute(testing.allocator, &input, GAS);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(GAS, result.gas_used);
    try testing.expectEqual(64, result.output.len);

    // Check FIELD_ELEMENTS_PER_BLOB (4096 = 0x1000)
    try testing.expectEqual(0x10, result.output[30]);
    try testing.expectEqual(0x00, result.output[31]);

    // Check BLS_MODULUS
    const expected_bls_modulus = [_]u8{
        0x73, 0xed, 0xa7, 0x53, 0x29, 0x9d, 0x7d, 0x48,
        0x33, 0x39, 0xd8, 0x08, 0x09, 0xa1, 0xd8, 0x05,
        0x53, 0xbd, 0xa4, 0x02, 0xff, 0xfe, 0x5b, 0xfe,
        0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01,
    };
    try testing.expectEqualSlices(u8, &expected_bls_modulus, result.output[32..64]);
}

test "point_evaluation - correct proof case 1" {
    const testing = std.testing;

    // Initialize KZG trusted setup
    try kzg_setup.init();
    defer kzg_setup.deinit(testing.allocator);

    // Test vector from EIP-4844: verify_kzg_proof_case_correct_proof_1_0
    const commitment_hex = "a572cbea904d67468808c8eb50a9450c9721db309128012543902d0ac358a62ae28f75bb8f1c7c42c39a8c5529bf0f4e";
    const z_hex = "0000000000000000000000000000000000000000000000000000000000000000";
    const y_hex = "0000000000000000000000000000000000000000000000000000000000000002";
    const proof_hex = "c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

    var input = [_]u8{0} ** 192;

    // Parse commitment
    var i: usize = 0;
    while (i < 48) : (i += 1) {
        const high = try std.fmt.charToDigit(commitment_hex[i * 2], 16);
        const low = try std.fmt.charToDigit(commitment_hex[i * 2 + 1], 16);
        input[96 + i] = (high << 4) | low;
    }

    // Parse z
    i = 0;
    while (i < 32) : (i += 1) {
        const high = try std.fmt.charToDigit(z_hex[i * 2], 16);
        const low = try std.fmt.charToDigit(z_hex[i * 2 + 1], 16);
        input[32 + i] = (high << 4) | low;
    }

    // Parse y
    i = 0;
    while (i < 32) : (i += 1) {
        const high = try std.fmt.charToDigit(y_hex[i * 2], 16);
        const low = try std.fmt.charToDigit(y_hex[i * 2 + 1], 16);
        input[64 + i] = (high << 4) | low;
    }

    // Parse proof
    i = 0;
    while (i < 48) : (i += 1) {
        const high = try std.fmt.charToDigit(proof_hex[i * 2], 16);
        const low = try std.fmt.charToDigit(proof_hex[i * 2 + 1], 16);
        input[144 + i] = (high << 4) | low;
    }

    // Compute versioned hash
    var computed_hash: [32]u8 = undefined;
    try crypto.keccak_asm.keccak256(input[96..144], &computed_hash);
    computed_hash[0] = 0x01;

    // Set versioned hash
    @memcpy(input[0..32], &computed_hash);

    const result = try execute(testing.allocator, &input, GAS);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(GAS, result.gas_used);
    try testing.expectEqual(64, result.output.len);

    // Verify non-zero output (valid proof)
    try testing.expectEqual(0x10, result.output[30]);
    try testing.expectEqual(0x00, result.output[31]);
}

test "point_evaluation - incorrect proof returns zero output" {
    const testing = std.testing;

    // Initialize KZG trusted setup
    try kzg_setup.init();
    defer kzg_setup.deinit(testing.allocator);

    // Test vector from EIP-4844: verify_kzg_proof_case_incorrect_proof_0_0
    const commitment_hex = "c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
    const z_hex = "0000000000000000000000000000000000000000000000000000000000000000";
    const y_hex = "0000000000000000000000000000000000000000000000000000000000000000";
    const proof_hex = "97f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb";

    var input = [_]u8{0} ** 192;

    // Parse commitment
    var i: usize = 0;
    while (i < 48) : (i += 1) {
        const high = try std.fmt.charToDigit(commitment_hex[i * 2], 16);
        const low = try std.fmt.charToDigit(commitment_hex[i * 2 + 1], 16);
        input[96 + i] = (high << 4) | low;
    }

    // Parse z
    i = 0;
    while (i < 32) : (i += 1) {
        const high = try std.fmt.charToDigit(z_hex[i * 2], 16);
        const low = try std.fmt.charToDigit(z_hex[i * 2 + 1], 16);
        input[32 + i] = (high << 4) | low;
    }

    // Parse y
    i = 0;
    while (i < 32) : (i += 1) {
        const high = try std.fmt.charToDigit(y_hex[i * 2], 16);
        const low = try std.fmt.charToDigit(y_hex[i * 2 + 1], 16);
        input[64 + i] = (high << 4) | low;
    }

    // Parse proof
    i = 0;
    while (i < 48) : (i += 1) {
        const high = try std.fmt.charToDigit(proof_hex[i * 2], 16);
        const low = try std.fmt.charToDigit(proof_hex[i * 2 + 1], 16);
        input[144 + i] = (high << 4) | low;
    }

    // Compute versioned hash
    var computed_hash: [32]u8 = undefined;
    try crypto.keccak_asm.keccak256(input[96..144], &computed_hash);
    computed_hash[0] = 0x01;

    // Set versioned hash
    @memcpy(input[0..32], &computed_hash);

    const result = try execute(testing.allocator, &input, GAS);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(GAS, result.gas_used);
    try testing.expectEqual(64, result.output.len);

    // Verify all zeros output (invalid proof)
    for (result.output) |byte| {
        try testing.expectEqual(0, byte);
    }
}

test "point_evaluation - invalid commitment malformed" {
    const testing = std.testing;

    // Initialize KZG trusted setup
    try kzg_setup.init();
    defer kzg_setup.deinit(testing.allocator);

    // Test vector from EIP-4844: verify_kzg_proof_case_invalid_commitment_0
    // This has an invalid commitment (wrong length in the test vector)
    // We'll create a malformed commitment by using invalid curve point
    const commitment_hex = "97f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb";
    const z_hex = "0000000000000000000000000000000000000000000000000000000000000001";
    const y_hex = "1824b159acc5056f998c4fefecbc4ff55884b7fa0003480200000001fffffffe";
    const proof_hex = "b0c829a8d2d3405304fecbea193e6c67f7c3912a6adc7c3737ad3f8a3b750425c1531a7426f03033a3994bc82a10609f";

    var input = [_]u8{0} ** 192;

    // Parse commitment
    var i: usize = 0;
    while (i < 48) : (i += 1) {
        const high = try std.fmt.charToDigit(commitment_hex[i * 2], 16);
        const low = try std.fmt.charToDigit(commitment_hex[i * 2 + 1], 16);
        input[96 + i] = (high << 4) | low;
    }

    // Parse z
    i = 0;
    while (i < 32) : (i += 1) {
        const high = try std.fmt.charToDigit(z_hex[i * 2], 16);
        const low = try std.fmt.charToDigit(z_hex[i * 2 + 1], 16);
        input[32 + i] = (high << 4) | low;
    }

    // Parse y
    i = 0;
    while (i < 32) : (i += 1) {
        const high = try std.fmt.charToDigit(y_hex[i * 2], 16);
        const low = try std.fmt.charToDigit(y_hex[i * 2 + 1], 16);
        input[64 + i] = (high << 4) | low;
    }

    // Parse proof
    i = 0;
    while (i < 48) : (i += 1) {
        const high = try std.fmt.charToDigit(proof_hex[i * 2], 16);
        const low = try std.fmt.charToDigit(proof_hex[i * 2 + 1], 16);
        input[144 + i] = (high << 4) | low;
    }

    // Compute versioned hash
    var computed_hash: [32]u8 = undefined;
    try crypto.keccak_asm.keccak256(input[96..144], &computed_hash);
    computed_hash[0] = 0x01;

    // Set versioned hash
    @memcpy(input[0..32], &computed_hash);

    const result = execute(testing.allocator, &input, GAS);
    try testing.expectError(error.InvalidInput, result);
}

test "point_evaluation - all zero input" {
    const testing = std.testing;

    // Initialize KZG trusted setup
    try kzg_setup.init();
    defer kzg_setup.deinit(testing.allocator);

    var input = [_]u8{0} ** 192;

    const result = execute(testing.allocator, &input, GAS);
    try testing.expectError(error.InvalidInput, result);
}

test "point_evaluation - all ones input" {
    const testing = std.testing;

    // Initialize KZG trusted setup
    try kzg_setup.init();
    defer kzg_setup.deinit(testing.allocator);

    var input = [_]u8{0xFF} ** 192;

    const result = execute(testing.allocator, &input, GAS);
    try testing.expectError(error.InvalidInput, result);
}

test "point_evaluation - versioned hash wrong version byte" {
    const testing = std.testing;

    // Initialize KZG trusted setup
    try kzg_setup.init();
    defer kzg_setup.deinit(testing.allocator);

    var input = [_]u8{0} ** 192;

    // Set commitment to point at infinity
    input[96] = 0xc0;

    // Set proof to point at infinity
    input[144] = 0xc0;

    // Compute versioned hash
    var computed_hash: [32]u8 = undefined;
    try crypto.keccak_asm.keccak256(input[96..144], &computed_hash);
    computed_hash[0] = 0x01;

    // Set versioned hash but with wrong version byte
    @memcpy(input[0..32], &computed_hash);
    input[0] = 0x02; // Wrong version (should be 0x01)

    const result = execute(testing.allocator, &input, GAS);
    try testing.expectError(error.InvalidInput, result);
}

test "point_evaluation - output format validation" {
    const testing = std.testing;

    // Initialize KZG trusted setup
    try kzg_setup.init();
    defer kzg_setup.deinit(testing.allocator);

    // Use valid test vector
    var input = [_]u8{0} ** 192;

    // Commitment (48 bytes) - point at infinity
    input[96] = 0xc0;

    // Proof (48 bytes) - point at infinity
    input[144] = 0xc0;

    // Compute versioned hash
    var computed_hash: [32]u8 = undefined;
    try crypto.keccak_asm.keccak256(input[96..144], &computed_hash);
    computed_hash[0] = 0x01;

    // Set versioned hash
    @memcpy(input[0..32], &computed_hash);

    const result = try execute(testing.allocator, &input, GAS);
    defer result.deinit(testing.allocator);

    // Verify output is exactly 64 bytes
    try testing.expectEqual(64, result.output.len);

    // Verify first 30 bytes are zero
    for (result.output[0..30]) |byte| {
        try testing.expectEqual(0, byte);
    }

    // Verify FIELD_ELEMENTS_PER_BLOB is 0x1000 (4096)
    try testing.expectEqual(0x10, result.output[30]);
    try testing.expectEqual(0x00, result.output[31]);

    // Verify BLS_MODULUS is correct
    const expected_bls_modulus = [_]u8{
        0x73, 0xed, 0xa7, 0x53, 0x29, 0x9d, 0x7d, 0x48,
        0x33, 0x39, 0xd8, 0x08, 0x09, 0xa1, 0xd8, 0x05,
        0x53, 0xbd, 0xa4, 0x02, 0xff, 0xfe, 0x5b, 0xfe,
        0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01,
    };
    try testing.expectEqualSlices(u8, &expected_bls_modulus, result.output[32..64]);
}

test "point_evaluation - gas usage always constant" {
    const testing = std.testing;

    // Initialize KZG trusted setup
    try kzg_setup.init();
    defer kzg_setup.deinit(testing.allocator);

    // Test with valid proof
    var input1 = [_]u8{0} ** 192;
    input1[96] = 0xc0;
    input1[144] = 0xc0;
    var hash1: [32]u8 = undefined;
    try crypto.keccak_asm.keccak256(input1[96..144], &hash1);
    hash1[0] = 0x01;
    @memcpy(input1[0..32], &hash1);

    const result1 = try execute(testing.allocator, &input1, GAS);
    defer result1.deinit(testing.allocator);

    try testing.expectEqual(GAS, result1.gas_used);

    // Test with invalid proof
    const commitment_hex = "c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
    const proof_hex = "97f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb";

    var input2 = [_]u8{0} ** 192;

    var i: usize = 0;
    while (i < 48) : (i += 1) {
        const high = try std.fmt.charToDigit(commitment_hex[i * 2], 16);
        const low = try std.fmt.charToDigit(commitment_hex[i * 2 + 1], 16);
        input2[96 + i] = (high << 4) | low;
    }

    i = 0;
    while (i < 48) : (i += 1) {
        const high = try std.fmt.charToDigit(proof_hex[i * 2], 16);
        const low = try std.fmt.charToDigit(proof_hex[i * 2 + 1], 16);
        input2[144 + i] = (high << 4) | low;
    }

    var hash2: [32]u8 = undefined;
    try crypto.keccak_asm.keccak256(input2[96..144], &hash2);
    hash2[0] = 0x01;
    @memcpy(input2[0..32], &hash2);

    const result2 = try execute(testing.allocator, &input2, GAS);
    defer result2.deinit(testing.allocator);

    // Gas usage should be the same for both valid and invalid proofs
    try testing.expectEqual(GAS, result2.gas_used);
    try testing.expectEqual(result1.gas_used, result2.gas_used);
}

test "point_evaluation - exact gas limit allowed" {
    const testing = std.testing;

    // Initialize KZG trusted setup
    try kzg_setup.init();
    defer kzg_setup.deinit(testing.allocator);

    var input = [_]u8{0} ** 192;
    input[96] = 0xc0;
    input[144] = 0xc0;
    var hash: [32]u8 = undefined;
    try crypto.keccak_asm.keccak256(input[96..144], &hash);
    hash[0] = 0x01;
    @memcpy(input[0..32], &hash);

    // Execute with exact gas limit (should succeed)
    const result = try execute(testing.allocator, &input, GAS);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(GAS, result.gas_used);
}

test "point_evaluation - high gas limit accepted" {
    const testing = std.testing;

    // Initialize KZG trusted setup
    try kzg_setup.init();
    defer kzg_setup.deinit(testing.allocator);

    var input = [_]u8{0} ** 192;
    input[96] = 0xc0;
    input[144] = 0xc0;
    var hash: [32]u8 = undefined;
    try crypto.keccak_asm.keccak256(input[96..144], &hash);
    hash[0] = 0x01;
    @memcpy(input[0..32], &hash);

    // Execute with high gas limit
    const result = try execute(testing.allocator, &input, 1000000);
    defer result.deinit(testing.allocator);

    // Should only use the required gas, not all available
    try testing.expectEqual(GAS, result.gas_used);
}

test "point_evaluation - memory allocation success" {
    const testing = std.testing;

    // Initialize KZG trusted setup
    try kzg_setup.init();
    defer kzg_setup.deinit(testing.allocator);

    var input = [_]u8{0} ** 192;
    input[96] = 0xc0;
    input[144] = 0xc0;
    var hash: [32]u8 = undefined;
    try crypto.keccak_asm.keccak256(input[96..144], &hash);
    hash[0] = 0x01;
    @memcpy(input[0..32], &hash);

    const result = try execute(testing.allocator, &input, GAS);
    defer result.deinit(testing.allocator);

    // Verify output was allocated
    try testing.expect(result.output.len > 0);

    // Verify output is writable (was properly allocated)
    result.output[0] = result.output[0];
}

test "point_evaluation - input components boundaries" {
    const testing = std.testing;

    // Initialize KZG trusted setup
    try kzg_setup.init();
    defer kzg_setup.deinit(testing.allocator);

    var input = [_]u8{0} ** 192;

    // Set each component to distinct values to verify boundaries
    @memset(input[0..32], 0x01); // versioned_hash
    @memset(input[32..64], 0x02); // z
    @memset(input[64..96], 0x03); // y
    @memset(input[96..144], 0x04); // commitment
    @memset(input[144..192], 0x05); // proof

    // This should fail due to invalid hash, but shouldn't crash
    const result = execute(testing.allocator, &input, GAS);
    try testing.expectError(error.InvalidInput, result);
}
