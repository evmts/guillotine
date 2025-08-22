const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const testing = std.testing;

// Helper function to create EVM execution context with custom environment
fn create_evm_context_with_env(allocator: std.mem.Allocator, env_config: struct {
    contract_address: ?primitives.Address = null,
    caller: ?primitives.Address = null,
    origin: ?primitives.Address = null,
    call_value: ?u256 = null,
    gas_price: ?u256 = null,
    block_number: ?u256 = null,
    timestamp: ?u256 = null,
    gas_limit: ?u256 = null,
    coinbase: ?primitives.Address = null,
    chain_id: ?u256 = null,
    base_fee: ?u256 = null,
}) !struct {
    db: evm.MemoryDatabase,
    vm: evm.Evm,
    contract: evm.Contract,
    frame: evm.Frame,
} {
    var db = evm.MemoryDatabase.init(allocator);
    var vm = try evm.Evm.init(allocator, db.to_database_interface(), null, null);
    
    const test_code = [_]u8{0x01}; // Simple ADD opcode
    
    // Set up contract with custom parameters
    const contract_addr = env_config.contract_address orelse primitives.Address.ZERO;
    const caller_addr = env_config.caller orelse primitives.Address.ZERO;
    const call_value = env_config.call_value orelse 0;
    
    var contract = evm.Contract.init(
        contract_addr,
        caller_addr,
        call_value,
        1000000,
        &test_code,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    
    var frame = try evm.Frame.init(allocator, &contract);
    frame.gas_remaining = 1000000;
    
    // Configure VM environment if specified
    if (env_config.origin) |origin| {
        vm.env.tx.caller = origin;
    }
    if (env_config.gas_price) |gas_price| {
        vm.env.tx.gas_price = gas_price;
    }
    if (env_config.block_number) |block_number| {
        vm.env.block.number = block_number;
    }
    if (env_config.timestamp) |timestamp| {
        vm.env.block.timestamp = timestamp;
    }
    if (env_config.gas_limit) |gas_limit| {
        vm.env.block.gas_limit = gas_limit;
    }
    if (env_config.coinbase) |coinbase| {
        vm.env.block.coinbase = coinbase;
    }
    if (env_config.chain_id) |chain_id| {
        vm.env.cfg.chain_id = chain_id;
    }
    if (env_config.base_fee) |base_fee| {
        vm.env.block.basefee = base_fee;
    }
    
    return .{
        .db = db,
        .vm = vm,
        .contract = contract,
        .frame = frame,
    };
}

fn deinit_evm_context(ctx: anytype, allocator: std.mem.Allocator) void {
    ctx.frame.deinit(std.testing.allocator);
    ctx.contract.deinit(allocator, null);
    ctx.vm.deinit();
    ctx.db.deinit();
}

// Comprehensive ADDRESS operation fuzz testing
test "fuzz_address_current_contract_address" {
    const allocator = testing.allocator;
    
    const address_tests = [_]struct {
        address: primitives.Address,
        description: []const u8,
    }{
        // Zero address
        .{
            .address = primitives.Address.ZERO,
            .description = "Zero address",
        },
        
        // Standard Ethereum addresses
        .{
            .address = primitives.Address{ .bytes = [_]u8{0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0} ++ ([_]u8{0x11} ** 12) },
            .description = "Standard address pattern",
        },
        
        // Maximum address (all 0xFF)
        .{
            .address = primitives.Address{ .bytes = [_]u8{0xFF} ** 20 },
            .description = "Maximum address",
        },
        
        // Common Ethereum addresses (like precompiles)
        .{
            .address = primitives.Address{ .bytes = [_]u8{0x00} ** 19 ++ [_]u8{0x01} },
            .description = "Precompile address 0x01",
        },
        
        .{
            .address = primitives.Address{ .bytes = [_]u8{0x00} ** 19 ++ [_]u8{0x09} },
            .description = "Precompile address 0x09",
        },
        
        // Random patterns
        .{
            .address = primitives.Address{ .bytes = [_]u8{0xAA, 0xBB, 0xCC, 0xDD, 0xEE} ++ ([_]u8{0x55} ** 15) },
            .description = "Pattern address",
        },
        
        // Ethereum mainnet-like addresses
        .{
            .address = primitives.Address{ .bytes = [_]u8{0xd8, 0xdA, 0x6B, 0xF2, 0x69, 0x64, 0xaF, 0x9D, 0x7e, 0xEd, 0x9e, 0x03, 0xE5, 0x34, 0x15, 0xD3, 0x7a, 0xA9, 0x60, 0x45} },
            .description = "Mainnet-like address",
        },
    };
    
    for (address_tests) |test_case| {
        var ctx = try create_evm_context_with_env(allocator, .{ .contract_address = test_case.address });
        defer deinit_evm_context(ctx, allocator);
        
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = evm.Operation.State = &ctx.frame;
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x30); // ADDRESS
        
        const result = try ctx.frame.stack.pop();
        
        // Convert address to u256 (address is stored in lower 160 bits)
        var expected: u256 = 0;
        for (test_case.address.bytes, 0..) |byte, i| {
            expected |= (@as(u256, byte) << @intCast((19 - i) * 8));
        }
        
        try testing.expectEqual(expected, result);
    }
}

// Comprehensive CALLER operation fuzz testing
test "fuzz_caller_address_edge_cases" {
    const allocator = testing.allocator;
    
    const caller_tests = [_]struct {
        caller: primitives.Address,
        description: []const u8,
    }{
        // Zero caller
        .{
            .caller = primitives.Address.ZERO,
            .description = "Zero caller",
        },
        
        // EOA-like caller
        .{
            .caller = primitives.Address{ .bytes = [_]u8{0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x12, 0x34, 0x56, 0x78} },
            .description = "EOA-like caller",
        },
        
        // Contract-like caller
        .{
            .caller = primitives.Address{ .bytes = [_]u8{0xCA, 0xFE, 0xBA, 0xBE} ++ ([_]u8{0x00} ** 16) },
            .description = "Contract-like caller",
        },
        
        // Maximum caller
        .{
            .caller = primitives.Address{ .bytes = [_]u8{0xFF} ** 20 },
            .description = "Maximum caller",
        },
    };
    
    for (caller_tests) |test_case| {
        var ctx = try create_evm_context_with_env(allocator, .{ .caller = test_case.caller });
        defer deinit_evm_context(ctx, allocator);
        
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = evm.Operation.State = &ctx.frame;
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x33); // CALLER
        
        const result = try ctx.frame.stack.pop();
        
        // Convert caller address to u256
        var expected: u256 = 0;
        for (test_case.caller.bytes, 0..) |byte, i| {
            expected |= (@as(u256, byte) << @intCast((19 - i) * 8));
        }
        
        try testing.expectEqual(expected, result);
    }
}

// Comprehensive CALLVALUE operation fuzz testing
test "fuzz_callvalue_edge_cases" {
    const allocator = testing.allocator;
    
    const value_tests = [_]u256{
        0, // Zero value (most common)
        1, // Minimal value
        1000000000000000000, // 1 ether in wei
        std.math.maxInt(u64), // Large but reasonable value
        std.math.maxInt(u128), // Very large value
        std.math.maxInt(u256), // Maximum possible value
        
        // Common Ethereum amounts
        1000000000, // 1 Gwei
        21000000000000000, // 0.021 ether (typical transaction cost)
        500000000000000000, // 0.5 ether
        
        // Powers of 2
        1 << 32,
        1 << 64,
        1 << 128,
        1 << 255,
        
        // Random large values
        0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0,
        0xFEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210,
    };
    
    for (value_tests) |test_value| {
        var ctx = try create_evm_context_with_env(allocator, .{ .call_value = test_value });
        defer deinit_evm_context(ctx, allocator);
        
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = evm.Operation.State = &ctx.frame;
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x34); // CALLVALUE
        
        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(test_value, result);
    }
}

// Comprehensive ORIGIN operation fuzz testing
test "fuzz_origin_transaction_originator" {
    const allocator = testing.allocator;
    
    const origin_tests = [_]struct {
        origin: primitives.Address,
        description: []const u8,
    }{
        // Zero origin (should not happen in practice but test anyway)
        .{
            .origin = primitives.Address.ZERO,
            .description = "Zero origin",
        },
        
        // Typical EOA origin
        .{
            .origin = primitives.Address{ .bytes = [_]u8{0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E, 0x7F, 0x80, 0x81, 0x82, 0x83} },
            .description = "Typical EOA origin",
        },
        
        // Maximum origin
        .{
            .origin = primitives.Address{ .bytes = [_]u8{0xFF} ** 20 },
            .description = "Maximum origin",
        },
        
        // Pattern-based origins
        .{
            .origin = primitives.Address{ .bytes = [_]u8{0xAA} ** 20 },
            .description = "Pattern origin (all 0xAA)",
        },
        
        .{
            .origin = primitives.Address{ .bytes = [_]u8{0x55} ** 20 },
            .description = "Pattern origin (all 0x55)",
        },
    };
    
    for (origin_tests) |test_case| {
        var ctx = try create_evm_context_with_env(allocator, .{ .origin = test_case.origin });
        defer deinit_evm_context(ctx, allocator);
        
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = evm.Operation.State = &ctx.frame;
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x32); // ORIGIN
        
        const result = try ctx.frame.stack.pop();
        
        // Convert origin address to u256
        var expected: u256 = 0;
        for (test_case.origin.bytes, 0..) |byte, i| {
            expected |= (@as(u256, byte) << @intCast((19 - i) * 8));
        }
        
        try testing.expectEqual(expected, result);
    }
}

// Comprehensive GASPRICE operation fuzz testing
test "fuzz_gasprice_edge_cases" {
    const allocator = testing.allocator;
    
    const gas_price_tests = [_]u256{
        0, // Zero gas price (should not happen but test anyway)
        1, // Minimal gas price
        1000000000, // 1 Gwei (common gas price)
        20000000000, // 20 Gwei (typical gas price)
        100000000000, // 100 Gwei (high gas price)
        1000000000000, // 1000 Gwei (very high gas price)
        
        // Maximum reasonable gas prices
        std.math.maxInt(u64),
        std.math.maxInt(u128),
        std.math.maxInt(u256),
        
        // Powers of 2
        1 << 32,
        1 << 64,
        1 << 128,
        
        // Random values
        0x123456789ABCDEF0,
        0xFEDCBA9876543210,
    };
    
    for (gas_price_tests) |test_gas_price| {
        var ctx = try create_evm_context_with_env(allocator, .{ .gas_price = test_gas_price });
        defer deinit_evm_context(ctx, allocator);
        
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = evm.Operation.State = &ctx.frame;
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x3A); // GASPRICE
        
        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(test_gas_price, result);
    }
}

// Comprehensive block environment operations fuzz testing (COINBASE, TIMESTAMP, NUMBER, GASLIMIT)
test "fuzz_block_environment_opcodes" {
    const allocator = testing.allocator;
    
    const block_tests = [_]struct {
        coinbase: primitives.Address,
        timestamp: u256,
        number: u256,
        gas_limit: u256,
        description: []const u8,
    }{
        // Genesis-like block
        .{
            .coinbase = primitives.Address.ZERO,
            .timestamp = 0,
            .number = 0,
            .gas_limit = 5000000,
            .description = "Genesis-like block",
        },
        
        // Typical mainnet block
        .{
            .coinbase = primitives.Address{ .bytes = [_]u8{0x12, 0x34, 0x56, 0x78, 0x9A} ++ ([_]u8{0xBC} ** 15) },
            .timestamp = 1640995200, // 2022-01-01 00:00:00 UTC
            .number = 13916166, // Block around that time
            .gas_limit = 30000000, // 30M gas limit
            .description = "Typical mainnet block",
        },
        
        // Future block
        .{
            .coinbase = primitives.Address{ .bytes = [_]u8{0xFF, 0xEE, 0xDD, 0xCC, 0xBB} ++ ([_]u8{0xAA} ** 15) },
            .timestamp = 2000000000, // Far future timestamp
            .number = 50000000, // Future block number
            .gas_limit = 100000000, // Large gas limit
            .description = "Future block",
        },
        
        // Edge case: maximum values
        .{
            .coinbase = primitives.Address{ .bytes = [_]u8{0xFF} ** 20 },
            .timestamp = std.math.maxInt(u256),
            .number = std.math.maxInt(u256),
            .gas_limit = std.math.maxInt(u256),
            .description = "Maximum values",
        },
        
        // Edge case: powers of 2
        .{
            .coinbase = primitives.Address{ .bytes = [_]u8{0x80} ++ ([_]u8{0x00} ** 19) },
            .timestamp = 1 << 32,
            .number = 1 << 24,
            .gas_limit = 1 << 26,
            .description = "Powers of 2",
        },
    };
    
    for (block_tests) |test_case| {
        var ctx = try create_evm_context_with_env(allocator, .{
            .coinbase = test_case.coinbase,
            .timestamp = test_case.timestamp,
            .block_number = test_case.number,
            .gas_limit = test_case.gas_limit,
        });
        defer deinit_evm_context(ctx, allocator);
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = evm.Operation.State = &ctx.frame;
        
        // Test COINBASE
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }
            
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x41); // COINBASE
            const coinbase_result = try ctx.frame.stack.pop();
            
            // Convert coinbase address to u256
            var expected_coinbase: u256 = 0;
            for (test_case.coinbase.bytes, 0..) |byte, i| {
                expected_coinbase |= (@as(u256, byte) << @intCast((19 - i) * 8));
            }
            
            try testing.expectEqual(expected_coinbase, coinbase_result);
        }
        
        // Test TIMESTAMP
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }
            
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x42); // TIMESTAMP
            const timestamp_result = try ctx.frame.stack.pop();
            try testing.expectEqual(test_case.timestamp, timestamp_result);
        }
        
        // Test NUMBER
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }
            
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x43); // NUMBER
            const number_result = try ctx.frame.stack.pop();
            try testing.expectEqual(test_case.number, number_result);
        }
        
        // Test GASLIMIT
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }
            
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x45); // GASLIMIT
            const gas_limit_result = try ctx.frame.stack.pop();
            try testing.expectEqual(test_case.gas_limit, gas_limit_result);
        }
    }
}

// Comprehensive CHAINID operation fuzz testing
test "fuzz_chainid_edge_cases" {
    const allocator = testing.allocator;
    
    const chain_id_tests = [_]u256{
        1, // Ethereum mainnet
        3, // Ropsten (deprecated)
        4, // Rinkeby (deprecated)  
        5, // Goerli
        11155111, // Sepolia
        56, // BSC mainnet
        137, // Polygon mainnet
        42161, // Arbitrum One
        10, // Optimism
        43114, // Avalanche C-Chain
        250, // Fantom Opera
        
        // Edge cases
        0, // Invalid but test anyway
        std.math.maxInt(u64), // Large chain ID
        std.math.maxInt(u256), // Maximum chain ID
        
        // Powers of 2
        1 << 16,
        1 << 32,
        1 << 64,
        
        // Random values
        0x123456789ABCDEF0,
        0xFEDCBA9876543210,
    };
    
    for (chain_id_tests) |test_chain_id| {
        var ctx = try create_evm_context_with_env(allocator, .{ .chain_id = test_chain_id });
        defer deinit_evm_context(ctx, allocator);
        
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = evm.Operation.State = &ctx.frame;
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x46); // CHAINID
        
        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(test_chain_id, result);
    }
}

// Comprehensive BASEFEE operation fuzz testing (EIP-1559)
test "fuzz_basefee_eip1559_edge_cases" {
    const allocator = testing.allocator;
    
    const base_fee_tests = [_]u256{
        0, // Zero base fee (theoretical)
        1000000000, // 1 Gwei
        7000000000, // 7 Gwei (typical)
        50000000000, // 50 Gwei (high congestion)
        100000000000, // 100 Gwei (very high congestion)
        1000000000000, // 1000 Gwei (extreme congestion)
        
        // Edge cases
        1, // Minimal base fee
        std.math.maxInt(u64), // Large base fee
        std.math.maxInt(u256), // Maximum base fee
        
        // Powers of 2
        1 << 32,
        1 << 64,
        1 << 128,
        
        // Random values
        0x123456789ABCDEF0,
        0xFEDCBA9876543210,
    };
    
    for (base_fee_tests) |test_base_fee| {
        var ctx = try create_evm_context_with_env(allocator, .{ .base_fee = test_base_fee });
        defer deinit_evm_context(ctx, allocator);
        
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = evm.Operation.State = &ctx.frame;
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x48); // BASEFEE
        
        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(test_base_fee, result);
    }
}

// Test environment consistency across multiple calls
test "fuzz_environment_consistency" {
    const allocator = testing.allocator;
    
    const test_env = struct {
        contract_address: primitives.Address,
        caller: primitives.Address,
        origin: primitives.Address,
        call_value: u256,
        gas_price: u256,
        block_number: u256,
        timestamp: u256,
        gas_limit: u256,
        coinbase: primitives.Address,
        chain_id: u256,
        base_fee: u256,
    }{
        .contract_address = primitives.Address{ .bytes = [_]u8{0x11} ** 20 },
        .caller = primitives.Address{ .bytes = [_]u8{0x22} ** 20 },
        .origin = primitives.Address{ .bytes = [_]u8{0x33} ** 20 },
        .call_value = 1000000000000000000, // 1 ether
        .gas_price = 20000000000, // 20 Gwei
        .block_number = 18000000,
        .timestamp = 1700000000,
        .gas_limit = 30000000,
        .coinbase = primitives.Address{ .bytes = [_]u8{0x44} ** 20 },
        .chain_id = 1, // Mainnet
        .base_fee = 15000000000, // 15 Gwei
    };
    
    var ctx = try create_evm_context_with_env(allocator, .{
        .contract_address = test_env.contract_address,
        .caller = test_env.caller,
        .origin = test_env.origin,
        .call_value = test_env.call_value,
        .gas_price = test_env.gas_price,
        .block_number = test_env.block_number,
        .timestamp = test_env.timestamp,
        .gas_limit = test_env.gas_limit,
        .coinbase = test_env.coinbase,
        .chain_id = test_env.chain_id,
        .base_fee = test_env.base_fee,
    });
    defer deinit_evm_context(ctx, allocator);
    
    var interpreter = evm.Operation.Interpreter = &ctx.vm;
    var state = *evm.Operation.State = @ptrCast(&ctx.frame);
    
    // Test multiple calls to each opcode to ensure consistency
    for (0..5) |_| {
        // Test ADDRESS
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }
            
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x30); // ADDRESS
            const address_result = try ctx.frame.stack.pop();
            
            var expected_address: u256 = 0;
            for (test_env.contract_address.bytes, 0..) |byte, i| {
                expected_address |= (@as(u256, byte) << @intCast((19 - i) * 8));
            }
            try testing.expectEqual(expected_address, address_result);
        }
        
        // Test CALLER
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }
            
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x33); // CALLER
            const caller_result = try ctx.frame.stack.pop();
            
            var expected_caller: u256 = 0;
            for (test_env.caller.bytes, 0..) |byte, i| {
                expected_caller |= (@as(u256, byte) << @intCast((19 - i) * 8));
            }
            try testing.expectEqual(expected_caller, caller_result);
        }
        
        // Test CALLVALUE
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }
            
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x34); // CALLVALUE
            const value_result = try ctx.frame.stack.pop();
            try testing.expectEqual(test_env.call_value, value_result);
        }
        
        // Test GASPRICE
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }
            
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x3A); // GASPRICE
            const gas_price_result = try ctx.frame.stack.pop();
            try testing.expectEqual(test_env.gas_price, gas_price_result);
        }
        
        // Test CHAINID
        {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }
            
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x46); // CHAINID
            const chain_id_result = try ctx.frame.stack.pop();
            try testing.expectEqual(test_env.chain_id, chain_id_result);
        }
    }
}

// Random environment stress test
test "fuzz_environment_random_stress_test" {
    const allocator = testing.allocator;
    
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();
    
    // Test many random environment configurations
    for (0..50) |_| {
        // Generate random addresses
        var contract_addr: primitives.Address = undefined;
        var caller_addr: primitives.Address = undefined;
        var origin_addr: primitives.Address = undefined;
        var coinbase_addr: primitives.Address = undefined;
        
        for (&contract_addr.bytes) |*byte| byte.* = random.int(u8);
        for (&caller_addr.bytes) |*byte| byte.* = random.int(u8);
        for (&origin_addr.bytes) |*byte| byte.* = random.int(u8);
        for (&coinbase_addr.bytes) |*byte| byte.* = random.int(u8);
        
        // Generate random values
        const call_value = random.int(u256);
        const gas_price = random.intRangeAtMost(u256, 1, 1000000000000); // Reasonable gas price range
        const block_number = random.intRangeAtMost(u256, 0, 100000000); // Reasonable block range
        const timestamp = random.intRangeAtMost(u256, 1600000000, 2000000000); // Reasonable timestamp range
        const gas_limit = random.intRangeAtMost(u256, 21000, 100000000); // Reasonable gas limit range
        const chain_id = random.intRangeAtMost(u256, 1, 1000000); // Reasonable chain ID range
        const base_fee = random.intRangeAtMost(u256, 1, 1000000000000); // Reasonable base fee range
        
        var ctx = try create_evm_context_with_env(allocator, .{
            .contract_address = contract_addr,
            .caller = caller_addr,
            .origin = origin_addr,
            .call_value = call_value,
            .gas_price = gas_price,
            .block_number = block_number,
            .timestamp = timestamp,
            .gas_limit = gas_limit,
            .coinbase = coinbase_addr,
            .chain_id = chain_id,
            .base_fee = base_fee,
        });
        defer deinit_evm_context(ctx, allocator);
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = evm.Operation.State = &ctx.frame;
        
        // Test random opcode selection
        const opcodes = [_]u8{ 0x30, 0x32, 0x33, 0x34, 0x3A, 0x41, 0x42, 0x43, 0x45, 0x46, 0x48 };
        const opcode = opcodes[random.intRangeAtMost(usize, 0, opcodes.len - 1)];
        
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        // Execute the random environment opcode
        _ = try ctx.vm.table.execute(0, interpreter, state, opcode);
        
        // Verify we got a result on the stack
        const result = try ctx.frame.stack.pop();
        
        // Basic sanity check: result should be reasonable based on opcode
        switch (opcode) {
            0x30, 0x32, 0x33, 0x41 => { // ADDRESS, ORIGIN, CALLER, COINBASE (addresses)
                // Address should fit in 160 bits (20 bytes)
                try testing.expect(result <= ((1 << 160) - 1));
            },
            0x34 => { // CALLVALUE
                try testing.expectEqual(call_value, result);
            },
            0x3A => { // GASPRICE
                try testing.expectEqual(gas_price, result);
            },
            0x42 => { // TIMESTAMP
                try testing.expectEqual(timestamp, result);
            },
            0x43 => { // NUMBER
                try testing.expectEqual(block_number, result);
            },
            0x45 => { // GASLIMIT
                try testing.expectEqual(gas_limit, result);
            },
            0x46 => { // CHAINID
                try testing.expectEqual(chain_id, result);
            },
            0x48 => { // BASEFEE
                try testing.expectEqual(base_fee, result);
            },
            else => unreachable,
        }
    }
}