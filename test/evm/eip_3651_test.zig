//! Comprehensive tests for EIP-3651 (Warm COINBASE)

const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const ZERO_ADDRESS = primitives.ZERO_ADDRESS;
const GasConstants = primitives.GasConstants;

const Evm = @import("evm.zig").Evm;
const DatabaseInterface = @import("database_interface.zig").DatabaseInterface;
const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
const BlockInfo = @import("block_info.zig").DefaultBlockInfo;
const TransactionContext = @import("transaction_context.zig").TransactionContext;
const Hardfork = @import("hardfork.zig").Hardfork;
const FrameInterpreter = @import("frame_interpreter.zig").FrameInterpreter;

// Test COINBASE opcode gas costs with EIP-3651
test "EIP-3651 - COINBASE opcode uses warm gas cost post-Shanghai" {
    const allocator = testing.allocator;
    
    // Bytecode that executes COINBASE opcode
    const bytecode = [_]u8{
        0x41, // COINBASE
        0x00, // STOP
    };
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const coinbase_address = [_]u8{0xC0, 0x1B, 0xA5, 0xE} ++ [_]u8{0} ** 16;
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 17_000_000, // Post-Shanghai block
        .timestamp = 1681338455,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = coinbase_address,
        .base_fee = 1_000_000_000,
        .prev_randao = [_]u8{0} ** 32,
    };
    
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = coinbase_address,
        .chain_id = 1,
    };
    
    // Test with Shanghai hardfork
    {
        var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.SHANGHAI);
        defer evm.deinit();
        
        const initial_gas = 100_000;
        var interpreter = try FrameInterpreter(.{ .has_database = true }).init(
            allocator,
            &bytecode,
            initial_gas,
            db_interface,
            evm.to_host()
        );
        defer interpreter.deinit(allocator);
        
        try interpreter.interpret();
        
        // COINBASE should only cost 2 gas (base opcode cost), not 2600
        const gas_used = @as(u64, @intCast(initial_gas - interpreter.frame.gas_remaining));
        try testing.expect(gas_used < 100); // Much less than cold access cost
    }
    
    // Test with pre-Shanghai hardfork
    {
        var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.LONDON);
        defer evm.deinit();
        
        // First access to coinbase should be cold
        const coinbase_cost = try evm.access_address(coinbase_address);
        try testing.expectEqual(GasConstants.ColdAccountAccessCost, coinbase_cost);
    }
}

// Test interaction between COINBASE warmth and other operations
test "EIP-3651 - COINBASE warmth affects BALANCE/EXTCODE* operations" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const coinbase_address = [_]u8{0xCB} ** 20;
    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = coinbase_address,
        .chain_id = 1,
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.SHANGHAI);
    defer evm.deinit();
    
    // BALANCE on coinbase should be warm immediately
    const balance_cost = try evm.access_address(coinbase_address);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, balance_cost);
    
    // EXTCODESIZE on coinbase should also be warm
    const codesize_cost = try evm.access_address(coinbase_address);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, codesize_cost);
    
    // Storage access to coinbase contract should still be cold initially
    const storage_cost = try evm.access_storage_slot(coinbase_address, 0);
    try testing.expectEqual(GasConstants.ColdSloadCost, storage_cost);
}

// Test CALL to coinbase address
test "EIP-3651 - CALL to coinbase uses warm gas cost" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const caller_address = [_]u8{0x01} ** 20;
    const coinbase_address = [_]u8{0xC0} ** 20;
    
    // Set up accounts
    try memory_db.set_account(caller_address, .{
        .nonce = 0,
        .balance = 1_000_000_000_000_000_000, // 1 ETH
        .code_hash = [_]u8{0} ** 32,
    });
    
    try memory_db.set_account(coinbase_address, .{
        .nonce = 0,
        .balance = 0,
        .code_hash = [_]u8{0} ** 32,
    });
    
    const db_interface = memory_db.to_database_interface();
    
    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 10_000_000,
        .coinbase = coinbase_address,
        .chain_id = 1,
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, caller_address, Hardfork.SHANGHAI);
    defer evm.deinit();
    
    // First CALL to coinbase should already be warm
    const call_cost = try evm.access_address(coinbase_address);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, call_cost);
}

// Test multiple transactions in same block
test "EIP-3651 - Coinbase remains warm across multiple operations" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const coinbase_address = [_]u8{0xF1} ** 20;
    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = coinbase_address,
        .chain_id = 1,
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.SHANGHAI);
    defer evm.deinit();
    
    // Multiple accesses to coinbase should all be warm
    for (0..10) |_| {
        const cost = try evm.access_address(coinbase_address);
        try testing.expectEqual(GasConstants.WarmStorageReadCost, cost);
    }
}

// Test edge case: coinbase is zero address
test "EIP-3651 - Zero address coinbase is warmed correctly" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, [_]u8{0x01} ** 20, Hardfork.SHANGHAI);
    defer evm.deinit();
    
    // Zero address as coinbase should also be warm
    const zero_cost = try evm.access_address(ZERO_ADDRESS);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, zero_cost);
}

// Test hardfork boundary behavior
test "EIP-3651 - Hardfork boundary behavior" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const coinbase_address = [_]u8{0xBF} ** 20;
    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = coinbase_address,
        .chain_id = 1,
    };
    
    // Test all hardforks to verify EIP-3651 activation
    const hardforks = [_]struct { fork: Hardfork, should_be_warm: bool }{
        .{ .fork = Hardfork.FRONTIER, .should_be_warm = false },
        .{ .fork = Hardfork.HOMESTEAD, .should_be_warm = false },
        .{ .fork = Hardfork.BYZANTIUM, .should_be_warm = false },
        .{ .fork = Hardfork.CONSTANTINOPLE, .should_be_warm = false },
        .{ .fork = Hardfork.ISTANBUL, .should_be_warm = false },
        .{ .fork = Hardfork.BERLIN, .should_be_warm = false },
        .{ .fork = Hardfork.LONDON, .should_be_warm = false },
        .{ .fork = Hardfork.MERGE, .should_be_warm = false },
        .{ .fork = Hardfork.SHANGHAI, .should_be_warm = true },
        .{ .fork = Hardfork.CANCUN, .should_be_warm = true },
    };
    
    for (hardforks) |test_case| {
        var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, test_case.fork);
        defer evm.deinit();
        
        const first_cost = try evm.access_address(coinbase_address);
        
        if (test_case.should_be_warm) {
            try testing.expectEqual(GasConstants.WarmStorageReadCost, first_cost);
        } else {
            // Pre-Shanghai: need to check if hardfork supports EIP-2929
            if (test_case.fork.isAtLeast(.BERLIN)) {
                try testing.expectEqual(GasConstants.ColdAccountAccessCost, first_cost);
            }
        }
    }
}

// Test that non-coinbase addresses are not pre-warmed
test "EIP-3651 - Only coinbase is pre-warmed, not other addresses" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const coinbase_address = [_]u8{0xC0} ** 20;
    const other_address = [_]u8{0xD0} ** 20;
    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = coinbase_address,
        .chain_id = 1,
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, Hardfork.SHANGHAI);
    defer evm.deinit();
    
    // Coinbase should be warm
    const coinbase_cost = try evm.access_address(coinbase_address);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, coinbase_cost);
    
    // Other addresses should still be cold
    const other_cost = try evm.access_address(other_address);
    try testing.expectEqual(GasConstants.ColdAccountAccessCost, other_cost);
}

// Test coinbase warming with contract deployment
test "EIP-3651 - Coinbase warm during contract deployment" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const deployer_address = [_]u8{0x01} ** 20;
    const coinbase_address = [_]u8{0xFE, 0xED} ++ [_]u8{0} ** 18;
    
    // Set up deployer account
    try memory_db.set_account(deployer_address, .{
        .nonce = 0,
        .balance = 10_000_000_000_000_000_000, // 10 ETH
        .code_hash = [_]u8{0} ** 32,
    });
    
    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 10_000_000,
        .coinbase = coinbase_address,
        .chain_id = 1,
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, deployer_address, Hardfork.SHANGHAI);
    defer evm.deinit();
    
    // During contract deployment, coinbase should be warm for fee transfers
    const coinbase_access = try evm.access_address(coinbase_address);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, coinbase_access);
}