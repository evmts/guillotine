const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

/// Load fixture file and convert hex string to bytes
fn loadFixture(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const hex_content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(hex_content);

    var trimmed = std.mem.trim(u8, hex_content, " \n\r\t");
    if (std.mem.startsWith(u8, trimmed, "0x") or std.mem.startsWith(u8, trimmed, "0X")) {
        trimmed = trimmed[2..];
    }

    const bytes = try allocator.alloc(u8, trimmed.len / 2);
    errdefer allocator.free(bytes);
    _ = try std.fmt.hexToBytes(bytes, trimmed);

    return bytes;
}

test "ERC20 mint test" {
    const allocator = std.testing.allocator;

    const init_code = try loadFixture(allocator, "fixtures/erc20-mint/bytecode.txt");
    defer allocator.free(init_code);

    const calldata = try loadFixture(allocator, "fixtures/erc20-mint/calldata.txt");
    defer allocator.free(calldata);

    var database = evm.Database.init(allocator);
    defer database.deinit();

    const caller_address = primitives.Address{
        .bytes = [_]u8{0x10} ++ [_]u8{0} ** 18 ++ [_]u8{0x01},
    };
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
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 7,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 1000000000,
        .blob_versioned_hashes = &.{},
    };
    const tx_context = evm.TransactionContext{
        .gas_limit = 16_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm_instance = try evm.DefaultEvm.init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
    );
    defer evm_instance.deinit();

    // Deploy ERC20 initcode via CREATE first
    var deploy_result = evm_instance.call(.{
        .create = .{
            .caller = caller_address,
            .value = 0,
            .init_code = init_code,
            .gas = 16_000_000,
        },
    });
    defer deploy_result.deinit(allocator);
    try std.testing.expect(deploy_result.success);

    const contract_address = deploy_result.created_address orelse
        try primitives.Address.getContractAddress(allocator, caller_address, 0);

    // Execute mint call on deployed contract
    var result = evm_instance.call(.{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = calldata,
            .gas = 16_000_000,
        },
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(result.gas_left < 16_000_000);
}
