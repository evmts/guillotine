/// C-KZG bindings for EIP-4844 support
const std = @import("std");

// Import the official zig bindings
const ckzg = @import("c_kzg");

// Re-export types from the official bindings
pub const KZGSettings = ckzg.KZGSettings;
pub const Blob = ckzg.Blob;
pub const KZGCommitment = ckzg.KZGCommitment;
pub const KZGProof = ckzg.KZGProof;
pub const Bytes32 = ckzg.Bytes32;
pub const Bytes48 = ckzg.Bytes48;

// Re-export constants
pub const BYTES_PER_BLOB = ckzg.BYTES_PER_BLOB;
pub const BYTES_PER_COMMITMENT = ckzg.BYTES_PER_COMMITMENT;
pub const BYTES_PER_PROOF = ckzg.BYTES_PER_PROOF;
pub const BYTES_PER_FIELD_ELEMENT = ckzg.BYTES_PER_FIELD_ELEMENT;
pub const FIELD_ELEMENTS_PER_BLOB = ckzg.FIELD_ELEMENTS_PER_BLOB;

// Re-export error type
pub const KZGError = ckzg.KZGError;

/// Load trusted setup from file
pub fn loadTrustedSetupFile(trusted_setup_path: []const u8, precompute: u64) KZGError!void {
    const file = std.fs.cwd().openFile(trusted_setup_path, .{}) catch return KZGError.FileNotFound;
    defer file.close();

    const file_data = file.readToEndAlloc(std.heap.page_allocator, 1024 * 1024 * 10) catch return KZGError.MallocError;
    defer std.heap.page_allocator.free(file_data);

    try ckzg.loadTrustedSetupFromText(file_data, precompute);
}

/// Free the trusted setup
pub fn freeTrustedSetup() KZGError!void {
    try ckzg.freeTrustedSetup();
}

/// Blob to KZG commitment
pub fn blobToKzgCommitment(blob: *const Blob) KZGError!KZGCommitment {
    return try ckzg.blobToKZGCommitment(blob);
}

/// Compute KZG proof
pub fn computeKZGProof(blob: *const Blob, z: *const Bytes32) KZGError!struct { proof: KZGProof, y: Bytes32 } {
    return try ckzg.computeKZGProof(blob, z);
}

/// Re-export the verifyKZGProof function from ckzg
pub const verifyKZGProof = ckzg.verifyKZGProof;

// Test helper to generate a valid random blob
fn getRandomBlob(seed: u64) Blob {
    var blob: Blob = undefined;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    random.bytes(&blob);

    // Ensure each field element is valid by clearing the top byte
    for (0..FIELD_ELEMENTS_PER_BLOB) |i| {
        blob[i * BYTES_PER_FIELD_ELEMENT] = 0;
    }

    return blob;
}

test "c_kzg constants are defined correctly" {
    const testing = std.testing;

    try testing.expectEqual(131072, BYTES_PER_BLOB);
    try testing.expectEqual(48, BYTES_PER_COMMITMENT);
    try testing.expectEqual(48, BYTES_PER_PROOF);
    try testing.expectEqual(32, BYTES_PER_FIELD_ELEMENT);
    try testing.expectEqual(4096, FIELD_ELEMENTS_PER_BLOB);
}

test "c_kzg type sizes are correct" {
    const testing = std.testing;

    try testing.expectEqual(32, @sizeOf(Bytes32));
    try testing.expectEqual(48, @sizeOf(Bytes48));
    try testing.expectEqual(48, @sizeOf(KZGCommitment));
    try testing.expectEqual(48, @sizeOf(KZGProof));
    try testing.expectEqual(BYTES_PER_BLOB, @sizeOf(Blob));
}

test "c_kzg error handling - file not found" {
    const testing = std.testing;

    const result = loadTrustedSetupFile("nonexistent_file.txt", 0);
    try testing.expectError(KZGError.FileNotFound, result);
}

test "c_kzg error handling - operations without trusted setup" {
    const testing = std.testing;

    // Ensure trusted setup is not loaded
    _ = freeTrustedSetup() catch {};

    var blob = getRandomBlob(42);

    // All operations should fail with TrustedSetupNotLoaded
    const commitment_result = blobToKzgCommitment(&blob);
    try testing.expectError(KZGError.TrustedSetupNotLoaded, commitment_result);

    var z: Bytes32 = undefined;
    @memset(&z, 0);
    const proof_result = computeKZGProof(&blob, &z);
    try testing.expectError(KZGError.TrustedSetupNotLoaded, proof_result);
}

test "c_kzg blob to commitment" {
    const testing = std.testing;

    // Load trusted setup using embedded data
    try ckzg.loadTrustedSetupFromText(ckzg.embedded_trusted_setup, 0);
    defer freeTrustedSetup() catch unreachable;

    // Test with multiple different blobs
    for (0..5) |i| {
        var blob = getRandomBlob(@intCast(i));

        const commitment = try blobToKzgCommitment(&blob);

        // Commitment should be 48 bytes
        try testing.expectEqual(48, commitment.len);

        // Commitment should not be all zeros (extremely unlikely)
        var all_zeros = true;
        for (commitment) |byte| {
            if (byte != 0) {
                all_zeros = false;
                break;
            }
        }
        try testing.expect(!all_zeros);
    }
}

test "c_kzg blob to commitment - deterministic" {
    const testing = std.testing;

    try ckzg.loadTrustedSetupFromText(ckzg.embedded_trusted_setup, 0);
    defer freeTrustedSetup() catch unreachable;

    var blob = getRandomBlob(12345);

    // Generate commitment twice - should be identical
    const commitment1 = try blobToKzgCommitment(&blob);
    const commitment2 = try blobToKzgCommitment(&blob);

    try testing.expectEqualSlices(u8, &commitment1, &commitment2);
}

test "c_kzg compute proof" {
    const testing = std.testing;

    try ckzg.loadTrustedSetupFromText(ckzg.embedded_trusted_setup, 0);
    defer freeTrustedSetup() catch unreachable;

    var blob = getRandomBlob(999);

    // Test with multiple evaluation points
    for (0..3) |i| {
        var z: Bytes32 = undefined;
        @memset(&z, @intCast(i));

        const result = try computeKZGProof(&blob, &z);

        // Proof should be 48 bytes
        try testing.expectEqual(48, result.proof.len);

        // Y value should be 32 bytes
        try testing.expectEqual(32, result.y.len);
    }
}

test "c_kzg compute proof - deterministic" {
    const testing = std.testing;

    try ckzg.loadTrustedSetupFromText(ckzg.embedded_trusted_setup, 0);
    defer freeTrustedSetup() catch unreachable;

    var blob = getRandomBlob(7777);
    var z: Bytes32 = undefined;
    @memset(&z, 0x42);

    // Generate proof twice - should be identical
    const result1 = try computeKZGProof(&blob, &z);
    const result2 = try computeKZGProof(&blob, &z);

    try testing.expectEqualSlices(u8, &result1.proof, &result2.proof);
    try testing.expectEqualSlices(u8, &result1.y, &result2.y);
}

test "c_kzg verify proof - valid proof" {
    const testing = std.testing;

    try ckzg.loadTrustedSetupFromText(ckzg.embedded_trusted_setup, 0);
    defer freeTrustedSetup() catch unreachable;

    var blob = getRandomBlob(8888);

    // Generate commitment
    const commitment = try blobToKzgCommitment(&blob);

    // Generate proof at evaluation point
    var z: Bytes32 = undefined;
    @memset(&z, 0x33);
    const result = try computeKZGProof(&blob, &z);

    // Verify proof should succeed
    const is_valid = try verifyKZGProof(&commitment, &z, &result.y, &result.proof);
    try testing.expect(is_valid);
}

test "c_kzg verify proof - invalid proof" {
    const testing = std.testing;

    try ckzg.loadTrustedSetupFromText(ckzg.embedded_trusted_setup, 0);
    defer freeTrustedSetup() catch unreachable;

    var blob = getRandomBlob(9999);

    const commitment = try blobToKzgCommitment(&blob);

    var z: Bytes32 = undefined;
    @memset(&z, 0x44);
    const result = try computeKZGProof(&blob, &z);

    // Corrupt the proof by flipping a bit
    var corrupted_proof = result.proof;
    corrupted_proof[0] = corrupted_proof[0] ^ 1;

    // Verification should fail
    const is_valid = verifyKZGProof(&commitment, &z, &result.y, &corrupted_proof) catch false;
    try testing.expect(!is_valid);
}

test "c_kzg verify proof - wrong commitment" {
    const testing = std.testing;

    try ckzg.loadTrustedSetupFromText(ckzg.embedded_trusted_setup, 0);
    defer freeTrustedSetup() catch unreachable;

    var blob1 = getRandomBlob(1111);
    var blob2 = getRandomBlob(2222);

    const commitment1 = try blobToKzgCommitment(&blob1);
    _ = try blobToKzgCommitment(&blob2);

    var z: Bytes32 = undefined;
    @memset(&z, 0x55);
    const result = try computeKZGProof(&blob1, &z);

    // Generate a different commitment
    const wrong_commitment = try blobToKzgCommitment(&blob2);

    // Verify with wrong commitment should fail
    const is_valid = verifyKZGProof(&wrong_commitment, &z, &result.y, &result.proof) catch false;
    try testing.expect(!is_valid);

    // Verify with correct commitment should succeed
    const is_valid_correct = try verifyKZGProof(&commitment1, &z, &result.y, &result.proof);
    try testing.expect(is_valid_correct);
}

test "c_kzg verify proof - wrong y value" {
    const testing = std.testing;

    try ckzg.loadTrustedSetupFromText(ckzg.embedded_trusted_setup, 0);
    defer freeTrustedSetup() catch unreachable;

    var blob = getRandomBlob(3333);

    const commitment = try blobToKzgCommitment(&blob);

    var z: Bytes32 = undefined;
    @memset(&z, 0x66);
    const result = try computeKZGProof(&blob, &z);

    // Corrupt the y value
    var wrong_y = result.y;
    wrong_y[0] = wrong_y[0] ^ 1;

    // Verification should fail
    const is_valid = verifyKZGProof(&commitment, &z, &wrong_y, &result.proof) catch false;
    try testing.expect(!is_valid);
}

test "c_kzg integration - full workflow" {
    const testing = std.testing;

    try ckzg.loadTrustedSetupFromText(ckzg.embedded_trusted_setup, 0);
    defer freeTrustedSetup() catch unreachable;

    // Create a blob
    var blob = getRandomBlob(54321);

    // Step 1: Blob to commitment
    const commitment = try blobToKzgCommitment(&blob);

    // Step 2: Compute proof at multiple evaluation points
    const test_points = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77 };

    for (test_points) |point_byte| {
        var z: Bytes32 = undefined;
        @memset(&z, point_byte);

        // Step 3: Generate proof
        const proof_result = try computeKZGProof(&blob, &z);

        // Step 4: Verify proof
        const is_valid = try verifyKZGProof(&commitment, &z, &proof_result.y, &proof_result.proof);
        try testing.expect(is_valid);
    }
}

test "c_kzg edge case - all zero blob" {
    const testing = std.testing;

    try ckzg.loadTrustedSetupFromText(ckzg.embedded_trusted_setup, 0);
    defer freeTrustedSetup() catch unreachable;

    var blob: Blob = undefined;
    @memset(&blob, 0);

    // Should still work with all-zero blob
    const commitment = try blobToKzgCommitment(&blob);

    var z: Bytes32 = undefined;
    @memset(&z, 0x01);
    const result = try computeKZGProof(&blob, &z);

    const is_valid = try verifyKZGProof(&commitment, &z, &result.y, &result.proof);
    try testing.expect(is_valid);
}

test "c_kzg edge case - zero evaluation point" {
    const testing = std.testing;

    try ckzg.loadTrustedSetupFromText(ckzg.embedded_trusted_setup, 0);
    defer freeTrustedSetup() catch unreachable;

    var blob = getRandomBlob(11111);
    const commitment = try blobToKzgCommitment(&blob);

    var z: Bytes32 = undefined;
    @memset(&z, 0);

    const result = try computeKZGProof(&blob, &z);
    const is_valid = try verifyKZGProof(&commitment, &z, &result.y, &result.proof);
    try testing.expect(is_valid);
}

test "c_kzg multiple blobs with same trusted setup" {
    const testing = std.testing;

    try ckzg.loadTrustedSetupFromText(ckzg.embedded_trusted_setup, 0);
    defer freeTrustedSetup() catch unreachable;

    // Test that we can process multiple blobs without reloading
    const num_blobs = 10;

    for (0..num_blobs) |i| {
        var blob = getRandomBlob(@intCast(i * 1000));
        const commitment = try blobToKzgCommitment(&blob);

        var z: Bytes32 = undefined;
        @memset(&z, @intCast(i));

        const result = try computeKZGProof(&blob, &z);
        const is_valid = try verifyKZGProof(&commitment, &z, &result.y, &result.proof);

        try testing.expect(is_valid);
    }
}

test "c_kzg commitment uniqueness" {
    const testing = std.testing;

    try ckzg.loadTrustedSetupFromText(ckzg.embedded_trusted_setup, 0);
    defer freeTrustedSetup() catch unreachable;

    // Different blobs should produce different commitments
    var blob1 = getRandomBlob(1);
    var blob2 = getRandomBlob(2);

    const commitment1 = try blobToKzgCommitment(&blob1);
    const commitment2 = try blobToKzgCommitment(&blob2);

    // Commitments should be different
    var are_different = false;
    for (commitment1, commitment2) |byte1, byte2| {
        if (byte1 != byte2) {
            are_different = true;
            break;
        }
    }
    try testing.expect(are_different);
}

test "c_kzg proof consistency across multiple calls" {
    const testing = std.testing;

    try ckzg.loadTrustedSetupFromText(ckzg.embedded_trusted_setup, 0);
    defer freeTrustedSetup() catch unreachable;

    var blob = getRandomBlob(55555);
    const commitment = try blobToKzgCommitment(&blob);

    var z: Bytes32 = undefined;
    @memset(&z, 0xAA);

    // Generate same proof multiple times
    for (0..5) |_| {
        const result = try computeKZGProof(&blob, &z);
        const is_valid = try verifyKZGProof(&commitment, &z, &result.y, &result.proof);
        try testing.expect(is_valid);
    }
}
