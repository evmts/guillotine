const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const Evm = @import("evm");
const Frame = Evm.Frame;
const AccessList = Evm.AccessList;
const Context = Evm.Context;
const MemoryDatabase = Evm.MemoryDatabase;

// Test that CALL opcodes properly track cold/warm access costs
test "CALL opcode cold/warm gas costs" {
    const allocator = testing.allocator;
    
    // Setup context and access list
    const context = Context.init();
    var access_list = AccessList.init(allocator, context);
    defer access_list.deinit();
    
    // Initialize transaction (pre-warms origin and coinbase)
    const to_address = primitives.Address.from_u256(0x1234);
    try access_list.init_transaction(to_address);
    
    // Test addresses
    const cold_address = primitives.Address.from_u256(0x5678);
    const warm_address = primitives.Address.from_u256(0x9ABC);
    
    // Pre-warm one address
    try access_list.pre_warm_addresses(&[_]primitives.Address.Address{warm_address});
    
    // Test cold address access
    const cold_cost = try access_list.get_call_cost(cold_address);
    try testing.expectEqual(AccessList.COLD_CALL_EXTRA_COST, cold_cost);
    
    // Test warm address access
    const warm_cost = try access_list.get_call_cost(warm_address);
    try testing.expectEqual(@as(u64, 0), warm_cost);
    
    // Verify cold address is now warm after access
    try testing.expect(access_list.is_address_warm(cold_address));
    
    // Second access to previously cold address should be warm
    const second_cost = try access_list.get_call_cost(cold_address);
    try testing.expectEqual(@as(u64, 0), second_cost);
}

// Test that precompiled contracts are pre-warmed
test "Precompiled contracts are pre-warmed" {
    const allocator = testing.allocator;
    const context = Context.init();
    var access_list = AccessList.init(allocator, context);
    defer access_list.deinit();
    
    // Initialize transaction
    try access_list.init_transaction(null);
    
    // Check all precompiled addresses (0x01 through 0x0A)
    var i: u8 = 1;
    while (i <= 10) : (i += 1) {
        var precompile_addr: primitives.Address.Address = [_]u8{0} ** 20;
        precompile_addr[19] = i;
        
        // All precompiles should be warm
        try testing.expect(access_list.is_address_warm(precompile_addr));
        
        // Access cost should be 0 (warm)
        const cost = try access_list.get_call_cost(precompile_addr);
        try testing.expectEqual(@as(u64, 0), cost);
    }
}

// Test CREATE/CREATE2 address warming
test "CREATE marks new addresses as warm" {
    const allocator = testing.allocator;
    const context = Context.init();
    var access_list = AccessList.init(allocator, context);
    defer access_list.deinit();
    
    // Initialize transaction
    try access_list.init_transaction(null);
    
    // Simulate a newly created contract address
    const new_contract = primitives.Address.from_u256(0xDEADBEEF);
    
    // Initially, the address should be cold
    try testing.expect(!access_list.is_address_warm(new_contract));
    
    // Access the address (simulating CREATE marking it as warm)
    _ = try access_list.access_address(new_contract);
    
    // Now it should be warm
    try testing.expect(access_list.is_address_warm(new_contract));
    
    // Subsequent calls should have no extra cost
    const cost = try access_list.get_call_cost(new_contract);
    try testing.expectEqual(@as(u64, 0), cost);
}

// Test storage slot access costs
test "Storage slot cold/warm gas costs" {
    const allocator = testing.allocator;
    const context = Context.init();
    var access_list = AccessList.init(allocator, context);
    defer access_list.deinit();
    
    const contract_address = primitives.Address.from_u256(0x1234);
    const slot1: u256 = 100;
    const slot2: u256 = 200;
    
    // First access to slot1 should be cold
    const cost1 = try access_list.access_storage_slot(contract_address, slot1);
    try testing.expectEqual(AccessList.COLD_SLOAD_COST, cost1);
    
    // Second access to slot1 should be warm
    const cost2 = try access_list.access_storage_slot(contract_address, slot1);
    try testing.expectEqual(AccessList.WARM_SLOAD_COST, cost2);
    
    // First access to slot2 should be cold
    const cost3 = try access_list.access_storage_slot(contract_address, slot2);
    try testing.expectEqual(AccessList.COLD_SLOAD_COST, cost3);
    
    // Verify warmth
    try testing.expect(access_list.is_storage_slot_warm(contract_address, slot1));
    try testing.expect(access_list.is_storage_slot_warm(contract_address, slot2));
}

// Test EIP-2930 access list pre-warming
test "EIP-2930 access list pre-warming" {
    const allocator = testing.allocator;
    const context = Context.init();
    var access_list = AccessList.init(allocator, context);
    defer access_list.deinit();
    
    // Pre-warm some addresses
    const addresses = [_]primitives.Address.Address{
        primitives.Address.from_u256(0x1111),
        primitives.Address.from_u256(0x2222),
        primitives.Address.from_u256(0x3333),
    };
    
    try access_list.pre_warm_addresses(&addresses);
    
    // All should be warm with no extra cost
    for (addresses) |addr| {
        try testing.expect(access_list.is_address_warm(addr));
        const cost = try access_list.get_call_cost(addr);
        try testing.expectEqual(@as(u64, 0), cost);
    }
    
    // Pre-warm storage slots
    const contract = primitives.Address.from_u256(0x4444);
    const slots = [_]u256{ 1, 2, 3, 100, 200 };
    
    try access_list.pre_warm_storage_slots(contract, &slots);
    
    // All slots should be warm
    for (slots) |slot| {
        try testing.expect(access_list.is_storage_slot_warm(contract, slot));
        const cost = try access_list.access_storage_slot(contract, slot);
        try testing.expectEqual(AccessList.WARM_SLOAD_COST, cost);
    }
}

// Test that transaction initialization pre-warms correct addresses
test "Transaction initialization pre-warming" {
    const allocator = testing.allocator;
    const tx_origin = primitives.Address.from_u256(0xAAAA);
    const coinbase = primitives.Address.from_u256(0xBBBB);
    const to_address = primitives.Address.from_u256(0xCCCC);
    
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
    
    // Initialize transaction with a to address
    try access_list.init_transaction(to_address);
    
    // Verify pre-warmed addresses
    try testing.expect(access_list.is_address_warm(tx_origin));
    try testing.expect(access_list.is_address_warm(coinbase));
    try testing.expect(access_list.is_address_warm(to_address));
    
    // All should have no extra access cost
    try testing.expectEqual(@as(u64, 0), try access_list.get_call_cost(tx_origin));
    try testing.expectEqual(@as(u64, 0), try access_list.get_call_cost(coinbase));
    try testing.expectEqual(@as(u64, 0), try access_list.get_call_cost(to_address));
}