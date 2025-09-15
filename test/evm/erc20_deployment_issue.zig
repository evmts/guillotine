const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const log = std.log;

test {
    std.testing.log_level = .debug;
}

fn hex_decode(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    const clean_hex = if (std.mem.startsWith(u8, hex_str, "0x")) hex_str[2..] else hex_str;
    const trimmed = std.mem.trim(u8, clean_hex, &std.ascii.whitespace);
    if (trimmed.len == 0) return allocator.alloc(u8, 0);
    
    const result = try allocator.alloc(u8, trimmed.len / 2);
    var i: usize = 0;
    while (i < trimmed.len) : (i += 2) {
        const byte_str = trimmed[i .. i + 2];
        result[i / 2] = std.fmt.parseInt(u8, byte_str, 16) catch {
            return error.InvalidHexCharacter;
        };
    }
    return result;
}

test "ERC20 deployment with standard EVM" {
    std.testing.log_level = .debug;
    const allocator = std.testing.allocator;

    // Read the ERC20 transfer bytecode
    const bytecode_file = try std.fs.cwd().openFile("src/evm/fixtures/erc20-transfer/bytecode.txt", .{});
    defer bytecode_file.close();
    const bytecode_hex = try bytecode_file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(bytecode_hex);

    const init_code = try hex_decode(allocator, bytecode_hex);
    defer allocator.free(init_code);

    log.info("Testing ERC20 deployment bytecode: {} bytes", .{init_code.len});

    const caller_address = primitives.Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 18 ++ [_]u8{0x01} };

    var database = evm.Database.init(allocator);
    defer database.deinit();

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
        .gas_limit = 1_000_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    // Use standard EVM (MinimalEvm is used automatically in debug mode)
    var deploy_evm = try evm.Evm(.{}).init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
        .CANCUN
    );
    defer deploy_evm.deinit();

    // Use high gas to rule out gas issues
    const gas_amount: u64 = 10_000_000;

    const create_params = evm.CallParams{
        .create = .{
            .caller = caller_address,
            .value = 0,
            .init_code = init_code,
            .gas = gas_amount,
        },
    };

    var result = deploy_evm.call(create_params);
    defer result.deinit(allocator);

    log.info("ERC20 deployment: success={}, gas_left={}, gas_used={}", .{
        result.success,
        result.gas_left,
        gas_amount - result.gas_left,
    });

    try std.testing.expect(result.success);
    log.info("✅ ERC20 deployment test passed!", .{});
}




test "Simple contract deployment test" {
    std.testing.log_level = .debug;
    const allocator = std.testing.allocator;

    // Use a very simple contract that just stores 42 and returns empty code
    const init_code = &[_]u8{
        0x60, 0x2a, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE
        0x60, 0x00, // PUSH1 0 (return data size)
        0x60, 0x00, // PUSH1 0 (return data offset)
        0xF3,       // RETURN
    };

    log.info("Simple contract bytecode: {} bytes", .{init_code.len});

    const caller_address = primitives.Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 18 ++ [_]u8{0x01} };

    var database = evm.Database.init(allocator);
    defer database.deinit();

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
        .gas_limit = 1_000_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    // Use standard EVM (MinimalEvm is used automatically in debug mode)
    var deploy_evm = try evm.Evm(.{}).init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
        .CANCUN
    );
    defer deploy_evm.deinit();

    const gas_amount: u64 = 1_000_000;

    log.info("\nTesting simple contract with {} gas", .{gas_amount});

    const create_params = evm.CallParams{
        .create = .{
            .caller = caller_address,
            .value = 0,
            .init_code = init_code,
            .gas = gas_amount,
        },
    };

    var result = deploy_evm.call(create_params);
    defer result.deinit(allocator);

    log.info("Simple contract deployment: success={}, gas_left={}, gas_used={}", .{
        result.success,
        result.gas_left,
        gas_amount - result.gas_left,
    });

    try std.testing.expect(result.success);
    log.info("✅ Simple contract deployment test passed!", .{});
}

test "Snailtracer deployment comparison" {
    std.testing.log_level = .debug;
    const allocator = std.testing.allocator;
    
    // Test with snailtracer which we know works
    const bytecode_file = try std.fs.cwd().openFile("src/evm/fixtures/snailtracer/bytecode.txt", .{});
    defer bytecode_file.close();
    const bytecode_hex = try bytecode_file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(bytecode_hex);
    
    const init_code = try hex_decode(allocator, bytecode_hex);
    defer allocator.free(init_code);
    
    log.info("Snailtracer bytecode loaded: {} bytes", .{init_code.len});
    
    const caller_address = primitives.Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 18 ++ [_]u8{0x01} };
    
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
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
        .gas_limit = 1_000_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var deploy_evm = try evm.Evm(.{}).init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
        .CANCUN
    );
    defer deploy_evm.deinit();
    
    const create_params = evm.CallParams{
        .create = .{
            .caller = caller_address,
            .value = 0,
            .init_code = init_code,
            .gas = 500_000_000,
        },
    };
    
    var deploy_result = deploy_evm.call(create_params);
    defer deploy_result.deinit(allocator);
    
    log.info("Snailtracer deployment: success={}, gas_left={}, gas_used={}", .{
        deploy_result.success,
        deploy_result.gas_left,
        500_000_000 - deploy_result.gas_left,
    });
    
    try std.testing.expect(deploy_result.success);
}