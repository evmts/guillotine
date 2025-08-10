const std = @import("std");
const root = @import("root.zig");
const Evm = root.Evm;
const primitives = root.primitives;
const Allocator = std.mem.Allocator;

/// Simple EIP-4844 Related Benchmarks
///
/// Using only basic functionality that we know exists from examples
pub fn transaction_type_benchmark(allocator: Allocator) void {
    transaction_type_benchmark_impl(allocator) catch |err| {
        std.log.err("Transaction type benchmark failed: {}", .{err});
    };
}

fn transaction_type_benchmark_impl(allocator: Allocator) !void {
    _ = allocator;

    // Create test transaction data for different types based on EIP-4844
    const legacy_tx_data = &[_]u8{ 0x60, 0x80, 0x60, 0x40, 0x52 };
    const eip1559_tx_data = &[_]u8{ 0x02, 0xf8, 0x6f };
    const eip2930_tx_data = &[_]u8{ 0x01, 0xf8, 0x6f };
    const eip4844_tx_data = &[_]u8{ 0x03, 0xf8, 0x6f };

    const test_data = [_][]const u8{
        legacy_tx_data,
        eip1559_tx_data,
        eip2930_tx_data,
        eip4844_tx_data,
    };

    // Benchmark transaction type detection
    for (0..2000) |_| {
        for (test_data) |tx_data| {
            const tx_type = primitives.Transaction.detect_transaction_type(tx_data);
            std.mem.doNotOptimizeAway(tx_type);
        }
    }
}

pub fn address_creation_benchmark(allocator: Allocator) void {
    address_creation_benchmark_impl(allocator) catch |err| {
        std.log.err("Address creation benchmark failed: {}", .{err});
    };
}

fn address_creation_benchmark_impl(allocator: Allocator) !void {
    _ = allocator;

    // Benchmark address creation and conversion
    for (0..1000) |i| {
        const addr1 = primitives.Address.from_u256(@as(u256, 0x1000 + i));
        const addr2 = primitives.Address.from_u256(@as(u256, 0x2000 + i));

        // Convert back to u256
        const val1 = primitives.Address.to_u256(addr1);
        const val2 = primitives.Address.to_u256(addr2);
        std.mem.doNotOptimizeAway(val1);
        std.mem.doNotOptimizeAway(val2);

        // Test zero address
        const zero_addr = primitives.Address.ZERO;
        const zero_val = primitives.Address.to_u256(zero_addr);
        std.mem.doNotOptimizeAway(zero_val);
    }
}

pub fn gas_calculation_eip4844_benchmark(allocator: Allocator) void {
    gas_calculation_eip4844_benchmark_impl(allocator) catch |err| {
        std.log.err("EIP-4844 gas calculation benchmark failed: {}", .{err});
    };
}

fn gas_calculation_eip4844_benchmark_impl(allocator: Allocator) !void {
    _ = allocator;

    // EIP-4844 specific gas calculations
    const base_fees = [_]u64{ 10, 50, 100, 200, 500, 1000 }; // gwei
    const priority_fees = [_]u64{ 1, 2, 5, 10, 50 }; // gwei
    const blob_base_fees = [_]u64{ 1, 10, 100, 1000 }; // wei

    // Standard EIP-1559 calculations
    for (base_fees) |base_fee| {
        for (priority_fees) |priority_fee| {
            const max_fee = base_fee + priority_fee + 10;
            const effective_price = @min(max_fee, base_fee + priority_fee);
            const gas_cost = effective_price * 21000;
            std.mem.doNotOptimizeAway(gas_cost);
        }
    }

    // EIP-4844 blob gas calculations
    for (blob_base_fees) |blob_base_fee| {
        const max_blob_fee = blob_base_fee * 2;
        const blob_fee = @min(max_blob_fee, blob_base_fee);

        // Use EIP-4844 constants
        const gas_per_blob = 131072; // Standard value
        const max_blobs_per_tx = 6; // Standard value
        const total_blob_cost = blob_fee * gas_per_blob * max_blobs_per_tx;
        std.mem.doNotOptimizeAway(total_blob_cost);
    }
}

pub fn data_structure_benchmark(allocator: Allocator) void {
    data_structure_benchmark_impl(allocator) catch |err| {
        std.log.err("Data structure benchmark failed: {}", .{err});
    };
}

fn data_structure_benchmark_impl(allocator: Allocator) !void {
    // Benchmark working with large data structures similar to blob data
    var large_data = try allocator.alloc(u8, 131072); // Size of a blob
    defer allocator.free(large_data);

    // Fill with pattern
    for (large_data, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    // Benchmark operations on blob-sized data
    for (0..100) |_| {
        var checksum: u32 = 0;
        for (large_data) |byte| {
            checksum = checksum +% byte;
        }
        std.mem.doNotOptimizeAway(checksum);

        // Simulate field element operations (32-byte chunks)
        var field_checksum: u64 = 0;
        var i: usize = 0;
        while (i < large_data.len) : (i += 32) {
            const chunk_end = @min(i + 32, large_data.len);
            for (large_data[i..chunk_end]) |byte| {
                field_checksum = field_checksum +% @as(u64, byte);
            }
        }
        std.mem.doNotOptimizeAway(field_checksum);
    }
}

pub fn hash_operations_benchmark(allocator: Allocator) void {
    hash_operations_benchmark_impl(allocator) catch |err| {
        std.log.err("Hash operations benchmark failed: {}", .{err});
    };
}

fn hash_operations_benchmark_impl(allocator: Allocator) !void {
    _ = allocator;

    // Benchmark hash-like operations (simulating versioned hashes)
    for (0..1000) |i| {
        // Create test data similar to KZG commitments (48 bytes)
        var commitment_data: [48]u8 = undefined;
        for (&commitment_data, 0..) |*byte, j| {
            byte.* = @intCast((i + j) % 256);
        }

        // Simulate versioned hash creation (first byte is version)
        var versioned_hash: [32]u8 = undefined;
        versioned_hash[0] = 0x01; // Version byte for EIP-4844

        // Simple hash simulation (not cryptographic)
        for (commitment_data, 1..) |byte, j| {
            if (j < 32) {
                versioned_hash[j] = byte ^ @as(u8, @intCast(j));
            }
        }

        std.mem.doNotOptimizeAway(versioned_hash);
    }
}

pub fn constants_access_benchmark(allocator: Allocator) void {
    constants_access_benchmark_impl(allocator) catch |err| {
        std.log.err("Constants access benchmark failed: {}", .{err});
    };
}

fn constants_access_benchmark_impl(allocator: Allocator) !void {
    _ = allocator;

    // Benchmark accessing EIP-4844 related constants
    for (0..10000) |_| {
        // EIP-4844 constants
        const bytes_per_blob = 131072;
        const field_elements_per_blob = 4096;
        const gas_per_blob = 131072;
        const max_blobs_per_transaction = 6;
        const target_blob_gas_per_block = 393216;
        const max_blob_gas_per_block = 786432;
        const blob_base_fee_update_fraction = 3338477;
        const min_blob_gasprice = 1;

        std.mem.doNotOptimizeAway(bytes_per_blob);
        std.mem.doNotOptimizeAway(field_elements_per_blob);
        std.mem.doNotOptimizeAway(gas_per_blob);
        std.mem.doNotOptimizeAway(max_blobs_per_transaction);
        std.mem.doNotOptimizeAway(target_blob_gas_per_block);
        std.mem.doNotOptimizeAway(max_blob_gas_per_block);
        std.mem.doNotOptimizeAway(blob_base_fee_update_fraction);
        std.mem.doNotOptimizeAway(min_blob_gasprice);
    }
}

test "simple EIP-4844 benchmarks compile and execute" {
    const allocator = std.testing.allocator;

    // Basic compilation and execution test
    transaction_type_benchmark(allocator);
    address_creation_benchmark(allocator);
    gas_calculation_eip4844_benchmark(allocator);
    data_structure_benchmark(allocator);
    hash_operations_benchmark(allocator);
    constants_access_benchmark(allocator);
}
