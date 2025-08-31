//! Integration tests for EIP-2929, EIP-3651, and EIP-4844 working together

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
const Contract = @import("contract.zig").Contract;

// Realistic smart contract interaction with all EIPs
test "Integration - DeFi contract with blob data and coinbase interaction" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    // Set up accounts
    const user_address = [_]u8{0x01} ** 20;
    const defi_contract = [_]u8{0xDE, 0xF1} ++ [_]u8{0} ** 18;
    const token_contract = [_]u8{0x70, 0xKE} ++ [_]u8{0} ** 18;
    const coinbase_address = [_]u8{0xC0, 0x1B} ++ [_]u8{0} ** 18;
    
    // Initialize accounts
    try memory_db.set_account(user_address, .{
        .nonce = 5,
        .balance = 10_000_000_000_000_000_000, // 10 ETH
        .code_hash = [_]u8{0} ** 32,
    });
    
    try memory_db.set_account(defi_contract, .{
        .nonce = 1,
        .balance = 1_000_000_000_000_000_000, // 1 ETH
        .code_hash = [_]u8{0xFF} ** 32, // Has code
    });
    
    try memory_db.set_account(token_contract, .{
        .nonce = 1,
        .balance = 0,
        .code_hash = [_]u8{0xEE} ** 32, // Has code
    });
    
    // Set up storage
    try memory_db.set_storage(defi_contract, 0x100, 1000); // Some state
    try memory_db.set_storage(token_contract, 0x200, 2000); // Token balance
    
    const db_interface = memory_db.to_database_interface();
    
    // Create blob data (e.g., batched transaction data)
    var blob_hashes: [3][32]u8 = undefined;
    for (0..3) |i| {
        blob_hashes[i][0] = 0x01; // KZG version
        for (1..32) |j| {
            blob_hashes[i][j] = @as(u8, @intCast((i * 32 + j) % 256));
        }
    }
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 18_000_000,
        .timestamp = 1700000000,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = coinbase_address,
        .base_fee = 20_000_000_000, // 20 gwei
        .prev_randao = [_]u8{0xAA} ** 32,
    };
    
    const context = TransactionContext{
        .gas_limit = 5_000_000,
        .coinbase = coinbase_address,
        .chain_id = 1,
        .blob_versioned_hashes = &blob_hashes,
        .blob_base_fee = 1_000_000_000, // 1 gwei
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 25_000_000_000, user_address, Hardfork.CANCUN);
    defer evm.deinit();
    
    // Complex contract bytecode that:
    // 1. Checks blob data
    // 2. Reads from multiple storage slots
    // 3. Calls other contracts
    // 4. Sends fees to coinbase
    const bytecode = [_]u8{
        // Read blob base fee
        0x4a,       // BLOBBASEFEE
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        
        // Read first blob hash
        0x60, 0x00, // PUSH1 0
        0x49,       // BLOBHASH
        0x60, 0x20, // PUSH1 32
        0x52,       // MSTORE
        
        // Check coinbase balance (should be warm due to EIP-3651)
        0x41,       // COINBASE
        0x31,       // BALANCE
        0x60, 0x40, // PUSH1 64
        0x52,       // MSTORE
        
        // Read from token contract (cold access)
        0x61, 0x02, 0x00, // PUSH2 0x200 (slot)
        0x73, // PUSH20
    } ++ token_contract ++ [_]u8{
        0x54,       // SLOAD
        0x60, 0x60, // PUSH1 96
        0x52,       // MSTORE
        
        // Read from same token contract (warm access)
        0x61, 0x02, 0x01, // PUSH2 0x201 (different slot)
        0x73, // PUSH20
    } ++ token_contract ++ [_]u8{
        0x54,       // SLOAD
        0x60, 0x80, // PUSH1 128
        0x52,       // MSTORE
        
        // Store to local storage (cold slot)
        0x60, 0x42, // PUSH1 0x42 (value)
        0x61, 0x03, 0x00, // PUSH2 0x300 (slot)
        0x55,       // SSTORE
        
        // Store to same slot again (warm)
        0x60, 0x43, // PUSH1 0x43 (value)
        0x61, 0x03, 0x00, // PUSH2 0x300 (slot)
        0x55,       // SSTORE
        
        0x00,       // STOP
    };
    
    const initial_gas = 500_000;
    var interpreter = try FrameInterpreter(.{ .has_database = true }).init(
        allocator,
        &bytecode,
        initial_gas,
        db_interface,
        evm.to_host()
    );
    defer interpreter.deinit(allocator);
    
    // Set the contract address for storage operations
    interpreter.frame.contract_address = defi_contract;
    
    try interpreter.interpret();
    
    // Verify results
    const gas_used = @as(u64, @intCast(initial_gas - interpreter.frame.gas_remaining));
    
    // Gas usage should reflect:
    // - Warm coinbase access (EIP-3651)
    // - Cold then warm token contract access (EIP-2929)
    // - Cold then warm storage slot access (EIP-2929)
    // - Blob opcode costs (EIP-4844)
    try testing.expect(gas_used > 0);
    
    // Verify memory contains expected values
    const memory_slice = interpreter.frame.memory.get_slice(0, 160) catch unreachable;
    
    // First 32 bytes: blob base fee
    var blob_base_fee_stored: u256 = 0;
    for (0..32) |i| {
        blob_base_fee_stored = (blob_base_fee_stored << 8) | memory_slice[i];
    }
    try testing.expectEqual(context.blob_base_fee, blob_base_fee_stored);
}

// Test gas accounting precision with all EIPs
test "Integration - Precise gas accounting with warm/cold transitions" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const contract_address = [_]u8{0x12} ** 20;
    const other_address = [_]u8{0x34} ** 20;
    const coinbase_address = [_]u8{0xCB} ** 20;
    
    // Set up accounts
    try memory_db.set_account(contract_address, .{
        .nonce = 1,
        .balance = 1_000_000_000_000_000_000,
        .code_hash = [_]u8{1} ** 32,
    });
    
    const db_interface = memory_db.to_database_interface();
    
    const block_info = BlockInfo.init();
    const blob_hash = [_]u8{0x01} ++ [_]u8{0xFF} ** 31;
    const blob_hashes = [_][32]u8{blob_hash};
    
    const context = TransactionContext{
        .gas_limit = 10_000_000,
        .coinbase = coinbase_address,
        .chain_id = 1,
        .blob_versioned_hashes = &blob_hashes,
        .blob_base_fee = 5_000_000_000,
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, contract_address, Hardfork.CANCUN);
    defer evm.deinit();
    
    // Track gas costs manually
    var expected_gas: u64 = 0;
    
    // Test sequence of operations
    // 1. COINBASE + BALANCE (coinbase is pre-warmed)
    expected_gas += 2; // COINBASE opcode
    expected_gas += 100; // BALANCE warm access
    
    // 2. BALANCE of other address (cold)
    expected_gas += 2600; // Cold access
    const other_cold_cost = try evm.access_address(other_address);
    try testing.expectEqual(@as(u64, 2600), other_cold_cost);
    
    // 3. BALANCE of other address again (warm)
    expected_gas += 100; // Warm access
    const other_warm_cost = try evm.access_address(other_address);
    try testing.expectEqual(@as(u64, 100), other_warm_cost);
    
    // 4. SLOAD from cold slot
    expected_gas += 2100; // Cold storage access
    const storage_cold = try evm.access_storage_slot(contract_address, 0x1000);
    try testing.expectEqual(@as(u64, 2100), storage_cold);
    
    // 5. SLOAD from same slot (warm)
    expected_gas += 100; // Warm storage access
    const storage_warm = try evm.access_storage_slot(contract_address, 0x1000);
    try testing.expectEqual(@as(u64, 100), storage_warm);
    
    // 6. BLOBHASH (flat cost)
    expected_gas += 3; // BLOBHASH opcode cost
    
    // 7. BLOBBASEFEE (flat cost)
    expected_gas += 2; // BLOBBASEFEE opcode cost
}

// Test transaction with maximum complexity
test "Integration - Maximum complexity transaction" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    // Create 10 different addresses
    var addresses: [10]Address = undefined;
    for (0..10) |i| {
        addresses[i] = [_]u8{@as(u8, @intCast(i + 1))} ** 20;
        try memory_db.set_account(addresses[i], .{
            .nonce = @as(u64, i),
            .balance = 1_000_000_000_000_000_000,
            .code_hash = [_]u8{@as(u8, @intCast(i))} ** 32,
        });
    }
    
    const coinbase_address = [_]u8{0xFE, 0xED} ++ [_]u8{0} ** 18;
    
    // Maximum blobs
    var blob_hashes: [6][32]u8 = undefined;
    for (0..6) |i| {
        blob_hashes[i][0] = 0x01;
        for (1..32) |j| {
            blob_hashes[i][j] = @as(u8, @intCast((i + j) % 256));
        }
    }
    
    const db_interface = memory_db.to_database_interface();
    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 30_000_000,
        .coinbase = coinbase_address,
        .chain_id = 1,
        .blob_versioned_hashes = &blob_hashes,
        .blob_base_fee = 10_000_000_000,
    };
    
    var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, addresses[0], Hardfork.CANCUN);
    defer evm.deinit();
    
    // Access all addresses (first access cold, second warm)
    for (addresses) |addr| {
        const cold_cost = try evm.access_address(addr);
        try testing.expectEqual(GasConstants.ColdAccountAccessCost, cold_cost);
        
        const warm_cost = try evm.access_address(addr);
        try testing.expectEqual(GasConstants.WarmStorageReadCost, warm_cost);
    }
    
    // Coinbase should always be warm
    const coinbase_cost = try evm.access_address(coinbase_address);
    try testing.expectEqual(GasConstants.WarmStorageReadCost, coinbase_cost);
    
    // Access multiple storage slots
    for (0..10) |i| {
        const slot = @as(u256, i * 0x100);
        const cold_storage = try evm.access_storage_slot(addresses[0], slot);
        try testing.expectEqual(GasConstants.ColdSloadCost, cold_storage);
        
        const warm_storage = try evm.access_storage_slot(addresses[0], slot);
        try testing.expectEqual(GasConstants.WarmStorageReadCost, warm_storage);
    }
    
    // Verify all blob hashes are accessible
    for (0..6) |i| {
        const hash = evm.get_blob_hash(i);
        try testing.expect(hash != null);
        try testing.expectEqual(blob_hashes[i], hash.?);
    }
    
    // Verify blob base fee
    try testing.expectEqual(@as(u256, 10_000_000_000), evm.get_blob_base_fee());
}

// Test hardfork transition scenarios
test "Integration - Hardfork transition behavior" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    const test_address = [_]u8{0x42} ** 20;
    const coinbase_address = [_]u8{0xC0} ** 20;
    const blob_hash = [_]u8{0x01} ++ [_]u8{0xAA} ** 31;
    const blob_hashes = [_][32]u8{blob_hash};
    
    const block_info = BlockInfo.init();
    const context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = coinbase_address,
        .chain_id = 1,
        .blob_versioned_hashes = &blob_hashes,
        .blob_base_fee = 1_000_000_000,
    };
    
    // Test progression through hardforks
    const test_cases = [_]struct {
        fork: Hardfork,
        has_warm_cold: bool,
        has_warm_coinbase: bool,
        has_blob_support: bool,
    }{
        .{ .fork = .ISTANBUL, .has_warm_cold = false, .has_warm_coinbase = false, .has_blob_support = false },
        .{ .fork = .BERLIN, .has_warm_cold = true, .has_warm_coinbase = false, .has_blob_support = false },
        .{ .fork = .LONDON, .has_warm_cold = true, .has_warm_coinbase = false, .has_blob_support = false },
        .{ .fork = .SHANGHAI, .has_warm_cold = true, .has_warm_coinbase = true, .has_blob_support = false },
        .{ .fork = .CANCUN, .has_warm_cold = true, .has_warm_coinbase = true, .has_blob_support = true },
    };
    
    for (test_cases) |tc| {
        var evm = try Evm(.{}).init(allocator, db_interface, block_info, context, 0, ZERO_ADDRESS, tc.fork);
        defer evm.deinit();
        
        // Test warm/cold access
        if (tc.has_warm_cold) {
            const first_access = try evm.access_address(test_address);
            try testing.expectEqual(GasConstants.ColdAccountAccessCost, first_access);
            
            const second_access = try evm.access_address(test_address);
            try testing.expectEqual(GasConstants.WarmStorageReadCost, second_access);
        }
        
        // Test coinbase warming
        if (tc.has_warm_coinbase) {
            const coinbase_cost = try evm.access_address(coinbase_address);
            try testing.expectEqual(GasConstants.WarmStorageReadCost, coinbase_cost);
        } else if (tc.has_warm_cold) {
            const coinbase_cost = try evm.access_address(coinbase_address);
            try testing.expectEqual(GasConstants.ColdAccountAccessCost, coinbase_cost);
        }
        
        // Test blob support
        if (tc.has_blob_support) {
            const blob = evm.get_blob_hash(0);
            try testing.expect(blob != null);
            try testing.expectEqual(blob_hash, blob.?);
            
            const fee = evm.get_blob_base_fee();
            try testing.expectEqual(context.blob_base_fee, fee);
        }
    }
}