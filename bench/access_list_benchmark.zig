const std = @import("std");
const root = @import("root.zig");
const Evm = root.Evm;
const primitives = root.primitives;
const Allocator = std.mem.Allocator;

/// Access List Benchmarks (EIP-2929 & EIP-2930)
///
/// Measures performance of:
/// - Address warming/cooling operations
/// - Storage slot access tracking
/// - Access list initialization
/// - Gas cost calculations
pub fn access_list_address_benchmark(allocator: Allocator) void {
    access_list_address_benchmark_impl(allocator) catch |err| {
        std.log.err("Access list address benchmark failed: {}", .{err});
    };
}

fn access_list_address_benchmark_impl(allocator: Allocator) !void {
    // Create access list with context
    const context = Evm.access_list.Context{
        .caller = primitives.Address.from_u256(0x1111),
        .tx_origin = primitives.Address.from_u256(0x1111),
        .coinbase = primitives.Address.from_u256(0x2222),
        .contract_address = primitives.Address.from_u256(0x3333),
    };

    var access_list = Evm.access_list.AccessList.init(allocator, context);
    defer access_list.deinit();

    // Generate test addresses
    var addresses: [1000]primitives.Address.Address = undefined;
    for (0..1000) |i| {
        addresses[i] = primitives.Address.from_u256(@as(u256, 0x10000 + i));
    }

    // Benchmark cold address access
    for (addresses) |addr| {
        const cost = try access_list.access_address(addr);
        std.mem.doNotOptimizeAway(cost);
    }

    // Benchmark warm address access (second access)
    for (addresses) |addr| {
        const cost = try access_list.access_address(addr);
        std.mem.doNotOptimizeAway(cost);
    }

    // Benchmark address warming check
    for (addresses) |addr| {
        const is_warm = access_list.is_address_warm(addr);
        std.mem.doNotOptimizeAway(is_warm);
    }
}

pub fn access_list_storage_benchmark(allocator: Allocator) void {
    access_list_storage_benchmark_impl(allocator) catch |err| {
        std.log.err("Access list storage benchmark failed: {}", .{err});
    };
}

fn access_list_storage_benchmark_impl(allocator: Allocator) !void {
    const context = Evm.access_list.Context{
        .caller = primitives.Address.from_u256(0x1111),
        .tx_origin = primitives.Address.from_u256(0x1111),
        .coinbase = primitives.Address.from_u256(0x2222),
        .contract_address = primitives.Address.from_u256(0x3333),
    };

    var access_list = Evm.access_list.AccessList.init(allocator, context);
    defer access_list.deinit();

    // Generate test address and storage slots
    const contract_addr = primitives.Address.from_u256(0x5555);

    var storage_slots: [500]primitives.U256 = undefined;
    for (0..500) |i| {
        storage_slots[i] = @as(u256, i * 7919); // Use prime number for distribution
    }

    // Benchmark cold storage access
    for (storage_slots) |slot| {
        const cost = try access_list.access_storage_slot(contract_addr, slot);
        std.mem.doNotOptimizeAway(cost);
    }

    // Benchmark warm storage access (second access)
    for (storage_slots) |slot| {
        const cost = try access_list.access_storage_slot(contract_addr, slot);
        std.mem.doNotOptimizeAway(cost);
    }

    // Benchmark storage slot warming check
    for (storage_slots) |slot| {
        const is_warm = access_list.is_storage_slot_warm(contract_addr, slot);
        std.mem.doNotOptimizeAway(is_warm);
    }
}

pub fn access_list_initialization_benchmark(allocator: Allocator) void {
    access_list_initialization_benchmark_impl(allocator) catch |err| {
        std.log.err("Access list initialization benchmark failed: {}", .{err});
    };
}

fn access_list_initialization_benchmark_impl(allocator: Allocator) !void {
    const context = Evm.access_list.Context{
        .caller = primitives.Address.from_u256(0x1111),
        .tx_origin = primitives.Address.from_u256(0x1111),
        .coinbase = primitives.Address.from_u256(0x2222),
        .contract_address = primitives.Address.from_u256(0x3333),
    };

    // Create transaction access list with pre-warmed addresses and storage slots
    var tx_access_list = primitives.AccessList.init(allocator);
    defer tx_access_list.deinit();

    // Add multiple addresses with storage slots
    for (0..50) |i| {
        const addr = primitives.Address.from_u256(@as(u256, 0x10000 + i));

        var storage_keys = std.ArrayList(primitives.U256).init(allocator);
        defer storage_keys.deinit();

        // Add multiple storage keys per address
        for (0..20) |j| {
            try storage_keys.append(@as(u256, i * 1000 + j));
        }

        try tx_access_list.append(.{
            .address = addr,
            .storage_keys = try storage_keys.toOwnedSlice(),
        });
    }

    // Benchmark access list initialization with pre-warming
    for (0..100) |_| {
        var access_list = Evm.access_list.AccessList.init(allocator, context);
        defer access_list.deinit();

        // Pre-warm from transaction access list
        for (tx_access_list.items) |entry| {
            try access_list.pre_warm_address(entry.address);

            for (entry.storage_keys) |key| {
                try access_list.pre_warm_storage_slot(entry.address, key);
            }
        }

        std.mem.doNotOptimizeAway(&access_list);
    }
}

pub fn access_list_mixed_operations_benchmark(allocator: Allocator) void {
    access_list_mixed_operations_benchmark_impl(allocator) catch |err| {
        std.log.err("Access list mixed operations benchmark failed: {}", .{err});
    };
}

fn access_list_mixed_operations_benchmark_impl(allocator: Allocator) !void {
    const context = Evm.access_list.Context{
        .caller = primitives.Address.from_u256(0x1111),
        .tx_origin = primitives.Address.from_u256(0x1111),
        .coinbase = primitives.Address.from_u256(0x2222),
        .contract_address = primitives.Address.from_u256(0x3333),
    };

    var access_list = Evm.access_list.AccessList.init(allocator, context);
    defer access_list.deinit();

    // Simulate realistic transaction execution pattern
    const addresses = [_]primitives.Address.Address{
        primitives.Address.from_u256(0x4444),
        primitives.Address.from_u256(0x5555),
        primitives.Address.from_u256(0x6666),
        primitives.Address.from_u256(0x7777),
    };

    var prng = std.rand.DefaultPrng.init(12345);
    const random = prng.random();

    // Mixed access pattern: addresses, storage slots, and lookups
    for (0..1000) |_| {
        const addr = addresses[random.uintLessThan(usize, addresses.len)];
        const slot = random.int(u256);

        // Random operation type
        switch (random.uintLessThan(u8, 4)) {
            0 => {
                // Address access
                const cost = try access_list.access_address(addr);
                std.mem.doNotOptimizeAway(cost);
            },
            1 => {
                // Storage access
                const cost = try access_list.access_storage_slot(addr, slot);
                std.mem.doNotOptimizeAway(cost);
            },
            2 => {
                // Check address warming
                const is_warm = access_list.is_address_warm(addr);
                std.mem.doNotOptimizeAway(is_warm);
            },
            3 => {
                // Check storage warming
                const is_warm = access_list.is_storage_slot_warm(addr, slot);
                std.mem.doNotOptimizeAway(is_warm);
            },
        }
    }
}

pub fn access_list_call_cost_benchmark(allocator: Allocator) void {
    access_list_call_cost_benchmark_impl(allocator) catch |err| {
        std.log.err("Access list call cost benchmark failed: {}", .{err});
    };
}

fn access_list_call_cost_benchmark_impl(allocator: Allocator) !void {
    const context = Evm.access_list.Context{
        .caller = primitives.Address.from_u256(0x1111),
        .tx_origin = primitives.Address.from_u256(0x1111),
        .coinbase = primitives.Address.from_u256(0x2222),
        .contract_address = primitives.Address.from_u256(0x3333),
    };

    var access_list = Evm.access_list.AccessList.init(allocator, context);
    defer access_list.deinit();

    // Test call cost calculations for various scenarios
    const test_addresses = [_]primitives.Address.Address{
        primitives.Address.from_u256(0x8888),
        primitives.Address.from_u256(0x9999),
        primitives.Address.from_u256(0xAAAA),
    };

    // Benchmark call cost calculation for cold addresses
    for (test_addresses) |addr| {
        const cost = try access_list.get_call_cost(addr, 1000000, 0);
        std.mem.doNotOptimizeAway(cost);
    }

    // Warm the addresses
    for (test_addresses) |addr| {
        _ = try access_list.access_address(addr);
    }

    // Benchmark call cost calculation for warm addresses
    for (test_addresses) |addr| {
        const cost = try access_list.get_call_cost(addr, 1000000, 0);
        std.mem.doNotOptimizeAway(cost);
    }

    // Benchmark with value transfer (affects gas calculation)
    for (test_addresses) |addr| {
        const cost = try access_list.get_call_cost(addr, 1000000, 1000000000000000000); // 1 ETH
        std.mem.doNotOptimizeAway(cost);
    }
}

pub fn access_list_large_scale_benchmark(allocator: Allocator) void {
    access_list_large_scale_benchmark_impl(allocator) catch |err| {
        std.log.err("Access list large scale benchmark failed: {}", .{err});
    };
}

fn access_list_large_scale_benchmark_impl(allocator: Allocator) !void {
    const context = Evm.access_list.Context{
        .caller = primitives.Address.from_u256(0x1111),
        .tx_origin = primitives.Address.from_u256(0x1111),
        .coinbase = primitives.Address.from_u256(0x2222),
        .contract_address = primitives.Address.from_u256(0x3333),
    };

    var access_list = Evm.access_list.AccessList.init(allocator, context);
    defer access_list.deinit();

    // Simulate a large transaction with many addresses and storage accesses
    for (0..5000) |i| {
        const addr = primitives.Address.from_u256(@as(u256, 0x100000 + (i / 10))); // 500 unique addresses
        const slot = @as(u256, i * 97); // Use prime for better distribution

        // Access address
        const addr_cost = try access_list.access_address(addr);
        std.mem.doNotOptimizeAway(addr_cost);

        // Access storage slot
        const storage_cost = try access_list.access_storage_slot(addr, slot);
        std.mem.doNotOptimizeAway(storage_cost);

        // Periodic warming checks
        if (i % 100 == 0) {
            const addr_warm = access_list.is_address_warm(addr);
            const storage_warm = access_list.is_storage_slot_warm(addr, slot);
            std.mem.doNotOptimizeAway(addr_warm);
            std.mem.doNotOptimizeAway(storage_warm);
        }
    }
}

test "access list benchmarks compile and basic execution" {
    const allocator = std.testing.allocator;

    // Basic compilation and execution test
    access_list_address_benchmark(allocator);
    access_list_storage_benchmark(allocator);
    access_list_call_cost_benchmark(allocator);
}
