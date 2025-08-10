const std = @import("std");
const root = @import("root.zig");
const Evm = root.Evm;
const primitives = root.primitives;
const Allocator = std.mem.Allocator;

/// Minimal EIP-4844 and Access List Benchmarks
///
/// Focus only on exported functionality that's confirmed to be available
pub fn blob_gas_market_minimal_benchmark(allocator: Allocator) void {
    blob_gas_market_minimal_benchmark_impl(allocator) catch |err| {
        std.log.err("Minimal blob gas market benchmark failed: {}", .{err});
    };
}

fn blob_gas_market_minimal_benchmark_impl(allocator: Allocator) !void {
    _ = allocator;

    // Create blob gas market instance using exported module
    var market = Evm.BlobGasMarket.init();

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

pub fn blob_data_structure_benchmark(allocator: Allocator) void {
    blob_data_structure_benchmark_impl(allocator) catch |err| {
        std.log.err("Blob data structure benchmark failed: {}", .{err});
    };
}

fn blob_data_structure_benchmark_impl(allocator: Allocator) !void {
    _ = allocator;

    // Benchmark blob data structure creation and manipulation using exported types
    for (0..100) |blob_idx| {
        var blob = Evm.Blob{};

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

pub fn transaction_type_detection_minimal_benchmark(allocator: Allocator) void {
    transaction_type_detection_minimal_benchmark_impl(allocator) catch |err| {
        std.log.err("Minimal transaction type detection benchmark failed: {}", .{err});
    };
}

fn transaction_type_detection_minimal_benchmark_impl(allocator: Allocator) !void {
    _ = allocator;

    // Create test transaction data for different types
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

    // Benchmark transaction type detection using exported function
    for (0..2000) |_| {
        for (test_data) |tx_data| {
            const tx_type = primitives.Transaction.detect_transaction_type(tx_data);
            std.mem.doNotOptimizeAway(tx_type);
        }
    }
}

pub fn gas_calculation_minimal_benchmark(allocator: Allocator) void {
    gas_calculation_minimal_benchmark_impl(allocator) catch |err| {
        std.log.err("Minimal gas calculation benchmark failed: {}", .{err});
    };
}

fn gas_calculation_minimal_benchmark_impl(allocator: Allocator) !void {
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

pub fn evm_context_benchmark(allocator: Allocator) void {
    evm_context_benchmark_impl(allocator) catch |err| {
        std.log.err("EVM context benchmark failed: {}", .{err});
    };
}

fn evm_context_benchmark_impl(allocator: Allocator) !void {
    _ = allocator;

    // Benchmark EVM context creation using exported types
    for (0..1000) |i| {
        const context = Evm.Context{
            .caller = primitives.Address.from_u256(@as(u256, 0x1000 + i)),
            .tx_origin = primitives.Address.from_u256(@as(u256, 0x1000 + i)),
            .coinbase = primitives.Address.from_u256(0x2222),
            .contract_address = primitives.Address.from_u256(@as(u256, 0x3000 + i)),
        };

        std.mem.doNotOptimizeAway(context.caller);
        std.mem.doNotOptimizeAway(context.tx_origin);
        std.mem.doNotOptimizeAway(context.coinbase);
        std.mem.doNotOptimizeAway(context.contract_address);
    }
}

pub fn blob_constants_benchmark(allocator: Allocator) void {
    blob_constants_benchmark_impl(allocator) catch |err| {
        std.log.err("Blob constants benchmark failed: {}", .{err});
    };
}

fn blob_constants_benchmark_impl(allocator: Allocator) !void {
    _ = allocator;

    // Benchmark using blob constants
    for (0..10000) |_| {
        const bytes_per_blob = Evm.blob.BYTES_PER_BLOB;
        const field_elements = Evm.blob.FIELD_ELEMENTS_PER_BLOB;
        const max_blobs = Evm.blob.MAX_BLOBS_PER_TRANSACTION;
        const gas_per_blob = Evm.blob.GAS_PER_BLOB;
        const min_blob_gas = Evm.blob.MIN_BLOB_GASPRICE;
        const max_blob_gas = Evm.blob.MAX_BLOB_GAS_PER_BLOCK;
        const target_blob_gas = Evm.blob.TARGET_BLOB_GAS_PER_BLOCK;

        std.mem.doNotOptimizeAway(bytes_per_blob);
        std.mem.doNotOptimizeAway(field_elements);
        std.mem.doNotOptimizeAway(max_blobs);
        std.mem.doNotOptimizeAway(gas_per_blob);
        std.mem.doNotOptimizeAway(min_blob_gas);
        std.mem.doNotOptimizeAway(max_blob_gas);
        std.mem.doNotOptimizeAway(target_blob_gas);
    }
}

test "minimal benchmarks compile and basic execution" {
    const allocator = std.testing.allocator;

    // Basic compilation and execution test
    blob_gas_market_minimal_benchmark(allocator);
    blob_data_structure_benchmark(allocator);
    transaction_type_detection_minimal_benchmark(allocator);
    gas_calculation_minimal_benchmark(allocator);
    evm_context_benchmark(allocator);
    blob_constants_benchmark(allocator);
}
