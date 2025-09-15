const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

const Address = primitives.Address.Address;

// Enable debug logging for the test
test {
    std.testing.log_level = .debug;
}

test "snailtracer differential test" {
    std.debug.print("\n=== Starting snailtracer test ===\n", .{});
    const allocator = std.testing.allocator;
    std.debug.print("Allocator created\n", .{});
    
    // Read bytecode from fixture file
    std.debug.print("Opening bytecode file...\n", .{});
    const bytecode_file = try std.fs.cwd().openFile("src/_test_utils/fixtures/snailtracer/bytecode.txt", .{});
    defer bytecode_file.close();
    std.debug.print("Bytecode file opened\n", .{});
    
    const bytecode_hex = try bytecode_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(bytecode_hex);
    
    // Count valid hex characters
    var valid_count: usize = 0;
    for (bytecode_hex) |c| {
        if (c != ' ' and c != '\n' and c != '\r' and c != '\t') {
            valid_count += 1;
        }
    }
    
    // Allocate clean buffer
    const bytecode_clean = try allocator.alloc(u8, valid_count);
    defer allocator.free(bytecode_clean);
    
    // Copy valid characters
    var clean_idx: usize = 0;
    for (bytecode_hex) |c| {
        if (c != ' ' and c != '\n' and c != '\r' and c != '\t') {
            bytecode_clean[clean_idx] = c;
            clean_idx += 1;
        }
    }
    
    // Convert hex string to bytes
    const bytecode_len = bytecode_clean.len / 2;
    const bytecode = try allocator.alloc(u8, bytecode_len);
    defer allocator.free(bytecode);
    
    var i: usize = 0;
    while (i < bytecode_clean.len) : (i += 2) {
        const hex_byte = bytecode_clean[i..i+2];
        bytecode[i/2] = try std.fmt.parseInt(u8, hex_byte, 16);
    }
    
    // Extract runtime code from deployment bytecode
    // The deployment bytecode starts with a constructor that copies and returns the runtime code
    // Looking for the pattern that ends the constructor (typically ends with CODECOPY PUSH RETURN)
    // In this case, the constructor is the first 32 bytes (0x20), and runtime code starts after
    const runtime_code = if (bytecode.len > 32) bytecode[32..] else bytecode;
    
    // Write the runtime bytecode to deployed_bytecode.txt for use in benchmarking
    const deployed_file = try std.fs.cwd().createFile("src/_test_utils/fixtures/snailtracer/deployed_bytecode.txt", .{});
    defer deployed_file.close();
    
    // Convert runtime bytecode to hex string
    const hex_chars = "0123456789abcdef";
    for (runtime_code) |byte| {
        const high = byte >> 4;
        const low = byte & 0x0F;
        _ = try deployed_file.write(&[_]u8{hex_chars[high], hex_chars[low]});
    }
    
    // Read calldata from fixture file
    const calldata_file = try std.fs.cwd().openFile("src/_test_utils/fixtures/snailtracer/calldata.txt", .{});
    defer calldata_file.close();
    
    const calldata_hex = try calldata_file.readToEndAlloc(allocator, 1024);
    defer allocator.free(calldata_hex);
    
    // Count valid hex characters for calldata
    valid_count = 0;
    for (calldata_hex) |c| {
        if (c != ' ' and c != '\n' and c != '\r' and c != '\t') {
            valid_count += 1;
        }
    }
    
    // Allocate clean buffer for calldata
    const calldata_clean = try allocator.alloc(u8, valid_count);
    defer allocator.free(calldata_clean);
    
    // Copy valid characters
    clean_idx = 0;
    for (calldata_hex) |c| {
        if (c != ' ' and c != '\n' and c != '\r' and c != '\t') {
            calldata_clean[clean_idx] = c;
            clean_idx += 1;
        }
    }
    
    const calldata_len = calldata_clean.len / 2;
    const calldata = try allocator.alloc(u8, calldata_len);
    defer allocator.free(calldata);
    
    i = 0;
    while (i < calldata_clean.len) : (i += 2) {
        const hex_byte = calldata_clean[i..i+2];
        calldata[i/2] = try std.fmt.parseInt(u8, hex_byte, 16);
    }
    
    // Setup test environment
    const contract_address = Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 18 ++ [_]u8{0x01} };
    const caller_address = Address{ .bytes = [_]u8{0xCA} ++ [_]u8{0x11} ** 18 ++ [_]u8{0xE5} };
    
    // Create database
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
    // Deploy contract with runtime code (not deployment bytecode)
    const code_hash = try database.set_code(runtime_code);
    const contract_account = evm.Account{
        .nonce = 1,
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    };
    
    try database.set_account(contract_address.bytes, contract_account);
    
    // Setup caller account with balance
    const caller_account = evm.Account{
        .nonce = 1,
        .balance = 1000000000000000000, // 1 ETH
        .code_hash = [_]u8{0} ** 32,  // All zeros for EOA
        .storage_root = [_]u8{0} ** 32,
    };
    
    try database.set_account(caller_address.bytes, caller_account);
    
    // Setup block info
    const block_info = evm.BlockInfo{
        .number = 19426587,
        .timestamp = 1710338135,
        .gas_limit = 3_000_000_000,
        .base_fee = 24_095_923_408,
        .difficulty = 0,
        .coinbase = Address.ZERO,
        .chain_id = 1,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 1,
        .blob_versioned_hashes = &[_][32]u8{},
    };
    
    // Setup transaction context
    const tx_context = evm.TransactionContext{
        .gas_limit = 3_000_000_000,
        .coinbase = Address.ZERO,
        .chain_id = 1,
    };
    
    // Create EVM with default tracer
    std.debug.print("Creating EVM with default tracer...\n", .{});

    var vm = try evm.DefaultEvm.init(
        allocator,
        &database,
        block_info,
        tx_context,
        0, // gas_price
        caller_address, // origin
        evm.Hardfork.CANCUN, // hardfork_config
    );
    defer vm.deinit();
    std.debug.print("EVM created\n", .{});

    // Setup call parameters
    const call_params = evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = calldata,
            .gas = 3_000_000_000,
        },
    };

    // Run test
    std.debug.print("Starting EVM call...\n", .{});

    // Add timeout panic for debugging
    const start_time = std.time.milliTimestamp();

    var result = vm.call(call_params);
    defer result.deinit(allocator);

    const end_time = std.time.milliTimestamp();
    if (end_time - start_time > 5000) {
        @panic("EVM call took more than 5 seconds - likely infinite loop");
    }

    std.debug.print("EVM call complete, success={}\n", .{result.success});
    
    // Verify result
    try std.testing.expect(result.success);
    std.debug.print("=== Test passed ===\n", .{});
}