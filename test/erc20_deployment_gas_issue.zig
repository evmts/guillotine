const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("voltaire");
const log = evm.log;

const Evm = evm.Evm;
const Database = evm.Database;
const CallParams = evm.CallParams;
const Address = primitives.Address.Address;
const BlockInfo = evm.BlockInfo;
const TransactionContext = evm.TransactionContext;

test "ERC20 deployment gas consumption issue" {
    const allocator = testing.allocator;
    log.info("Starting ERC20 deployment test", .{});

    // Create database
    var database = Database.init(allocator);
    defer database.deinit();

    // Create block info and transaction context
    const block_info = BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 1_000_000_000,
        .prev_randao = [_]u8{0} ** 32,
        .chain_id = 1,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };
    const tx_context = TransactionContext{
        .gas_limit = 16_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    // Create caller account with balance
    const caller_address = Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    const caller_account = evm.Account{
        .balance = 1_000_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
        .delegated_address = null,
    };
    try database.set_account(caller_address.bytes, caller_account);

    // Read the actual ERC20 bytecode from fixtures
    const bytecode_file = try std.fs.cwd().openFile("fixtures/erc20-transfer/bytecode.txt", .{});
    defer bytecode_file.close();

    const bytecode_hex = try bytecode_file.readToEndAlloc(allocator, 100_000);
    defer allocator.free(bytecode_hex);

    // Parse hex bytecode
    const trimmed = std.mem.trim(u8, bytecode_hex, " \t\n\r");
    const start_offset: usize = if (std.mem.startsWith(u8, trimmed, "0x")) 2 else 0;
    const hex_string = trimmed[start_offset..];

    var init_code = try allocator.alloc(u8, hex_string.len / 2);
    defer allocator.free(init_code);

    for (0..init_code.len) |i| {
        const byte_str = hex_string[i * 2 .. i * 2 + 2];
        init_code[i] = try std.fmt.parseInt(u8, byte_str, 16);
    }

    log.info("ERC20 init code size: {} bytes", .{init_code.len});

    const gas_amounts = [_]u64{
        1_000_000,
    };

    var deployed_ok = false;
    for (gas_amounts) |gas_amount| {
        log.info("Testing with gas: {}", .{gas_amount});

        var test_db = Database.init(allocator);
        defer test_db.deinit();

        try test_db.set_account(caller_address.bytes, caller_account);

        var test_evm = try Evm(.{}).init(
            allocator,
            &test_db,
            block_info,
            tx_context,
            0,
            caller_address,
        );
        defer test_evm.deinit();

        const create_params = CallParams{
            .create = .{
                .caller = caller_address,
                .value = 0,
                .init_code = init_code,
                .gas = gas_amount,
            },
        };

        var deploy_result = test_evm.call(create_params);
        defer deploy_result.deinit(allocator);

        log.info("  Result: success={}, gas_left={}, output_len={}", .{
            deploy_result.success,
            deploy_result.gas_left,
            deploy_result.output.len,
        });

        if (deploy_result.success) {
            const gas_used = gas_amount - deploy_result.gas_left;
            log.info("  Gas used: {} ({d:.2}% of provided)", .{
                gas_used,
                @as(f64, @floatFromInt(gas_used)) / @as(f64, @floatFromInt(gas_amount)) * 100.0,
            });

            const contract_address = deploy_result.created_address orelse
                try primitives.Address.getContractAddress(allocator, caller_address, 0);
            const account = try test_db.get_account(contract_address.bytes);
            try testing.expect(account != null);
            if (account) |acc| {
                const has_code = !std.mem.eql(u8, &acc.code_hash, &([_]u8{0} ** 32));
                try testing.expect(has_code);
                const code = try test_db.get_code(acc.code_hash);
                try testing.expect(code.len > 0);
            }
            deployed_ok = true;
            break;
        }
    }
    try testing.expect(deployed_ok);

    // Minimal contract: just STOP
    const minimal_init_code = [_]u8{0x00};

    var minimal_db = Database.init(allocator);
    defer minimal_db.deinit();
    try minimal_db.set_account(caller_address.bytes, caller_account);

    var minimal_evm = try Evm(.{}).init(
        allocator,
        &minimal_db,
        block_info,
        tx_context,
        0,
        caller_address,
    );
    defer minimal_evm.deinit();

    const minimal_create = CallParams{
        .create = .{
            .caller = caller_address,
            .value = 0,
            .init_code = &minimal_init_code,
            .gas = 1_000_000,
        },
    };

    var minimal_result = minimal_evm.call(minimal_create);
    defer minimal_result.deinit(allocator);
    try testing.expect(minimal_result.success);
}