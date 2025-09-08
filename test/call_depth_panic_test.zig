const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

test "call depth limit panic - segfaults when max_call_depth is reached" {
    const allocator = testing.allocator;
    
    // BUG: Setting max_call_depth to a small value causes a segfault when the limit is reached.
    // The EVM likely panics or mishandles the error when hitting the call depth limit,
    // causing memory corruption that manifests as a segfault in arena_allocator during
    // the next allocation attempt.
    //
    // This configuration WILL CRASH:
    const TestEvm = evm.Evm(.{ .max_call_depth = 3 });
    
    // To make the test pass, comment the line above and uncomment this:
    // const TestEvm = evm.Evm(.{}); // Uses default max_call_depth = 1024
    
    // Recursive bytecode that calls itself indefinitely
    const recursive_bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0x00 (retLength)
        0x60, 0x00, // PUSH1 0x00 (retOffset) 
        0x60, 0x00, // PUSH1 0x00 (argsLength)
        0x60, 0x00, // PUSH1 0x00 (argsOffset)
        0x60, 0x00, // PUSH1 0x00 (value)
        0x30,       // ADDRESS (pushes current contract address)
        0x61, 0x27, 0x10, // PUSH2 0x2710 (gas = 10000)
        0xf1,       // CALL (recursive call to self)
        0x50,       // POP (remove call result from stack)
        0x60, 0x01, // PUSH1 1 (success indicator)
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52,       // MSTORE (store success in memory)
        0x60, 0x20, // PUSH1 32 (return data size)
        0x60, 0x00, // PUSH1 0 (return data offset)
        0xf3,       // RETURN
    };
    
    // Setup database
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
    const caller_address = primitives.Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 18 ++ [_]u8{0x01} };
    const contract_address = primitives.Address{ .bytes = [_]u8{0x20} ++ [_]u8{0} ** 18 ++ [_]u8{0x02} };
    
    // Set the recursive bytecode on the contract account
    const code_hash = try database.set_code(&recursive_bytecode);
    
    try database.set_account(contract_address.bytes, .{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Set up caller as EOA with balance
    try database.set_account(caller_address.bytes, .{
        .balance = std.math.maxInt(u256),
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });
    
    const block_info = evm.BlockInfo{
        .chain_id = 1,
        .number = 20_000_000,
        .timestamp = 1_800_000_000,
        .difficulty = 0,
        .gas_limit = 1_000_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 7,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 1000000000,
        .blob_versioned_hashes = &.{},
    };

    const tx_context = evm.TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    // Initialize EVM
    var test_evm = try TestEvm.init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
        .CANCUN
    );
    defer test_evm.deinit();
    
    // Execute recursive call - THIS WILL SEGFAULT when max_call_depth = 3
    const call_params = TestEvm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 1_000_000,
        },
    };
    
    var result = test_evm.call(call_params);
    defer result.deinit(allocator);
    
    try testing.expect(result.success);
    try testing.expect(result.output.len == 32);
    try testing.expectEqual(@as(u8, 0x01), result.output[31]);
}