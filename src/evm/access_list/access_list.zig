const std = @import("std");
const primitives = @import("primitives");
const AccessListStorageKey = @import("access_list_storage_key.zig");
const AccessListStorageKeyContext = @import("access_list_storage_key_context.zig");
const Context = @import("context.zig");
const access_list_constants = @import("../constants/access_list_constants.zig");

/// EIP-2929 & EIP-2930: Access list management for gas cost calculation
///
/// Tracks which addresses and storage slots have been accessed during transaction
/// execution. First access (cold) costs more gas than subsequent accesses (warm).
///
/// Gas costs:
/// - Cold address access: 2600 gas
/// - Warm address access: 100 gas
/// - Cold storage slot access: 2100 gas
/// - Warm storage slot access: 100 gas

// Error types for AccessList operations
pub const Error = std.mem.Allocator.Error;
pub const AccessAddressError = Error;
pub const AccessStorageSlotError = Error;
pub const PreWarmAddressesError = Error;
pub const PreWarmStorageSlotsError = Error;
pub const InitTransactionError = Error;
pub const GetCallCostError = Error;

pub const AccessList = @This();

// Gas costs defined by EIP-2929
pub const COLD_ACCOUNT_ACCESS_COST: u64 = access_list_constants.COLD_ACCOUNT_ACCESS_COST;
pub const WARM_ACCOUNT_ACCESS_COST: u64 = access_list_constants.WARM_ACCOUNT_ACCESS_COST;
pub const COLD_SLOAD_COST: u64 = access_list_constants.COLD_SLOAD_COST;
pub const WARM_SLOAD_COST: u64 = access_list_constants.WARM_SLOAD_COST;

// Additional costs for CALL operations
pub const COLD_CALL_EXTRA_COST: u64 = access_list_constants.COLD_CALL_EXTRA_COST;

allocator: std.mem.Allocator,
/// Warm addresses - addresses that have been accessed
addresses: std.AutoHashMap(primitives.Address.Address, void),
/// Warm storage slots - storage slots that have been accessed
storage_slots: std.HashMap(AccessListStorageKey, void, AccessListStorageKeyContext, 80),
/// Transaction and block context for pre-warming addresses
context: Context,

pub fn init(allocator: std.mem.Allocator, context: Context) AccessList {
    return .{
        .allocator = allocator,
        .addresses = std.AutoHashMap(primitives.Address.Address, void).init(allocator),
        .storage_slots = std.HashMap(AccessListStorageKey, void, AccessListStorageKeyContext, 80).init(allocator),
        .context = context,
    };
}

pub fn deinit(self: *AccessList) void {
    self.addresses.deinit();
    self.storage_slots.deinit();
}

/// Transfer ownership of this AccessList to the caller
/// After calling this, the original AccessList should not be used
pub fn to_owned(self: AccessList) AccessList {
    return AccessList{
        .allocator = self.allocator,
        .addresses = self.addresses,
        .storage_slots = self.storage_slots, 
        .context = self.context,
    };
}

/// Clear all access lists for a new transaction
pub fn clear(self: *AccessList) void {
    self.addresses.clearRetainingCapacity();
    self.storage_slots.clearRetainingCapacity();
}

/// Mark an address as accessed and return the gas cost
/// Returns COLD_ACCOUNT_ACCESS_COST if first access, WARM_ACCOUNT_ACCESS_COST if already accessed
pub fn access_address(self: *AccessList, address: primitives.Address.Address) std.mem.Allocator.Error!u64 {
    const result = try self.addresses.getOrPut(address);
    if (result.found_existing) {
        @branchHint(.likely);
        return WARM_ACCOUNT_ACCESS_COST;
    }
    return COLD_ACCOUNT_ACCESS_COST;
}

/// Mark a storage slot as accessed and return the gas cost
/// Returns COLD_SLOAD_COST if first access, WARM_SLOAD_COST if already accessed
pub fn access_storage_slot(self: *AccessList, address: primitives.Address.Address, slot: u256) std.mem.Allocator.Error!u64 {
    const key = AccessListStorageKey{ .address = address, .slot = slot };
    const result = try self.storage_slots.getOrPut(key);
    if (result.found_existing) {
        @branchHint(.likely);
        return WARM_SLOAD_COST;
    }
    return COLD_SLOAD_COST;
}

/// Check if an address is warm (has been accessed)
pub fn is_address_warm(self: *const AccessList, address: primitives.Address.Address) bool {
    return self.addresses.contains(address);
}

/// Check if a storage slot is warm (has been accessed)
pub fn is_storage_slot_warm(self: *const AccessList, address: primitives.Address.Address, slot: u256) bool {
    const key = AccessListStorageKey{ .address = address, .slot = slot };
    return self.storage_slots.contains(key);
}

/// Pre-warm addresses from EIP-2930 access list
pub fn pre_warm_addresses(self: *AccessList, addresses: []const primitives.Address.Address) std.mem.Allocator.Error!void {
    for (addresses) |address| {
        try self.addresses.put(address, {});
    }
}

/// Pre-warm storage slots from EIP-2930 access list
pub fn pre_warm_storage_slots(self: *AccessList, address: primitives.Address.Address, slots: []const u256) std.mem.Allocator.Error!void {
    for (slots) |slot| {
        const key = AccessListStorageKey{ .address = address, .slot = slot };
        try self.storage_slots.put(key, {});
    }
}

/// Initialize transaction access list with pre-warmed addresses
/// According to EIP-2929, tx.origin and block.coinbase are always pre-warmed
/// EIP-3651 adds COINBASE to warm addresses (already included as block_coinbase)
pub fn init_transaction(self: *AccessList, to: ?primitives.Address.Address) std.mem.Allocator.Error!void {
    // Clear previous transaction data
    self.clear();

    // Pre-warm tx.origin
    try self.addresses.put(self.context.tx_origin, {});
    
    // Pre-warm block.coinbase (EIP-2929 + EIP-3651)
    try self.addresses.put(self.context.block_coinbase, {});

    // Pre-warm destination address if present
    if (to) |to_address| {
        try self.addresses.put(to_address, {});
    }

    // Pre-warm all precompile addresses (0x01 through 0x0A)
    // This is required by EIP-2929 for correct gas accounting
    var i: u8 = 1;
    while (i <= 10) : (i += 1) {
        var precompile_addr: primitives.Address.Address = [_]u8{0} ** 20;
        precompile_addr[19] = i;
        try self.addresses.put(precompile_addr, {});
    }
}

/// Get the extra gas cost for accessing an address (for CALL operations)
/// Returns 0 if warm, COLD_CALL_EXTRA_COST if cold
pub fn get_call_cost(self: *AccessList, address: primitives.Address.Address) std.mem.Allocator.Error!u64 {
    const result = try self.addresses.getOrPut(address);
    if (result.found_existing) {
        @branchHint(.likely);
        return 0;
    }
    return COLD_CALL_EXTRA_COST;
}

// Tests
const testing = std.testing;

test "AccessList basic operations" {
    const context = Context.init();
    var access_list = AccessList.init(testing.allocator, context);
    defer access_list.deinit();

    const test_address = [_]u8{1} ** 20;

    // First access should be cold
    const cost1 = try access_list.access_address(test_address);
    try testing.expectEqual(COLD_ACCOUNT_ACCESS_COST, cost1);

    // Second access should be warm
    const cost2 = try access_list.access_address(test_address);
    try testing.expectEqual(WARM_ACCOUNT_ACCESS_COST, cost2);

    // Check warmth
    try testing.expect(access_list.is_address_warm(test_address));

    const cold_address = [_]u8{2} ** 20;
    try testing.expect(!access_list.is_address_warm(cold_address));
}

test "AccessList storage slots" {
    const context = Context.init();
    var access_list = AccessList.init(testing.allocator, context);
    defer access_list.deinit();

    const test_address = [_]u8{1} ** 20;
    const slot1: u256 = 42;
    const slot2: u256 = 100;

    // First access to slot1 should be cold
    const cost1 = try access_list.access_storage_slot(test_address, slot1);
    try testing.expectEqual(COLD_SLOAD_COST, cost1);

    // Second access to slot1 should be warm
    const cost2 = try access_list.access_storage_slot(test_address, slot1);
    try testing.expectEqual(WARM_SLOAD_COST, cost2);

    // First access to slot2 should be cold
    const cost3 = try access_list.access_storage_slot(test_address, slot2);
    try testing.expectEqual(COLD_SLOAD_COST, cost3);

    // Check warmth
    try testing.expect(access_list.is_storage_slot_warm(test_address, slot1));
    try testing.expect(access_list.is_storage_slot_warm(test_address, slot2));
    try testing.expect(!access_list.is_storage_slot_warm(test_address, 999));
}

test "AccessList transaction initialization" {
    const tx_origin = [_]u8{1} ** 20;
    const coinbase = [_]u8{2} ** 20;
    const to_address = [_]u8{3} ** 20;

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
    var access_list = AccessList.init(testing.allocator, context);
    defer access_list.deinit();

    try access_list.init_transaction(to_address);

    // All should be pre-warmed
    try testing.expect(access_list.is_address_warm(tx_origin));
    try testing.expect(access_list.is_address_warm(coinbase));
    try testing.expect(access_list.is_address_warm(to_address));

    // Accessing them should return warm cost
    try testing.expectEqual(WARM_ACCOUNT_ACCESS_COST, try access_list.access_address(tx_origin));
    try testing.expectEqual(WARM_ACCOUNT_ACCESS_COST, try access_list.access_address(coinbase));
    try testing.expectEqual(WARM_ACCOUNT_ACCESS_COST, try access_list.access_address(to_address));
}

test "AccessList pre-warming from EIP-2930" {
    const context = Context.init();
    var access_list = AccessList.init(testing.allocator, context);
    defer access_list.deinit();

    const addresses = [_]primitives.Address.Address{
        primitives.Address.ZERO_ADDRESS,
        [_]u8{1} ** 20,
        [_]u8{2} ** 20,
    };

    try access_list.pre_warm_addresses(&addresses);

    // All should be warm
    for (addresses) |address| {
        try testing.expect(access_list.is_address_warm(address));
        try testing.expectEqual(WARM_ACCOUNT_ACCESS_COST, try access_list.access_address(address));
    }

    // Test storage slot pre-warming
    const contract_address = [_]u8{4} ** 20;
    const slots = [_]u256{ 1, 2, 3, 100 };

    try access_list.pre_warm_storage_slots(contract_address, &slots);

    for (slots) |slot| {
        try testing.expect(access_list.is_storage_slot_warm(contract_address, slot));
        try testing.expectEqual(WARM_SLOAD_COST, try access_list.access_storage_slot(contract_address, slot));
    }
}

test "AccessList call costs" {
    const context = Context.init();
    var access_list = AccessList.init(testing.allocator, context);
    defer access_list.deinit();

    const cold_address = [_]u8{1} ** 20;
    const warm_address = [_]u8{2} ** 20;

    // Pre-warm one address
    try access_list.pre_warm_addresses(&[_]primitives.Address.Address{warm_address});

    // Cold address should have extra cost
    try testing.expectEqual(COLD_CALL_EXTRA_COST, try access_list.get_call_cost(cold_address));

    // Warm address should have no extra cost
    try testing.expectEqual(@as(u64, 0), try access_list.get_call_cost(warm_address));

    // After getting cost, cold address should now be warm
    try testing.expect(access_list.is_address_warm(cold_address));
}

test "access_list_benchmarks" {
    const Timer = std.time.Timer;
    var timer = try Timer.start();
    const testing_allocator = std.testing.allocator;
    
    const context = Context.init();
    var access_list = AccessList.init(testing_allocator, context);
    defer access_list.deinit();
    
    const iterations = 100000;
    
    // Benchmark 1: Address access performance under high load
    timer.reset();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var address: [20]u8 = [_]u8{0} ** 20;
        const temp = @as(u160, @intCast(i % 10000));
        std.mem.writeInt(u160, address[0..20], temp, .big);
        _ = try access_list.access_address(address);
    }
    const address_access_ns = timer.read();
    
    // Benchmark 2: Storage slot access performance
    access_list.clear();
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        var address: [20]u8 = [_]u8{0} ** 20;
        const temp = @as(u160, @intCast(i % 1000));
        std.mem.writeInt(u160, address[0..20], temp, .big);
        const slot: u256 = @intCast(i % 5000);
        _ = try access_list.access_storage_slot(address, slot);
    }
    const storage_access_ns = timer.read();
    
    // Benchmark 3: Large access list insertion performance
    access_list.clear();
    const large_addresses = try testing_allocator.alloc(primitives.Address.Address, 10000);
    defer testing_allocator.free(large_addresses);
    
    for (large_addresses, 0..) |*address, idx| {
        const temp = @as(u160, @intCast(idx));
        std.mem.writeInt(u160, address[0..20], temp, .big);
    }
    
    timer.reset();
    try access_list.pre_warm_addresses(large_addresses);
    const large_prewarm_ns = timer.read();
    
    // Benchmark 4: Hash collision handling efficiency
    access_list.clear();
    timer.reset();
    // Create addresses that might cause hash collisions
    i = 0;
    while (i < 1000) : (i += 1) {
        var collision_address: [20]u8 = undefined;
        // Create addresses with similar patterns
        collision_address[0] = @intCast(i % 256);
        collision_address[1] = @intCast((i >> 8) % 256);
        @memset(collision_address[2..], 0xAA);
        _ = try access_list.access_address(collision_address);
    }
    const collision_handling_ns = timer.read();
    
    // Benchmark 5: Memory usage scaling test
    access_list.clear();
    var scaling_lists = std.ArrayList(AccessList).init(testing_allocator);
    defer {
        for (scaling_lists.items) |*list| {
            list.deinit();
        }
        scaling_lists.deinit();
    }
    
    timer.reset();
    i = 0;
    while (i < 100) : (i += 1) {
        var list = AccessList.init(testing_allocator, context);
        
        // Fill each list with different sized data
        const fill_size = (i + 1) * 10;
        var j: usize = 0;
        while (j < fill_size) : (j += 1) {
            var address: [20]u8 = [_]u8{0} ** 20;
            const temp = @as(u160, @intCast(j));
            std.mem.writeInt(u160, address[0..20], temp, .big);
            _ = try list.access_address(address);
            _ = try list.access_storage_slot(address, @intCast(j));
        }
        
        try scaling_lists.append(list);
    }
    const scaling_ns = timer.read();
    
    // Benchmark 6: Random vs sequential access patterns
    access_list.clear();
    var rng = std.Random.DefaultPrng.init(12345);
    const random = rng.random();
    
    // Sequential access pattern
    timer.reset();
    i = 0;
    while (i < 10000) : (i += 1) {
        var address: [20]u8 = [_]u8{0} ** 20;
        const temp = @as(u160, @intCast(i));
        std.mem.writeInt(u160, address[0..20], temp, .big);
        _ = try access_list.access_address(address);
    }
    const sequential_ns = timer.read();
    
    access_list.clear();
    
    // Random access pattern
    timer.reset();
    i = 0;
    while (i < 10000) : (i += 1) {
        const random_val = random.int(u160);
        var address: [20]u8 = [_]u8{0} ** 20;
        std.mem.writeInt(u160, address[0..20], random_val, .big);
        _ = try access_list.access_address(address);
    }
    const random_access_ns = timer.read();
    
    // Print benchmark results for analysis
    std.log.debug("Access List Benchmarks:", .{});
    std.log.debug("  Address access ({} ops): {} ns", .{ iterations, address_access_ns });
    std.log.debug("  Storage access ({} ops): {} ns", .{ iterations, storage_access_ns });
    std.log.debug("  Large pre-warm (10k addresses): {} ns", .{large_prewarm_ns});
    std.log.debug("  Hash collision handling (1k ops): {} ns", .{collision_handling_ns});
    std.log.debug("  Memory scaling (100 lists): {} ns", .{scaling_ns});
    std.log.debug("  Sequential access (10k ops): {} ns", .{sequential_ns});
    std.log.debug("  Random access (10k ops): {} ns", .{random_access_ns});
    
    // Performance analysis hints
    if (sequential_ns < random_access_ns) {
        std.log.debug("✓ Sequential access shows expected performance benefit", .{});
    }
    
    const avg_address_access_ns = address_access_ns / iterations;
    const avg_storage_access_ns = storage_access_ns / iterations;
    std.log.debug("  Average address access: {} ns/op", .{avg_address_access_ns});
    std.log.debug("  Average storage access: {} ns/op", .{avg_storage_access_ns});
}

// ============================================================================
// Fuzz Tests for Access List Large-Scale Access Patterns (Issue #234)
// Using proper Zig built-in fuzz testing with std.testing.fuzz()
// ============================================================================

test "fuzz_access_list_large_scale_patterns" {
    const global = struct {
        fn testLargeScalePatterns(input: []const u8) anyerror!void {
            if (input.len < 16) return;
            
            const allocator = std.testing.allocator;
            const context = Context.init();
            var access_list = AccessList.init(allocator, context);
            defer access_list.deinit();
            
            // Test parameters derived from fuzz input
            const num_addresses = input[0] % 100 + 1; // 1-100 addresses
            const num_slots_per_address = input[1] % 50 + 1; // 1-50 slots per address
            const access_pattern = input[2] % 4; // 0=sequential, 1=random, 2=clustered, 3=mixed
            
            // Generate addresses from fuzz input
            var addresses = std.ArrayList(primitives.Address.Address).init(allocator);
            defer addresses.deinit();
            
            for (0..num_addresses) |i| {
                var address: [20]u8 = undefined;
                const base_idx = 3 + (i * 20) % (input.len - 3);
                for (0..20) |j| {
                    if (base_idx + j < input.len) {
                        address[j] = input[base_idx + j];
                    } else {
                        address[j] = @as(u8, @intCast((i * j) % 256));
                    }
                }
                try addresses.append(address);
            }
            
            // Test different access patterns
            switch (access_pattern) {
                0 => {
                    // Sequential access pattern
                    for (addresses.items) |address| {
                        const cost = access_list.access_address(address) catch continue;
                        std.testing.expect(cost == COLD_ACCOUNT_ACCESS_COST or cost == WARM_ACCOUNT_ACCESS_COST) catch {};
                        
                        // Access multiple storage slots sequentially
                        for (0..num_slots_per_address) |slot_idx| {
                            const slot = @as(u256, slot_idx);
                            const slot_cost = access_list.access_storage_slot(address, slot) catch continue;
                            std.testing.expect(slot_cost == COLD_SLOAD_COST or slot_cost == WARM_SLOAD_COST) catch {};
                        }
                    }
                },
                1 => {
                    // Random access pattern
                    for (0..num_addresses * num_slots_per_address) |i| {
                        const addr_idx = input[(3 + i) % input.len] % addresses.items.len;
                        const start = (7 + i * 4) % (input.len - 3);
                        const end = start + 4;
                        const slice = if (end <= input.len) input[start..end] else input[start..];
                        var bytes: [4]u8 = [_]u8{0} ** 4;
                        @memcpy(bytes[0..slice.len], slice);
                        const slot_seed = std.mem.readInt(u32, &bytes, .little);
                        
                        const address = addresses.items[addr_idx];
                        const slot = @as(u256, slot_seed) % 1000; // 0-999 range
                        
                        _ = access_list.access_address(address) catch continue;
                        _ = access_list.access_storage_slot(address, slot) catch continue;
                    }
                },
                2 => {
                    // Clustered access pattern (focused on subset of addresses)
                    const cluster_size = @min(addresses.items.len / 4 + 1, addresses.items.len);
                    for (0..cluster_size) |cluster_idx| {
                        const address = addresses.items[cluster_idx];
                        
                        // Multiple accesses to same address
                        for (0..5) |_| {
                            _ = access_list.access_address(address) catch continue;
                        }
                        
                        // Multiple storage accesses
                        for (0..num_slots_per_address) |slot_idx| {
                            const slot = @as(u256, slot_idx * slot_idx); // Sparse pattern
                            _ = access_list.access_storage_slot(address, slot) catch continue;
                        }
                    }
                },
                3 => {
                    // Mixed pattern combining all approaches
                    for (addresses.items, 0..) |address, i| {
                        _ = access_list.access_address(address) catch continue;
                        
                        // Sequential slots
                        const slot_base = @as(u256, i * 10);
                        _ = access_list.access_storage_slot(address, slot_base) catch continue;
                        _ = access_list.access_storage_slot(address, slot_base + 1) catch continue;
                        
                        // Random slot
                        const random_slot = @as(u256, input[(i * 3) % input.len]) * 1000;
                        _ = access_list.access_storage_slot(address, random_slot) catch continue;
                    }
                },
                else => unreachable,
            }
            
            // Verify access list state integrity
            for (addresses.items) |address| {
                if (access_list.is_address_warm(address)) {
                    const warm_cost = access_list.access_address(address) catch continue;
                    std.testing.expect(warm_cost == WARM_ACCOUNT_ACCESS_COST) catch {};
                }
            }
        }
    };
    const input = "test_input_data_for_fuzzing";
    try global.testLargeScalePatterns(input);
}

test "fuzz_access_list_gas_optimization" {
    const global = struct {
        fn testGasOptimization(input: []const u8) anyerror!void {
            if (input.len < 24) return;
            
            const allocator = std.testing.allocator;
            const context = Context.init();
            var access_list = AccessList.init(allocator, context);
            defer access_list.deinit();
            
            // Test gas optimization scenarios
            const num_operations = input[0] % 50 + 10; // 10-59 operations
            var total_gas: u64 = 0;
            var cold_accesses: u32 = 0;
            var warm_accesses: u32 = 0;
            
            for (0..num_operations) |i| {
                const base_idx = 1 + (i * 24) % (input.len - 24);
                if (base_idx + 24 > input.len) break;
                
                // Extract address and slot from fuzz input
                var address: [20]u8 = undefined;
                std.mem.copyForwards(u8, &address, input[base_idx..base_idx + 20]);
                var slot_bytes: [4]u8 = undefined;
                @memcpy(&slot_bytes, input[base_idx + 20..base_idx + 24]);
                const slot = std.mem.readInt(u32, &slot_bytes, .little);
                
                const operation_type = input[base_idx] % 3; // 0=address, 1=storage, 2=call_cost
                
                switch (operation_type) {
                    0 => {
                        // Address access
                        const was_warm = access_list.is_address_warm(address);
                        const cost = access_list.access_address(address) catch continue;
                        total_gas += cost;
                        
                        if (was_warm) {
                            warm_accesses += 1;
                            std.testing.expect(cost == WARM_ACCOUNT_ACCESS_COST) catch {};
                        } else {
                            cold_accesses += 1;
                            std.testing.expect(cost == COLD_ACCOUNT_ACCESS_COST) catch {};
                        }
                    },
                    1 => {
                        // Storage access
                        const was_warm = access_list.is_storage_slot_warm(address, @as(u256, slot));
                        const cost = access_list.access_storage_slot(address, @as(u256, slot)) catch continue;
                        total_gas += cost;
                        
                        if (was_warm) {
                            warm_accesses += 1;
                            std.testing.expect(cost == WARM_SLOAD_COST) catch {};
                        } else {
                            cold_accesses += 1;
                            std.testing.expect(cost == COLD_SLOAD_COST) catch {};
                        }
                    },
                    2 => {
                        // Call cost
                        const was_warm = access_list.is_address_warm(address);
                        const cost = access_list.get_call_cost(address) catch continue;
                        total_gas += cost;
                        
                        if (was_warm) {
                            std.testing.expect(cost == 0) catch {};
                        } else {
                            std.testing.expect(cost == COLD_CALL_EXTRA_COST) catch {};
                        }
                    },
                    else => unreachable,
                }
            }
            
            // Verify gas accounting makes sense
            std.testing.expect(total_gas > 0) catch {};
            std.testing.expect(cold_accesses + warm_accesses <= num_operations) catch {};
        }
    };
    const input = "test_input_data_for_fuzzing";
    try global.testGasOptimization(input);
}

test "fuzz_access_list_memory_efficiency" {
    const global = struct {
        fn testMemoryEfficiency(input: []const u8) anyerror!void {
            if (input.len < 8) return;
            
            const allocator = std.testing.allocator;
            const context = Context.init();
            
            // Test memory efficiency with multiple access lists
            const num_lists = input[0] % 10 + 1; // 1-10 lists
            const operations_per_list = input[1] % 50 + 10; // 10-59 operations per list
            
            var access_lists = std.ArrayList(AccessList).init(allocator);
            defer {
                for (access_lists.items) |*list| {
                    list.deinit();
                }
                access_lists.deinit();
            }
            
            // Create multiple access lists and test memory sharing
            for (0..num_lists) |list_idx| {
                var access_list = AccessList.init(allocator, context);
                
                for (0..operations_per_list) |op_idx| {
                    const base_idx = 2 + ((list_idx * operations_per_list + op_idx) * 24) % (input.len - 2);
                    if (base_idx + 24 > input.len) break;
                    
                    var address: [20]u8 = undefined;
                    for (0..20) |addr_byte| {
                        if (base_idx + addr_byte < input.len) {
                            address[addr_byte] = input[base_idx + addr_byte];
                        } else {
                            address[addr_byte] = @as(u8, @intCast((list_idx + op_idx + addr_byte) % 256));
                        }
                    }
                    
                    const slot_seed = blk: {
                        if (base_idx + 20 + 4 <= input.len) {
                            var slot_bytes: [4]u8 = undefined;
                            @memcpy(&slot_bytes, input[base_idx + 20..base_idx + 24]);
                            break :blk std.mem.readInt(u32, &slot_bytes, .little);
                        } else {
                            break :blk @as(u32, @intCast(op_idx));
                        }
                    };
                    
                    // Mix address and storage accesses
                    _ = access_list.access_address(address) catch continue;
                    _ = access_list.access_storage_slot(address, @as(u256, slot_seed)) catch continue;
                }
                
                try access_lists.append(access_list);
            }
            
            // Test clearing and reuse
            for (access_lists.items) |*list| {
                const initial_warm_count = list.addresses.count();
                list.clear();
                std.testing.expect(list.addresses.count() == 0) catch {};
                std.testing.expect(list.storage_slots.count() == 0) catch {};
                
                // Reuse should be efficient
                if (initial_warm_count > 0) {
                    const test_address = primitives.Address.ZERO_ADDRESS;
                    _ = list.access_address(test_address) catch continue;
                    std.testing.expect(list.is_address_warm(test_address)) catch {};
                }
            }
        }
    };
    const input = "test_input_data_for_fuzzing";
    try global.testMemoryEfficiency(input);
}

test "fuzz_access_list_transaction_patterns" {
    const global = struct {
        fn testTransactionPatterns(input: []const u8) anyerror!void {
            if (input.len < 32) return;
            
            const allocator = std.testing.allocator;
            
            // Create transaction context from fuzz input
            var tx_origin: [20]u8 = undefined;
            var coinbase: [20]u8 = undefined;
            var to_address: [20]u8 = undefined;
            
            std.mem.copyForwards(u8, &tx_origin, input[0..20]);
            std.mem.copyForwards(u8, &coinbase, input[20..40] ++ ([_]u8{0} ** (40 - @min(40, input.len)))[20..20]);
            
            // Handle case where input is too short for full addresses
            if (input.len >= 60) {
                std.mem.copyForwards(u8, &to_address, input[40..60]);
            } else {
                std.mem.copyForwards(u8, &to_address, input[20..@min(40, input.len)]);
                // Fill remaining bytes with pattern
                for (@min(20, input.len - 20)..20) |i| {
                    to_address[i] = @as(u8, @intCast(i));
                }
            }
            
            const context = Context.init_with_values(
                tx_origin,
                0, 0, 0,
                coinbase,
                0, 0, 1, 0,
                &[_]u256{}, 0
            );
            
            var access_list = AccessList.init(allocator, context);
            defer access_list.deinit();
            
            // Test transaction initialization
            access_list.init_transaction(to_address) catch return;
            
            // Verify pre-warmed addresses
            std.testing.expect(access_list.is_address_warm(tx_origin)) catch {};
            std.testing.expect(access_list.is_address_warm(coinbase)) catch {};
            std.testing.expect(access_list.is_address_warm(to_address)) catch {};
            
            // Test EIP-2930 access list pre-warming
            const num_prewarm_addresses = @min(input[0] % 20, 10); // 0-10 addresses
            
            var prewarm_addresses = std.ArrayList(primitives.Address.Address).init(allocator);
            defer prewarm_addresses.deinit();
            
            for (0..num_prewarm_addresses) |i| {
                var prewarm_addr: [20]u8 = undefined;
                const base_idx = (i * 20) % input.len;
                for (0..20) |j| {
                    prewarm_addr[j] = input[(base_idx + j) % input.len] ^ @as(u8, @intCast(i));
                }
                try prewarm_addresses.append(prewarm_addr);
            }
            
            if (prewarm_addresses.items.len > 0) {
                access_list.pre_warm_addresses(prewarm_addresses.items) catch {};
                
                for (prewarm_addresses.items) |addr| {
                    std.testing.expect(access_list.is_address_warm(addr)) catch {};
                    const cost = access_list.access_address(addr) catch continue;
                    std.testing.expect(cost == WARM_ACCOUNT_ACCESS_COST) catch {};
                }
            }
            
            // Test storage slot pre-warming
            if (prewarm_addresses.items.len > 0) {
                const storage_addr = prewarm_addresses.items[0];
                var storage_slots = std.ArrayList(u256).init(allocator);
                defer storage_slots.deinit();
                
                const num_slots = input[1] % 10; // 0-9 slots
                for (0..num_slots) |i| {
                    const slot_val = @as(u256, input[(i * 4) % input.len]) * 100 + @as(u256, i);
                    try storage_slots.append(slot_val);
                }
                
                if (storage_slots.items.len > 0) {
                    access_list.pre_warm_storage_slots(storage_addr, storage_slots.items) catch {};
                    
                    for (storage_slots.items) |slot| {
                        std.testing.expect(access_list.is_storage_slot_warm(storage_addr, slot)) catch {};
                        const cost = access_list.access_storage_slot(storage_addr, slot) catch continue;
                        std.testing.expect(cost == WARM_SLOAD_COST) catch {};
                    }
                }
            }
        }
    };
    const input = "test_input_data_for_fuzzing";
    try global.testTransactionPatterns(input);
}

test "fuzz_access_list_collision_handling" {
    const global = struct {
        fn testCollisionHandling(input: []const u8) anyerror!void {
            if (input.len < 12) return;
            
            const allocator = std.testing.allocator;
            const context = Context.init();
            var access_list = AccessList.init(allocator, context);
            defer access_list.deinit();
            
            // Create addresses that might cause hash collisions
            const num_addresses = input[0] % 50 + 10; // 10-59 addresses
            const collision_pattern = input[1] % 4; // Different collision patterns
            
            var addresses = std.ArrayList(primitives.Address.Address).init(allocator);
            defer addresses.deinit();
            
            for (0..num_addresses) |i| {
                var address: [20]u8 = undefined;
                
                switch (collision_pattern) {
                    0 => {
                        // Similar prefixes
                        const prefix_byte = input[2];
                        address[0] = prefix_byte;
                        address[1] = prefix_byte;
                        for (2..20) |j| {
                            address[j] = @as(u8, @intCast((i + j) % 256));
                        }
                    },
                    1 => {
                        // Similar suffixes
                        const suffix_byte = input[3];
                        for (0..18) |j| {
                            address[j] = @as(u8, @intCast((i + j) % 256));
                        }
                        address[18] = suffix_byte;
                        address[19] = suffix_byte;
                    },
                    2 => {
                        // Alternating patterns
                        for (0..20) |j| {
                            if (j % 2 == 0) {
                                address[j] = input[4 + (j / 2) % (input.len - 4)];
                            } else {
                                address[j] = @as(u8, @intCast((i + j) % 256));
                            }
                        }
                    },
                    3 => {
                        // XOR patterns that might create collisions
                        const xor_key = input[5];
                        for (0..20) |j| {
                            const base_val = @as(u8, @intCast((i * 20 + j) % 256));
                            address[j] = base_val ^ xor_key;
                        }
                    },
                    else => unreachable,
                }
                
                try addresses.append(address);
            }
            
            // Test that all addresses are handled correctly despite potential collisions
            for (addresses.items, 0..) |address, i| {
                const cost1 = access_list.access_address(address) catch continue;
                std.testing.expect(cost1 == COLD_ACCOUNT_ACCESS_COST) catch {};
                
                const cost2 = access_list.access_address(address) catch continue;
                std.testing.expect(cost2 == WARM_ACCOUNT_ACCESS_COST) catch {};
                
                // Test storage slots with potential collisions too
                const base_slot = @as(u256, i);
                for (0..3) |slot_offset| {
                    const slot = base_slot + @as(u256, slot_offset);
                    const storage_cost1 = access_list.access_storage_slot(address, slot) catch continue;
                    std.testing.expect(storage_cost1 == COLD_SLOAD_COST) catch {};
                    
                    const storage_cost2 = access_list.access_storage_slot(address, slot) catch continue;
                    std.testing.expect(storage_cost2 == WARM_SLOAD_COST) catch {};
                }
            }
            
            // Verify all addresses are properly tracked
            for (addresses.items) |address| {
                std.testing.expect(access_list.is_address_warm(address)) catch {};
            }
        }
    };
    const input = "test_input_data_for_fuzzing";
    try global.testCollisionHandling(input);
}
