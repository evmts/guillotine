const std = @import("std");
const abi = @import("primitives").abi;
const Address = @import("primitives").Address.Address;

pub const ContractName = enum {
    aave_v3_pool,
    chainlink_price_feed,
    compound_cusdc,
    opensea_seaport,
    uniswap_v2_router,
    uniswap_v3_pool_eth_usdc,
    usdc_proxy,
    weth_mainnet,
};

pub const FixtureContract = struct {
    bytecode: []const u8,
    address: Address,
    abi: []const u8, // JSON string for now, can be parsed later

    pub fn get(contract: ContractName) FixtureContract {
        return switch (contract) {
            .aave_v3_pool => aave_v3_pool_fixture,
            .chainlink_price_feed => chainlink_price_feed_fixture,
            .compound_cusdc => compound_cusdc_fixture,
            .opensea_seaport => opensea_seaport_fixture,
            .uniswap_v2_router => uniswap_v2_router_fixture,
            .uniswap_v3_pool_eth_usdc => uniswap_v3_pool_eth_usdc_fixture,
            .usdc_proxy => usdc_proxy_fixture,
            .weth_mainnet => weth_mainnet_fixture,
        };
    }
    
    // Convenience method for string-based lookup (compile-time only)
    pub fn getByName(comptime name: []const u8) FixtureContract {
        // Use compile-time string comparison since std.meta.stringToEnum seems unreliable
        if (comptime std.mem.eql(u8, name, "aave_v3_pool")) return get(.aave_v3_pool)
        else if (comptime std.mem.eql(u8, name, "chainlink_price_feed")) return get(.chainlink_price_feed)
        else if (comptime std.mem.eql(u8, name, "compound_cusdc")) return get(.compound_cusdc)
        else if (comptime std.mem.eql(u8, name, "opensea_seaport")) return get(.opensea_seaport)
        else if (comptime std.mem.eql(u8, name, "uniswap_v2_router")) return get(.uniswap_v2_router)
        else if (comptime std.mem.eql(u8, name, "uniswap_v3_pool_eth_usdc")) return get(.uniswap_v3_pool_eth_usdc)
        else if (comptime std.mem.eql(u8, name, "usdc_proxy")) return get(.usdc_proxy)
        else if (comptime std.mem.eql(u8, name, "weth_mainnet")) return get(.weth_mainnet)
        else @compileError("Invalid contract name '" ++ name ++ "'. Valid names are: aave_v3_pool, chainlink_price_feed, compound_cusdc, opensea_seaport, uniswap_v2_router, uniswap_v3_pool_eth_usdc, usdc_proxy, weth_mainnet");
    }
};

const valid_contract_names = "aave_v3_pool, chainlink_price_feed, compound_cusdc, opensea_seaport, uniswap_v2_router, uniswap_v3_pool_eth_usdc, usdc_proxy, weth_mainnet";

// AAVE V3 Pool
const aave_v3_pool_fixture = FixtureContract{
    .address = Address.from_hex("0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2") catch unreachable,
    .bytecode = @embedFile("aave-v3-pool/bytecode.txt"),
    .abi = 
    \\[{
    \\  "inputs": [{"internalType": "address", "name": "asset", "type": "address"},
    \\             {"internalType": "uint256", "name": "amount", "type": "uint256"},
    \\             {"internalType": "address", "name": "onBehalfOf", "type": "address"},
    \\             {"internalType": "uint16", "name": "referralCode", "type": "uint16"}],
    \\  "name": "supply",
    \\  "outputs": [],
    \\  "stateMutability": "nonpayable",
    \\  "type": "function"
    \\},
    \\{
    \\  "inputs": [{"internalType": "address", "name": "asset", "type": "address"},
    \\             {"internalType": "uint256", "name": "amount", "type": "uint256"},
    \\             {"internalType": "address", "name": "to", "type": "address"}],
    \\  "name": "withdraw",
    \\  "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
    \\  "stateMutability": "nonpayable",
    \\  "type": "function"
    \\}]
    ,
};

// Chainlink Price Feed
const chainlink_price_feed_fixture = FixtureContract{
    .address = Address.from_hex("0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419") catch unreachable,
    .bytecode = @embedFile("chainlink-price-feed/bytecode.txt"),
    .abi = 
    \\[{
    \\  "inputs": [],
    \\  "name": "latestRoundData",
    \\  "outputs": [
    \\    {"internalType": "uint80", "name": "roundId", "type": "uint80"},
    \\    {"internalType": "int256", "name": "answer", "type": "int256"},
    \\    {"internalType": "uint256", "name": "startedAt", "type": "uint256"},
    \\    {"internalType": "uint256", "name": "updatedAt", "type": "uint256"},
    \\    {"internalType": "uint80", "name": "answeredInRound", "type": "uint80"}
    \\  ],
    \\  "stateMutability": "view",
    \\  "type": "function"
    \\},
    \\{
    \\  "inputs": [],
    \\  "name": "decimals",
    \\  "outputs": [{"internalType": "uint8", "name": "", "type": "uint8"}],
    \\  "stateMutability": "view",
    \\  "type": "function"
    \\}]
    ,
};

// Compound cUSDC
const compound_cusdc_fixture = FixtureContract{
    .address = Address.from_hex("0x39AA39c021dfbaE8faC545936693aC917d5E7563") catch unreachable,
    .bytecode = @embedFile("compound-cusdc/bytecode.txt"),
    .abi = 
    \\[{
    \\  "inputs": [{"internalType": "uint256", "name": "mintAmount", "type": "uint256"}],
    \\  "name": "mint",
    \\  "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
    \\  "stateMutability": "nonpayable",
    \\  "type": "function"
    \\},
    \\{
    \\  "inputs": [{"internalType": "uint256", "name": "redeemTokens", "type": "uint256"}],
    \\  "name": "redeem",
    \\  "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
    \\  "stateMutability": "nonpayable",
    \\  "type": "function"
    \\}]
    ,
};

// OpenSea Seaport
const opensea_seaport_fixture = FixtureContract{
    .address = Address.from_hex("0x00000000000000ADc04C56Bf30aC9d3c0aAF14dC") catch unreachable,
    .bytecode = @embedFile("opensea-seaport/bytecode.txt"),
    .abi = 
    \\[{
    \\  "inputs": [
    \\    {"components": [
    \\      {"internalType": "address", "name": "offerer", "type": "address"},
    \\      {"internalType": "address", "name": "zone", "type": "address"}
    \\    ], "internalType": "struct Order[]", "name": "orders", "type": "tuple[]"}
    \\  ],
    \\  "name": "fulfillOrder",
    \\  "outputs": [{"internalType": "bool", "name": "fulfilled", "type": "bool"}],
    \\  "stateMutability": "payable",
    \\  "type": "function"
    \\}]
    ,
};

// Uniswap V2 Router
const uniswap_v2_router_fixture = FixtureContract{
    .address = Address.from_hex("0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D") catch unreachable,
    .bytecode = @embedFile("uniswap-v2-router/bytecode.txt"),
    .abi = 
    \\[{
    \\  "inputs": [
    \\    {"internalType": "uint256", "name": "amountOutMin", "type": "uint256"},
    \\    {"internalType": "address[]", "name": "path", "type": "address[]"},
    \\    {"internalType": "address", "name": "to", "type": "address"},
    \\    {"internalType": "uint256", "name": "deadline", "type": "uint256"}
    \\  ],
    \\  "name": "swapExactETHForTokens",
    \\  "outputs": [{"internalType": "uint256[]", "name": "amounts", "type": "uint256[]"}],
    \\  "stateMutability": "payable",
    \\  "type": "function"
    \\}]
    ,
};

// Uniswap V3 Pool ETH/USDC
const uniswap_v3_pool_eth_usdc_fixture = FixtureContract{
    .address = Address.from_hex("0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8") catch unreachable,
    .bytecode = @embedFile("uniswap-v3-pool-eth-usdc/bytecode.txt"),
    .abi = 
    \\[{
    \\  "inputs": [
    \\    {"internalType": "address", "name": "recipient", "type": "address"},
    \\    {"internalType": "bool", "name": "zeroForOne", "type": "bool"},
    \\    {"internalType": "int256", "name": "amountSpecified", "type": "int256"},
    \\    {"internalType": "uint160", "name": "sqrtPriceLimitX96", "type": "uint160"},
    \\    {"internalType": "bytes", "name": "data", "type": "bytes"}
    \\  ],
    \\  "name": "swap",
    \\  "outputs": [
    \\    {"internalType": "int256", "name": "amount0", "type": "int256"},
    \\    {"internalType": "int256", "name": "amount1", "type": "int256"}
    \\  ],
    \\  "stateMutability": "nonpayable",
    \\  "type": "function"
    \\}]
    ,
};

// USDC Proxy (uses USDC implementation ABI)
const usdc_proxy_fixture = FixtureContract{
    .address = Address.from_hex("0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48") catch unreachable,
    .bytecode = @embedFile("usdc-proxy/bytecode.txt"),
    .abi = 
    \\[{
    \\  "inputs": [
    \\    {"internalType": "address", "name": "to", "type": "address"},
    \\    {"internalType": "uint256", "name": "value", "type": "uint256"}
    \\  ],
    \\  "name": "transfer",
    \\  "outputs": [{"internalType": "bool", "name": "", "type": "bool"}],
    \\  "stateMutability": "nonpayable",
    \\  "type": "function"
    \\},
    \\{
    \\  "inputs": [{"internalType": "address", "name": "account", "type": "address"}],
    \\  "name": "balanceOf",
    \\  "outputs": [{"internalType": "uint256", "name": "", "type": "uint256"}],
    \\  "stateMutability": "view",
    \\  "type": "function"
    \\}]
    ,
};

// WETH Mainnet
const weth_mainnet_fixture = FixtureContract{
    .address = Address.from_hex("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2") catch unreachable,
    .bytecode = @embedFile("weth-mainnet/bytecode.txt"),
    .abi = 
    \\[{
    \\  "inputs": [],
    \\  "name": "deposit",
    \\  "outputs": [],
    \\  "stateMutability": "payable",
    \\  "type": "function"
    \\},
    \\{
    \\  "inputs": [{"internalType": "uint256", "name": "wad", "type": "uint256"}],
    \\  "name": "withdraw",
    \\  "outputs": [],
    \\  "stateMutability": "nonpayable",
    \\  "type": "function"
    \\}]
    ,
};

// Test to verify compile-time checking works
test "FixtureContract enum-based validation" {
    // This should compile fine with enum
    const weth = FixtureContract.get(.weth_mainnet);
    try std.testing.expect(weth.address.equals(Address.from_hex("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2") catch unreachable));
    
    // Test string-based method too
    const weth_str = FixtureContract.getByName("weth_mainnet");
    try std.testing.expect(weth_str.address.equals(weth.address));
    
    // This would cause compile error if uncommented:
    // const invalid = FixtureContract.getByName("invalid_contract");
}