const std = @import("std");
const Abi = @import("primitives").Abi;
const Address = @import("primitives").Address.Address;
const FunctionDefinition = Abi.FunctionDefinition;
const StateMutability = Abi.StateMutability;
const AbiType = Abi.AbiType;

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

// Contract ABI structure that holds functions and events
pub const ContractAbi = struct {
    name: []const u8,
    functions: []const FunctionDefinition,
    // events: []const EventDefinition, // TODO: Add when EventDefinition is available
};

pub const FixtureContract = struct {
    bytecode: []const u8,
    address: Address,
    abi: ContractAbi,

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

// Helper functions to convert .zon data to ABI format
fn stringToAbiType(comptime type_str: []const u8) AbiType {
    if (comptime std.mem.eql(u8, type_str, "uint8")) return .uint8;
    if (comptime std.mem.eql(u8, type_str, "uint16")) return .uint16;
    if (comptime std.mem.eql(u8, type_str, "uint32")) return .uint32;
    if (comptime std.mem.eql(u8, type_str, "uint64")) return .uint64;
    if (comptime std.mem.eql(u8, type_str, "uint128")) return .uint128;
    if (comptime std.mem.eql(u8, type_str, "uint256")) return .uint256;
    if (comptime std.mem.eql(u8, type_str, "int8")) return .int8;
    if (comptime std.mem.eql(u8, type_str, "int16")) return .int16;
    if (comptime std.mem.eql(u8, type_str, "int32")) return .int32;
    if (comptime std.mem.eql(u8, type_str, "int64")) return .int64;
    if (comptime std.mem.eql(u8, type_str, "int128")) return .int128;
    if (comptime std.mem.eql(u8, type_str, "int256")) return .int256;
    if (comptime std.mem.eql(u8, type_str, "address")) return .address;
    if (comptime std.mem.eql(u8, type_str, "bool")) return .bool;
    if (comptime std.mem.eql(u8, type_str, "bytes32")) return .bytes32;
    if (comptime std.mem.eql(u8, type_str, "bytes")) return .bytes;
    if (comptime std.mem.eql(u8, type_str, "string")) return .string;
    if (comptime std.mem.eql(u8, type_str, "uint256[]")) return .uint256_array;
    if (comptime std.mem.eql(u8, type_str, "address[]")) return .address_array;
    // Handle specific sized types
    if (comptime std.mem.eql(u8, type_str, "bytes1")) return .bytes1;
    if (comptime std.mem.eql(u8, type_str, "bytes2")) return .bytes2;
    if (comptime std.mem.eql(u8, type_str, "bytes3")) return .bytes3;
    if (comptime std.mem.eql(u8, type_str, "bytes4")) return .bytes4;
    if (comptime std.mem.eql(u8, type_str, "bytes8")) return .bytes8;
    if (comptime std.mem.eql(u8, type_str, "bytes16")) return .bytes16;
    // Handle non-standard sized uints by mapping to larger types
    if (comptime std.mem.eql(u8, type_str, "uint40")) return .uint64; // Map to larger type
    if (comptime std.mem.eql(u8, type_str, "uint80")) return .uint128; // Map to larger type
    // Handle complex types by mapping to simpler types for now
    if (comptime std.mem.eql(u8, type_str, "tuple")) return .bytes32; // Temporary mapping
    if (comptime std.mem.eql(u8, type_str, "tuple[]")) return .bytes32_array; // Temporary mapping
    if (comptime std.mem.eql(u8, type_str, "tuple[][]")) return .bytes32_array; // Temporary mapping for nested arrays
    // Fallback: for any other complex type, map to bytes32
    return .bytes32;
}

fn stringToStateMutability(comptime mutability_str: []const u8) StateMutability {
    if (comptime std.mem.eql(u8, mutability_str, "pure")) return .pure;
    if (comptime std.mem.eql(u8, mutability_str, "view")) return .view;
    if (comptime std.mem.eql(u8, mutability_str, "nonpayable")) return .nonpayable;
    if (comptime std.mem.eql(u8, mutability_str, "payable")) return .payable;
    @compileError("Unsupported state mutability: " ++ mutability_str);
}

// Function to convert input/output parameters from .zon to AbiType array
fn convertZonParameters(comptime zon_params: anytype) []const AbiType {
    const fields = std.meta.fields(@TypeOf(zon_params));
    var types: [fields.len]AbiType = undefined;
    inline for (fields, 0..) |field, i| {
        const param = @field(zon_params, field.name);
        types[i] = stringToAbiType(param.type);
    }
    const result = types;
    return &result;
}

// Function to convert a .zon function definition to FunctionDefinition
fn convertZonFunction(comptime zon_func: anytype) FunctionDefinition {
    const inputs = convertZonParameters(zon_func.inputs);
    const outputs = convertZonParameters(zon_func.outputs);
    return FunctionDefinition{
        .name = zon_func.name,
        .inputs = inputs,
        .outputs = outputs,
        .state_mutability = stringToStateMutability(zon_func.stateMutability),
    };
}

// Function to convert full .zon ABI to ContractAbi
fn convertZonAbi(comptime zon_abi: anytype) ContractAbi {
    const functions_struct = zon_abi.functions;
    const function_fields = std.meta.fields(@TypeOf(functions_struct));
    
    var functions: [function_fields.len]FunctionDefinition = undefined;
    inline for (function_fields, 0..) |field, i| {
        const zon_func = @field(functions_struct, field.name);
        functions[i] = convertZonFunction(zon_func);
    }
    
    const result_functions = functions;
    return ContractAbi{
        .name = zon_abi.name,
        .functions = &result_functions,
    };
}

// AAVE V3 Pool
const aave_v3_pool_fixture = FixtureContract{
    .address = Address.from_hex("0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2") catch unreachable,
    .bytecode = @embedFile("aave-v3-pool/bytecode.txt"),
    .abi = convertZonAbi(@import("aave-v3-pool/contract.abi.zon")),
};

// Chainlink Price Feed
const chainlink_price_feed_fixture = FixtureContract{
    .address = Address.from_hex("0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419") catch unreachable,
    .bytecode = @embedFile("chainlink-price-feed/bytecode.txt"),
    .abi = convertZonAbi(@import("chainlink-price-feed/contract.abi.zon")),
};

// Compound cUSDC
const compound_cusdc_fixture = FixtureContract{
    .address = Address.from_hex("0x39AA39c021dfbaE8faC545936693aC917d5E7563") catch unreachable,
    .bytecode = @embedFile("compound-cusdc/bytecode.txt"),
    .abi = convertZonAbi(@import("compound-cusdc/contract.abi.zon")),
};

// OpenSea Seaport
const opensea_seaport_fixture = FixtureContract{
    .address = Address.from_hex("0x00000000000000ADc04C56Bf30aC9d3c0aAF14dC") catch unreachable,
    .bytecode = @embedFile("opensea-seaport/bytecode.txt"),
    .abi = convertZonAbi(@import("opensea-seaport/contract.abi.zon")),
};

// Uniswap V2 Router
const uniswap_v2_router_fixture = FixtureContract{
    .address = Address.from_hex("0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D") catch unreachable,
    .bytecode = @embedFile("uniswap-v2-router/bytecode.txt"),
    .abi = convertZonAbi(@import("uniswap-v2-router/contract.abi.zon")),
};

// Uniswap V3 Pool ETH/USDC
const uniswap_v3_pool_eth_usdc_fixture = FixtureContract{
    .address = Address.from_hex("0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8") catch unreachable,
    .bytecode = @embedFile("uniswap-v3-pool-eth-usdc/bytecode.txt"),
    .abi = convertZonAbi(@import("uniswap-v3-pool-eth-usdc/contract.abi.zon")),
};

// USDC Proxy (uses USDC implementation ABI)
const usdc_proxy_fixture = FixtureContract{
    .address = Address.from_hex("0xA0b86991c6218b36c1d19d4a2e9eb0ce3606eb48") catch unreachable,
    .bytecode = @embedFile("usdc-proxy/bytecode.txt"),
    .abi = convertZonAbi(@import("usdc-proxy/contract.abi.zon")),
};

// WETH Mainnet
const weth_mainnet_fixture = FixtureContract{
    .address = Address.from_hex("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2") catch unreachable,
    .bytecode = @embedFile("weth-mainnet/bytecode.txt"),
    .abi = convertZonAbi(@import("weth-mainnet/contract.abi.zon")),
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