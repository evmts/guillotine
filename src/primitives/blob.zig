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
pub const MIN_BLOB_BASE_FEE = 1;
pub const BLOB_GAS_PER_BLOB = 131072; // 2^17

// Hardfork-specific blob gas parameters
// Cancun (EIP-4844)
pub const TARGET_BLOB_GAS_PER_BLOCK_CANCUN = 393216; // 3 * BLOB_GAS_PER_BLOB
pub const MAX_BLOB_GAS_PER_BLOCK_CANCUN = 786432; // 6 * BLOB_GAS_PER_BLOB
pub const BLOB_BASE_FEE_UPDATE_FRACTION_CANCUN = 3338477;

// Prague/Electra (EIP-7691)
pub const TARGET_BLOB_GAS_PER_BLOCK_PRAGUE = 786432; // 6 * BLOB_GAS_PER_BLOB
pub const MAX_BLOB_GAS_PER_BLOCK_PRAGUE = 1179648; // 9 * BLOB_GAS_PER_BLOB
pub const BLOB_BASE_FEE_UPDATE_FRACTION_PRAGUE = 5007716;

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
pub fn commitment_to_versioned_hash(commitment: BlobCommitment) VersionedHash {
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
pub fn is_valid_versioned_hash(h: VersionedHash) bool {
    return h.bytes[0] == BLOB_COMMITMENT_VERSION_KZG;
}

// Calculate blob gas price
pub fn calculate_blob_gas_price(excess_gas: u64, update_fraction: u64) u64 {
    return fake_exponential(MIN_BLOB_BASE_FEE, excess_gas, update_fraction);
}

// Fake exponential from EIP-4844
fn fake_exponential(factor: u64, numerator: u64, denominator: u64) u64 {
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
pub fn excess_blob_gas(parent_excess_blob_gas: u64, parent_blob_gas_used: u64, target_blob_gas: u64) u64 {
    if (parent_excess_blob_gas + parent_blob_gas_used < target_blob_gas) {
        return 0;
    } else {
        return parent_excess_blob_gas + parent_blob_gas_used - target_blob_gas;
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
            if (!is_valid_versioned_hash(h)) {
                return BlobError.InvalidVersionedHash;
            }
        }

        // Max fee must be positive
        if (self.max_fee_per_blob_gas == 0) {
            return BlobError.ZeroMaxFeePerBlobGas;
        }
    }

    pub fn blob_gas_used(self: *const BlobTransaction) u64 {
        return self.blob_versioned_hashes.len * BLOB_GAS_PER_BLOB;
    }

    pub fn blob_gas_cost(self: *const BlobTransaction, blob_base_fee: u64) u64 {
        return self.blob_gas_used() * blob_base_fee;
    }
};

// Blob sidecar for consensus layer
pub const BlobSidecar = struct {
    blob: Blob,
    commitment: BlobCommitment,
    proof: BlobProof,

    pub fn versioned_hash(self: *const BlobSidecar) VersionedHash {
        return commitment_to_versioned_hash(self.commitment);
    }
};

// Helpers for blob data encoding
pub fn encode_blob_data(allocator: Allocator, data: []const u8) !Blob {
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

pub fn decode_blob_data(allocator: Allocator, blob: Blob) ![]u8 {
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
    const versioned_hash = commitment_to_versioned_hash(commitment);

    // Should start with version byte
    try testing.expectEqual(BLOB_COMMITMENT_VERSION_KZG, versioned_hash.bytes[0]);

    // Should be valid
    try testing.expect(is_valid_versioned_hash(versioned_hash));
}

test "invalid versioned hash" {
    var h: VersionedHash = undefined;
    h.bytes = [_]u8{0x00} ** 32;
    h.bytes[0] = 0x02; // Invalid version

    try testing.expect(!is_valid_versioned_hash(h));
}

test "blob gas price calculation" {
    // Test with no excess gas
    const price_zero = calculate_blob_gas_price(0, BLOB_BASE_FEE_UPDATE_FRACTION_CANCUN);
    try testing.expectEqual(@as(u64, 1), price_zero); // MIN_BLOB_BASE_FEE

    // Test with some excess gas
    const price_low = calculate_blob_gas_price(131072, BLOB_BASE_FEE_UPDATE_FRACTION_CANCUN); // 1 blob worth
    try testing.expect(price_low > 1);

    // Test with high excess gas
    const price_high = calculate_blob_gas_price(10 * BLOB_GAS_PER_BLOB, BLOB_BASE_FEE_UPDATE_FRACTION_CANCUN);
    try testing.expect(price_high > price_low);
}

test "excess blob gas calculation" {
    // No blobs used, no excess
    var excess = excess_blob_gas(0, 0, TARGET_BLOB_GAS_PER_BLOCK_CANCUN);
    try testing.expectEqual(@as(u64, 0), excess);

    // Used exactly target
    excess = excess_blob_gas(0, 0, TARGET_BLOB_GAS_PER_BLOCK_CANCUN);
    try testing.expectEqual(@as(u64, 0), excess);

    // Used more than target
    excess = excess_blob_gas(0, 0, TARGET_BLOB_GAS_PER_BLOCK_CANCUN + BLOB_GAS_PER_BLOB);
    try testing.expectEqual(BLOB_GAS_PER_BLOB, excess);

    // With existing excess
    excess = excess_blob_gas(BLOB_GAS_PER_BLOB, 0, TARGET_BLOB_GAS_PER_BLOCK_CANCUN);
    try testing.expectEqual(BLOB_GAS_PER_BLOB, excess);
}

test "blob transaction validation" {
    const hash1 = commitment_to_versioned_hash([_]u8{0x01} ** 48);
    const hash2 = commitment_to_versioned_hash([_]u8{0x02} ** 48);

    const hashes = [_]VersionedHash{ hash1, hash2 };

    var tx = BlobTransaction{
        .max_fee_per_blob_gas = 1000,
        .blob_versioned_hashes = &hashes,
    };

    // Should be valid
    try tx.validate();

    // Test gas calculations
    try testing.expectEqual(@as(u64, 2 * BLOB_GAS_PER_BLOB), tx.blob_gas_used());
    try testing.expectEqual(@as(u64, 2 * BLOB_GAS_PER_BLOB * 10), tx.blob_gas_cost(10));
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
        many_hashes[i] = commitment_to_versioned_hash([_]u8{@intCast(i)} ** 48);
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
    const valid_hash = commitment_to_versioned_hash([_]u8{0x01} ** 48);
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

    const h = sidecar.versioned_hash();
    try testing.expect(is_valid_versioned_hash(h));
}

test "blob gas economics" {
    // Simulate block progression
    var excess_gas: u64 = 0;

    // Block 1: 4 blobs used (above target)
    var blob_gas_used: u64 = 4 * BLOB_GAS_PER_BLOB;
    var blob_price = calculate_blob_gas_price(excess_gas, BLOB_BASE_FEE_UPDATE_FRACTION_CANCUN);
    try testing.expectEqual(@as(u64, 1), blob_price); // Min price initially

    excess_blob_gas = excess_blob_gas(excess_gas, blob_gas_used, TARGET_BLOB_GAS_PER_BLOCK_CANCUN);
    try testing.expect(excess_blob_gas > 0); // Should increase

    // Block 2: Price should have increased
    blob_price = calculate_blob_gas_price(excess_gas, BLOB_BASE_FEE_UPDATE_FRACTION_CANCUN);
    try testing.expect(blob_price > 1);

    // Block 3: Use only 1 blob (below target)
    blob_gas_used = BLOB_GAS_PER_BLOB;
    const old_excess = excess_blob_gas;
    excess_gas = excess_blob_gas(excess_blob_gas, blob_gas_used, TARGET_BLOB_GAS_PER_BLOCK_CANCUN);
    try testing.expect(excess_blob_gas < old_excess); // Should decrease
}

test "blob data encoding and decoding" {
    const allocator = testing.allocator;

    const test_data = "Hello, blob world!";

    const blob = try encode_blob_data(allocator, test_data);

    const decoded = try decode_blob_data(allocator, blob);
    defer allocator.free(decoded);

    try testing.expectEqualStrings(test_data, decoded);
}

test "blob data too large" {
    const allocator = testing.allocator;

    const large_data = try allocator.alloc(u8, BYTES_PER_BLOB);
    defer allocator.free(large_data);
    @memset(large_data, 0xFF);

    const result = encode_blob_data(allocator, large_data);
    try testing.expectError(BlobError.DataTooLarge, result);
}
