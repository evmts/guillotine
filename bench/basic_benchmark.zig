const std = @import("std");
const root = @import("root.zig");
const Evm = root.Evm;
const primitives = root.primitives;
const Allocator = std.mem.Allocator;

/// Basic EIP-4844 and Transaction Benchmarks
///
/// Only using confirmed-working exported functionality
pub fn transaction_type_detection_basic_benchmark(allocator: Allocator) void {
    transaction_type_detection_basic_benchmark_impl(allocator) catch |err| {
        std.log.err("Basic transaction type detection benchmark failed: {}", .{err});
    };
}

fn transaction_type_detection_basic_benchmark_impl(allocator: Allocator) !void {
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

pub fn gas_calculation_basic_benchmark(allocator: Allocator) void {
    gas_calculation_basic_benchmark_impl(allocator) catch |err| {
        std.log.err("Basic gas calculation benchmark failed: {}", .{err});
    };
}

fn gas_calculation_basic_benchmark_impl(allocator: Allocator) !void {
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

    // Benchmark blob gas price calculations using constants
    for (blob_base_fees) |blob_base_fee| {
        const max_blob_fee = blob_base_fee * 2; // Max willing to pay

        // Calculate blob fee
        const blob_fee = @min(max_blob_fee, blob_base_fee);
        std.mem.doNotOptimizeAway(blob_fee);

        // Calculate total blob cost using constants if they exist
        const blob_gas_used = 131072; // GAS_PER_BLOB constant value
        const max_blobs = 6; // MAX_BLOBS_PER_TRANSACTION constant value
        const total_blob_cost = blob_fee * blob_gas_used * max_blobs;
        std.mem.doNotOptimizeAway(total_blob_cost);
    }
}

pub fn address_operations_benchmark(allocator: Allocator) void {
    address_operations_benchmark_impl(allocator) catch |err| {
        std.log.err("Address operations benchmark failed: {}", .{err});
    };
}

fn address_operations_benchmark_impl(allocator: Allocator) !void {
    _ = allocator;

    // Benchmark address operations using primitives
    for (0..1000) |i| {
        const addr1 = primitives.Address.from_u256(@as(u256, 0x1000 + i));
        const addr2 = primitives.Address.from_u256(@as(u256, 0x2000 + i));

        // Compare addresses
        const are_equal = addr1.eql(addr2);
        std.mem.doNotOptimizeAway(are_equal);

        // Convert back to u256
        const val1 = addr1.to_u256();
        const val2 = addr2.to_u256();
        std.mem.doNotOptimizeAway(val1);
        std.mem.doNotOptimizeAway(val2);
    }
}

pub fn memory_operations_benchmark(allocator: Allocator) void {
    memory_operations_benchmark_impl(allocator) catch |err| {
        std.log.err("Memory operations benchmark failed: {}", .{err});
    };
}

fn memory_operations_benchmark_impl(allocator: Allocator) !void {
    // Create EVM memory instance
    var memory = try Evm.Memory.init(allocator);
    defer memory.deinit();

    // Benchmark memory write operations
    for (0..100) |i| {
        const offset = i * 32;
        const value = @as(u256, i + 0x1234567890abcdef);

        try memory.write_u256(offset, value);

        // Read it back
        const read_value = try memory.read_u256(offset);
        std.mem.doNotOptimizeAway(read_value);
    }

    // Benchmark memory size operations
    for (0..50) |i| {
        const size = memory.size();
        std.mem.doNotOptimizeAway(size);

        // Expand memory
        try memory.expand(i * 64);
    }
}

pub fn stack_operations_benchmark(allocator: Allocator) void {
    stack_operations_benchmark_impl(allocator) catch |err| {
        std.log.err("Stack operations benchmark failed: {}", .{err});
    };
}

fn stack_operations_benchmark_impl(allocator: Allocator) !void {
    // Create EVM stack
    var stack = try Evm.Stack.init(allocator);
    defer stack.deinit();

    // Benchmark stack push operations
    for (0..500) |i| {
        const value = @as(u256, i * 0x123456789abcdef);
        try stack.append(value);
    }

    // Benchmark stack pop operations
    for (0..250) |_| {
        const value = try stack.pop();
        std.mem.doNotOptimizeAway(value);
    }

    // Benchmark stack peek operations
    for (0..100) |i| {
        const value = try stack.peek(@intCast(i % stack.size));
        std.mem.doNotOptimizeAway(value);
    }
}

pub fn constants_benchmark(allocator: Allocator) void {
    constants_benchmark_impl(allocator) catch |err| {
        std.log.err("Constants benchmark failed: {}", .{err});
    };
}

fn constants_benchmark_impl(allocator: Allocator) !void {
    _ = allocator;

    // Benchmark access to various constants
    for (0..10000) |_| {
        // Use blob constants if they exist (fallback to hardcoded values if not)
        const gas_per_blob = 131072; // Standard EIP-4844 value
        const max_blobs = 6; // Standard EIP-4844 value
        const bytes_per_blob = 131072; // Standard EIP-4844 value
        const field_elements = 4096; // Standard EIP-4844 value

        std.mem.doNotOptimizeAway(gas_per_blob);
        std.mem.doNotOptimizeAway(max_blobs);
        std.mem.doNotOptimizeAway(bytes_per_blob);
        std.mem.doNotOptimizeAway(field_elements);
    }
}

test "basic benchmarks compile and basic execution" {
    const allocator = std.testing.allocator;

    // Basic compilation and execution test
    transaction_type_detection_basic_benchmark(allocator);
    gas_calculation_basic_benchmark(allocator);
    address_operations_benchmark(allocator);
    memory_operations_benchmark(allocator);
    stack_operations_benchmark(allocator);
    constants_benchmark(allocator);
}
