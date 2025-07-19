const std = @import("std");
const root = @import("root.zig");
const timing = @import("timing.zig");
const Evm = root.Evm;
const primitives = root.primitives;

// Transaction related imports
const BlobTransaction = Evm.transaction.BlobTransaction;
const BlobTransactionValidator = Evm.transaction.BlobTransactionValidator;
const blob_types = Evm.blob.blob_types;
const blob_gas_market = Evm.blob.blob_gas_market;
const AccessList = Evm.access_list.AccessList;
const Context = Evm.access_list.Context;

/// Transaction type constants for benchmarking
pub const LEGACY_TX_TYPE = 0x00;
pub const ACCESS_LIST_TX_TYPE = 0x01;
pub const EIP1559_TX_TYPE = 0x02;
pub const BLOB_TX_TYPE = 0x03;

/// Benchmark transaction type detection performance
pub fn transaction_type_detection_benchmark(allocator: std.mem.Allocator) !void {
    _ = allocator;
    std.log.info("=== Transaction Type Detection Benchmark ===", .{});

    const tx_types = [_]u8{ LEGACY_TX_TYPE, ACCESS_LIST_TX_TYPE, EIP1559_TX_TYPE, BLOB_TX_TYPE };
    const iterations = 100000;

    var total_time: u64 = 0;

    const start_time = timing.nanoTimestamp();

    for (0..iterations) |_| {
        for (tx_types) |tx_type| {
            // Simulate type detection logic
            const detected_type = detect_transaction_type(tx_type);
            std.mem.doNotOptimizeAway(detected_type);
        }
    }

    const end_time = timing.nanoTimestamp();
    total_time = end_time - start_time;

    const total_detections = iterations * tx_types.len;
    const avg_time = total_time / total_detections;
    const throughput = @as(f64, @floatFromInt(total_detections * 1000000000)) / @as(f64, @floatFromInt(total_time));

    std.log.info("  {} type detections completed", .{total_detections});
    std.log.info("  Average detection time: {d:.2f}ns", .{@as(f64, @floatFromInt(avg_time))});
    std.log.info("  Throughput: {d:.2f} detections/sec", .{throughput});
}

/// Benchmark blob transaction parsing performance
pub fn blob_transaction_parsing_benchmark(allocator: std.mem.Allocator) !void {
    std.log.info("=== Blob Transaction Parsing Benchmark ===", .{});

    const blob_counts = [_]u32{ 1, 2, 3, 6 };
    const iterations = 1000;

    for (blob_counts) |blob_count| {
        std.log.info("Benchmarking parsing with {} blobs", .{blob_count});

        var total_time: u64 = 0;

        const start_time = timing.nanoTimestamp();

        for (0..iterations) |i| {
            // Create a transaction to parse
            var transaction = BlobTransaction.init(allocator);
            defer transaction.deinit();

            // Simulate filling transaction fields (parsing)
            transaction.chain_id = 1;
            transaction.nonce = i;
            transaction.max_fee_per_gas = 20000000000;
            transaction.max_priority_fee_per_gas = 2000000000;
            transaction.gas_limit = 21000;
            transaction.to = create_test_address(i);
            transaction.value = 1000000000000000000;
            transaction.max_fee_per_blob_gas = 5000000;

            // Create blob sidecar data
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

            // Set blob sidecar (parsing step)
            try transaction.set_blob_sidecar(blobs, commitments, proofs);
            try transaction.set_versioned_hashes_from_commitments(commitments);

            // Simulate additional parsing steps
            _ = transaction.get_blob_count();
            _ = transaction.get_blob_gas_used();
            _ = transaction.has_valid_sidecar();

            std.mem.doNotOptimizeAway(&transaction);
        }

        const end_time = timing.nanoTimestamp();
        total_time = end_time - start_time;

        const avg_time = total_time / iterations;
        const throughput = @as(f64, @floatFromInt(iterations * 1000000000)) / @as(f64, @floatFromInt(total_time));

        std.log.info("  {} blobs: {d:.2f}μs avg, {d:.2f} parses/sec", .{
            blob_count,
            @as(f64, @floatFromInt(avg_time)) / 1000.0,
            throughput,
        });
    }
}

/// Benchmark transaction validation performance
pub fn transaction_validation_benchmark(allocator: std.mem.Allocator) !void {
    std.log.info("=== Transaction Validation Benchmark ===", .{});

    const validation_scenarios = [_]struct {
        name: []const u8,
        blob_count: u32,
        should_pass: bool,
        blob_base_fee: u256,
        max_blob_fee: u256,
    }{
        .{ .name = "Valid 1 blob", .blob_count = 1, .should_pass = true, .blob_base_fee = 1000000, .max_blob_fee = 5000000 },
        .{ .name = "Valid 3 blobs", .blob_count = 3, .should_pass = true, .blob_base_fee = 2000000, .max_blob_fee = 10000000 },
        .{ .name = "Valid max blobs", .blob_count = 6, .should_pass = true, .blob_base_fee = 3000000, .max_blob_fee = 15000000 },
        .{ .name = "Invalid blob count", .blob_count = 7, .should_pass = false, .blob_base_fee = 1000000, .max_blob_fee = 5000000 },
        .{ .name = "Insufficient fee", .blob_count = 2, .should_pass = false, .blob_base_fee = 10000000, .max_blob_fee = 5000000 },
    };

    const iterations = 1000;

    for (validation_scenarios) |scenario| {
        std.log.info("Benchmarking validation: {s}", .{scenario.name});

        var successful_validations: u32 = 0;
        var total_time: u64 = 0;

        const start_time = timing.nanoTimestamp();

        for (0..iterations) |i| {
            var transaction = BlobTransaction.init(allocator);
            defer transaction.deinit();

            // Set up transaction
            transaction.chain_id = 1;
            transaction.nonce = i;
            transaction.max_fee_per_gas = 20000000000;
            transaction.max_priority_fee_per_gas = 2000000000;
            transaction.gas_limit = 21000;
            transaction.to = create_test_address(i);
            transaction.value = 1000000000000000000;
            transaction.max_fee_per_blob_gas = scenario.max_blob_fee;

            if (scenario.blob_count <= blob_types.MAX_BLOBS_PER_TRANSACTION) {
                // Create blob sidecar data
                var blobs = try allocator.alloc(blob_types.Blob, scenario.blob_count);
                defer allocator.free(blobs);

                var commitments = try allocator.alloc(blob_types.KZGCommitment, scenario.blob_count);
                defer allocator.free(commitments);

                var proofs = try allocator.alloc(blob_types.KZGProof, scenario.blob_count);
                defer allocator.free(proofs);

                for (0..scenario.blob_count) |j| {
                    blobs[j] = create_test_blob(i + j);
                    commitments[j] = create_test_commitment(i + j);
                    proofs[j] = create_test_proof(i + j);
                }

                try transaction.set_blob_sidecar(blobs, commitments, proofs);
                try transaction.set_versioned_hashes_from_commitments(commitments);
            } else {
                // Create invalid versioned hashes for blob count > MAX
                var versioned_hashes = try allocator.alloc(blob_types.VersionedHash, scenario.blob_count);
                defer allocator.free(versioned_hashes);

                for (0..scenario.blob_count) |j| {
                    const commitment = create_test_commitment(i + j);
                    versioned_hashes[j] = blob_types.VersionedHash.compute_versioned_hash(&commitment);
                }

                // This will be cleaned up by deinit
                if (transaction.blob_versioned_hashes.len > 0) {
                    allocator.free(transaction.blob_versioned_hashes);
                }
                transaction.blob_versioned_hashes = versioned_hashes;
            }

            // Validate transaction
            const validation_result = transaction.validate(scenario.blob_base_fee);
            if (validation_result) |_| {
                if (scenario.should_pass) {
                    successful_validations += 1;
                }
            } else |_| {
                if (!scenario.should_pass) {
                    successful_validations += 1;
                }
            }

            std.mem.doNotOptimizeAway(&transaction);
        }

        const end_time = timing.nanoTimestamp();
        total_time = end_time - start_time;

        const avg_time = total_time / iterations;
        const throughput = @as(f64, @floatFromInt(iterations * 1000000000)) / @as(f64, @floatFromInt(total_time));
        const success_rate = @as(f64, @floatFromInt(successful_validations)) / @as(f64, @floatFromInt(iterations)) * 100.0;

        std.log.info("  {s}:", .{scenario.name});
        std.log.info("    Average validation time: {d:.2f}μs", .{@as(f64, @floatFromInt(avg_time)) / 1000.0});
        std.log.info("    Throughput: {d:.2f} validations/sec", .{throughput});
        std.log.info("    Success rate: {d:.1f}%", .{success_rate});
    }
}

/// Benchmark block-level transaction validation
pub fn block_validation_benchmark(allocator: std.mem.Allocator) !void {
    std.log.info("=== Block-level Transaction Validation Benchmark ===", .{});

    const block_scenarios = [_]struct {
        name: []const u8,
        transaction_count: u32,
        avg_blob_count: u32,
    }{
        .{ .name = "Small block", .transaction_count = 10, .avg_blob_count = 2 },
        .{ .name = "Medium block", .transaction_count = 50, .avg_blob_count = 3 },
        .{ .name = "Large block", .transaction_count = 100, .avg_blob_count = 2 },
        .{ .name = "Max blob block", .transaction_count = 20, .avg_blob_count = 6 },
    };

    const iterations = 10;

    for (block_scenarios) |scenario| {
        std.log.info("Benchmarking block validation: {s}", .{scenario.name});

        var total_time: u64 = 0;
        var total_transactions_processed: u32 = 0;

        const start_time = timing.nanoTimestamp();

        for (0..iterations) |block_num| {
            var current_block_blob_gas: u64 = 0;
            const current_blob_base_fee: u256 = 2000000 + @as(u256, @intCast(block_num)) * 100000;

            // Process transactions in the block
            for (0..scenario.transaction_count) |tx_idx| {
                var transaction = BlobTransaction.init(allocator);
                defer transaction.deinit();

                // Set up transaction
                transaction.chain_id = 1;
                transaction.nonce = tx_idx;
                transaction.max_fee_per_gas = 20000000000;
                transaction.max_priority_fee_per_gas = 2000000000;
                transaction.gas_limit = 21000;
                transaction.to = create_test_address(tx_idx);
                transaction.value = 1000000000000000000;
                transaction.max_fee_per_blob_gas = current_blob_base_fee + 1000000;

                const blob_count = scenario.avg_blob_count;

                // Create blob data
                var blobs = try allocator.alloc(blob_types.Blob, blob_count);
                defer allocator.free(blobs);

                var commitments = try allocator.alloc(blob_types.KZGCommitment, blob_count);
                defer allocator.free(commitments);

                var proofs = try allocator.alloc(blob_types.KZGProof, blob_count);
                defer allocator.free(proofs);

                for (0..blob_count) |j| {
                    blobs[j] = create_test_blob(tx_idx + j);
                    commitments[j] = create_test_commitment(tx_idx + j);
                    proofs[j] = create_test_proof(tx_idx + j);
                }

                try transaction.set_blob_sidecar(blobs, commitments, proofs);
                try transaction.set_versioned_hashes_from_commitments(commitments);

                // Validate for block inclusion
                const validation_result = BlobTransactionValidator.validate_for_block(
                    &transaction,
                    current_blob_base_fee,
                    current_block_blob_gas,
                );

                if (validation_result) |_| {
                    current_block_blob_gas += transaction.get_blob_gas_used();
                    total_transactions_processed += 1;
                } else |_| {
                    // Transaction rejected
                }

                std.mem.doNotOptimizeAway(&transaction);
            }
        }

        const end_time = timing.nanoTimestamp();
        total_time = end_time - start_time;

        const total_tx_attempts = iterations * scenario.transaction_count;
        const avg_time_per_block = total_time / iterations;
        const avg_time_per_tx = total_time / total_tx_attempts;
        const block_throughput = @as(f64, @floatFromInt(iterations * 1000000000)) / @as(f64, @floatFromInt(total_time));
        const tx_throughput = @as(f64, @floatFromInt(total_tx_attempts * 1000000000)) / @as(f64, @floatFromInt(total_time));
        const success_rate = @as(f64, @floatFromInt(total_transactions_processed)) / @as(f64, @floatFromInt(total_tx_attempts)) * 100.0;

        std.log.info("  {s}:", .{scenario.name});
        std.log.info("    Average block validation time: {d:.2f}ms", .{@as(f64, @floatFromInt(avg_time_per_block)) / 1000000.0});
        std.log.info("    Average transaction validation time: {d:.2f}μs", .{@as(f64, @floatFromInt(avg_time_per_tx)) / 1000.0});
        std.log.info("    Block throughput: {d:.2f} blocks/sec", .{block_throughput});
        std.log.info("    Transaction throughput: {d:.2f} tx/sec", .{tx_throughput});
        std.log.info("    Transaction success rate: {d:.1f}%", .{success_rate});
    }
}

/// Benchmark gas price calculations for different transaction types
pub fn gas_price_calculations_benchmark(allocator: std.mem.Allocator) !void {
    _ = allocator;
    std.log.info("=== Gas Price Calculations Benchmark ===", .{});

    const price_scenarios = [_]struct {
        name: []const u8,
        blob_count: u32,
        base_fee: u256,
        blob_base_fee: u256,
    }{
        .{ .name = "Low fees", .blob_count = 2, .base_fee = 1000000000, .blob_base_fee = 1000000 },
        .{ .name = "Medium fees", .blob_count = 3, .base_fee = 20000000000, .blob_base_fee = 5000000 },
        .{ .name = "High fees", .blob_count = 4, .base_fee = 50000000000, .blob_base_fee = 20000000 },
        .{ .name = "Very high fees", .blob_count = 6, .base_fee = 100000000000, .blob_base_fee = 100000000 },
    };

    const iterations = 50000;

    for (price_scenarios) |scenario| {
        std.log.info("Benchmarking gas price calculations: {s}", .{scenario.name});

        var total_time: u64 = 0;
        var total_blob_fee: u256 = 0;
        var total_blob_gas: u64 = 0;

        const start_time = timing.nanoTimestamp();

        for (0..iterations) |_| {
            // Calculate blob gas used
            const blob_gas_used = blob_gas_market.BlobGasMarket.calculate_blob_gas_used(scenario.blob_count);
            total_blob_gas += blob_gas_used;

            // Calculate blob fee
            const blob_fee = blob_gas_market.BlobGasMarket.calculate_blob_fee(scenario.blob_count, scenario.blob_base_fee);
            total_blob_fee += blob_fee;

            // Validate blob gas limit
            _ = blob_gas_market.BlobGasMarket.validate_blob_gas_limit(scenario.blob_count);

            // Validate fee affordability
            const max_fee = scenario.blob_base_fee + 2000000;
            _ = blob_gas_market.BlobGasMarket.validate_blob_fee_affordability(max_fee, scenario.blob_base_fee);

            // Simulate additional gas calculations
            const priority_fee: u256 = 2000000000;
            const max_fee_per_gas = scenario.base_fee + priority_fee;
            const gas_limit: u64 = 21000;
            const total_gas_fee = max_fee_per_gas * gas_limit;

            // Prevent optimization
            std.mem.doNotOptimizeAway(total_gas_fee);
        }

        const end_time = timing.nanoTimestamp();
        total_time = end_time - start_time;

        const avg_time = total_time / iterations;
        const throughput = @as(f64, @floatFromInt(iterations * 1000000000)) / @as(f64, @floatFromInt(total_time));
        const avg_blob_fee = total_blob_fee / iterations;
        const avg_blob_gas = total_blob_gas / iterations;

        std.log.info("  {s}:", .{scenario.name});
        std.log.info("    Average calculation time: {d:.2f}ns", .{@as(f64, @floatFromInt(avg_time))});
        std.log.info("    Throughput: {d:.2f} calculations/sec", .{throughput});
        std.log.info("    Average blob fee: {} wei", .{avg_blob_fee});
        std.log.info("    Average blob gas: {} gas", .{avg_blob_gas});
    }
}

// Helper functions
fn detect_transaction_type(tx_type: u8) u8 {
    return switch (tx_type) {
        LEGACY_TX_TYPE => LEGACY_TX_TYPE,
        ACCESS_LIST_TX_TYPE => ACCESS_LIST_TX_TYPE,
        EIP1559_TX_TYPE => EIP1559_TX_TYPE,
        BLOB_TX_TYPE => BLOB_TX_TYPE,
        else => LEGACY_TX_TYPE, // Default fallback
    };
}

fn create_test_address(seed: usize) primitives.Address.Address {
    var address: primitives.Address.Address = undefined;
    var prng = std.Random.DefaultPrng.init(@intCast(seed));
    const random = prng.random();

    for (0..address.len) |i| {
        address[i] = random.int(u8);
    }

    return address;
}

fn create_test_blob(seed: usize) blob_types.Blob {
    var blob: blob_types.Blob = undefined;
    var prng = std.Random.DefaultPrng.init(@intCast(seed));
    const random = prng.random();

    for (0..blob_types.FIELD_ELEMENTS_PER_BLOB) |i| {
        for (0..32) |j| {
            blob.data[i * 32 + j] = random.int(u8);
        }
    }

    return blob;
}

fn create_test_commitment(seed: usize) blob_types.KZGCommitment {
    var commitment: blob_types.KZGCommitment = undefined;
    var prng = std.Random.DefaultPrng.init(@intCast(seed));
    const random = prng.random();

    for (0..commitment.bytes.len) |i| {
        commitment.bytes[i] = random.int(u8);
    }

    return commitment;
}

fn create_test_proof(seed: usize) blob_types.KZGProof {
    var proof: blob_types.KZGProof = undefined;
    var prng = std.Random.DefaultPrng.init(@intCast(seed));
    const random = prng.random();

    for (0..proof.bytes.len) |i| {
        proof.bytes[i] = random.int(u8);
    }

    return proof;
}

// Tests to ensure benchmark functions compile
test "transaction benchmark compilation" {
    const allocator = std.testing.allocator;

    // Test that all benchmark functions compile
    _ = transaction_type_detection_benchmark;
    _ = blob_transaction_parsing_benchmark;
    _ = transaction_validation_benchmark;
    _ = block_validation_benchmark;
    _ = gas_price_calculations_benchmark;

    // Test helper functions
    const detected_type = detect_transaction_type(BLOB_TX_TYPE);
    try std.testing.expectEqual(BLOB_TX_TYPE, detected_type);

    const test_address = create_test_address(42);
    _ = test_address;

    const test_blob = create_test_blob(42);
    _ = test_blob;

    const test_commitment = create_test_commitment(42);
    _ = test_commitment;

    const test_proof = create_test_proof(42);
    _ = test_proof;
}