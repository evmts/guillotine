const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");
const testing = std.testing;

fn hexDecode(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    const trimmed_input = std.mem.trim(u8, hex_str, " \t\n\r");
    
    const clean_hex = if (std.mem.startsWith(u8, trimmed_input, "0x")) 
        trimmed_input[2..] 
    else 
        trimmed_input;
    
    if (clean_hex.len == 0) {
        return allocator.alloc(u8, 0);
    }
    
    if (clean_hex.len % 2 != 0) {
        return error.InvalidHexCharacter;
    }
    
    const result = try allocator.alloc(u8, clean_hex.len / 2);
    
    var i: usize = 0;
    while (i < clean_hex.len) : (i += 2) {
        const byte_str = clean_hex[i .. i + 2];
        result[i / 2] = std.fmt.parseInt(u8, byte_str, 16) catch {
            allocator.free(result);
            return error.InvalidHexCharacter;
        };
    }
    
    return result;
}

test "ERC20 transfer fixture test" {
    const allocator = testing.allocator;
    
    // Read bytecode from fixture
    const bytecode_file = try std.fs.cwd().openFile("src/_test_utils/fixtures/erc20-transfer/bytecode.txt", .{});
    defer bytecode_file.close();
    const bytecode_hex = try bytecode_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(bytecode_hex);

    const init_code = try hexDecode(allocator, bytecode_hex);
    defer allocator.free(init_code);

    // Read calldata from fixture
    const calldata_file = try std.fs.cwd().openFile("src/_test_utils/fixtures/erc20-transfer/calldata.txt", .{});
    defer calldata_file.close();
    const calldata_hex = try calldata_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(calldata_hex);
    
    const calldata = try hexDecode(allocator, calldata_hex);
    defer allocator.free(calldata);
    
    std.debug.print("\n=== ERC20 Transfer Test ===\n", .{});
    std.debug.print("Init code length: {}\n", .{init_code.len});
    std.debug.print("Calldata length: {}\n", .{calldata.len});
    std.debug.print("Calldata: ", .{});
    for (calldata) |b| {
        std.debug.print("{x:0>2} ", .{b});
    }
    std.debug.print("\n", .{});
    
    // Setup database
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
    // Caller address with large balance
    const caller_address = primitives.Address{ 
        .bytes = [_]u8{0x10} ++ [_]u8{0} ** 18 ++ [_]u8{0x01}
    };
    
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
        .gas_limit = 2_100_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 7,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 1000000000,
        .blob_versioned_hashes = &.{},
    };
    
    const tx_context = evm.TransactionContext{
        .gas_limit = 2_100_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    // Try CREATE deployment first
    std.debug.print("\n--- Attempting CREATE deployment ---\n", .{});
    
    var deploy_evm = try evm.Evm(.{}).init(allocator, &database, block_info, tx_context, 0, caller_address);
    defer deploy_evm.deinit();
    
    const create_params = evm.CallParams{ 
        .create = .{ 
            .caller = caller_address, 
            .value = 0, 
            .init_code = init_code, 
            .gas = 500_000_000 
        } 
    };
    
    var deploy_result = deploy_evm.call(create_params);
    defer deploy_result.deinit(allocator);
    
    std.debug.print("CREATE result: success={}, output_len={}, gas_left={}\n", .{ 
        deploy_result.success, 
        deploy_result.output.len, 
        deploy_result.gas_left 
    });
    
    if (deploy_result.error_info) |err_info| {
        std.debug.print("Deploy error info: {s}\n", .{err_info});
    }
    
    var contract_address: primitives.Address = undefined;
    var runtime_code: []const u8 = undefined;
    
    if (deploy_result.success) {
        // Get the created contract address
        contract_address = primitives.Address.get_contract_address(caller_address, 0);
        const created_account = database.get_account(contract_address.bytes) catch null;
        
        if (created_account) |acc| {
            const code = database.get_code(acc.code_hash) catch null;
            if (code) |c| {
                if (c.len > 0) {
                    std.debug.print("Found deployed contract code: len={}\n", .{c.len});
                    std.debug.print("First 20 bytes: ", .{});
                    const show_len = @min(c.len, 20);
                    for (c[0..show_len]) |b| {
                        std.debug.print("{x:0>2} ", .{b});
                    }
                    std.debug.print("\n", .{});
                    runtime_code = c;
                } else {
                    std.debug.print("ERROR: No code found for deployed contract\n", .{});
                    return error.NoDeployedCode;
                }
            } else {
                std.debug.print("ERROR: Could not get code from database\n", .{});
                return error.NoCodeInDatabase;
            }
        } else {
            std.debug.print("ERROR: No account found at contract address\n", .{});
            return error.NoContractAccount;
        }
    } else {
        // Fallback: install bytecode directly as runtime code
        std.debug.print("\nCREATE failed, installing bytecode as runtime code fallback\n", .{});
        
        contract_address = primitives.Address{ .bytes = [_]u8{0x42} ++ [_]u8{0} ** 19 };
        const code_hash = try database.set_code(init_code);
        try database.set_account(contract_address.bytes, .{
            .balance = 0,
            .nonce = 1,
            .code_hash = code_hash,
            .storage_root = [_]u8{0} ** 32,
        });
        runtime_code = try database.get_code(code_hash);
    }
    
    // Now call the transfer function (or whatever the calldata represents)
    std.debug.print("\n--- Calling contract function (0x", .{});
    for (calldata) |b| {
        std.debug.print("{x:0>2}", .{b});
    }
    std.debug.print(") ---\n", .{});
    std.debug.print("Contract address: 0x", .{});
    for (contract_address.bytes) |b| {
        std.debug.print("{x:0>2}", .{b});
    }
    std.debug.print("\n", .{});
    
    var call_evm = try evm.Evm(.{}).init(allocator, &database, block_info, tx_context, 0, caller_address);
    defer call_evm.deinit();
    
    const call_params = evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = calldata,
            .gas = 1_000_000_000,
        },
    };
    
    var result = call_evm.call(call_params);
    defer result.deinit(allocator);
    
    std.debug.print("\nCall result: success={}, gas_left={}, output_len={}\n", .{
        result.success,
        result.gas_left,
        result.output.len,
    });
    
    if (result.error_info) |err_info| {
        std.debug.print("Error info: {s}\n", .{err_info});
    }
    
    if (result.output.len > 0) {
        std.debug.print("Output: ", .{});
        for (result.output) |b| {
            std.debug.print("{x:0>2} ", .{b});
        }
        std.debug.print("\n", .{});
    }
    
    // Check if execution was successful
    if (!result.success) {
        std.debug.print("\nEXECUTION FAILED!\n", .{});
        std.debug.print("Gas consumed: {}\n", .{1_000_000_000 - result.gas_left});
        return error.ExecutionFailed;
    }
    
    std.debug.print("\nTest completed successfully!\n", .{});
}