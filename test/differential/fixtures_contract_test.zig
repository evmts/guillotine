const std = @import("std");
const FixtureContract = @import("evm").FixtureContract;
const ContractName = @import("evm").ContractName;
const Address = @import("primitives").Address.Address;

test "FixtureContract enum-based get method" {
    // Test all valid contract enums
    const weth = FixtureContract.get(.weth_mainnet);
    const chainlink = FixtureContract.get(.chainlink_price_feed);
    const compound = FixtureContract.get(.compound_cusdc);
    const opensea = FixtureContract.get(.opensea_seaport);
    const uniswap_v2 = FixtureContract.get(.uniswap_v2_router);
    const uniswap_v3 = FixtureContract.get(.uniswap_v3_pool_eth_usdc);
    const usdc = FixtureContract.get(.usdc_proxy);
    const aave = FixtureContract.get(.aave_v3_pool);
    
    // Check all contracts have bytecode, addresses, and ABIs
    const contracts = [_]FixtureContract{ weth, chainlink, compound, opensea, uniswap_v2, uniswap_v3, usdc, aave };
    for (contracts) |contract| {
        try std.testing.expect(contract.bytecode.len > 0);
        try std.testing.expect(contract.abi.len > 0);
        try std.testing.expect(!contract.address.is_zero());
    }
}

test "FixtureContract address validation" {
    const weth = FixtureContract.get(.weth_mainnet);
    const expected_weth = Address.from_hex("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2") catch unreachable;
    try std.testing.expect(weth.address.equals(expected_weth));
    
    const usdc = FixtureContract.get(.usdc_proxy);
    const expected_usdc = Address.from_hex("0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48") catch unreachable;
    try std.testing.expect(usdc.address.equals(expected_usdc));
}

test "FixtureContract bytecode content validation" {
    // Test that bytecode files are loaded correctly
    const weth = FixtureContract.get(.weth_mainnet);
    const chainlink = FixtureContract.get(.chainlink_price_feed);
    
    // WETH bytecode should be substantial
    try std.testing.expect(weth.bytecode.len > 1000);
    
    // Chainlink price feed should have bytecode
    try std.testing.expect(chainlink.bytecode.len > 100);
    
    // All contracts should have different bytecode
    try std.testing.expect(!std.mem.eql(u8, weth.bytecode, chainlink.bytecode));
}

test "FixtureContract ABI format validation" {
    const weth = FixtureContract.get(.weth_mainnet);
    
    // ABI should be JSON format
    try std.testing.expect(std.mem.startsWith(u8, weth.abi, "["));
    try std.testing.expect(std.mem.endsWith(u8, weth.abi, "]"));
    
    // Should contain function definitions
    try std.testing.expect(std.mem.indexOf(u8, weth.abi, "function") != null);
}

test "FixtureContract string-based lookup" {
    // Test the getByName method for backward compatibility
    const weth = FixtureContract.getByName("weth_mainnet");
    const enum_weth = FixtureContract.get(.weth_mainnet);
    
    // Both methods should return the same contract
    try std.testing.expect(weth.address.equals(enum_weth.address));
    try std.testing.expect(std.mem.eql(u8, weth.bytecode, enum_weth.bytecode));
    try std.testing.expect(std.mem.eql(u8, weth.abi, enum_weth.abi));
}

test "ContractName enum completeness" {
    // Test that we can iterate over all enum values
    const all_contracts = std.meta.tags(ContractName);
    try std.testing.expect(all_contracts.len == 8); // We have 8 contracts
    
    // Test that each enum value maps to a valid contract
    inline for (all_contracts) |contract_name| {
        const contract = FixtureContract.get(contract_name);
        try std.testing.expect(contract.bytecode.len > 0);
        try std.testing.expect(contract.abi.len > 0);
        try std.testing.expect(!contract.address.is_zero());
    }
}