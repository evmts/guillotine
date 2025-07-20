const std = @import("std");
const Evm = @import("evm");
const Address = @import("Address");

test "Optimism L1Block precompile integration" {
    const allocator = std.testing.allocator;
    
    // Create Optimism chain rules
    const chain_rules = Evm.chain_rules.for_hardfork_and_chain(.CANCUN, .OPTIMISM);
    
    // L1Block address
    const l1_block_address = Address.from_hex("0x4200000000000000000000000000000000000015") catch unreachable;
    
    // Check that L1Block is available on Optimism
    try std.testing.expect(Evm.Precompiles.is_available(l1_block_address, chain_rules));
    
    // number() selector
    const input = &[_]u8{ 0x83, 0x81, 0xf5, 0x8a };
    var output: [32]u8 = undefined;
    
    const result = Evm.Precompiles.execute_precompile(l1_block_address, input, &output, 1000, chain_rules);
    
    try std.testing.expect(result.is_success());
    try std.testing.expectEqual(@as(u64, 100), result.get_gas_used());
    try std.testing.expectEqual(@as(usize, 32), result.get_output_size());
    try std.testing.expectEqual(@as(u8, 0x01), output[30]);
    try std.testing.expectEqual(@as(u8, 0x00), output[31]);
}

test "L2 precompiles not available on Ethereum" {
    const allocator = std.testing.allocator;
    
    // Create Ethereum chain rules
    const chain_rules = Evm.chain_rules.for_hardfork(.CANCUN); // Defaults to ETHEREUM
    
    // L1Block address
    const l1_block_address = Address.from_hex("0x4200000000000000000000000000000000000015") catch unreachable;
    
    // Check that L2 precompiles are NOT available on Ethereum
    try std.testing.expect(!Evm.Precompiles.is_available(l1_block_address, chain_rules));
}

test "ChainType from chain ID" {
    try std.testing.expectEqual(Evm.ChainType.ETHEREUM, Evm.ChainType.fromChainId(1));
    try std.testing.expectEqual(Evm.ChainType.OPTIMISM, Evm.ChainType.fromChainId(10));
    
    // Test testnets
    try std.testing.expectEqual(Evm.ChainType.ETHEREUM, Evm.ChainType.fromChainId(11155111)); // Sepolia
    try std.testing.expectEqual(Evm.ChainType.OPTIMISM, Evm.ChainType.fromChainId(11155420)); // OP Sepolia
}