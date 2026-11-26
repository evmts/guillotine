/// Integration tests for EVM precompiles with known test vectors
/// These tests verify that precompiles produce correct outputs

const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("voltaire");

const precompiles = evm.precompiles;
const crypto = @import("crypto");

// EIP-4844 point evaluation success output: FIELD_ELEMENTS_PER_BLOB (4096) and
// BLS_MODULUS, each as a 32-byte big-endian word.
const point_evaluation_success_output = @as([30]u8, @splat(0)) ++ [_]u8{ 0x10, 0x00 } ++ [_]u8{
    0x73, 0xed, 0xa7, 0x53, 0x29, 0x9d, 0x7d, 0x48, 0x33, 0x39, 0xd8, 0x08, 0x09, 0xa1, 0xd8, 0x05,
    0x53, 0xbd, 0xa4, 0x02, 0xff, 0xfe, 0x5b, 0xfe, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01,
};

test "Point Evaluation precompile - valid proof roundtrip" {
    const allocator = std.testing.allocator;
    const kzg_setup = evm.kzg_setup;
    // Mainnet trusted setup embedded from c-kzg-4844 (src/trusted_setup.txt).
    try kzg_setup.init();
    defer kzg_setup.deinit(allocator);

    // Build a simple blob (all zero)
    var blob: crypto.c_kzg.Blob = undefined;
    @memset(&blob, 0);

    // Compute commitment
    const commitment = try crypto.c_kzg.blobToKZGCommitment(&blob);

    // Choose an evaluation point z and compute proof + y
    var z: crypto.c_kzg.Bytes32 = @as([32]u8, @splat(0));
    z[31] = 0x02; // small non-zero
    const proof_y = try crypto.c_kzg.computeKZGProof(&blob, &z);
    const proof = proof_y.proof;
    const y = proof_y.y;

    // Build versioned hash from commitment
    const commit48: primitives.Blob.BlobCommitment = commitment;
    const versioned_hash = primitives.Blob.commitmentToVersionedHash(commit48);

    // Assemble precompile input: vh(32) | z(32) | y(32) | commitment(48) | proof(48)
    var input: [192]u8 = undefined;
    @memcpy(input[0..32], versioned_hash.bytes[0..]);
    @memcpy(input[32..64], &z);
    @memcpy(input[64..96], &y);
    @memcpy(input[96..144], &commitment);
    @memcpy(input[144..192], &proof);

    const gas = precompiles.point_evaluation.GAS + 1000;
    const result = try precompiles.point_evaluation.execute(allocator, &input, gas);
    defer result.deinit(allocator);
    // EIP-4844: success returns FIELD_ELEMENTS_PER_BLOB ++ BLS_MODULUS (64 bytes)
    try std.testing.expectEqualSlices(u8, &point_evaluation_success_output, result.output);
    try std.testing.expectEqual(precompiles.point_evaluation.GAS, result.gas_used);
}

test "Point Evaluation precompile - invalid proof fails" {
    const allocator = std.testing.allocator;
    const kzg_setup = evm.kzg_setup;
    // Mainnet trusted setup embedded from c-kzg-4844 (src/trusted_setup.txt).
    try kzg_setup.init();
    defer kzg_setup.deinit(allocator);

    var blob: crypto.c_kzg.Blob = undefined;
    @memset(&blob, 1);
    const commitment = try crypto.c_kzg.blobToKZGCommitment(&blob);

    var z: crypto.c_kzg.Bytes32 = @as([32]u8, @splat(0));
    z[31] = 0x03;
    const proof_y = try crypto.c_kzg.computeKZGProof(&blob, &z);
    const proof = proof_y.proof;
    var y = proof_y.y;

    // Corrupt y to force verification failure
    y[31] ^= 0x01;

    const commit48: primitives.Blob.BlobCommitment = commitment;
    const versioned_hash = primitives.Blob.commitmentToVersionedHash(commit48);

    var input: [192]u8 = undefined;
    @memcpy(input[0..32], versioned_hash.bytes[0..]);
    @memcpy(input[32..64], &z);
    @memcpy(input[64..96], &y);
    @memcpy(input[96..144], &commitment);
    @memcpy(input[144..192], &proof);

    const gas = precompiles.point_evaluation.GAS + 1000;
    try std.testing.expectError(error.InvalidInput, precompiles.point_evaluation.execute(allocator, &input, gas));
}

test "Point Evaluation precompile - mismatched versioned hash fails" {
    const allocator = std.testing.allocator;
    const kzg_setup = evm.kzg_setup;
    // Mainnet trusted setup embedded from c-kzg-4844 (src/trusted_setup.txt).
    try kzg_setup.init();
    defer kzg_setup.deinit(allocator);

    var blob: crypto.c_kzg.Blob = undefined;
    @memset(&blob, 2);
    const commitment = try crypto.c_kzg.blobToKZGCommitment(&blob);

    var z: crypto.c_kzg.Bytes32 = @as([32]u8, @splat(0));
    z[31] = 0x04;
    const proof_y = try crypto.c_kzg.computeKZGProof(&blob, &z);
    const proof = proof_y.proof;
    const y = proof_y.y;

    // Build versioned hash and then corrupt the version byte
    const commit48: primitives.Blob.BlobCommitment = commitment;
    var versioned_hash = primitives.Blob.commitmentToVersionedHash(commit48);
    versioned_hash.bytes[0] = 0x02; // invalid version

    var input: [192]u8 = undefined;
    @memcpy(input[0..32], versioned_hash.bytes[0..]);
    @memcpy(input[32..64], &z);
    @memcpy(input[64..96], &y);
    @memcpy(input[96..144], &commitment);
    @memcpy(input[144..192], &proof);

    const gas = precompiles.point_evaluation.GAS + 1000;
    try std.testing.expectError(error.InvalidInput, precompiles.point_evaluation.execute(allocator, &input, gas));
}

test "Point Evaluation precompile - insufficient gas" {
    const allocator = std.testing.allocator;
    const kzg_setup = evm.kzg_setup;
    // Mainnet trusted setup embedded from c-kzg-4844 (src/trusted_setup.txt).
    try kzg_setup.init();
    defer kzg_setup.deinit(allocator);

    var blob: crypto.c_kzg.Blob = undefined;
    @memset(&blob, 3);
    const commitment = try crypto.c_kzg.blobToKZGCommitment(&blob);
    const z: crypto.c_kzg.Bytes32 = @as([32]u8, @splat(0));
    const proof_y = try crypto.c_kzg.computeKZGProof(&blob, &z);

    var input: [192]u8 = undefined;
    const versioned_hash = primitives.Blob.commitmentToVersionedHash(commitment);
    @memcpy(input[0..32], versioned_hash.bytes[0..]);
    @memcpy(input[32..64], &z);
    @memcpy(input[64..96], &proof_y.y);
    @memcpy(input[96..144], &commitment);
    @memcpy(input[144..192], &proof_y.proof);

    const gas = precompiles.point_evaluation.GAS - 1; // insufficient
    // Out of gas is an exceptional halt: the EVM consumes all forwarded gas.
    try std.testing.expectError(error.OutOfGas, precompiles.point_evaluation.execute(allocator, &input, gas));
}

test "Point Evaluation precompile - invalid input length fails" {
    const allocator = std.testing.allocator;
    const bad: [191]u8 = @as([191]u8, @splat(0)); // should be 192
    try std.testing.expectError(error.InvalidInput, precompiles.point_evaluation.execute(allocator, &bad, precompiles.point_evaluation.GAS + 100));
}

test "SHA256 precompile with test vectors" {
    const allocator = testing.allocator;
    
    const TestVector = struct {
        input: []const u8,
        expected: [32]u8,
    };
    
    const test_vectors = [_]TestVector{
        .{
            .input = "",
            .expected = [_]u8{
                0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14, 0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
                0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c, 0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
            },
        },
        .{
            .input = "abc",
            .expected = [_]u8{
                0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
                0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
            },
        },
        .{
            .input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
            .expected = [_]u8{
                0x24, 0x8d, 0x6a, 0x61, 0xd2, 0x06, 0x38, 0xb8, 0xe5, 0xc0, 0x26, 0x93, 0x0c, 0x3e, 0x60, 0x39,
                0xa3, 0x3c, 0xe4, 0x59, 0x64, 0xff, 0x21, 0x67, 0xf6, 0xec, 0xed, 0xd4, 0x19, 0xdb, 0x06, 0xc1,
            },
        },
    };
    
    for (test_vectors) |tv| {
        const result = try precompiles.sha256.execute(allocator, tv.input, 1_000_000);
        defer result.deinit(allocator);
        
        try testing.expectEqualSlices(u8, &tv.expected, result.output);
    }
}

test "Identity precompile copies data correctly" {
    const allocator = testing.allocator;
    
    const test_cases = [_][]const u8{
        "",
        "a",
        "Hello, World!",
        &@as([32]u8, @splat(0)),
        &@as([64]u8, @splat(0xFF)),
        "The quick brown fox jumps over the lazy dog",
    };
    
    for (test_cases) |input| {
        const result = try precompiles.identity.execute(allocator, input, 1_000_000);
        defer result.deinit(allocator);
        
        try testing.expectEqualSlices(u8, input, result.output);
        
        // Verify gas calculation
        const expected_gas = precompiles.identity.BASE_GAS + 
            ((input.len + 31) / 32) * precompiles.identity.PER_WORD_GAS;
        try testing.expectEqual(expected_gas, result.gas_used);
    }
}

test "RIPEMD160 precompile with test vectors" {
    const allocator = testing.allocator;
    
    const TestVector = struct {
        input: []const u8,
        expected: [20]u8, // RIPEMD160 produces 20 bytes
    };
    
    // Test vectors from https://homes.esat.kuleuven.be/~bosselae/ripemd160.html
    const test_vectors = [_]TestVector{
        .{
            .input = "",
            .expected = [_]u8{
                0x9c, 0x11, 0x85, 0xa5, 0xc5, 0xe9, 0xfc, 0x54, 0x61, 0x28,
                0x08, 0x97, 0x7e, 0xe8, 0xf5, 0x48, 0xb2, 0x25, 0x8d, 0x31,
            },
        },
        .{
            .input = "abc",
            .expected = [_]u8{
                0x8e, 0xb2, 0x08, 0xf7, 0xe0, 0x5d, 0x98, 0x7a, 0x9b, 0x04,
                0x4a, 0x8e, 0x98, 0xc6, 0xb0, 0x87, 0xf1, 0x5a, 0x0b, 0xfc,
            },
        },
        .{
            .input = "message digest",
            .expected = [_]u8{
                0x5d, 0x06, 0x89, 0xef, 0x49, 0xd2, 0xfa, 0xe5, 0x72, 0xb8,
                0x81, 0xb1, 0x23, 0xa8, 0x5f, 0xfa, 0x21, 0x59, 0x5f, 0x36,
            },
        },
    };
    
    for (test_vectors) |tv| {
        const result = try precompiles.ripemd160.execute(allocator, tv.input, 1_000_000);
        defer result.deinit(allocator);
        
        try testing.expectEqual(@as(usize, 32), result.output.len);
        
        // First 12 bytes should be zero padding
        try testing.expectEqualSlices(u8, &@as([12]u8, @splat(0)), result.output[0..12]);
        
        // Last 20 bytes should be the hash
        try testing.expectEqualSlices(u8, &tv.expected, result.output[12..32]);
    }
}

test "modexp precompile with test vectors" {
    const allocator = testing.allocator;
    
    const TestCase = struct {
        base: []const u8,
        exp: []const u8,
        mod: []const u8,
        expected: []const u8,
    };
    
    // Test cases from Ethereum tests
    const test_cases = [_]TestCase{
        // 3^4 mod 5 = 81 mod 5 = 1
        .{
            .base = &[_]u8{3},
            .exp = &[_]u8{4},
            .mod = &[_]u8{5},
            .expected = &[_]u8{1},
        },
        // 0^0 mod 1 = 1 mod 1 = 0 (EIP-198: output is (B**E) % M)
        .{
            .base = &[_]u8{0},
            .exp = &[_]u8{0},
            .mod = &[_]u8{1},
            .expected = &[_]u8{0},
        },
        // 2^8 mod 17 = 256 mod 17 = 1
        .{
            .base = &[_]u8{2},
            .exp = &[_]u8{8},
            .mod = &[_]u8{17},
            .expected = &[_]u8{1},
        },
    };
    
    for (test_cases) |tc| {
        // Build input: base_len(32) + exp_len(32) + mod_len(32) + base + exp + mod
        var input = std.ArrayList(u8).empty;
        defer input.deinit(allocator);
        
        // Write lengths as 32-byte big-endian
        var base_len_bytes = @as([32]u8, @splat(0));
        base_len_bytes[31] = @intCast(tc.base.len);
        try input.appendSlice(allocator, &base_len_bytes);
        
        var exp_len_bytes = @as([32]u8, @splat(0));
        exp_len_bytes[31] = @intCast(tc.exp.len);
        try input.appendSlice(allocator, &exp_len_bytes);
        
        var mod_len_bytes = @as([32]u8, @splat(0));
        mod_len_bytes[31] = @intCast(tc.mod.len);
        try input.appendSlice(allocator, &mod_len_bytes);
        
        // Append the actual values
        try input.appendSlice(allocator, tc.base);
        try input.appendSlice(allocator, tc.exp);
        try input.appendSlice(allocator, tc.mod);
        
        const result = try precompiles.modexp.execute(allocator, input.items, 1_000_000, .OSAKA);
        defer result.deinit(allocator);
        
        try testing.expectEqualSlices(u8, tc.expected, result.output);
    }
}

test "Blake2F compression with test vector" {
    const allocator = testing.allocator;
    
    // Test vector from EIP-152
    var input: [213]u8 = undefined;
    
    // rounds = 12 (big-endian)
    input[0] = 0x00;
    input[1] = 0x00;
    input[2] = 0x00;
    input[3] = 0x0c;
    
    // h (state vector, 8 x u64 little-endian)
    const h_values = [_]u64{
        0x6a09e667f2bdc948, 0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    };
    
    var offset: usize = 4;
    for (h_values) |h| {
        std.mem.writeInt(u64, input[offset..][0..8], h, .little);
        offset += 8;
    }
    
    // m (message block, 16 x u64 little-endian) - all zeros for this test
    @memset(input[68..196], 0);
    
    // t (offset counters, 2 x u64 little-endian) - all zeros
    @memset(input[196..212], 0);
    
    // f (final block flag)
    input[212] = 0; // not final block
    
    const result = try precompiles.blake2f.execute(allocator, &input, 1_000_000);
    defer result.deinit(allocator);
    
    try testing.expectEqual(@as(usize, 64), result.output.len);
    
    // The output should be different from input (compression happened)
    try testing.expect(!std.mem.eql(u8, input[4..68], result.output));
}

test "ecAdd precompile with identity element" {
    const allocator = testing.allocator;
    
    // Test: point + identity = point
    // Using the generator point G
    var input = @as([128]u8, @splat(0));
    
    // First point: generator G (x=1, y=2 in simplified form)
    input[31] = 1;  // x = 1
    input[63] = 2;  // y = 2
    
    // Second point: identity (all zeros)
    // Already zeroed
    
    const result = try precompiles.bn254_add.execute(allocator, &input, 1_000_000);
    defer result.deinit(allocator);
    
    try testing.expectEqual(@as(usize, 64), result.output.len);
    
    // Result should be the first point (G)
    try testing.expectEqual(@as(u8, 1), result.output[31]);
    try testing.expectEqual(@as(u8, 2), result.output[63]);
}

test "ecMul precompile with scalar 0" {
    const allocator = testing.allocator;
    
    // Test: point * 0 = identity
    var input = @as([96]u8, @splat(0));
    
    // Point: generator G
    input[31] = 1;  // x = 1
    input[63] = 2;  // y = 2
    
    // Scalar: 0 (already zeroed)
    
    const result = try precompiles.bn254_mul.execute(allocator, &input, 1_000_000);
    defer result.deinit(allocator);
    
    try testing.expectEqual(@as(usize, 64), result.output.len);
    
    // Result should be identity (all zeros)
    for (result.output) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "ecPairing with empty input" {
    const allocator = testing.allocator;
    
    // Empty input should return 1 (true)
    const result = try precompiles.bn254_pairing.execute(allocator, "", 1_000_000);
    defer result.deinit(allocator);
    
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    // Check that result is 1
    for (result.output[0..31]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
    try testing.expectEqual(@as(u8, 1), result.output[31]);
}

test "Gas consumption for all precompiles" {
    const allocator = testing.allocator;
    
    // Test that gas is properly consumed for each precompile
    
    // SHA256
    {
        const input = "test input";
        const result = try precompiles.sha256.execute(allocator, input, 1_000_000);
        defer result.deinit(allocator);
        
        const expected_gas = precompiles.sha256.BASE_GAS + 
            precompiles.sha256.PER_WORD_GAS;
        try testing.expectEqual(expected_gas, result.gas_used);
    }
    
    // Identity
    {
        const input = [_]u8{1, 2, 3, 4, 5};
        const result = try precompiles.identity.execute(allocator, &input, 1_000_000);
        defer result.deinit(allocator);
        
        const expected_gas = precompiles.identity.BASE_GAS + 
            precompiles.identity.PER_WORD_GAS;
        try testing.expectEqual(expected_gas, result.gas_used);
    }
    
    // ecRecover
    {
        const input = @as([128]u8, @splat(0));
        const result = try precompiles.ecrecover.execute(allocator, &input, 10_000);
        defer result.deinit(allocator);
        
        try testing.expectEqual(precompiles.ecrecover.GAS, result.gas_used);
    }
}
