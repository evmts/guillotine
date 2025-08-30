const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const guillotine_evm = @import("evm");
const revm = @import("revm");
const differential_testor = @import("differential_testor.zig");

const DifferentialTestor = differential_testor.DifferentialTestor;
const ExecutionResultWithTrace = differential_testor.ExecutionResultWithTrace;
const ExecutionDiff = differential_testor.ExecutionDiff;

/// Comprehensive contract test suite for all popular contracts
pub const ComprehensiveContractTest = struct {
    testor: DifferentialTestor,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .testor = try DifferentialTestor.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.testor.deinit();
    }

    /// Load bytecode from fixture file
    fn loadBytecode(allocator: std.mem.Allocator, fixture_path: []const u8) ![]u8 {
        const cwd = std.fs.cwd();
        const file = try cwd.openFile(fixture_path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const contents = try allocator.alloc(u8, file_size);
        _ = try file.readAll(contents);

        // Remove 0x prefix if present
        const hex_str = if (std.mem.startsWith(u8, contents, "0x"))
            contents[2..]
        else
            contents;

        // Convert hex to bytes
        const bytecode_len = hex_str.len / 2;
        const bytecode = try allocator.alloc(u8, bytecode_len);
        for (0..bytecode_len) |i| {
            const hex_byte = hex_str[i * 2..i * 2 + 2];
            bytecode[i] = try std.fmt.parseInt(u8, hex_byte, 16);
        }

        allocator.free(contents);
        return bytecode;
    }

    /// Helper to create calldata with function selector
    fn createCalldata(allocator: std.mem.Allocator, selector: [4]u8, params: []const u8) ![]u8 {
        const calldata = try allocator.alloc(u8, 4 + params.len);
        @memcpy(calldata[0..4], &selector);
        if (params.len > 0) {
            @memcpy(calldata[4..], params);
        }
        return calldata;
    }

    /// Helper to create address parameter (32 bytes, zero-padded)
    fn createAddressParam(address: [20]u8) [32]u8 {
        var param = [_]u8{0} ** 32;
        @memcpy(param[12..32], &address);
        return param;
    }

    /// Helper to create uint256 parameter
    fn createUint256Param(value: u256) [32]u8 {
        var param = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &param, value, .big);
        return param;
    }

    /// Test method execution helper
    fn testMethod(self: *Self, contract_name: []const u8, method_name: []const u8, 
                  selector: [4]u8, params: []const u8, value: u64, gas_limit: u64) !void {
        const calldata = try createCalldata(self.allocator, selector, params);
        defer self.allocator.free(calldata);

        var result = try self.testor.executeAndDiff(
            self.testor.caller,
            self.testor.contract,
            value,
            calldata,
            gas_limit,
        );
        defer result.deinit();

        // If the results don't match, print the diff and fail the test
        if (!result.result_match) {
            const test_name = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{contract_name, method_name});
            defer self.allocator.free(test_name);
            
            std.log.err("Differential test failure: {s}", .{test_name});
            self.testor.printDiff(result, test_name);
            return error.DifferentialTestFailed;
        }
    }

    //////////////////////////////////////////////////////////////////////////
    // AAVE V3 Pool Tests
    //////////////////////////////////////////////////////////////////////////

    pub fn testAAVEV3Pool(self: *Self) !void {
        const bytecode = try loadBytecode(self.allocator, "src/evm/fixtures/aave-v3-pool/bytecode.txt");
        defer self.allocator.free(bytecode);

        // Test AAVE V3 Pool deployment
        try self.testor.test_bytecode(bytecode);

        // Test getUserAccountData(address user) - Read method
        // getUserAccountData(address) -> (uint256,uint256,uint256,uint256,uint256,uint256)
        const user_address = createAddressParam([_]u8{0x12} ++ [_]u8{0} ** 19);
        try self.testMethod("AAVE V3 Pool", "getUserAccountData", .{0xbf, 0x92, 0x95, 0x7c}, &user_address, 0, 1_000_000);

        // Test getReserveData(address asset) - Read method  
        // getReserveData(address) -> (tuple)
        const asset_address = createAddressParam([_]u8{0xA0, 0xb8, 0x69, 0x91, 0xc6, 0x21, 0x8b, 0x36, 0xc1, 0xd1, 0x9d, 0x4a, 0x2e, 0x9e, 0xb0, 0xce, 0x36, 0x06, 0xeb, 0x48}); // USDC
        try self.testMethod("AAVE V3 Pool", "getReserveData", .{0x35, 0xea, 0x6a, 0x75}, &asset_address, 0, 1_000_000);

        // Test supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) - Write method
        var supply_params: [128]u8 = undefined;
        @memcpy(supply_params[0..32], &asset_address); // asset
        @memcpy(supply_params[32..64], &createUint256Param(1000000)); // amount
        @memcpy(supply_params[64..96], &createAddressParam([_]u8{0x12} ++ [_]u8{0} ** 19)); // onBehalfOf
        @memcpy(supply_params[96..128], &createUint256Param(0)); // referralCode (as uint256 for simplicity)
        try self.testMethod("AAVE V3 Pool", "supply", .{0x61, 0x7b, 0xa0, 0x37}, supply_params[0..128], 0, 2_000_000);
    }

    //////////////////////////////////////////////////////////////////////////  
    // Chainlink Price Feed Tests
    //////////////////////////////////////////////////////////////////////////

    pub fn testChainlinkPriceFeed(self: *Self) !void {
        const bytecode = try loadBytecode(self.allocator, "src/evm/fixtures/chainlink-price-feed/bytecode.txt");
        defer self.allocator.free(bytecode);

        // Test Chainlink Price Feed deployment
        try self.testor.test_bytecode(bytecode);

        // Test latestRoundData() - Read method
        // latestRoundData() -> (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
        try self.testMethod("Chainlink Price Feed", "latestRoundData", .{0xfe, 0xaf, 0x96, 0x8c}, &.{}, 0, 1_000_000);

        // Test decimals() - Read method
        // decimals() -> uint8
        try self.testMethod("Chainlink Price Feed", "decimals", .{0x31, 0x3c, 0xe5, 0x67}, &.{}, 0, 100_000);

        // Test latestAnswer() - Read method  
        // latestAnswer() -> int256
        try self.testMethod("Chainlink Price Feed", "latestAnswer", .{0x50, 0xd2, 0x5b, 0xcd}, &.{}, 0, 100_000);
    }

    //////////////////////////////////////////////////////////////////////////
    // Compound cUSDC Tests  
    //////////////////////////////////////////////////////////////////////////

    pub fn testCompoundCUSDC(self: *Self) !void {
        const bytecode = try loadBytecode(self.allocator, "src/evm/fixtures/compound-cusdc/bytecode.txt");
        defer self.allocator.free(bytecode);

        // Test Compound cUSDC deployment
        try self.testor.test_bytecode(bytecode);

        // Test totalSupply() - Read method
        // totalSupply() -> uint256
        try self.testMethod("Compound cUSDC", "totalSupply", .{0x18, 0x16, 0x0d, 0xdd}, &.{}, 0, 200_000);

        // Test exchangeRateStored() - Read method  
        // exchangeRateStored() -> uint256
        try self.testMethod("Compound cUSDC", "exchangeRateStored", .{0x18, 0x2d, 0xf0, 0xf5}, &.{}, 0, 200_000);

        // Test balanceOf(address) - Read method
        // balanceOf(address) -> uint256
        const account_address = createAddressParam([_]u8{0x12} ++ [_]u8{0} ** 19);
        try self.testMethod("Compound cUSDC", "balanceOf", .{0x70, 0xa0, 0x82, 0x31}, &account_address, 0, 200_000);

        // Test mint(uint256) - Write method  
        // mint(uint256 mintAmount) -> uint256
        const mint_amount = createUint256Param(1000000);
        try self.testMethod("Compound cUSDC", "mint", .{0xa0, 0x71, 0x2d, 0x68}, &mint_amount, 0, 1_000_000);

        // Test redeem(uint256) - Write method
        // redeem(uint256 redeemTokens) -> uint256  
        const redeem_amount = createUint256Param(100000);
        try self.testMethod("Compound cUSDC", "redeem", .{0xdb, 0x00, 0x6a, 0x75}, &redeem_amount, 0, 1_000_000);
    }

    //////////////////////////////////////////////////////////////////////////
    // OpenSea Seaport Tests
    //////////////////////////////////////////////////////////////////////////

    pub fn testOpenSeaSeaport(self: *Self) !void {
        const bytecode = try loadBytecode(self.allocator, "src/evm/fixtures/opensea-seaport/bytecode.txt");
        defer self.allocator.free(bytecode);

        // Test OpenSea Seaport deployment
        try self.testor.test_bytecode(bytecode);

        // Test name() - Read method
        // name() -> string
        try self.testMethod("OpenSea Seaport", "name", .{0x06, 0xfd, 0xde, 0x03}, &.{}, 0, 200_000);

        // Test getOrderHash(OrderComponents) - Read method
        // This is complex, so we'll pass empty tuple for now
        var order_data = [_]u8{0} ** 320; // Simplified order structure
        try self.testMethod("OpenSea Seaport", "getOrderHash", .{0x79, 0xdf, 0x72, 0xbd}, &order_data, 0, 1_000_000);

        // Test getOrderStatus(bytes32) - Read method
        // getOrderStatus(bytes32 orderHash) -> (bool,bool,uint256,uint256)
        const order_hash = createUint256Param(0x1234567890abcdef);
        try self.testMethod("OpenSea Seaport", "getOrderStatus", .{0x46, 0x42, 0x37, 0x65}, &order_hash, 0, 500_000);
    }

    //////////////////////////////////////////////////////////////////////////
    // Uniswap V2 Router Tests
    //////////////////////////////////////////////////////////////////////////

    pub fn testUniswapV2Router(self: *Self) !void {
        const bytecode = try loadBytecode(self.allocator, "src/evm/fixtures/uniswap-v2-router/bytecode.txt");
        defer self.allocator.free(bytecode);

        // Test Uniswap V2 Router deployment
        try self.testor.test_bytecode(bytecode);

        // Test factory() - Read method
        // factory() -> address
        try self.testMethod("Uniswap V2 Router", "factory", .{0xc4, 0x5a, 0x01, 0x55}, &.{}, 0, 200_000);

        // Test WETH() - Read method
        // WETH() -> address  
        try self.testMethod("Uniswap V2 Router", "WETH", .{0xad, 0x5c, 0x46, 0x48}, &.{}, 0, 200_000);

        // Test getAmountsOut(uint256,address[]) - Read method
        var amounts_out_params: [160]u8 = undefined;
        @memcpy(amounts_out_params[0..32], &createUint256Param(1000000)); // amountIn
        // Simplified path array (offset + length + addresses)
        @memcpy(amounts_out_params[32..64], &createUint256Param(64)); // path array offset
        @memcpy(amounts_out_params[64..96], &createUint256Param(2)); // path array length
        @memcpy(amounts_out_params[96..128], &createAddressParam([_]u8{0xA0, 0xb8, 0x69, 0x91, 0xc6, 0x21, 0x8b, 0x36, 0xc1, 0xd1, 0x9d, 0x4a, 0x2e, 0x9e, 0xb0, 0xce, 0x36, 0x06, 0xeb, 0x48})); // USDC
        @memcpy(amounts_out_params[128..160], &createAddressParam([_]u8{0xC0, 0x2a, 0xaA, 0x39, 0xb2, 0x23, 0xFE, 0x8D, 0x0A, 0x0e, 0x5C, 0x4F, 0x27, 0xeA, 0xD9, 0x08, 0x3C, 0x75, 0x6C, 0xc2})); // WETH
        try self.testMethod("Uniswap V2 Router", "getAmountsOut", .{0xd0, 0x6c, 0xa6, 0x1f}, amounts_out_params[0..160], 0, 1_000_000);
    }

    //////////////////////////////////////////////////////////////////////////
    // Uniswap V3 Pool Tests
    //////////////////////////////////////////////////////////////////////////

    pub fn testUniswapV3Pool(self: *Self) !void {
        const bytecode = try loadBytecode(self.allocator, "src/evm/fixtures/uniswap-v3-pool-eth-usdc/bytecode.txt");
        defer self.allocator.free(bytecode);

        // Test Uniswap V3 Pool deployment
        try self.testor.test_bytecode(bytecode);

        // Test token0() - Read method
        // token0() -> address
        try self.testMethod("Uniswap V3 Pool", "token0", .{0x0d, 0xfe, 0x16, 0x81}, &.{}, 0, 200_000);

        // Test token1() - Read method  
        // token1() -> address
        try self.testMethod("Uniswap V3 Pool", "token1", .{0xd2, 0x1c, 0x20, 0xc0}, &.{}, 0, 200_000);

        // Test fee() - Read method
        // fee() -> uint24
        try self.testMethod("Uniswap V3 Pool", "fee", .{0xdd, 0xca, 0x3f, 0x43}, &.{}, 0, 200_000);

        // Test slot0() - Read method  
        // slot0() -> (uint160,int24,uint16,uint16,uint16,uint8,bool)
        try self.testMethod("Uniswap V3 Pool", "slot0", .{0x35, 0x14, 0xa9, 0xd7}, &.{}, 0, 500_000);

        // Test liquidity() - Read method
        // liquidity() -> uint128
        try self.testMethod("Uniswap V3 Pool", "liquidity", .{0x12, 0x8a, 0xcb, 0x08}, &.{}, 0, 200_000);
    }

    //////////////////////////////////////////////////////////////////////////
    // USDC Proxy Tests (Enhanced with full implementation methods)
    //////////////////////////////////////////////////////////////////////////

    pub fn testUSDCProxy(self: *Self) !void {
        const bytecode = try loadBytecode(self.allocator, "src/evm/fixtures/usdc-proxy/bytecode.txt");
        defer self.allocator.free(bytecode);

        // Test USDC Proxy deployment
        try self.testor.test_bytecode(bytecode);

        // Basic ERC-20 Read methods
        // totalSupply() -> uint256
        try self.testMethod("USDC Proxy", "totalSupply", .{0x18, 0x16, 0x0d, 0xdd}, &.{}, 0, 200_000);

        // decimals() -> uint8
        try self.testMethod("USDC Proxy", "decimals", .{0x31, 0x3c, 0xe5, 0x67}, &.{}, 0, 100_000);

        // balanceOf(address) -> uint256
        const account_address = createAddressParam([_]u8{0x12} ++ [_]u8{0} ** 19);
        try self.testMethod("USDC Proxy", "balanceOf", .{0x70, 0xa0, 0x82, 0x31}, &account_address, 0, 200_000);

        // allowance(address,address) -> uint256
        var allowance_params: [64]u8 = undefined;
        @memcpy(allowance_params[0..32], &account_address); // owner
        @memcpy(allowance_params[32..64], &createAddressParam([_]u8{0x34} ++ [_]u8{0} ** 19)); // spender
        try self.testMethod("USDC Proxy", "allowance", .{0xdd, 0x62, 0xed, 0x3e}, allowance_params[0..64], 0, 200_000);

        // Enhanced proxy-specific Read methods
        // paused() -> bool
        try self.testMethod("USDC Proxy", "paused", .{0x5c, 0x97, 0x52, 0x35}, &.{}, 0, 100_000);

        // isBlacklisted(address) -> bool  
        try self.testMethod("USDC Proxy", "isBlacklisted", .{0xfe, 0x57, 0x5a, 0x87}, &account_address, 0, 200_000);

        // isMinter(address) -> bool
        try self.testMethod("USDC Proxy", "isMinter", .{0xaa, 0x27, 0x1e, 0x1a}, &account_address, 0, 200_000);

        // minterAllowance(address) -> uint256  
        try self.testMethod("USDC Proxy", "minterAllowance", .{0x8a, 0x6d, 0xb9, 0xc3}, &account_address, 0, 200_000);

        // owner() -> address
        try self.testMethod("USDC Proxy", "owner", .{0x8d, 0xa5, 0xcb, 0x5c}, &.{}, 0, 100_000);

        // masterMinter() -> address
        try self.testMethod("USDC Proxy", "masterMinter", .{0x35, 0xd9, 0x9f, 0x35}, &.{}, 0, 100_000);

        // Basic Write methods (these will likely fail due to permissions, but good to test)
        // transfer(address,uint256) -> bool
        var transfer_params: [64]u8 = undefined;
        @memcpy(transfer_params[0..32], &createAddressParam([_]u8{0x56} ++ [_]u8{0} ** 19)); // to
        @memcpy(transfer_params[32..64], &createUint256Param(1000)); // amount
        try self.testMethod("USDC Proxy", "transfer", .{0xa9, 0x05, 0x9c, 0xbb}, transfer_params[0..64], 0, 500_000);

        // approve(address,uint256) -> bool
        var approve_params: [64]u8 = undefined;
        @memcpy(approve_params[0..32], &createAddressParam([_]u8{0x78} ++ [_]u8{0} ** 19)); // spender  
        @memcpy(approve_params[32..64], &createUint256Param(5000)); // amount
        try self.testMethod("USDC Proxy", "approve", .{0x09, 0x5e, 0xa7, 0xb3}, approve_params[0..64], 0, 500_000);
    }

    //////////////////////////////////////////////////////////////////////////
    // WETH Mainnet Tests
    //////////////////////////////////////////////////////////////////////////

    pub fn testWETHMainnet(self: *Self) !void {
        const bytecode = try loadBytecode(self.allocator, "src/evm/fixtures/weth-mainnet/bytecode.txt");
        defer self.allocator.free(bytecode);

        // Test WETH deployment
        try self.testor.test_bytecode(bytecode);

        // Read methods
        // totalSupply() -> uint256
        try self.testMethod("WETH Mainnet", "totalSupply", .{0x18, 0x16, 0x0d, 0xdd}, &.{}, 0, 200_000);

        // balanceOf(address) -> uint256
        const account_address = createAddressParam([_]u8{0x12} ++ [_]u8{0} ** 19);
        try self.testMethod("WETH Mainnet", "balanceOf", .{0x70, 0xa0, 0x82, 0x31}, &account_address, 0, 200_000);

        // allowance(address,address) -> uint256
        var allowance_params: [64]u8 = undefined;
        @memcpy(allowance_params[0..32], &account_address); // owner
        @memcpy(allowance_params[32..64], &createAddressParam([_]u8{0x34} ++ [_]u8{0} ** 19)); // spender
        try self.testMethod("WETH Mainnet", "allowance", .{0xdd, 0x62, 0xed, 0x3e}, allowance_params[0..64], 0, 200_000);

        // Write methods
        // deposit() payable
        try self.testMethod("WETH Mainnet", "deposit", .{0xd0, 0xe3, 0x0d, 0xb0}, &.{}, 1000000000000000000, 300_000); // 1 ETH

        // withdraw(uint256)
        const withdraw_amount = createUint256Param(500000000000000000); // 0.5 ETH  
        try self.testMethod("WETH Mainnet", "withdraw", .{0x2e, 0x1a, 0x7d, 0x4d}, &withdraw_amount, 0, 300_000);

        // transfer(address,uint256) -> bool
        var transfer_params: [64]u8 = undefined;
        @memcpy(transfer_params[0..32], &createAddressParam([_]u8{0x56} ++ [_]u8{0} ** 19)); // to
        @memcpy(transfer_params[32..64], &createUint256Param(100000000000000000)); // 0.1 ETH
        try self.testMethod("WETH Mainnet", "transfer", .{0xa9, 0x05, 0x9c, 0xbb}, transfer_params[0..64], 0, 300_000);

        // approve(address,uint256) -> bool  
        var approve_params: [64]u8 = undefined;
        @memcpy(approve_params[0..32], &createAddressParam([_]u8{0x78} ++ [_]u8{0} ** 19)); // spender
        @memcpy(approve_params[32..64], &createUint256Param(1000000000000000000)); // 1 ETH
        try self.testMethod("WETH Mainnet", "approve", .{0x09, 0x5e, 0xa7, 0xb3}, approve_params[0..64], 0, 300_000);
    }
};

//////////////////////////////////////////////////////////////////////////
// Individual Test Functions
//////////////////////////////////////////////////////////////////////////

test "AAVE V3 Pool comprehensive differential test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_suite = try ComprehensiveContractTest.init(allocator);
    defer test_suite.deinit();

    try test_suite.testAAVEV3Pool();
}

test "Chainlink Price Feed comprehensive differential test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_suite = try ComprehensiveContractTest.init(allocator);
    defer test_suite.deinit();

    try test_suite.testChainlinkPriceFeed();
}

test "Compound cUSDC comprehensive differential test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_suite = try ComprehensiveContractTest.init(allocator);
    defer test_suite.deinit();

    try test_suite.testCompoundCUSDC();
}

test "OpenSea Seaport comprehensive differential test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_suite = try ComprehensiveContractTest.init(allocator);
    defer test_suite.deinit();

    try test_suite.testOpenSeaSeaport();
}

test "Uniswap V2 Router comprehensive differential test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_suite = try ComprehensiveContractTest.init(allocator);
    defer test_suite.deinit();

    try test_suite.testUniswapV2Router();
}

test "Uniswap V3 Pool comprehensive differential test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_suite = try ComprehensiveContractTest.init(allocator);
    defer test_suite.deinit();

    try test_suite.testUniswapV3Pool();
}

test "USDC Proxy comprehensive differential test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_suite = try ComprehensiveContractTest.init(allocator);
    defer test_suite.deinit();

    try test_suite.testUSDCProxy();
}

test "WETH Mainnet comprehensive differential test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_suite = try ComprehensiveContractTest.init(allocator);
    defer test_suite.deinit();

    try test_suite.testWETHMainnet();
}