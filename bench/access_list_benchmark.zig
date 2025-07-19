const std = @import("std");
const root = @import("root.zig");
const timing = @import("timing.zig");
const Evm = root.Evm;
const primitives = root.primitives;

// Access list related imports
const AccessList = Evm.access_list.AccessList;
const Context = Evm.access_list.Context;

/// Benchmark access list address warming/cooling operations
pub fn address_warming_cooling_benchmark(allocator: std.mem.Allocator) !void {
    std.log.info("=== Access List Address Warming/Cooling Benchmark ===", .{});

    const address_counts = [_]u32{ 10, 50, 100, 500, 1000, 5000 };
    const iterations = 1000;

    for (address_counts) |address_count| {
        std.log.info("Benchmarking with {} addresses", .{address_count});

        // Create test context
        const context = Context.init();
        var access_list = AccessList.init(allocator, context);
        defer access_list.deinit();

        // Create test addresses
        var addresses = try allocator.alloc(primitives.Address.Address, address_count);
        defer allocator.free(addresses);

        for (0..address_count) |i| {
            addresses[i] = create_test_address(i);
        }

        // Benchmark cold access (first access)
        var cold_access_time: u64 = 0;
        var warm_access_time: u64 = 0;

        // Cold access benchmark
        const start_cold = timing.nanoTimestamp();
        for (0..iterations) |_| {
            access_list.clear(); // Ensure all addresses are cold

            for (addresses) |address| {
                _ = try access_list.access_address(address);
            }
        }
        const end_cold = timing.nanoTimestamp();
        cold_access_time = end_cold - start_cold;

        // Warm access benchmark (pre-warm all addresses first)
        try access_list.pre_warm_addresses(addresses);

        const start_warm = timing.nanoTimestamp();
        for (0..iterations) |_| {
            for (addresses) |address| {
                _ = try access_list.access_address(address);
            }
        }
        const end_warm = timing.nanoTimestamp();
        warm_access_time = end_warm - start_warm;

        const cold_avg = cold_access_time / (iterations * address_count);
        const warm_avg = warm_access_time / (iterations * address_count);

        const cold_throughput = @as(f64, @floatFromInt(iterations * address_count * 1000000000)) / @as(f64, @floatFromInt(cold_access_time));
        const warm_throughput = @as(f64, @floatFromInt(iterations * address_count * 1000000000)) / @as(f64, @floatFromInt(warm_access_time));

        std.log.info("  {} addresses:", .{address_count});
        std.log.info("    Cold access: {d:.2f}ns avg, {d:.2f} accesses/sec", .{ @as(f64, @floatFromInt(cold_avg)), cold_throughput });
        std.log.info("    Warm access: {d:.2f}ns avg, {d:.2f} accesses/sec", .{ @as(f64, @floatFromInt(warm_avg)), warm_throughput });
        std.log.info("    Speedup: {d:.2f}x", .{@as(f64, @floatFromInt(cold_avg)) / @as(f64, @floatFromInt(warm_avg))});
    }
}

/// Benchmark storage slot access tracking performance
pub fn storage_slot_tracking_benchmark(allocator: std.mem.Allocator) !void {
    std.log.info("=== Storage Slot Access Tracking Benchmark ===", .{});

    const slot_counts = [_]u32{ 10, 50, 100, 500, 1000 };
    const address_counts = [_]u32{ 1, 10, 50 };
    const iterations = 500;

    for (address_counts) |address_count| {
        for (slot_counts) |slot_count| {
            std.log.info("Benchmarking {} addresses with {} slots each", .{ address_count, slot_count });

            const context = Context.init();
            var access_list = AccessList.init(allocator, context);
            defer access_list.deinit();

            // Create test data
            var addresses = try allocator.alloc(primitives.Address.Address, address_count);
            defer allocator.free(addresses);

            var slots = try allocator.alloc(u256, slot_count);
            defer allocator.free(slots);

            for (0..address_count) |i| {
                addresses[i] = create_test_address(i);
            }

            for (0..slot_count) |i| {
                slots[i] = @intCast(i * 100); // Spread out slot numbers
            }

            // Benchmark cold storage access
            var cold_time: u64 = 0;
            var warm_time: u64 = 0;

            const start_cold = timing.nanoTimestamp();
            for (0..iterations) |_| {
                access_list.clear();

                for (addresses) |address| {
                    for (slots) |slot| {
                        _ = try access_list.access_storage_slot(address, slot);
                    }
                }
            }
            const end_cold = timing.nanoTimestamp();
            cold_time = end_cold - start_cold;

            // Pre-warm all storage slots
            for (addresses) |address| {
                try access_list.pre_warm_storage_slots(address, slots);
            }

            const start_warm = timing.nanoTimestamp();
            for (0..iterations) |_| {
                for (addresses) |address| {
                    for (slots) |slot| {
                        _ = try access_list.access_storage_slot(address, slot);
                    }
                }
            }
            const end_warm = timing.nanoTimestamp();
            warm_time = end_warm - start_warm;

            const total_accesses = iterations * address_count * slot_count;
            const cold_avg = cold_time / total_accesses;
            const warm_avg = warm_time / total_accesses;

            const cold_throughput = @as(f64, @floatFromInt(total_accesses * 1000000000)) / @as(f64, @floatFromInt(cold_time));
            const warm_throughput = @as(f64, @floatFromInt(total_accesses * 1000000000)) / @as(f64, @floatFromInt(warm_time));

            std.log.info("  {} addrs × {} slots:", .{ address_count, slot_count });
            std.log.info("    Cold access: {d:.2f}ns avg, {d:.2f} accesses/sec", .{ @as(f64, @floatFromInt(cold_avg)), cold_throughput });
            std.log.info("    Warm access: {d:.2f}ns avg, {d:.2f} accesses/sec", .{ @as(f64, @floatFromInt(warm_avg)), warm_throughput });
        }
    }
}

/// Benchmark access list initialization from transactions (EIP-2930)
pub fn access_list_initialization_benchmark(allocator: std.mem.Allocator) !void {
    std.log.info("=== Access List Initialization Benchmark ===", .{});

    const scenarios = [_]struct {
        addresses: u32,
        slots_per_address: u32,
    }{
        .{ .addresses = 5, .slots_per_address = 10 },
        .{ .addresses = 10, .slots_per_address = 20 },
        .{ .addresses = 20, .slots_per_address = 50 },
        .{ .addresses = 50, .slots_per_address = 100 },
        .{ .addresses = 100, .slots_per_address = 200 },
    };

    const iterations = 1000;

    for (scenarios) |scenario| {
        std.log.info("Benchmarking {} addresses with {} slots each", .{ scenario.addresses, scenario.slots_per_address });

        // Create test data
        var addresses = try allocator.alloc(primitives.Address.Address, scenario.addresses);
        defer allocator.free(addresses);

        var all_slots = try allocator.alloc([]u256, scenario.addresses);
        defer allocator.free(all_slots);

        for (0..scenario.addresses) |i| {
            addresses[i] = create_test_address(i);

            var slots = try allocator.alloc(u256, scenario.slots_per_address);
            for (0..scenario.slots_per_address) |j| {
                slots[j] = @intCast(i * 1000 + j);
            }
            all_slots[i] = slots;
        }
        defer {
            for (all_slots) |slots| {
                allocator.free(slots);
            }
        }

        var total_time: u64 = 0;

        const start_time = timing.nanoTimestamp();

        for (0..iterations) |_| {
            const tx_origin = create_test_address(999);
            const coinbase = create_test_address(1000);
            const to_address = create_test_address(1001);

            const context = Context.init_with_values(
                tx_origin,
                0, // gas_price
                0, // block_number
                0, // block_timestamp
                coinbase,
                0, // block_difficulty
                0, // block_gas_limit
                1, // chain_id
                0, // block_base_fee
                &[_]u256{}, // blob_hashes
                0, // blob_base_fee
            );

            var access_list = AccessList.init(allocator, context);
            defer access_list.deinit();

            // Initialize transaction (pre-warms tx.origin, coinbase, and to)
            try access_list.init_transaction(to_address);

            // Pre-warm addresses from EIP-2930 access list
            try access_list.pre_warm_addresses(addresses);

            // Pre-warm storage slots
            for (addresses, all_slots) |address, slots| {
                try access_list.pre_warm_storage_slots(address, slots);
            }
        }

        const end_time = timing.nanoTimestamp();
        total_time = end_time - start_time;

        const avg_time = total_time / iterations;
        const throughput = @as(f64, @floatFromInt(iterations * 1000000000)) / @as(f64, @floatFromInt(total_time));

        std.log.info("  {} addrs × {} slots:", .{ scenario.addresses, scenario.slots_per_address });
        std.log.info("    Average init time: {d:.2f}μs", .{@as(f64, @floatFromInt(avg_time)) / 1000.0});
        std.log.info("    Throughput: {d:.2f} inits/sec", .{throughput});
    }
}

/// Benchmark gas cost calculations with access lists
pub fn gas_cost_calculations_benchmark(allocator: std.mem.Allocator) !void {
    std.log.info("=== Gas Cost Calculations Benchmark ===", .{});

    const test_scenarios = [_]struct {
        name: []const u8,
        warm_addresses: u32,
        cold_addresses: u32,
        warm_slots: u32,
        cold_slots: u32,
    }{
        .{ .name = "Mostly Cold", .warm_addresses = 5, .cold_addresses = 45, .warm_slots = 10, .cold_slots = 90 },
        .{ .name = "Mixed", .warm_addresses = 25, .cold_addresses = 25, .warm_slots = 50, .cold_slots = 50 },
        .{ .name = "Mostly Warm", .warm_addresses = 45, .cold_addresses = 5, .warm_slots = 90, .cold_slots = 10 },
        .{ .name = "All Warm", .warm_addresses = 50, .cold_addresses = 0, .warm_slots = 100, .cold_slots = 0 },
        .{ .name = "All Cold", .warm_addresses = 0, .cold_addresses = 50, .warm_slots = 0, .cold_slots = 100 },
    };

    const iterations = 5000;

    for (test_scenarios) |scenario| {
        std.log.info("Benchmarking gas costs for scenario: {s}", .{scenario.name});

        const context = Context.init();
        var access_list = AccessList.init(allocator, context);
        defer access_list.deinit();

        // Create test addresses
        const total_addresses = scenario.warm_addresses + scenario.cold_addresses;
        var addresses = try allocator.alloc(primitives.Address.Address, total_addresses);
        defer allocator.free(addresses);

        for (0..total_addresses) |i| {
            addresses[i] = create_test_address(i);
        }

        // Pre-warm some addresses
        if (scenario.warm_addresses > 0) {
            try access_list.pre_warm_addresses(addresses[0..scenario.warm_addresses]);
        }

        // Create storage slots for first address
        const total_slots = scenario.warm_slots + scenario.cold_slots;
        var slots = try allocator.alloc(u256, total_slots);
        defer allocator.free(slots);

        for (0..total_slots) |i| {
            slots[i] = @intCast(i);
        }

        // Pre-warm some storage slots
        if (scenario.warm_slots > 0) {
            try access_list.pre_warm_storage_slots(addresses[0], slots[0..scenario.warm_slots]);
        }

        var total_time: u64 = 0;
        var total_gas_cost: u64 = 0;

        const start_time = timing.nanoTimestamp();

        for (0..iterations) |_| {
            var iteration_gas: u64 = 0;

            // Access all addresses
            for (addresses) |address| {
                iteration_gas += try access_list.access_address(address);
            }

            // Access all storage slots for the first address
            for (slots) |slot| {
                iteration_gas += try access_list.access_storage_slot(addresses[0], slot);
            }

            // Calculate call costs for some addresses
            for (addresses[0..@min(10, addresses.len)]) |address| {
                iteration_gas += try access_list.get_call_cost(address);
            }

            total_gas_cost += iteration_gas;
        }

        const end_time = timing.nanoTimestamp();
        total_time = end_time - start_time;

        const avg_time = total_time / iterations;
        const avg_gas_cost = total_gas_cost / iterations;
        const throughput = @as(f64, @floatFromInt(iterations * 1000000000)) / @as(f64, @floatFromInt(total_time));

        std.log.info("  Scenario: {s}", .{scenario.name});
        std.log.info("    Average time: {d:.2f}μs", .{@as(f64, @floatFromInt(avg_time)) / 1000.0});
        std.log.info("    Average gas cost: {} gas", .{avg_gas_cost});
        std.log.info("    Throughput: {d:.2f} calculations/sec", .{throughput});
    }
}

/// Comprehensive memory usage benchmarks for large access lists
pub fn memory_usage_benchmark(allocator: std.mem.Allocator) !void {
    std.log.info("=== Memory Usage Benchmark for Large Access Lists ===", .{});

    const test_sizes = [_]struct {
        addresses: u32,
        slots_per_address: u32,
    }{
        .{ .addresses = 1000, .slots_per_address = 100 },
        .{ .addresses = 5000, .slots_per_address = 200 },
        .{ .addresses = 10000, .slots_per_address = 500 },
        .{ .addresses = 20000, .slots_per_address = 1000 },
    };

    for (test_sizes) |size| {
        std.log.info("Testing memory usage with {} addresses and {} slots per address", .{ size.addresses, size.slots_per_address });

        // Create access list
        const context = Context.init();
        var access_list = AccessList.init(allocator, context);
        defer access_list.deinit();

        // Measure memory allocation time
        const start_alloc = timing.nanoTimestamp();

        // Create addresses
        var addresses = try allocator.alloc(primitives.Address.Address, size.addresses);
        defer allocator.free(addresses);

        for (0..size.addresses) |i| {
            addresses[i] = create_test_address(i);
        }

        // Create slots for each address
        var all_slots = try allocator.alloc([]u256, size.addresses);
        defer allocator.free(all_slots);

        for (0..size.addresses) |i| {
            var slots = try allocator.alloc(u256, size.slots_per_address);
            for (0..size.slots_per_address) |j| {
                slots[j] = @intCast(i * 10000 + j);
            }
            all_slots[i] = slots;
        }
        defer {
            for (all_slots) |slots| {
                allocator.free(slots);
            }
        }

        const end_alloc = timing.nanoTimestamp();
        const alloc_time = end_alloc - start_alloc;

        // Measure pre-warming time
        const start_prewarm = timing.nanoTimestamp();

        try access_list.pre_warm_addresses(addresses);

        for (addresses, all_slots) |address, slots| {
            try access_list.pre_warm_storage_slots(address, slots);
        }

        const end_prewarm = timing.nanoTimestamp();
        const prewarm_time = end_prewarm - start_prewarm;

        // Measure lookup performance with large access list
        const lookup_iterations = 1000;
        const start_lookup = timing.nanoTimestamp();

        for (0..lookup_iterations) |_| {
            // Random lookups
            const random_addr_idx = std.crypto.random.uintAtMost(usize, size.addresses - 1);
            const random_slot_idx = std.crypto.random.uintAtMost(usize, size.slots_per_address - 1);

            _ = access_list.is_address_warm(addresses[random_addr_idx]);
            _ = access_list.is_storage_slot_warm(addresses[random_addr_idx], all_slots[random_addr_idx][random_slot_idx]);
        }

        const end_lookup = timing.nanoTimestamp();
        const lookup_time = end_lookup - start_lookup;

        const total_entries = size.addresses + (size.addresses * size.slots_per_address);
        const avg_lookup_time = lookup_time / lookup_iterations;

        std.log.info("  {} addresses × {} slots ({} total entries):", .{ size.addresses, size.slots_per_address, total_entries });
        std.log.info("    Allocation time: {d:.2f}ms", .{@as(f64, @floatFromInt(alloc_time)) / 1000000.0});
        std.log.info("    Pre-warming time: {d:.2f}ms", .{@as(f64, @floatFromInt(prewarm_time)) / 1000000.0});
        std.log.info("    Average lookup time: {d:.2f}ns", .{@as(f64, @floatFromInt(avg_lookup_time))});
        std.log.info("    Estimated memory usage: ~{d:.2f}MB", .{@as(f64, @floatFromInt(total_entries * 50)) / 1024.0 / 1024.0}); // Rough estimate
    }
}

/// Benchmark call cost calculations for different access patterns
pub fn call_cost_benchmark(allocator: std.mem.Allocator) !void {
    std.log.info("=== Call Cost Calculation Benchmark ===", .{});

    const iterations = 10000;
    const address_count = 1000;

    // Create test addresses
    var addresses = try allocator.alloc(primitives.Address.Address, address_count);
    defer allocator.free(addresses);

    for (0..address_count) |i| {
        addresses[i] = create_test_address(i);
    }

    const context = Context.init();
    var access_list = AccessList.init(allocator, context);
    defer access_list.deinit();

    // Test all cold calls
    access_list.clear();

    const start_cold_calls = timing.nanoTimestamp();
    var total_cold_cost: u64 = 0;

    for (0..iterations) |_| {
        access_list.clear();
        for (addresses) |address| {
            total_cold_cost += try access_list.get_call_cost(address);
        }
    }

    const end_cold_calls = timing.nanoTimestamp();
    const cold_calls_time = end_cold_calls - start_cold_calls;

    // Test all warm calls (pre-warm all addresses)
    try access_list.pre_warm_addresses(addresses);

    const start_warm_calls = timing.nanoTimestamp();
    var total_warm_cost: u64 = 0;

    for (0..iterations) |_| {
        for (addresses) |address| {
            total_warm_cost += try access_list.get_call_cost(address);
        }
    }

    const end_warm_calls = timing.nanoTimestamp();
    const warm_calls_time = end_warm_calls - start_warm_calls;

    const cold_avg = cold_calls_time / (iterations * address_count);
    const warm_avg = warm_calls_time / (iterations * address_count);

    const cold_throughput = @as(f64, @floatFromInt(iterations * address_count * 1000000000)) / @as(f64, @floatFromInt(cold_calls_time));
    const warm_throughput = @as(f64, @floatFromInt(iterations * address_count * 1000000000)) / @as(f64, @floatFromInt(warm_calls_time));

    std.log.info("  Cold calls:");
    std.log.info("    Average time: {d:.2f}ns", .{@as(f64, @floatFromInt(cold_avg))});
    std.log.info("    Average cost: {} gas", .{total_cold_cost / (iterations * address_count)});
    std.log.info("    Throughput: {d:.2f} calls/sec", .{cold_throughput});

    std.log.info("  Warm calls:");
    std.log.info("    Average time: {d:.2f}ns", .{@as(f64, @floatFromInt(warm_avg))});
    std.log.info("    Average cost: {} gas", .{total_warm_cost / (iterations * address_count)});
    std.log.info("    Throughput: {d:.2f} calls/sec", .{warm_throughput});

    std.log.info("  Speedup: {d:.2f}x", .{@as(f64, @floatFromInt(cold_avg)) / @as(f64, @floatFromInt(warm_avg))});
}

// Helper function to create test addresses
fn create_test_address(seed: usize) primitives.Address.Address {
    var address: primitives.Address.Address = undefined;

    // Fill with deterministic test data based on seed
    var prng = std.Random.DefaultPrng.init(@intCast(seed));
    const random = prng.random();

    for (0..address.len) |i| {
        address[i] = random.int(u8);
    }

    return address;
}

// Tests to ensure benchmark functions compile
test "access list benchmark compilation" {
    const allocator = std.testing.allocator;

    // Test that all benchmark functions compile
    _ = address_warming_cooling_benchmark;
    _ = storage_slot_tracking_benchmark;
    _ = access_list_initialization_benchmark;
    _ = gas_cost_calculations_benchmark;
    _ = memory_usage_benchmark;
    _ = call_cost_benchmark;

    // Test helper function
    const test_address = create_test_address(42);
    _ = test_address;
}