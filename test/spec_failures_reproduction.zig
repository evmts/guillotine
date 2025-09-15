const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

// Enable debug logging to see tracer output
test {
    std.testing.log_level = .debug;
}

// Minimal test to reproduce the synchronization issue
test "reproducing PC=0 PUSH0 misidentification" {
    const allocator = std.testing.allocator;

    // Minimal bytecode: just PUSH0 followed by STOP
    const bytecode = &[_]u8{
        0x5f, // PUSH0
        0x00, // STOP
    };

    // Setup Guillotine EVM
    var database = evm.Database.init(allocator);
    defer database.deinit();

    const caller_address = primitives.Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 18 ++ [_]u8{0x01} };
    const contract_address = primitives.Address{ .bytes = [_]u8{0x20} ++ [_]u8{0} ** 18 ++ [_]u8{0x02} };

    // Set the bytecode on the contract account
    const code_hash = try database.set_code(bytecode);

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
        .code_hash = [_]u8{0} ** 32, // Empty code hash for EOA
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

    const gas_limit = 100_000;
    var vm = try evm.VM(evm.DefaultConfig).init(allocator, &database, block_info);
    defer vm.deinit();

    const result = try vm.call(
        caller_address.bytes,
        contract_address.bytes,
        0, // value
        &.{}, // data
        gas_limit, // gas
    );

    // We expect this simple code to succeed
    try std.testing.expect(result.success);
}

// Test the actual failing case with CALL
test "reproducing CALL opcode issue" {
    const allocator = std.testing.allocator;

    // Build the actual 0xf1 CALL bytecode as in common.zig
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);

    // CALL bytecode exactly as generated
    try buf.append(allocator, 0x5f); // PUSH0 for retLength
    try buf.append(allocator, 0x5f); // PUSH0 for retOffset
    try buf.append(allocator, 0x5f); // PUSH0 for argsLength
    try buf.append(allocator, 0x5f); // PUSH0 for argsOffset
    try buf.append(allocator, 0x5f); // PUSH0 for value
    try buf.append(allocator, 0x30); // ADDRESS
    try buf.append(allocator, 0x61); // PUSH2
    try buf.append(allocator, 0x27); // 0x2710 >> 8
    try buf.append(allocator, 0x10); // 0x2710 & 0xff (10000 gas)
    try buf.append(allocator, 0xf1); // CALL

    // ret_top32 sequence
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, 0x00); // 0 (memory offset)
    try buf.append(allocator, 0x52); // MSTORE - stores top of stack at memory[0]
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, 0x20); // 32 (length)
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, 0x00); // 0 (offset)
    try buf.append(allocator, 0xf3); // RETURN

    const bytecode = buf.items;

    // Setup Guillotine EVM
    var database = evm.Database.init(allocator);
    defer database.deinit();

    const caller_address = primitives.Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 18 ++ [_]u8{0x01} };
    const contract_address = primitives.Address{ .bytes = [_]u8{0x20} ++ [_]u8{0} ** 18 ++ [_]u8{0x02} };

    // Set the bytecode on the contract account
    const code_hash = try database.set_code(bytecode);

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
        .code_hash = [_]u8{0} ** 32, // Empty code hash for EOA
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

    const gas_limit = 100_000;
    var vm = try evm.VM(evm.DefaultConfig).init(allocator, &database, block_info);
    defer vm.deinit();

    const result = try vm.call(
        caller_address.bytes,
        contract_address.bytes,
        0, // value
        &.{}, // data
        gas_limit, // gas
    );

    // We expect this to succeed
    try std.testing.expect(result.success);
}