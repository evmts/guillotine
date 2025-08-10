const std = @import("std");
const root = @import("root.zig");
const Evm = root.Evm;
const primitives = root.primitives;
const Allocator = std.mem.Allocator;

/// EIP-4844 Blob Transaction Benchmarks
///
/// Measures performance of:
/// - KZG verification operations
/// - Blob gas market calculations
/// - Versioned hash validation
/// - Blob data handling
pub fn blob_kzg_verification_benchmark(allocator: Allocator) void {
    blob_kzg_verification_benchmark_impl(allocator) catch |err| {
        std.log.err("KZG verification benchmark failed: {}", .{err});
    };
}

fn blob_kzg_verification_benchmark_impl(allocator: Allocator) !void {
    // Initialize KZG verifier
    var kzg_verifier = try Evm.blob.KZGVerifier.init(allocator);
    defer kzg_verifier.deinit();

    // Create test blob data (simplified for benchmark)
    var blob = Evm.blob.Blob{};

    // Fill blob with test data pattern
    for (0..Evm.blob.FIELD_ELEMENTS_PER_BLOB) |i| {
        const element_bytes = @as(u32, @intCast(i)) * 31; // Simple pattern
        for (0..31) |j| {
            blob.data[i * 32 + j] = @intCast((element_bytes + @as(u32, @intCast(j))) % 256);
        }
    }

    // Generate commitment for the blob
    const commitment = try kzg_verifier.blob_to_kzg_commitment(&blob);
    const proof = try kzg_verifier.compute_blob_kzg_proof(&blob, &commitment.data);

    // Benchmark the verification process
    const start_time = std.time.nanoTimestamp();

    // Perform multiple verifications to get stable timing
    for (0..10) |_| {
        const is_valid = try kzg_verifier.verify_blob_kzg_proof(&blob, &commitment.bytes, &proof.bytes);
        std.mem.doNotOptimizeAway(is_valid);
    }

    const end_time = std.time.nanoTimestamp();
    const elapsed_ns = @as(u64, @intCast(end_time - start_time));

    std.mem.doNotOptimizeAway(elapsed_ns);
}

pub fn blob_gas_market_benchmark(allocator: Allocator) void {
    blob_gas_market_benchmark_impl(allocator) catch |err| {
        std.log.err("Blob gas market benchmark failed: {}", .{err});
    };
}

fn blob_gas_market_benchmark_impl(allocator: Allocator) !void {
    _ = allocator;

    // Create blob gas market instance
    var market = Evm.blob.BlobGasMarket.init();

    // Simulate a series of blocks with varying blob usage
    const blob_usages = [_]u64{ 0, 131072, 262144, 393216, 524288, 393216, 262144, 131072 };

    for (blob_usages) |blob_gas_used| {
        // Calculate blob base fee for this block
        const base_fee = market.calculate_blob_base_fee(blob_gas_used);
        std.mem.doNotOptimizeAway(base_fee);

        // Update market state
        market.update_blob_base_fee(blob_gas_used);

        // Calculate data gas fee for transactions
        const data_gas_fee = market.calculate_data_gas_fee(Evm.blob.GAS_PER_BLOB * 2); // 2 blobs
        std.mem.doNotOptimizeAway(data_gas_fee);
    }
}

pub fn versioned_hash_validation_benchmark(allocator: Allocator) void {
    versioned_hash_validation_benchmark_impl(allocator) catch |err| {
        std.log.err("Versioned hash validation benchmark failed: {}", .{err});
    };
}

fn versioned_hash_validation_benchmark_impl(allocator: Allocator) !void {
    // Initialize KZG verifier
    var kzg_verifier = try Evm.blob.KZGVerifier.init(allocator);
    defer kzg_verifier.deinit();

    // Create test blob and generate commitment
    var blob = Evm.blob.Blob{};
    for (0..Evm.blob.FIELD_ELEMENTS_PER_BLOB) |i| {
        const pattern = @as(u8, @intCast(i % 256));
        for (0..31) |j| {
            blob.data[i * 32 + j] = pattern ^ @as(u8, @intCast(j));
        }
    }

    const commitment = try kzg_verifier.blob_to_kzg_commitment(&blob);

    // Generate versioned hash from commitment
    const versioned_hash = Evm.blob.blob_types.commitment_to_versioned_hash(&commitment.bytes);

    // Benchmark hash validation operations
    for (0..1000) |_| {
        const is_valid = Evm.blob.validate_commitment_hash(&commitment.bytes, &versioned_hash.hash);
        std.mem.doNotOptimizeAway(is_valid);
    }
}

pub fn blob_data_handling_benchmark(allocator: Allocator) void {
    blob_data_handling_benchmark_impl(allocator) catch |err| {
        std.log.err("Blob data handling benchmark failed: {}", .{err});
    };
}

fn blob_data_handling_benchmark_impl(allocator: Allocator) !void {
    // Create multiple blobs with different data patterns
    var blobs: [Evm.blob.MAX_BLOBS_PER_TRANSACTION]Evm.blob.Blob = undefined;

    for (0..Evm.blob.MAX_BLOBS_PER_TRANSACTION) |blob_idx| {
        for (0..Evm.blob.FIELD_ELEMENTS_PER_BLOB) |field_idx| {
            const value = (@as(u32, @intCast(blob_idx)) << 16) | @as(u32, @intCast(field_idx));
            for (0..31) |byte_idx| {
                blobs[blob_idx].data[field_idx * 32 + byte_idx] = @intCast((value + @as(u32, @intCast(byte_idx))) % 256);
            }
        }
    }

    // Benchmark blob validation and processing
    var kzg_verifier = try Evm.blob.KZGVerifier.init(allocator);
    defer kzg_verifier.deinit();

    // Process each blob
    for (blobs) |*blob| {
        // Validate blob data
        if (try kzg_verifier.validate_blob_data(blob)) {
            // Generate commitment
            const commitment = try kzg_verifier.blob_to_kzg_commitment(blob);
            std.mem.doNotOptimizeAway(commitment);

            // Compute proof
            const proof = try kzg_verifier.compute_blob_kzg_proof(blob, &commitment.bytes);
            std.mem.doNotOptimizeAway(proof);
        }
    }
}

pub fn blob_transaction_validation_benchmark(allocator: Allocator) void {
    blob_transaction_validation_benchmark_impl(allocator) catch |err| {
        std.log.err("Blob transaction validation benchmark failed: {}", .{err});
    };
}

fn blob_transaction_validation_benchmark_impl(allocator: Allocator) !void {
    // Create a blob transaction with full validation pipeline
    var kzg_verifier = try Evm.blob.KZGVerifier.init(allocator);
    defer kzg_verifier.deinit();

    // Create test blob
    var blob = Evm.blob.Blob{};
    for (0..Evm.blob.FIELD_ELEMENTS_PER_BLOB) |i| {
        const seed = @as(u64, i) * 0x9E3779B97F4A7C15; // Simple hash-like pattern
        for (0..31) |j| {
            blob.data[i * 32 + j] = @intCast((seed >> (@intCast(j * 8))) & 0xFF);
        }
    }

    // Generate KZG commitment and proof
    const commitment = try kzg_verifier.blob_to_kzg_commitment(&blob);
    const proof = try kzg_verifier.compute_blob_kzg_proof(&blob, &commitment.bytes);

    // Create versioned hash
    const versioned_hash = Evm.blob.blob_types.commitment_to_versioned_hash(&commitment.bytes);

    // Benchmark the full validation pipeline
    for (0..100) |_| {
        // 1. Validate versioned hash format
        const hash_valid = Evm.blob.validate_commitment_hash(&commitment.bytes, &versioned_hash.hash);
        std.mem.doNotOptimizeAway(hash_valid);

        // 2. Validate blob data format
        const blob_valid = try kzg_verifier.validate_blob_data(&blob);
        std.mem.doNotOptimizeAway(blob_valid);

        // 3. Verify KZG proof
        const proof_valid = try kzg_verifier.verify_blob_kzg_proof(&blob, &commitment.bytes, &proof.bytes);
        std.mem.doNotOptimizeAway(proof_valid);

        // 4. Calculate blob gas cost
        var market = Evm.blob.BlobGasMarket.init();
        const gas_cost = market.calculate_data_gas_fee(Evm.blob.GAS_PER_BLOB);
        std.mem.doNotOptimizeAway(gas_cost);
    }
}

test "EIP-4844 benchmarks compile and basic execution" {
    const allocator = std.testing.allocator;

    // Basic compilation and execution test
    blob_gas_market_benchmark(allocator);
    versioned_hash_validation_benchmark(allocator);
    blob_data_handling_benchmark(allocator);

    // Note: KZG verification benchmarks require c-kzg-4844 library
    // and may be too heavy for unit tests
}
