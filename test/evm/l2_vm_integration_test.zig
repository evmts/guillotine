const std = @import("std");
const Evm = @import("evm");
const Address = @import("Address");
const primitives = @import("primitives");

test "VM executes Optimism L1Block precompile calls" {
    const allocator = std.testing.allocator;
    
    // Create a memory database
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    // Initialize VM with Optimism chain type
    var vm = try Evm.Evm.init_with_hardfork_and_chain(allocator, db_interface, .CANCUN, .OPTIMISM);
    defer vm.deinit();
    
    // L1Block address
    const l1_block_address = Address.from_hex("0x4200000000000000000000000000000000000015") catch unreachable;
    
    // Call L1Block.number()
    const input = &[_]u8{ 0x83, 0x81, 0xf5, 0x8a }; // number() selector
    var output: [32]u8 = undefined;
    
    const result = Evm.Precompiles.execute_precompile(l1_block_address, input, &output, 1000, vm.chain_rules);
    
    try std.testing.expect(result.is_success());
    try std.testing.expectEqual(@as(u64, 100), result.get_gas_used());
    try std.testing.expectEqual(@as(usize, 32), result.get_output_size());
}

test "VM rejects L2 precompiles on Ethereum mainnet" {
    const allocator = std.testing.allocator;
    
    // Create a memory database
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    // Initialize VM with Ethereum chain type (default)
    var vm = try Evm.Evm.init_with_hardfork(allocator, db_interface, .CANCUN);
    defer vm.deinit();
    
    // Try to call L1Block on Ethereum - should fail
    const l1_block_address = Address.from_hex("0x4200000000000000000000000000000000000015") catch unreachable;
    const input = &[_]u8{ 0x83, 0x81, 0xf5, 0x8a }; // number() selector
    var output: [32]u8 = undefined;
    
    const result = Evm.Precompiles.execute_precompile(l1_block_address, input, &output, 1000, vm.chain_rules);
    
    // Should fail because L1Block is not available on Ethereum
    try std.testing.expect(result.is_failure());
}