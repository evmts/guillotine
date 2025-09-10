const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const evm = @import("evm");

// Test demonstrating REVERT opcode implementation issues
//
// Issue: The REVERT opcode has multiple implementation problems:
// 1. Error messages are empty even when revert data is present
// 2. Non-tracing execution mode completely loses all revert data  
// 3. Missing REVERT case in non-tracing error handler
//
// Root Causes:
// 1. `revert_with_data` function doesn't set error_info field
// 2. Non-tracing mode in evm.zig missing error.REVERT case
//
// Expected behavior:
// - REVERT should gracefully fail with preserved output data
// - Error message should indicate "execution reverted" or similar
// - Both tracing and non-tracing modes should handle REVERT correctly

test "REVERT should preserve data and error message in both tracing and non-tracing modes" {
    const allocator = testing.allocator;
    
    // Initialize database and EVM
    var db = evm.Database.init(allocator);
    defer db.deinit();
    
    const block_info = evm.BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    
    const tx_context = evm.TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    // Test non-tracing mode first (this is where the critical bug is)
    {
        var vm = try evm.Evm(.{}).init(allocator, &db, block_info, tx_context, 0, primitives.Address.ZERO_ADDRESS, .BERLIN);
        defer vm.deinit();
        
        const contract_addr = primitives.Address{ .bytes = [_]u8{0x12} ** 20 };
        
        // Bytecode: Store "FAIL" (0x4641494c) in memory and revert with it
        // PUSH4 0x4641494c (FAIL), PUSH1 0, MSTORE
        // PUSH1 4 (size), PUSH1 28 (offset), REVERT
        const bytecode = [_]u8{
            0x63, 0x46, 0x41, 0x49, 0x4c,  // PUSH4 "FAIL"
            0x60, 0x00,                     // PUSH1 0
            0x52,                            // MSTORE
            0x60, 0x04,                     // PUSH1 4 (size)
            0x60, 0x1c,                     // PUSH1 28 (offset)
            0xfd,                            // REVERT
        };
        
        const code_hash = try db.set_code(&bytecode);
        const account = evm.Account{
            .balance = 0,
            .code_hash = code_hash,
            .storage_root = [_]u8{0} ** 32,
            .nonce = 0,
            .delegated_address = null,
        };
        try db.set_account(contract_addr.bytes, account);
        
        // Execute call that should revert (non-tracing mode)
        const params = evm.CallParams{ .call = .{
            .caller = primitives.Address.ZERO_ADDRESS,
            .to = contract_addr,
            .value = 0,
            .input = &.{},
            .gas = 100_000,
        }};
        
        const result = vm.call(params);
        
        // Verify revert was handled correctly
        try testing.expect(!result.success);
        
        // After fix: Output should contain "FAIL" in non-tracing mode
        std.debug.print("Non-tracing mode - Output length: {d}\n", .{result.output.len});
        if (result.output.len > 0) {
            std.debug.print("Non-tracing mode - Output data: {s}\n", .{result.output});
        }
        
        // After fix: This should work because non-tracing mode now preserves revert data
        try testing.expect(result.output.len == 4);
        try testing.expect(std.mem.eql(u8, result.output, "FAIL"));
        
        // After fix: Error message should not be empty
        std.debug.print("Non-tracing mode - Error info: {any}\n", .{result.error_info});
        try testing.expect(result.error_info != null);
        if (result.error_info) |info| {
            try testing.expect(std.mem.eql(u8, info, "execution reverted"));
        }
        
        // Gas should be partially consumed, not zero
        std.debug.print("Non-tracing mode - Gas left: {d}\n", .{result.gas_left});
        try testing.expect(result.gas_left < 100_000); // Some gas should be consumed
        
        // Clean up result
        var mutable_result = result;
        mutable_result.deinit(allocator);
    }
    
    // Test tracing mode (this should work better but still has error_info issue)
    {
        var vm = try evm.Evm(.{ .enable_tracer = true }).init(allocator, &db, block_info, tx_context, 0, primitives.Address.ZERO_ADDRESS, .BERLIN);
        defer vm.deinit();
        
        const contract_addr = primitives.Address{ .bytes = [_]u8{0x13} ** 20 };
        
        // Same bytecode as above
        const bytecode = [_]u8{
            0x63, 0x46, 0x41, 0x49, 0x4c,  // PUSH4 "FAIL"
            0x60, 0x00,                     // PUSH1 0
            0x52,                            // MSTORE
            0x60, 0x04,                     // PUSH1 4 (size)
            0x60, 0x1c,                     // PUSH1 28 (offset)
            0xfd,                            // REVERT
        };
        
        const code_hash = try db.set_code(&bytecode);
        const account = evm.Account{
            .balance = 0,
            .code_hash = code_hash,
            .storage_root = [_]u8{0} ** 32,
            .nonce = 0,
            .delegated_address = null,
        };
        try db.set_account(contract_addr.bytes, account);
        
        // Execute call that should revert (tracing mode)
        const params = evm.CallParams{ .call = .{
            .caller = primitives.Address.ZERO_ADDRESS,
            .to = contract_addr,
            .value = 0,
            .input = &.{},
            .gas = 100_000,
        }};
        
        const result = vm.call(params);
        
        // Verify revert was handled correctly
        try testing.expect(!result.success);
        
        // In tracing mode, output should be preserved
        std.debug.print("Tracing mode - Output length: {d}\n", .{result.output.len});
        if (result.output.len > 0) {
            std.debug.print("Tracing mode - Output data: {s}\n", .{result.output});
        }
        
        // This should work in tracing mode
        try testing.expect(result.output.len == 4);
        try testing.expect(std.mem.eql(u8, result.output, "FAIL"));
        
        // After fix: Error message should not be empty even in tracing mode
        std.debug.print("Tracing mode - Error info: {any}\n", .{result.error_info});
        try testing.expect(result.error_info != null);
        if (result.error_info) |info| {
            try testing.expect(std.mem.eql(u8, info, "execution reverted"));
        }
        
        // Gas should be partially consumed
        std.debug.print("Tracing mode - Gas left: {d}\n", .{result.gas_left});
        try testing.expect(result.gas_left > 0);
        try testing.expect(result.gas_left < 100_000);
        
        // Verify trace is present
        try testing.expect(result.trace != null);
        
        // Clean up result
        var mutable_result = result;
        mutable_result.deinit(allocator);
    }
}

test "REVERT with empty data should still have error message" {
    const allocator = testing.allocator;
    
    // Initialize database and EVM
    var db = evm.Database.init(allocator);
    defer db.deinit();
    
    const block_info = evm.BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    
    const tx_context = evm.TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.Address.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var vm = try evm.Evm(.{}).init(allocator, &db, block_info, tx_context, 0, primitives.Address.ZERO_ADDRESS, .BERLIN);
    defer vm.deinit();
    
    const contract_addr = primitives.Address{ .bytes = [_]u8{0x14} ** 20 };
    
    // Bytecode: Simple REVERT with no data
    // PUSH1 0 (size), PUSH1 0 (offset), REVERT
    const bytecode = [_]u8{
        0x60, 0x00,  // PUSH1 0 (size)
        0x60, 0x00,  // PUSH1 0 (offset)  
        0xfd,        // REVERT
    };
    
    const code_hash = try db.set_code(&bytecode);
    const account = evm.Account{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
        .delegated_address = null,
    };
    try db.set_account(contract_addr.bytes, account);
    
    // Execute call that should revert
    const params = evm.CallParams{ .call = .{
        .caller = primitives.Address.ZERO_ADDRESS,
        .to = contract_addr,
        .value = 0,
        .input = &.{},
        .gas = 100_000,
    }};
    
    const result = vm.call(params);
    
    // Verify revert was handled correctly
    try testing.expect(!result.success);
    
    // Output should be empty
    try testing.expect(result.output.len == 0);
    
    // After fix: Error message should indicate revert even with empty data
    std.debug.print("Empty revert - Error info: {any}\n", .{result.error_info});
    try testing.expect(result.error_info != null);
    if (result.error_info) |info| {
        try testing.expect(std.mem.eql(u8, info, "execution reverted"));
    }
    
    // Gas should be partially consumed
    try testing.expect(result.gas_left < 100_000);
    
    // Clean up result
    var mutable_result = result;
    mutable_result.deinit(allocator);
}