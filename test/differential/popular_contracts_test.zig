const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const guillotine_evm = @import("evm");
const differential_testor = @import("differential_testor.zig");

const DifferentialTestor = differential_testor.DifferentialTestor;
const ExecutionResultWithTrace = differential_testor.ExecutionResultWithTrace;
const ExecutionDiff = differential_testor.ExecutionDiff;

/// Popular contract test suite for differential testing against revm
pub const PopularContractsTest = struct {
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

    /// Test WETH contract basic functions
    pub fn testWETHContract(self: *Self) !void {
        const bytecode = try loadBytecode(self.allocator, "src/evm/fixtures/weth-mainnet/bytecode.txt");
        defer self.allocator.free(bytecode);

        // Test contract deployment by testing the bytecode - let it fail if there are bugs
        try self.testor.test_bytecode(bytecode);

        // Test deposit function (payable fallback) using executeAndDiff
        const deposit_calldata = &[_]u8{}; // Empty calldata for fallback
        const deposit_value = 1000000000000000000; // 1 ETH in wei

        var deposit_result = try self.testor.executeAndDiff(
            self.testor.caller,
            self.testor.contract,
            deposit_value,
            deposit_calldata,
            1_000_000,
        );
        defer deposit_result.deinit();

        if (!deposit_result.result_match) {
            std.log.err("WETH deposit differential test failed", .{});
            self.testor.printDiff(deposit_result, "WETH deposit");
            return error.DifferentialTestFailed;
        }

        // Test balanceOf function (0x70a08231)
        const balance_calldata = blk: {
            var calldata = try self.allocator.alloc(u8, 36);
            // balanceOf(address) selector
            calldata[0] = 0x70;
            calldata[1] = 0xa0;
            calldata[2] = 0x82;
            calldata[3] = 0x31;
            // Address parameter (32 bytes, zero-padded)
            @memset(calldata[4..], 0);
            break :blk calldata;
        };
        defer self.allocator.free(balance_calldata);

        var balance_result = try self.testor.executeAndDiff(
            self.testor.caller,
            self.testor.contract,
            0,
            balance_calldata,
            1_000_000,
        );
        defer balance_result.deinit();

        if (!balance_result.result_match) {
            std.log.err("WETH balanceOf differential test failed", .{});
            self.testor.printDiff(balance_result, "WETH balanceOf");
            return error.DifferentialTestFailed;
        }
    }

    /// Test USDC proxy contract
    pub fn testUSDCProxy(self: *Self) !void {
        const bytecode = try loadBytecode(self.allocator, "src/evm/fixtures/usdc-proxy/bytecode.txt");
        defer self.allocator.free(bytecode);

        // Test proxy deployment
        try self.testor.test_bytecode(bytecode);

        // Test implementation() function (0x5c60da1b)
        const impl_calldata = &[_]u8{ 0x5c, 0x60, 0xda, 0x1b };

        var impl_result = try self.testor.executeAndDiff(
            self.testor.caller,
            self.testor.contract,
            0,
            impl_calldata,
            1_000_000,
        );
        defer impl_result.deinit();

        if (!impl_result.result_match) {
            std.log.err("USDC implementation differential test failed", .{});
            self.testor.printDiff(impl_result, "USDC implementation");
            return error.DifferentialTestFailed;
        }
    }

    /// Test Uniswap V2 Router
    pub fn testUniswapV2Router(self: *Self) !void {
        const bytecode = try loadBytecode(self.allocator, "src/evm/fixtures/uniswap-v2-router/bytecode.txt");
        defer self.allocator.free(bytecode);

        // Test router deployment (this is a large contract)
        try self.testor.test_bytecode(bytecode);

        // Test factory() function (0xc45a0155)
        const factory_calldata = &[_]u8{ 0xc4, 0x5a, 0x01, 0x55 };

        var factory_result = try self.testor.executeAndDiff(
            self.testor.caller,
            self.testor.contract,
            0,
            factory_calldata,
            1_000_000,
        );
        defer factory_result.deinit();

        if (!factory_result.result_match) {
            std.log.err("Uniswap V2 Router factory differential test failed", .{});
            self.testor.printDiff(factory_result, "Uniswap V2 Router factory");
            return error.DifferentialTestFailed;
        }
    }

    /// Test Uniswap V3 Pool
    pub fn testUniswapV3Pool(self: *Self) !void {
        const bytecode = try loadBytecode(self.allocator, "src/evm/fixtures/uniswap-v3-pool-eth-usdc/bytecode.txt");
        defer self.allocator.free(bytecode);

        // Test pool deployment
        try self.testor.test_bytecode(bytecode);

        // Test token0() function (0x0dfe1681)
        const token0_calldata = &[_]u8{ 0x0d, 0xfe, 0x16, 0x81 };

        var token0_result = try self.testor.executeAndDiff(
            self.testor.caller,
            self.testor.contract,
            0,
            token0_calldata,
            1_000_000,
        );
        defer token0_result.deinit();

        if (!token0_result.result_match) {
            std.log.err("Uniswap V3 Pool token0 differential test failed", .{});
            self.testor.printDiff(token0_result, "Uniswap V3 Pool token0");
            return error.DifferentialTestFailed;
        }
    }

    /// Test Compound cUSDC
    pub fn testCompoundCUSDC(self: *Self) !void {
        const bytecode = try loadBytecode(self.allocator, "src/evm/fixtures/compound-cusdc/bytecode.txt");
        defer self.allocator.free(bytecode);

        // Test cUSDC deployment
        try self.testor.test_bytecode(bytecode);

        // Test totalSupply() function (0x18160ddd)
        const total_supply_calldata = &[_]u8{ 0x18, 0x16, 0x0d, 0xdd };

        var supply_result = try self.testor.executeAndDiff(
            self.testor.caller,
            self.testor.contract,
            0,
            total_supply_calldata,
            1_000_000,
        );
        defer supply_result.deinit();

        if (!supply_result.result_match) {
            std.log.err("Compound cUSDC totalSupply differential test failed", .{});
            self.testor.printDiff(supply_result, "Compound cUSDC totalSupply");
            return error.DifferentialTestFailed;
        }
    }

    /// Run comprehensive test suite on all popular contracts
    pub fn runFullTestSuite(self: *Self) !void {
        std.log.info("Starting popular contracts differential test suite...", .{});

        std.log.info("Testing WETH contract...", .{});
        try self.testWETHContract();

        std.log.info("Testing USDC proxy contract...", .{});
        try self.testUSDCProxy();

        std.log.info("Testing Uniswap V2 Router...", .{});
        try self.testUniswapV2Router();

        std.log.info("Testing Uniswap V3 Pool...", .{});
        try self.testUniswapV3Pool();

        std.log.info("Testing Compound cUSDC...", .{});
        try self.testCompoundCUSDC();

        std.log.info("Popular contracts test suite completed!", .{});
    }
};

test "Popular contracts differential testing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_suite = try PopularContractsTest.init(allocator);
    defer test_suite.deinit();

    try test_suite.runFullTestSuite();
}

test "WETH contract differential test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_suite = try PopularContractsTest.init(allocator);
    defer test_suite.deinit();

    try test_suite.testWETHContract();
}

test "USDC proxy differential test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_suite = try PopularContractsTest.init(allocator);
    defer test_suite.deinit();

    try test_suite.testUSDCProxy();
}

test "Uniswap V2 Router differential test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_suite = try PopularContractsTest.init(allocator);
    defer test_suite.deinit();

    try test_suite.testUniswapV2Router();
}

test "Uniswap V3 Pool differential test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_suite = try PopularContractsTest.init(allocator);
    defer test_suite.deinit();

    try test_suite.testUniswapV3Pool();
}

test "Compound cUSDC differential test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_suite = try PopularContractsTest.init(allocator);
    defer test_suite.deinit();

    try test_suite.testCompoundCUSDC();
}