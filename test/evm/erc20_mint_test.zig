const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

/// Load fixture file and convert hex string to bytes
fn loadFixture(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // Open file relative to current working directory
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    
    const file_size = try file.getEndPos();
    const hex_content = try allocator.alloc(u8, file_size);
    defer allocator.free(hex_content);
    _ = try file.read(hex_content);
    
    // Trim whitespace
    const trimmed = std.mem.trim(u8, hex_content, " \n\r\t");
    
    // Convert hex to bytes
    const bytes = try allocator.alloc(u8, trimmed.len / 2);
    _ = try std.fmt.hexToBytes(bytes, trimmed);
    
    return bytes;
}

test "ERC20 mint test" {
    const allocator = std.testing.allocator;
    
    // Load bytecode and calldata from fixtures
    const bytecode = try loadFixture(allocator, "src/evm/fixtures/erc20-mint/bytecode.txt");
    defer allocator.free(bytecode);
    
    const calldata = try loadFixture(allocator, "src/evm/fixtures/erc20-mint/calldata.txt");
    defer allocator.free(calldata);
    
    std.debug.print("\n=== ERC20 Mint Test ===\n", .{});
    std.debug.print("Bytecode size: {} bytes\n", .{bytecode.len});
    std.debug.print("Calldata size: {} bytes\n", .{calldata.len});
    std.debug.print("Calldata: {x}\n", .{calldata});
    
    // Setup database
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
    // Deploy contract address
    const contract_address = primitives.Address{ 
        .bytes = [_]u8{0x42} ++ [_]u8{0} ** 19 
    };
    
    // Set the bytecode on the contract
    const code_hash = try database.set_code(bytecode);
    try database.set_account(contract_address.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Caller address (EOA)
    const caller_address = primitives.Address{ 
        .bytes = [_]u8{0x10} ++ [_]u8{0} ** 18 ++ [_]u8{0x01} 
    };
    
    // Give caller some ETH
    try database.set_account(caller_address.bytes, .{
        .balance = std.math.maxInt(u256),
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Setup block info
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
    
    // Setup transaction context
    const tx_context = evm.TransactionContext{
        .gas_limit = 10_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    // Initialize EVM
    var evm_instance = try evm.DefaultEvm.init(
        allocator,
        &database,
        block_info,
        tx_context,
        0, // gas_price
        caller_address, // origin
        .CANCUN
    );
    defer evm_instance.deinit();
    
    // Setup call parameters for mint function
    const call_params = evm.DefaultEvm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = calldata,
            .gas = 5_000_000,
        },
    };
    
    std.debug.print("\nExecuting mint function call...\n", .{});
    std.debug.print("  Caller: 0x{x}\n", .{caller_address.bytes});
    std.debug.print("  Contract: 0x{x}\n", .{contract_address.bytes});
    std.debug.print("  Function selector: 0x{x}\n", .{calldata[0..4]});
    
    // Execute EVM call
    const result = evm_instance.call(call_params) catch |err| {
        std.debug.print("\n❌ EVM call failed: {}\n", .{err});
        return err;
    };
    defer {
        var mutable_result = result;
        mutable_result.deinit(allocator);
    }
    
    std.debug.print("\n✅ EVM test passed!\n", .{});
    std.debug.print("  Success: {}\n", .{result.success});
    std.debug.print("  Gas left: {}\n", .{result.gas_left});
    std.debug.print("  Output size: {} bytes\n", .{result.output.len});
    
    // The mint function should succeed
    try std.testing.expect(result.success);
    
    // Note: The contract execution may return different output sizes depending on the specific calldata
    std.debug.print("  Output content (first 32 bytes): ", .{});
    const show_len = @min(result.output.len, 32);
    for (result.output[0..show_len]) |b| {
        std.debug.print("{x:0>2} ", .{b});
    }
    std.debug.print("\n", .{});
    
    std.debug.print("\n=== Test Complete ===\n", .{});
}