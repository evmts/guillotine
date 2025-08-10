const std = @import("std");
const root = @import("root.zig");
const timing = @import("timing.zig");
const Evm = root.Evm;
const primitives = root.primitives;

// EIP-4844 Blob transaction benchmarks
const BlobTransaction = Evm.transaction.BlobTransaction;
const blob_types = Evm.blob.blob_types;
const blob_gas_market = Evm.blob.blob_gas_market;
const kzg_verification = Evm.blob.kzg_verification;

/// Benchmark KZG verification performance with various blob counts
pub fn kzg_verification_benchmark(allocator: std.mem.Allocator) !void {
    std.log.info("=== KZG Verification Performance Benchmark ===", .{});

    // Initialize global KZG verifier if available
    if (kzg_verification.init_global_verifier(allocator)) |_| {
        defer kzg_verification.deinit_global_verifier();

        // Test with different numbers of blobs
        const blob_counts = [_]u32{ 1, 2, 3, 4, 5, 6 }; // Up to MAX_BLOBS_PER_TRANSACTION

        for (blob_counts) |blob_count| {
            try benchmark_kzg_verification_for_count(allocator, blob_count);
        }
    } else |_| {
        std.log.warn("KZG verifier not available, skipping KZG verification benchmarks", .{});
    }
}

fn benchmark_kzg_verification_for_count(allocator: std.mem.Allocator, blob_count: u32) !void {
    std.log.info("Benchmarking KZG verification with {} blobs", .{blob_count});

    // Create test blob data
    var blobs = try allocator.alloc(blob_types.Blob, blob_count);
    defer allocator.free(blobs);

    var commitments = try allocator.alloc(blob_types.KZGCommitment, blob_count);
    defer allocator.free(commitments);

    var proofs = try allocator.alloc(blob_types.KZGProof, blob_count);
    defer allocator.free(proofs);

    // Initialize test data
    for (0..blob_count) |i| {
        blobs[i] = create_test_blob(i);
        commitments[i] = create_test_commitment(i);
        proofs[i] = create_test_proof(i);
    }

    // Benchmark KZG verification
    const iterations = 100;
    var total_time: u64 = 0;

    for (0..iterations) |_| {
        const start_time = timing.nanoTimestamp();

        if (kzg_verification.get_global_verifier()) |verifier| {
            for (blobs, commitments, proofs) |*blob, *commitment, *proof| {
                _ = verifier.verify_blob_kzg_proof(blob, commitment, proof) catch false;
            }
        }

        const end_time = timing.nanoTimestamp();
        total_time += end_time - start_time;
    }

    const avg_time = total_time / iterations;
    const throughput = @as(f64, @floatFromInt(blob_count * 1000000000)) / @as(f64, @floatFromInt(avg_time));

    std.log.info("  {} blobs: {d:.2f}ms avg, {d:.2f} blobs/sec", .{
        blob_count,
        @as(f64, @floatFromInt(avg_time)) / 1000000.0,
        throughput,
    });
}

/// Benchmark blob gas market calculations
pub fn blob_gas_market_benchmark(allocator: std.mem.Allocator) !void {
    _ = allocator;
    std.log.info("=== Blob Gas Market Calculations Benchmark ===", .{});

    // Test different blob counts for gas calculations
    const blob_counts = [_]u32{ 1, 2, 3, 4, 5, 6 };
    const base_fees = [_]u256{ 1000000, 5000000, 10000000, 50000000, 100000000 }; // Various base fees

    const iterations = 10000;

    for (blob_counts) |blob_count| {
        for (base_fees) |base_fee| {
            var total_time: u64 = 0;

            const start_time = timing.nanoTimestamp();

            for (0..iterations) |_| {
                // Calculate blob gas used
                const blob_gas_used = blob_gas_market.BlobGasMarket.calculate_blob_gas_used(blob_count);

                // Calculate blob fee
                const blob_fee = blob_gas_market.BlobGasMarket.calculate_blob_fee(blob_count, base_fee);

                // Validate blob gas limit
                _ = blob_gas_market.BlobGasMarket.validate_blob_gas_limit(blob_count);

                // Validate fee affordability
                const max_fee = base_fee + 1000000; // Slightly above base fee
                _ = blob_gas_market.BlobGasMarket.validate_blob_fee_affordability(max_fee, base_fee);

                // Prevent optimization
                std.mem.doNotOptimizeAway(blob_gas_used);
                std.mem.doNotOptimizeAway(blob_fee);
            }

            const end_time = timing.nanoTimestamp();
            total_time = end_time - start_time;

            const avg_time = total_time / iterations;
            const throughput = @as(f64, @floatFromInt(iterations * 1000000000)) / @as(f64, @floatFromInt(total_time));

            std.log.info("  {} blobs, base_fee {}: {d:.2f}ns avg, {d:.2f} ops/sec", .{
                blob_count,
                base_fee,
                @as(f64, @floatFromInt(avg_time)),
                throughput,
            });
        }
    }
}

/// Benchmark versioned hash validation
pub fn versioned_hash_benchmark(allocator: std.mem.Allocator) !void {
    std.log.info("=== Versioned Hash Validation Benchmark ===", .{});

    const blob_counts = [_]u32{ 1, 5, 10, 20, 50 }; // Test with various hash counts
    const iterations = 5000;

    for (blob_counts) |hash_count| {
        // Create test commitments and versioned hashes
        var commitments = try allocator.alloc(blob_types.KZGCommitment, hash_count);
        defer allocator.free(commitments);

        var versioned_hashes = try allocator.alloc(blob_types.VersionedHash, hash_count);
        defer allocator.free(versioned_hashes);

        // Initialize test data
        for (0..hash_count) |i| {
            commitments[i] = create_test_commitment(i);
            versioned_hashes[i] = blob_types.VersionedHash.compute_versioned_hash(&commitments[i]);
        }

        var total_time: u64 = 0;

        const start_time = timing.nanoTimestamp();

        for (0..iterations) |_| {
            // Validate each versioned hash against its commitment
            for (commitments, versioned_hashes) |*commitment, *versioned_hash| {
                _ = blob_types.validate_commitment_hash(commitment, versioned_hash);
            }
        }

        const end_time = timing.nanoTimestamp();
        total_time = end_time - start_time;

        const avg_time = total_time / iterations;
        const throughput = @as(f64, @floatFromInt(hash_count * iterations * 1000000000)) / @as(f64, @floatFromInt(total_time));

        std.log.info("  {} hashes: {d:.2f}ns avg per iteration, {d:.2f} validations/sec", .{
            hash_count,
            @as(f64, @floatFromInt(avg_time)),
            throughput,
        });
    }
}

/// Benchmark blob data handling and serialization
pub fn blob_data_handling_benchmark(allocator: std.mem.Allocator) !void {
    std.log.info("=== Blob Data Handling and Serialization Benchmark ===", .{});

    const blob_counts = [_]u32{ 1, 2, 3, 6 };
    const iterations = 1000;

    for (blob_counts) |blob_count| {
        var total_creation_time: u64 = 0;
        var total_validation_time: u64 = 0;
        var total_serialization_time: u64 = 0;

        for (0..iterations) |_| {
            // Benchmark blob transaction creation
            const start_creation = timing.nanoTimestamp();

            var transaction = BlobTransaction.init(allocator);
            defer transaction.deinit();

            // Create test blob sidecar
            var blobs = try allocator.alloc(blob_types.Blob, blob_count);
            defer allocator.free(blobs);

            var commitments = try allocator.alloc(blob_types.KZGCommitment, blob_count);
            defer allocator.free(commitments);

            var proofs = try allocator.alloc(blob_types.KZGProof, blob_count);
            defer allocator.free(proofs);

            for (0..blob_count) |i| {
                blobs[i] = create_test_blob(i);
                commitments[i] = create_test_commitment(i);
                proofs[i] = create_test_proof(i);
            }

            try transaction.set_blob_sidecar(blobs, commitments, proofs);
            try transaction.set_versioned_hashes_from_commitments(commitments);

            const end_creation = timing.nanoTimestamp();
            total_creation_time += end_creation - start_creation;

            // Benchmark validation
            const start_validation = timing.nanoTimestamp();

            const current_blob_base_fee: u256 = 1000000;
            transaction.validate(current_blob_base_fee) catch {};

            const end_validation = timing.nanoTimestamp();
            total_validation_time += end_validation - start_validation;

            // Benchmark serialization
            const start_serialization = timing.nanoTimestamp();

            const encoded = transaction.encode_for_signing() catch continue;
            defer allocator.free(encoded);

            const end_serialization = timing.nanoTimestamp();
            total_serialization_time += end_serialization - start_serialization;
        }

        const avg_creation = total_creation_time / iterations;
        const avg_validation = total_validation_time / iterations;
        const avg_serialization = total_serialization_time / iterations;

        std.log.info("  {} blobs:", .{blob_count});
        std.log.info("    Creation: {d:.2f}μs avg", .{@as(f64, @floatFromInt(avg_creation)) / 1000.0});
        std.log.info("    Validation: {d:.2f}μs avg", .{@as(f64, @floatFromInt(avg_validation)) / 1000.0});
        std.log.info("    Serialization: {d:.2f}μs avg", .{@as(f64, @floatFromInt(avg_serialization)) / 1000.0});
    }
}

/// Comprehensive blob transaction throughput benchmark
pub fn blob_transaction_throughput_benchmark(allocator: std.mem.Allocator) !void {
    std.log.info("=== Blob Transaction Throughput Benchmark ===", .{});

    const iterations = 1000;
    const blob_count: u32 = 3; // Average case

    var total_time: u64 = 0;

    const start_time = timing.nanoTimestamp();

    for (0..iterations) |i| {
        var transaction = BlobTransaction.init(allocator);
        defer transaction.deinit();

        // Set transaction parameters
        transaction.chain_id = 1;
        transaction.nonce = i;
        transaction.max_fee_per_gas = 20000000000;
        transaction.max_priority_fee_per_gas = 2000000000;
        transaction.gas_limit = 21000;
        transaction.to = create_test_address(i);
        transaction.value = 1000000000000000000; // 1 ETH
        transaction.max_fee_per_blob_gas = 5000000;

        // Create and set blob sidecar
        var blobs = try allocator.alloc(blob_types.Blob, blob_count);
        defer allocator.free(blobs);

        var commitments = try allocator.alloc(blob_types.KZGCommitment, blob_count);
        defer allocator.free(commitments);

        var proofs = try allocator.alloc(blob_types.KZGProof, blob_count);
        defer allocator.free(proofs);

        for (0..blob_count) |j| {
            blobs[j] = create_test_blob(i + j);
            commitments[j] = create_test_commitment(i + j);
            proofs[j] = create_test_proof(i + j);
        }

        try transaction.set_blob_sidecar(blobs, commitments, proofs);
        try transaction.set_versioned_hashes_from_commitments(commitments);

        // Validate and process transaction
        const current_blob_base_fee: u256 = 2000000;
        _ = transaction.validate(current_blob_base_fee) catch false;
        _ = transaction.get_blob_gas_used();
        _ = transaction.calculate_blob_fee(current_blob_base_fee);
        _ = transaction.hash() catch continue;

        // Prevent optimization
        std.mem.doNotOptimizeAway(&transaction);
    }

    const end_time = timing.nanoTimestamp();
    total_time = end_time - start_time;

    const avg_time = total_time / iterations;
    const throughput = @as(f64, @floatFromInt(iterations * 1000000000)) / @as(f64, @floatFromInt(total_time));

    std.log.info("  {} transactions processed", .{iterations});
    std.log.info("  Average time per transaction: {d:.2f}μs", .{@as(f64, @floatFromInt(avg_time)) / 1000.0});
    std.log.info("  Throughput: {d:.2f} transactions/sec", .{throughput});
}

// Helper functions to create test data
fn create_test_blob(seed: usize) blob_types.Blob {
    var blob: blob_types.Blob = undefined;

    // Fill with deterministic test data
    var prng = std.Random.DefaultPrng.init(@intCast(seed));
    const random = prng.random();

    for (0..blob_types.FIELD_ELEMENTS_PER_BLOB) |i| {
        // Each field element is 32 bytes
        for (0..32) |j| {
            blob.data[i * 32 + j] = random.int(u8);
        }
    }

    return blob;
}

fn create_test_commitment(seed: usize) blob_types.KZGCommitment {
    var commitment: blob_types.KZGCommitment = undefined;

    // Fill with deterministic test data
    var prng = std.Random.DefaultPrng.init(@intCast(seed));
    const random = prng.random();

    for (0..commitment.bytes.len) |i| {
        commitment.bytes[i] = random.int(u8);
    }

    return commitment;
}

fn create_test_proof(seed: usize) blob_types.KZGProof {
    var proof: blob_types.KZGProof = undefined;

    // Fill with deterministic test data
    var prng = std.Random.DefaultPrng.init(@intCast(seed));
    const random = prng.random();

    for (0..proof.bytes.len) |i| {
        proof.bytes[i] = random.int(u8);
    }

    return proof;
}

fn create_test_address(seed: usize) primitives.Address.Address {
    var address: primitives.Address.Address = undefined;

    // Fill with deterministic test data
    var prng = std.Random.DefaultPrng.init(@intCast(seed));
    const random = prng.random();

    for (0..address.len) |i| {
        address[i] = random.int(u8);
    }

    return address;
}

// Tests to ensure benchmark functions compile
test "blob benchmark compilation" {
    // Test that all benchmark functions compile
    _ = kzg_verification_benchmark;
    _ = blob_gas_market_benchmark;
    _ = versioned_hash_benchmark;
    _ = blob_data_handling_benchmark;
    _ = blob_transaction_throughput_benchmark;

    // Test helper functions
    const test_blob = create_test_blob(42);
    _ = test_blob;

    const test_commitment = create_test_commitment(42);
    _ = test_commitment;

    const test_proof = create_test_proof(42);
    _ = test_proof;

    const test_address = create_test_address(42);
    _ = test_address;
}
