const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("voltaire");

test "simple trace generation" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;

    // Simple bytecode: PUSH1 0x42, PUSH1 0x10, ADD, STOP
    const code = [_]u8{ 0x60, 0x42, 0x60, 0x10, 0x01, 0x00 };

    var database = Evm.Database.init(allocator);
    defer database.deinit();

    const caller = primitives.ZERO_ADDRESS;
    try database.set_account(caller.bytes, .{
        .balance = 1_000_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    const block_info = Evm.BlockInfo.init();
    const tx_context = Evm.TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    const TracingEvm = Evm.Evm(.{
        .tracer_config = .{
            .enabled = true,
            .enable_step_capture = true,
        },
    });
    var evm_instance = try TracingEvm.init(allocator, &database, block_info, tx_context, 0, caller);
    defer evm_instance.deinit();

    var deploy_result = evm_instance.call(.{
        .create = .{
            .caller = caller,
            .value = 0,
            .init_code = &code,
            .gas = 1_000_000,
        },
    });
    defer deploy_result.deinit(allocator);

    try testing.expect(deploy_result.success);
    try testing.expect(deploy_result.gas_left < 1_000_000);
}

test "trace with dispatch analysis" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;

    // PUSH1 0x05, PUSH1 0x00, SSTORE, PUSH1 0x00, SLOAD, PUSH1 0x0A, ADD, PUSH1 0x01, SSTORE, STOP
    const code = [_]u8{
        0x60, 0x05,
        0x60, 0x00,
        0x55,
        0x60, 0x00,
        0x54,
        0x60, 0x0A,
        0x01,
        0x60, 0x01,
        0x55,
        0x00,
    };

    var bytecode = try Evm.Bytecode(.{}).init(allocator, &code);
    defer bytecode.deinit();

    const pretty = try bytecode.pretty_print(allocator);
    defer allocator.free(pretty);
    try testing.expect(pretty.len > 0);

    var database = Evm.Database.init(allocator);
    defer database.deinit();

    const caller = primitives.ZERO_ADDRESS;
    const contract_address = try primitives.Address.fromHex("0x1111111111111111111111111111111111111111");
    const code_hash = try database.set_code(&code);
    try database.set_account(contract_address.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    const block_info = Evm.BlockInfo.init();
    const tx_context = Evm.TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm_instance = try Evm.DefaultEvm.init(allocator, &database, block_info, tx_context, 0, caller);
    defer evm_instance.deinit();

    var call_result = evm_instance.call(.{
        .call = .{
            .caller = caller,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 1_000_000,
        },
    });
    defer call_result.deinit(allocator);

    try testing.expect(call_result.success);
    try testing.expectEqual(@as(u256, 5), try database.get_storage(contract_address.bytes, 0));
    try testing.expectEqual(@as(u256, 15), try database.get_storage(contract_address.bytes, 1));
}

test "erc20 mint trace - minimal" {
    std.testing.log_level = .err;
    const allocator = testing.allocator;

    const mint_calldata = [_]u8{
        0x40, 0xc1, 0x0f, 0x19, // mint(address,uint256) selector
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, // recipient = 1
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0xe8, // amount = 1000
    };

    // Minimal ERC20 mint implementation with exact JUMPDEST PC (0x14 = 20)
    const contract_code = [_]u8{
        0x60, 0x00, // 0x00: PUSH1 0x00
        0x35, // 0x02: CALLDATALOAD
        0x60, 0xe0, // 0x03: PUSH1 0xe0
        0x1c, // 0x05: SHR
        0x63, 0x40, 0xc1, 0x0f, 0x19, // 0x06: PUSH4 0x40c10f19
        0x14, // 0x0b: EQ
        0x60, 0x14, // 0x0c: PUSH1 0x14 (JUMPDEST)
        0x57, // 0x0e: JUMPI
        0x60, 0x00, // 0x0f: PUSH1 0x00
        0x60, 0x00, // 0x11: PUSH1 0x00
        0xfd, // 0x13: REVERT
        0x5b, // 0x14: JUMPDEST
        0x60, 0x04, // 0x15: PUSH1 0x04
        0x35, // 0x17: CALLDATALOAD (recipient)
        0x60, 0x24, // 0x18: PUSH1 0x24
        0x35, // 0x1a: CALLDATALOAD (amount)
        0x81, // 0x1b: DUP2 (recipient)
        0x54, // 0x1c: SLOAD
        0x01, // 0x1d: ADD
        0x81, // 0x1e: DUP2 (recipient)
        0x55, // 0x1f: SSTORE
        0x60, 0x01, // 0x20: PUSH1 0x01
        0x60, 0x00, // 0x22: PUSH1 0x00
        0x52, // 0x24: MSTORE
        0x60, 0x20, // 0x25: PUSH1 0x20
        0x60, 0x00, // 0x27: PUSH1 0x00
        0xf3, // 0x29: RETURN
    };

    var database = Evm.Database.init(allocator);
    defer database.deinit();

    const contract_address = try primitives.Address.fromHex("0x5FbDB2315678afecb367f032d93F642f64180aa3");
    const code_hash = try database.set_code(&contract_code);
    try database.set_account(contract_address.bytes, .{
        .nonce = 1,
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });

    const block_info = Evm.BlockInfo.init();
    const tx_context = Evm.TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var evm_instance = try Evm.DefaultEvm.init(allocator, &database, block_info, tx_context, 0, primitives.ZERO_ADDRESS);
    defer evm_instance.deinit();

    var call_result = evm_instance.call(.{
        .call = .{
            .caller = primitives.ZERO_ADDRESS,
            .to = contract_address,
            .value = 0,
            .input = &mint_calldata,
            .gas = 1_000_000,
        },
    });
    defer call_result.deinit(allocator);

    try testing.expect(call_result.success);
    try testing.expectEqual(@as(usize, 32), call_result.output.len);
    try testing.expectEqual(@as(u256, 1), std.mem.readInt(u256, call_result.output[0..32], .big));
    try testing.expectEqual(@as(u256, 1000), try database.get_storage(contract_address.bytes, 1));
}
