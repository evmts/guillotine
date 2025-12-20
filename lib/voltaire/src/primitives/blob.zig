const std = @import("std");
const testing = std.testing;
const hex = @import("hex.zig");
const Hash = [32]u8;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Allocator = std.mem.Allocator;

// EIP-4844 Blob Transaction Constants
pub const FIELD_ELEMENTS_PER_BLOB = 4096;
pub const BYTES_PER_FIELD_ELEMENT = 32;
pub const BYTES_PER_BLOB = FIELD_ELEMENTS_PER_BLOB * BYTES_PER_FIELD_ELEMENT; // 131072
pub const MAX_BLOBS_PER_TRANSACTION = 6;
pub const BLOB_COMMITMENT_VERSION_KZG = 0x01;
pub const BLOB_BASE_FEE_UPDATE_FRACTION = 3338477;
pub const MIN_BLOB_BASE_FEE = 1;
pub const BLOB_GAS_PER_BLOB = 131072; // 2^17

// Blob error types
pub const BlobError = error{
    NoBlobs,
    TooManyBlobs,
    InvalidVersionedHash,
    ZeroMaxFeePerBlobGas,
    DataTooLarge,
    InvalidBlobData,
    OutOfMemory,
};

// Blob types
pub const Blob = [BYTES_PER_BLOB]u8;
pub const BlobCommitment = [48]u8;
pub const BlobProof = [48]u8;
pub const VersionedHash = struct { bytes: [32]u8 };

// Create versioned hash from commitment
pub fn commitmentToVersionedHash(commitment: BlobCommitment) VersionedHash {
    // versioned_hash = BLOB_COMMITMENT_VERSION_KZG ++ sha256(commitment)[1:]
    var hash_input: [48]u8 = commitment;
    var sha256_hash: [32]u8 = undefined;
    Sha256.hash(&hash_input, &sha256_hash, .{});

    var versioned = VersionedHash{ .bytes = undefined };
    versioned.bytes[0] = BLOB_COMMITMENT_VERSION_KZG;
    @memcpy(versioned.bytes[1..32], sha256_hash[1..32]);

    return versioned;
}

// Validate versioned hash
pub fn isValidVersionedHash(h: VersionedHash) bool {
    return h.bytes[0] == BLOB_COMMITMENT_VERSION_KZG;
}

// Calculate blob gas price
pub fn calculateBlobGasPrice(excess_blob_gas: u64) u64 {
    // fakeExponential(MIN_BLOB_BASE_FEE, excess_blob_gas, BLOB_BASE_FEE_UPDATE_FRACTION)
    return fakeExponential(MIN_BLOB_BASE_FEE, excess_blob_gas, BLOB_BASE_FEE_UPDATE_FRACTION);
}

// Fake exponential from EIP-4844
fn fakeExponential(factor: u64, numerator: u64, denominator: u64) u64 {
    var output: u64 = 0;
    var numerator_accum = factor * denominator;
    var i: u64 = 1;

    while (numerator_accum > 0) {
        output += numerator_accum;
        numerator_accum = (numerator_accum * numerator) / (denominator * i);
        i += 1;

        // Prevent infinite loop
        if (i > 256) break;
    }

    return output / denominator;
}

// Calculate excess blob gas for next block
pub fn calculateExcessBlobGas(parent_excess_blob_gas: u64, parent_blob_gas_used: u64) u64 {
    const target_blob_gas_per_block = 393216; // 3 * BLOB_GAS_PER_BLOB

    if (parent_excess_blob_gas + parent_blob_gas_used < target_blob_gas_per_block) {
        return 0;
    } else {
        return parent_excess_blob_gas + parent_blob_gas_used - target_blob_gas_per_block;
    }
}

// Blob transaction validation
pub const BlobTransaction = struct {
    max_fee_per_blob_gas: u64,
    blob_versioned_hashes: []const VersionedHash,

    pub fn validate(self: *const BlobTransaction) !void {
        // Must have at least one blob
        if (self.blob_versioned_hashes.len == 0) {
            return BlobError.NoBlobs;
        }

        // Cannot exceed max blobs
        if (self.blob_versioned_hashes.len > MAX_BLOBS_PER_TRANSACTION) {
            return BlobError.TooManyBlobs;
        }

        // All hashes must be valid
        for (self.blob_versioned_hashes) |h| {
            if (!isValidVersionedHash(h)) {
                return BlobError.InvalidVersionedHash;
            }
        }

        // Max fee must be positive
        if (self.max_fee_per_blob_gas == 0) {
            return BlobError.ZeroMaxFeePerBlobGas;
        }
    }

    pub fn blobGasUsed(self: *const BlobTransaction) u64 {
        return self.blob_versioned_hashes.len * BLOB_GAS_PER_BLOB;
    }

    pub fn blobGasCost(self: *const BlobTransaction, blob_base_fee: u64) u64 {
        return self.blobGasUsed() * blob_base_fee;
    }
};

// Blob sidecar for consensus layer
pub const BlobSidecar = struct {
    blob: Blob,
    commitment: BlobCommitment,
    proof: BlobProof,

    pub fn versionedHash(self: *const BlobSidecar) VersionedHash {
        return commitmentToVersionedHash(self.commitment);
    }
};

// Helpers for blob data encoding
pub fn encodeBlobData(allocator: Allocator, data: []const u8) !Blob {
    _ = allocator;

    if (data.len > BYTES_PER_BLOB - 1) {
        return BlobError.DataTooLarge;
    }

    var blob: Blob = [_]u8{0x00} ** BYTES_PER_BLOB;

    // Simple encoding: length prefix + data
    // In practice, this would use more sophisticated encoding
    const len_bytes = std.mem.toBytes(data.len);
    @memcpy(blob[0..8], &len_bytes);
    @memcpy(blob[8 .. 8 + data.len], data);

    return blob;
}

pub fn decodeBlobData(allocator: Allocator, blob: Blob) ![]u8 {
    // Decode length
    const len = std.mem.bytesToValue(usize, blob[0..8]);

    if (len > BYTES_PER_BLOB - 8) {
        return BlobError.InvalidBlobData;
    }

    const data = try allocator.alloc(u8, len);
    @memcpy(data, blob[8 .. 8 + len]);

    return data;
}

// Tests

test "commitment to versioned hash" {
    const commitment: BlobCommitment = [_]u8{0x12} ** 48;
    const versioned_hash = commitmentToVersionedHash(commitment);

    // Should start with version byte
    try testing.expectEqual(BLOB_COMMITMENT_VERSION_KZG, versioned_hash.bytes[0]);

    // Should be valid
    try testing.expect(isValidVersionedHash(versioned_hash));
}

test "invalid versioned hash" {
    var h: VersionedHash = undefined;
    h.bytes = [_]u8{0x00} ** 32;
    h.bytes[0] = 0x02; // Invalid version

    try testing.expect(!isValidVersionedHash(h));
}

test "blob gas price calculation" {
    // Test with no excess gas
    const price_zero = calculateBlobGasPrice(0);
    try testing.expectEqual(@as(u64, 1), price_zero); // MIN_BLOB_BASE_FEE

    // Test with some excess gas
    const price_low = calculateBlobGasPrice(131072); // 1 blob worth
    try testing.expect(price_low > 1);

    // Test with high excess gas
    const price_high = calculateBlobGasPrice(10 * BLOB_GAS_PER_BLOB);
    try testing.expect(price_high > price_low);
}

test "excess blob gas calculation" {
    const target = 393216; // 3 blobs

    // No blobs used, no excess
    var excess = calculateExcessBlobGas(0, 0);
    try testing.expectEqual(@as(u64, 0), excess);

    // Used exactly target
    excess = calculateExcessBlobGas(0, target);
    try testing.expectEqual(@as(u64, 0), excess);

    // Used more than target
    excess = calculateExcessBlobGas(0, target + BLOB_GAS_PER_BLOB);
    try testing.expectEqual(BLOB_GAS_PER_BLOB, excess);

    // With existing excess
    excess = calculateExcessBlobGas(BLOB_GAS_PER_BLOB, target);
    try testing.expectEqual(BLOB_GAS_PER_BLOB, excess);
}

test "blob transaction validation" {
    const hash1 = commitmentToVersionedHash([_]u8{0x01} ** 48);
    const hash2 = commitmentToVersionedHash([_]u8{0x02} ** 48);

    const hashes = [_]VersionedHash{ hash1, hash2 };

    var tx = BlobTransaction{
        .max_fee_per_blob_gas = 1000,
        .blob_versioned_hashes = &hashes,
    };

    // Should be valid
    try tx.validate();

    // Test gas calculations
    try testing.expectEqual(@as(u64, 2 * BLOB_GAS_PER_BLOB), tx.blobGasUsed());
    try testing.expectEqual(@as(u64, 2 * BLOB_GAS_PER_BLOB * 10), tx.blobGasCost(10));
}

test "blob transaction validation failures" {
    // No blobs
    var tx = BlobTransaction{
        .max_fee_per_blob_gas = 1000,
        .blob_versioned_hashes = &.{},
    };
    try testing.expectError(BlobError.NoBlobs, tx.validate());

    // Too many blobs
    var many_hashes: [MAX_BLOBS_PER_TRANSACTION + 1]VersionedHash = undefined;
    for (0..many_hashes.len) |i| {
        many_hashes[i] = commitmentToVersionedHash([_]u8{@intCast(i)} ** 48);
    }

    tx = BlobTransaction{
        .max_fee_per_blob_gas = 1000,
        .blob_versioned_hashes = &many_hashes,
    };
    try testing.expectError(BlobError.TooManyBlobs, tx.validate());

    // Invalid versioned hash
    var invalid_hash: VersionedHash = undefined;
    invalid_hash.bytes = [_]u8{0x00} ** 32;
    invalid_hash.bytes[0] = 0xFF; // Invalid version

    tx = BlobTransaction{
        .max_fee_per_blob_gas = 1000,
        .blob_versioned_hashes = &[_]VersionedHash{invalid_hash},
    };
    try testing.expectError(BlobError.InvalidVersionedHash, tx.validate());

    // Zero max fee
    const valid_hash = commitmentToVersionedHash([_]u8{0x01} ** 48);
    tx = BlobTransaction{
        .max_fee_per_blob_gas = 0,
        .blob_versioned_hashes = &[_]VersionedHash{valid_hash},
    };
    try testing.expectError(BlobError.ZeroMaxFeePerBlobGas, tx.validate());
}

test "blob sidecar" {
    const sidecar = BlobSidecar{
        .blob = [_]u8{0x00} ** BYTES_PER_BLOB,
        .commitment = [_]u8{0x12} ** 48,
        .proof = [_]u8{0x34} ** 48,
    };

    const h = sidecar.versionedHash();
    try testing.expect(isValidVersionedHash(h));
}

test "blob gas economics" {
    // Simulate block progression
    var excess_blob_gas: u64 = 0;

    // Block 1: 4 blobs used (above target)
    var blob_gas_used: u64 = 4 * BLOB_GAS_PER_BLOB;
    var blob_price = calculateBlobGasPrice(excess_blob_gas);
    try testing.expectEqual(@as(u64, 1), blob_price); // Min price initially

    excess_blob_gas = calculateExcessBlobGas(excess_blob_gas, blob_gas_used);
    try testing.expect(excess_blob_gas > 0); // Should increase

    // Block 2: Price should have increased
    blob_price = calculateBlobGasPrice(excess_blob_gas);
    try testing.expect(blob_price > 1);

    // Block 3: Use only 1 blob (below target)
    blob_gas_used = BLOB_GAS_PER_BLOB;
    const old_excess = excess_blob_gas;
    excess_blob_gas = calculateExcessBlobGas(excess_blob_gas, blob_gas_used);
    try testing.expect(excess_blob_gas < old_excess); // Should decrease
}

test "blob data encoding and decoding" {
    const allocator = testing.allocator;

    const test_data = "Hello, blob world!";

    const blob = try encodeBlobData(allocator, test_data);

    const decoded = try decodeBlobData(allocator, blob);
    defer allocator.free(decoded);

    try testing.expectEqualStrings(test_data, decoded);
}

test "blob data too large" {
    const allocator = testing.allocator;

    const large_data = try allocator.alloc(u8, BYTES_PER_BLOB);
    defer allocator.free(large_data);
    @memset(large_data, 0xFF);

    const result = encodeBlobData(allocator, large_data);
    try testing.expectError(BlobError.DataTooLarge, result);
}

// Comprehensive tests for isValidVersionedHash

test "isValidVersionedHash with correct version" {
    var h: VersionedHash = undefined;
    h.bytes = [_]u8{0x00} ** 32;
    h.bytes[0] = BLOB_COMMITMENT_VERSION_KZG; // 0x01

    try testing.expect(isValidVersionedHash(h));
}

test "isValidVersionedHash with version zero" {
    var h: VersionedHash = undefined;
    h.bytes = [_]u8{0x00} ** 32;
    h.bytes[0] = 0x00;

    try testing.expect(!isValidVersionedHash(h));
}

test "isValidVersionedHash with version two" {
    var h: VersionedHash = undefined;
    h.bytes = [_]u8{0x00} ** 32;
    h.bytes[0] = 0x02;

    try testing.expect(!isValidVersionedHash(h));
}

test "isValidVersionedHash with max version byte" {
    var h: VersionedHash = undefined;
    h.bytes = [_]u8{0xFF} ** 32;
    h.bytes[0] = 0xFF;

    try testing.expect(!isValidVersionedHash(h));
}

test "isValidVersionedHash with various invalid versions" {
    const invalid_versions = [_]u8{ 0x00, 0x02, 0x03, 0x10, 0xAA, 0xFF };

    for (invalid_versions) |version| {
        var h: VersionedHash = undefined;
        h.bytes = [_]u8{0x00} ** 32;
        h.bytes[0] = version;

        try testing.expect(!isValidVersionedHash(h));
    }
}

// Comprehensive tests for calculateBlobGasPrice

test "calculateBlobGasPrice with zero excess gas" {
    const price = calculateBlobGasPrice(0);
    try testing.expectEqual(@as(u64, MIN_BLOB_BASE_FEE), price);
}

test "calculateBlobGasPrice with small excess gas" {
    const price = calculateBlobGasPrice(1000);
    try testing.expect(price >= MIN_BLOB_BASE_FEE);
}

test "calculateBlobGasPrice with one blob worth of excess" {
    const price = calculateBlobGasPrice(BLOB_GAS_PER_BLOB);
    try testing.expect(price > MIN_BLOB_BASE_FEE);
}

test "calculateBlobGasPrice with target blob gas" {
    const target = 393216; // 3 * BLOB_GAS_PER_BLOB
    const price = calculateBlobGasPrice(target);
    try testing.expect(price > MIN_BLOB_BASE_FEE);
}

test "calculateBlobGasPrice monotonically increases" {
    const price1 = calculateBlobGasPrice(0);
    const price2 = calculateBlobGasPrice(BLOB_GAS_PER_BLOB);
    const price3 = calculateBlobGasPrice(2 * BLOB_GAS_PER_BLOB);
    const price4 = calculateBlobGasPrice(10 * BLOB_GAS_PER_BLOB);

    try testing.expect(price2 > price1);
    try testing.expect(price3 > price2);
    try testing.expect(price4 > price3);
}

test "calculateBlobGasPrice with various excess blob gas values" {
    const test_values = [_]u64{
        0,
        1,
        100,
        1000,
        BLOB_GAS_PER_BLOB,
        BLOB_GAS_PER_BLOB * 2,
        BLOB_GAS_PER_BLOB * 6, // Max blobs worth
        393216, // Target
        393216 * 2, // 2x target
    };

    for (test_values) |excess| {
        const price = calculateBlobGasPrice(excess);
        try testing.expect(price >= MIN_BLOB_BASE_FEE);
    }
}

test "calculateBlobGasPrice with high excess gas" {
    const price = calculateBlobGasPrice(100 * BLOB_GAS_PER_BLOB);
    try testing.expect(price > calculateBlobGasPrice(10 * BLOB_GAS_PER_BLOB));
}

// Comprehensive tests for calculateExcessBlobGas

test "calculateExcessBlobGas with no excess and no usage" {
    const excess = calculateExcessBlobGas(0, 0);
    try testing.expectEqual(@as(u64, 0), excess);
}

test "calculateExcessBlobGas with no excess and below target usage" {
    const target = 393216;
    const excess = calculateExcessBlobGas(0, target - 1);
    try testing.expectEqual(@as(u64, 0), excess);
}

test "calculateExcessBlobGas with no excess at exact target" {
    const target = 393216;
    const excess = calculateExcessBlobGas(0, target);
    try testing.expectEqual(@as(u64, 0), excess);
}

test "calculateExcessBlobGas with no excess above target" {
    const target = 393216;
    const excess = calculateExcessBlobGas(0, target + 1);
    try testing.expectEqual(@as(u64, 1), excess);
}

test "calculateExcessBlobGas with existing excess below target usage" {
    const existing_excess = BLOB_GAS_PER_BLOB;
    const usage = BLOB_GAS_PER_BLOB; // Total < target

    const excess = calculateExcessBlobGas(existing_excess, usage);
    try testing.expectEqual(@as(u64, 0), excess);
}

test "calculateExcessBlobGas with existing excess at target" {
    const existing_excess = BLOB_GAS_PER_BLOB;
    const usage = 393216 - existing_excess;

    const excess = calculateExcessBlobGas(existing_excess, usage);
    try testing.expectEqual(@as(u64, 0), excess);
}

test "calculateExcessBlobGas with existing excess above target" {
    const existing_excess = BLOB_GAS_PER_BLOB;
    const usage = 393216;

    const excess = calculateExcessBlobGas(existing_excess, usage);
    try testing.expectEqual(existing_excess, excess);
}

test "calculateExcessBlobGas rollover accumulation" {
    // Start with no excess
    var excess: u64 = 0;

    // Use 6 blobs (max) - above target
    excess = calculateExcessBlobGas(excess, 6 * BLOB_GAS_PER_BLOB);
    try testing.expect(excess > 0);

    // Use another 6 blobs - should accumulate
    const prev_excess = excess;
    excess = calculateExcessBlobGas(excess, 6 * BLOB_GAS_PER_BLOB);
    try testing.expect(excess > prev_excess);
}

test "calculateExcessBlobGas boundary at target minus one" {
    const target = 393216;
    const excess = calculateExcessBlobGas(0, target - 1);
    try testing.expectEqual(@as(u64, 0), excess);
}

test "calculateExcessBlobGas boundary at target plus one" {
    const target = 393216;
    const excess = calculateExcessBlobGas(0, target + 1);
    try testing.expectEqual(@as(u64, 1), excess);
}

// Comprehensive tests for fakeExponential

test "fakeExponential with zero numerator" {
    const result = fakeExponential(MIN_BLOB_BASE_FEE, 0, BLOB_BASE_FEE_UPDATE_FRACTION);
    try testing.expectEqual(@as(u64, MIN_BLOB_BASE_FEE), result);
}

test "fakeExponential approximation accuracy small values" {
    // For small values, should approximate e^x well
    const result = fakeExponential(1, 1000, BLOB_BASE_FEE_UPDATE_FRACTION);
    try testing.expect(result >= 1);
}

test "fakeExponential does not overflow" {
    // Test with large values that could overflow
    const result = fakeExponential(MIN_BLOB_BASE_FEE, 1000000, BLOB_BASE_FEE_UPDATE_FRACTION);
    try testing.expect(result > MIN_BLOB_BASE_FEE);
}

test "fakeExponential iteration limit" {
    // Ensure iteration limit prevents infinite loop
    const result = fakeExponential(1, 100000000, 1);
    try testing.expect(result > 0);
}

test "fakeExponential consistency with calculateBlobGasPrice" {
    // Verify that calculateBlobGasPrice uses fakeExponential correctly
    const excess = BLOB_GAS_PER_BLOB;
    const price = calculateBlobGasPrice(excess);
    const direct = fakeExponential(MIN_BLOB_BASE_FEE, excess, BLOB_BASE_FEE_UPDATE_FRACTION);
    try testing.expectEqual(direct, price);
}

// Comprehensive tests for BlobTransaction.validate

test "BlobTransaction validate with single valid blob" {
    const hash = commitmentToVersionedHash([_]u8{0x01} ** 48);
    const hashes = [_]VersionedHash{hash};

    const tx = BlobTransaction{
        .max_fee_per_blob_gas = 1,
        .blob_versioned_hashes = &hashes,
    };

    try tx.validate();
}

test "BlobTransaction validate with max blobs exactly" {
    var hashes: [MAX_BLOBS_PER_TRANSACTION]VersionedHash = undefined;
    for (0..MAX_BLOBS_PER_TRANSACTION) |i| {
        hashes[i] = commitmentToVersionedHash([_]u8{@intCast(i + 1)} ** 48);
    }

    const tx = BlobTransaction{
        .max_fee_per_blob_gas = 1,
        .blob_versioned_hashes = &hashes,
    };

    try tx.validate();
}

test "BlobTransaction validate fails with zero blobs" {
    const tx = BlobTransaction{
        .max_fee_per_blob_gas = 1,
        .blob_versioned_hashes = &.{},
    };

    try testing.expectError(BlobError.NoBlobs, tx.validate());
}

test "BlobTransaction validate fails with max blobs plus one" {
    var hashes: [MAX_BLOBS_PER_TRANSACTION + 1]VersionedHash = undefined;
    for (0..hashes.len) |i| {
        hashes[i] = commitmentToVersionedHash([_]u8{@intCast(i + 1)} ** 48);
    }

    const tx = BlobTransaction{
        .max_fee_per_blob_gas = 1,
        .blob_versioned_hashes = &hashes,
    };

    try testing.expectError(BlobError.TooManyBlobs, tx.validate());
}

test "BlobTransaction validate fails with many blobs" {
    var hashes: [100]VersionedHash = undefined;
    for (0..hashes.len) |i| {
        hashes[i] = commitmentToVersionedHash([_]u8{@intCast((i % 255) + 1)} ** 48);
    }

    const tx = BlobTransaction{
        .max_fee_per_blob_gas = 1,
        .blob_versioned_hashes = &hashes,
    };

    try testing.expectError(BlobError.TooManyBlobs, tx.validate());
}

test "BlobTransaction validate fails with invalid versioned hash in middle" {
    const valid_hash1 = commitmentToVersionedHash([_]u8{0x01} ** 48);
    var invalid_hash: VersionedHash = undefined;
    invalid_hash.bytes = [_]u8{0x00} ** 32;
    invalid_hash.bytes[0] = 0x00; // Invalid version
    const valid_hash2 = commitmentToVersionedHash([_]u8{0x02} ** 48);

    const hashes = [_]VersionedHash{ valid_hash1, invalid_hash, valid_hash2 };

    const tx = BlobTransaction{
        .max_fee_per_blob_gas = 1,
        .blob_versioned_hashes = &hashes,
    };

    try testing.expectError(BlobError.InvalidVersionedHash, tx.validate());
}

test "BlobTransaction validate fails with zero max fee" {
    const hash = commitmentToVersionedHash([_]u8{0x01} ** 48);
    const hashes = [_]VersionedHash{hash};

    const tx = BlobTransaction{
        .max_fee_per_blob_gas = 0,
        .blob_versioned_hashes = &hashes,
    };

    try testing.expectError(BlobError.ZeroMaxFeePerBlobGas, tx.validate());
}

test "BlobTransaction validate succeeds with minimal max fee" {
    const hash = commitmentToVersionedHash([_]u8{0x01} ** 48);
    const hashes = [_]VersionedHash{hash};

    const tx = BlobTransaction{
        .max_fee_per_blob_gas = 1,
        .blob_versioned_hashes = &hashes,
    };

    try tx.validate();
}

test "BlobTransaction validate succeeds with high max fee" {
    const hash = commitmentToVersionedHash([_]u8{0x01} ** 48);
    const hashes = [_]VersionedHash{hash};

    const tx = BlobTransaction{
        .max_fee_per_blob_gas = 999999999999,
        .blob_versioned_hashes = &hashes,
    };

    try tx.validate();
}

// Tests for max blob count enforcement

test "max blob count is six" {
    try testing.expectEqual(@as(usize, 6), MAX_BLOBS_PER_TRANSACTION);
}

test "BlobTransaction with exactly max blobs is valid" {
    var hashes: [MAX_BLOBS_PER_TRANSACTION]VersionedHash = undefined;
    for (0..MAX_BLOBS_PER_TRANSACTION) |i| {
        hashes[i] = commitmentToVersionedHash([_]u8{@intCast(i + 1)} ** 48);
    }

    const tx = BlobTransaction{
        .max_fee_per_blob_gas = 100,
        .blob_versioned_hashes = &hashes,
    };

    try tx.validate();
    try testing.expectEqual(@as(u64, 6 * BLOB_GAS_PER_BLOB), tx.blobGasUsed());
}

test "BlobTransaction gas calculations with max blobs" {
    var hashes: [MAX_BLOBS_PER_TRANSACTION]VersionedHash = undefined;
    for (0..MAX_BLOBS_PER_TRANSACTION) |i| {
        hashes[i] = commitmentToVersionedHash([_]u8{@intCast(i + 1)} ** 48);
    }

    const tx = BlobTransaction{
        .max_fee_per_blob_gas = 100,
        .blob_versioned_hashes = &hashes,
    };

    const expected_gas = 6 * BLOB_GAS_PER_BLOB;
    try testing.expectEqual(expected_gas, tx.blobGasUsed());

    const blob_base_fee: u64 = 50;
    const expected_cost = expected_gas * blob_base_fee;
    try testing.expectEqual(expected_cost, tx.blobGasCost(blob_base_fee));
}

// Edge case tests near boundaries

test "blob gas calculation boundary with one blob" {
    const hash = commitmentToVersionedHash([_]u8{0x01} ** 48);
    const hashes = [_]VersionedHash{hash};

    const tx = BlobTransaction{
        .max_fee_per_blob_gas = 1,
        .blob_versioned_hashes = &hashes,
    };

    try testing.expectEqual(BLOB_GAS_PER_BLOB, tx.blobGasUsed());
}

test "blob gas calculation boundary with two blobs" {
    const hash1 = commitmentToVersionedHash([_]u8{0x01} ** 48);
    const hash2 = commitmentToVersionedHash([_]u8{0x02} ** 48);
    const hashes = [_]VersionedHash{ hash1, hash2 };

    const tx = BlobTransaction{
        .max_fee_per_blob_gas = 1,
        .blob_versioned_hashes = &hashes,
    };

    try testing.expectEqual(@as(u64, 2 * BLOB_GAS_PER_BLOB), tx.blobGasUsed());
}

test "excess blob gas at target boundary minus one blob" {
    const target = 393216;
    const excess = calculateExcessBlobGas(0, target - BLOB_GAS_PER_BLOB);
    try testing.expectEqual(@as(u64, 0), excess);
}

test "excess blob gas at target boundary plus one blob" {
    const target = 393216;
    const excess = calculateExcessBlobGas(0, target + BLOB_GAS_PER_BLOB);
    try testing.expectEqual(BLOB_GAS_PER_BLOB, excess);
}

test "blob price at target boundary" {
    const target = 393216;

    // Price with zero excess
    const price_zero = calculateBlobGasPrice(0);

    // Price with target excess
    const price_target = calculateBlobGasPrice(target);

    try testing.expect(price_target > price_zero);
}

test "blob gas cost calculation with zero base fee" {
    const hash = commitmentToVersionedHash([_]u8{0x01} ** 48);
    const hashes = [_]VersionedHash{hash};

    const tx = BlobTransaction{
        .max_fee_per_blob_gas = 100,
        .blob_versioned_hashes = &hashes,
    };

    const cost = tx.blobGasCost(0);
    try testing.expectEqual(@as(u64, 0), cost);
}

test "blob gas cost calculation with high base fee" {
    const hash = commitmentToVersionedHash([_]u8{0x01} ** 48);
    const hashes = [_]VersionedHash{hash};

    const tx = BlobTransaction{
        .max_fee_per_blob_gas = 1000000,
        .blob_versioned_hashes = &hashes,
    };

    const base_fee: u64 = 1000000;
    const expected = BLOB_GAS_PER_BLOB * base_fee;
    const cost = tx.blobGasCost(base_fee);
    try testing.expectEqual(expected, cost);
}

// Gas price calculation edge cases

test "gas price with maximum practical excess" {
    // Test with very high excess (100 blobs worth)
    const high_excess = 100 * BLOB_GAS_PER_BLOB;
    const price = calculateBlobGasPrice(high_excess);
    try testing.expect(price > MIN_BLOB_BASE_FEE);
}

test "gas price progression with incremental excess" {
    var excess: u64 = 0;
    var prev_price = calculateBlobGasPrice(excess);

    for (0..10) |_| {
        excess += BLOB_GAS_PER_BLOB;
        const price = calculateBlobGasPrice(excess);
        try testing.expect(price >= prev_price); // Should never decrease
        prev_price = price;
    }
}

test "blob transaction cost realistic scenario" {
    const hash1 = commitmentToVersionedHash([_]u8{0x01} ** 48);
    const hash2 = commitmentToVersionedHash([_]u8{0x02} ** 48);
    const hash3 = commitmentToVersionedHash([_]u8{0x03} ** 48);
    const hashes = [_]VersionedHash{ hash1, hash2, hash3 };

    const tx = BlobTransaction{
        .max_fee_per_blob_gas = 1000000,
        .blob_versioned_hashes = &hashes,
    };

    try tx.validate();

    // Calculate gas with current excess
    const excess_blob_gas: u64 = BLOB_GAS_PER_BLOB * 2;
    const blob_base_fee = calculateBlobGasPrice(excess_blob_gas);
    const total_cost = tx.blobGasCost(blob_base_fee);

    // Verify cost is reasonable
    try testing.expect(total_cost > 0);
    try testing.expectEqual(@as(u64, 3 * BLOB_GAS_PER_BLOB), tx.blobGasUsed());
}

test "excess blob gas converges to zero with low usage" {
    var excess: u64 = 10 * BLOB_GAS_PER_BLOB; // Start high

    // Use 1 blob per block (well below target of 3)
    for (0..20) |_| {
        const prev_excess = excess;
        excess = calculateExcessBlobGas(excess, BLOB_GAS_PER_BLOB);

        if (excess > 0) {
            try testing.expect(excess <= prev_excess); // Should decrease or stay zero
        }
    }

    // Should eventually reach zero
    try testing.expectEqual(@as(u64, 0), excess);
}
