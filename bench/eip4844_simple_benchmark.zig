const std = @import("std");
const root = @import("root.zig");
const Evm = root.Evm;
const primitives = root.primitives;
const Allocator = std.mem.Allocator;

/// Simplified EIP-4844 Blob Transaction Benchmarks
///
/// Measures performance of core blob and access list operations
/// that are available and working in the current implementation.
pub fn blob_gas_market_simple_benchmark(allocator: Allocator) void {
    blob_gas_market_simple_benchmark_impl(allocator) catch |err| {
        std.log.err("Simple blob gas market benchmark failed: {}", .{err});
    };
}

fn blob_gas_market_simple_benchmark_impl(allocator: Allocator) !void {
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

pub fn blob_data_creation_benchmark(allocator: Allocator) void {
    blob_data_creation_benchmark_impl(allocator) catch |err| {
        std.log.err("Blob data creation benchmark failed: {}", .{err});
    };
}

fn blob_data_creation_benchmark_impl(allocator: Allocator) !void {
    _ = allocator;

    // Benchmark blob data structure creation and manipulation
    for (0..100) |blob_idx| {
        var blob = Evm.blob.Blob{};

        // Fill blob with test data pattern
        for (0..Evm.blob.FIELD_ELEMENTS_PER_BLOB) |field_idx| {
            const value = (@as(u32, @intCast(blob_idx)) << 16) | @as(u32, @intCast(field_idx));
            for (0..31) |byte_idx| {
                blob.data[field_idx * 32 + byte_idx] = @intCast((value + @as(u32, @intCast(byte_idx))) % 256);
            }
        }

        // Simulate basic blob validation (size checks, etc.)
        const blob_size = blob.data.len;
        std.mem.doNotOptimizeAway(blob_size);

        // Calculate simple checksum
        var checksum: u32 = 0;
        for (blob.data) |byte| {
            checksum = checksum +% byte;
        }
        std.mem.doNotOptimizeAway(checksum);
    }
}

pub fn versioned_hash_simple_benchmark(allocator: Allocator) void {
    versioned_hash_simple_benchmark_impl(allocator) catch |err| {
        std.log.err("Versioned hash simple benchmark failed: {}", .{err});
    };
}

fn versioned_hash_simple_benchmark_impl(allocator: Allocator) !void {
    _ = allocator;

    // Create test commitment data
    var commitment_data: [48]u8 = undefined;
    for (&commitment_data, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    // Benchmark versioned hash operations
    for (0..1000) |_| {
        const versioned_hash = Evm.blob.blob_types.commitment_to_versioned_hash(&commitment_data);
        std.mem.doNotOptimizeAway(versioned_hash.hash);

        // Validate hash format
        const is_valid = Evm.blob.validate_commitment_hash(&commitment_data, &versioned_hash.hash);
        std.mem.doNotOptimizeAway(is_valid);
    }
}

pub fn access_list_integration_benchmark(allocator: Allocator) void {
    access_list_integration_benchmark_impl(allocator) catch |err| {
        std.log.err("Access list integration benchmark failed: {}", .{err});
    };
}

fn access_list_integration_benchmark_impl(allocator: Allocator) !void {
    // Create context for access list
    const context = Evm.access_list.Context{
        .caller = primitives.Address.from_u256(0x1111),
        .tx_origin = primitives.Address.from_u256(0x1111),
        .coinbase = primitives.Address.from_u256(0x2222),
        .contract_address = primitives.Address.from_u256(0x3333),
    };

    var access_list = Evm.access_list.AccessList.init(allocator, context);
    defer access_list.deinit();

    // Benchmark integration between blob transactions and access lists
    for (0..500) |i| {
        const addr = primitives.Address.from_u256(@as(u256, 0x10000 + i));
        const slot = @as(u256, i * 7919);

        // Access address (simulating blob transaction touching contracts)
        const addr_cost = try access_list.access_address(addr);
        std.mem.doNotOptimizeAway(addr_cost);

        // Access storage (simulating blob data retrieval)
        const storage_cost = try access_list.access_storage_slot(addr, slot);
        std.mem.doNotOptimizeAway(storage_cost);

        // Check if warm
        if (i % 10 == 0) {
            const is_addr_warm = access_list.is_address_warm(addr);
            const is_storage_warm = access_list.is_storage_slot_warm(addr, slot);
            std.mem.doNotOptimizeAway(is_addr_warm);
            std.mem.doNotOptimizeAway(is_storage_warm);
        }
    }
}

pub fn transaction_type_detection_simple_benchmark(allocator: Allocator) void {
    transaction_type_detection_simple_benchmark_impl(allocator) catch |err| {
        std.log.err("Transaction type detection simple benchmark failed: {}", .{err});
    };
}

fn transaction_type_detection_simple_benchmark_impl(allocator: Allocator) !void {
    _ = allocator;

    // Create test transaction data for different types
    const legacy_tx_data = &[_]u8{ 0x60, 0x80, 0x60, 0x40, 0x52 }; // Simple legacy transaction
    const eip1559_tx_data = &[_]u8{ 0x02, 0xf8, 0x6f }; // EIP-1559 transaction prefix
    const eip2930_tx_data = &[_]u8{ 0x01, 0xf8, 0x6f }; // EIP-2930 transaction prefix
    const eip4844_tx_data = &[_]u8{ 0x03, 0xf8, 0x6f }; // EIP-4844 transaction prefix

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

pub fn gas_calculation_benchmark(allocator: Allocator) void {
    gas_calculation_benchmark_impl(allocator) catch |err| {
        std.log.err("Gas calculation benchmark failed: {}", .{err});
    };
}

fn gas_calculation_benchmark_impl(allocator: Allocator) !void {
    _ = allocator;

    // Test data for different transaction types and market conditions
    const base_fees = [_]u64{ 10, 50, 100, 200, 500, 1000 }; // gwei
    const priority_fees = [_]u64{ 1, 2, 5, 10, 50 }; // gwei
    const blob_base_fees = [_]u64{ 1, 10, 100, 1000 }; // wei

    // Benchmark EIP-1559 gas price calculations
    for (base_fees) |base_fee| {
        for (priority_fees) |priority_fee| {
            const max_fee = base_fee + priority_fee + 10; // Add buffer

            // Calculate effective gas price
            const effective_price = @min(max_fee, base_fee + priority_fee);
            std.mem.doNotOptimizeAway(effective_price);

            // Calculate gas cost
            const gas_cost = effective_price * 21000; // Standard transfer
            std.mem.doNotOptimizeAway(gas_cost);
        }
    }

    // Benchmark blob gas price calculations
    for (blob_base_fees) |blob_base_fee| {
        const max_blob_fee = blob_base_fee * 2; // Max willing to pay

        // Calculate blob fee
        const blob_fee = @min(max_blob_fee, blob_base_fee);
        std.mem.doNotOptimizeAway(blob_fee);

        // Calculate total blob cost (for max blobs)
        const blob_gas_used = Evm.blob.GAS_PER_BLOB * Evm.blob.MAX_BLOBS_PER_TRANSACTION;
        const total_blob_cost = blob_fee * blob_gas_used;
        std.mem.doNotOptimizeAway(total_blob_cost);
    }
}

test "simplified EIP-4844 benchmarks compile and basic execution" {
    const allocator = std.testing.allocator;

    // Basic compilation and execution test
    blob_gas_market_simple_benchmark(allocator);
    blob_data_creation_benchmark(allocator);
    versioned_hash_simple_benchmark(allocator);
    transaction_type_detection_simple_benchmark(allocator);
    gas_calculation_benchmark(allocator);
    access_list_integration_benchmark(allocator);
}
