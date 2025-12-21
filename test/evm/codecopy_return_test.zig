const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");
const testing = std.testing;

test "CODECOPY and RETURN differential test" {
    const allocator = testing.allocator;
    
    // Simple bytecode that copies itself to memory and returns it
    // PUSH1 10    (size = 16 bytes)
    // PUSH1 00    (offset = 0)  
    // PUSH1 00    (destOffset = 0)
    // CODECOPY    
    // PUSH1 10    (size = 16 bytes to return)
    // PUSH1 00    (offset = 0)
    // RETURN
    const bytecode = [_]u8{
        0x60, 0x10,  // PUSH1 16
        0x60, 0x00,  // PUSH1 0
        0x60, 0x00,  // PUSH1 0  
        0x39,        // CODECOPY
        0x60, 0x10,  // PUSH1 16
        0x60, 0x00,  // PUSH1 0
        0xf3,        // RETURN
    };
    
    std.debug.print("\n=== CODECOPY+RETURN Test ===\n", .{});
    std.debug.print("Bytecode: ", .{});
    for (bytecode) |b| {
        std.debug.print("{x:0>2} ", .{b});
    }
    std.debug.print("\n", .{});
    
    // Setup database
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
    // Deploy contract
    const contract_address = primitives.Address{ 
        .bytes = [_]u8{0x42} ++ [_]u8{0} ** 19 
    };
    
    // Set the bytecode on the contract
    const code_hash = try database.set_code(&bytecode);
    try database.set_account(contract_address.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Caller address
    const caller_address = primitives.Address{ 
        .bytes = [_]u8{0x10} ++ [_]u8{0} ** 19
    };
    
    // Give caller some ETH
    try database.set_account(caller_address.bytes, .{
        .balance = std.math.maxInt(u256),
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Setup EVM
    const block_info = evm.BlockInfo{
        .chain_id = 1,
        .number = 20_000_000,
        .timestamp = 1_800_000_000,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 7,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 1000000000,
        .blob_versioned_hashes = &.{},
    };
    
    const tx_context = evm.TransactionContext{
        .gas_limit = 10_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var guillotine_evm = try evm.DefaultEvm.init(
        allocator,
        &database,
        block_info,
        tx_context,
        0, // gas_price
        caller_address // origin
    );
    defer guillotine_evm.deinit();
    
    // Call the contract
    const call_params = evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 1_000_000,
        },
    };
    
    std.debug.print("\nExecuting CODECOPY+RETURN...\n", .{});
    
    var result = guillotine_evm.call(call_params);
    defer result.deinit(allocator);
    
    std.debug.print("Success: {}\n", .{result.success});
    std.debug.print("Gas left: {}\n", .{result.gas_left});
    std.debug.print("Output size: {} bytes\n", .{result.output.len});
    
    if (result.output.len > 0) {
        std.debug.print("Output: ", .{});
        for (result.output) |b| {
            std.debug.print("{x:0>2} ", .{b});
        }
        std.debug.print("\n", .{});
    }
    
    // The output should be the first 16 bytes of the bytecode
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 16), result.output.len);
    
    // Check that the output matches the bytecode
    for (0..16) |i| {
        if (i < bytecode.len) {
            try testing.expectEqual(bytecode[i], result.output[i]);
        } else {
            // Past bytecode length, should be zeros
            try testing.expectEqual(@as(u8, 0), result.output[i]);
        }
    }
    
    std.debug.print("\n✅ CODECOPY+RETURN test passed!\n", .{});
}
