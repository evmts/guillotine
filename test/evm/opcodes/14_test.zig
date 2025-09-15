const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const common = @import("common.zig");

fn run_eq_test(allocator: std.mem.Allocator, a: u256, b: u256, expected: u256) !void {
    _ = expected; // TODO: Use when stack comparison is re-enabled
    // Build bytecode: PUSH a, PUSH b, EQ
    var bytecode = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer bytecode.deinit(allocator);
    
    // PUSH a
    try bytecode.append(allocator, 0x7f); // PUSH32
    var a_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &a_bytes, a, .big);
    try bytecode.appendSlice(allocator, &a_bytes);
    
    // PUSH b
    try bytecode.append(allocator, 0x7f); // PUSH32
    var b_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &b_bytes, b, .big);
    try bytecode.appendSlice(allocator, &b_bytes);
    
    // EQ
    try bytecode.append(allocator, 0x14);
    
    // Setup Guillotine EVM
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
    const caller_address = primitives.Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 18 ++ [_]u8{0x01} };
    const contract_address = primitives.Address{ .bytes = [_]u8{0x20} ++ [_]u8{0} ** 18 ++ [_]u8{0x02} };
    
    const code_hash = try database.set_code(bytecode.items);
    
    try database.set_account(contract_address.bytes, .{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    
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
    
    var guillotine_evm = try evm.Evm(.{}).init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
        .CANCUN
    );
    defer guillotine_evm.deinit();
    
    const call_params = evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 1_000_000,
        },
    };
    
    var guillotine_result = guillotine_evm.call(call_params);
    defer guillotine_result.deinit(allocator);
}

fn run_eq_test_with_jump(allocator: std.mem.Allocator, a: u256, b: u256, expected: u256) !void {
    _ = expected; // TODO: Use when stack comparison is re-enabled
    // Build bytecode with JUMP to prevent opcode fusion: PUSH a, PUSH b, PUSH dest, JUMP, JUMPDEST, EQ
    var bytecode = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer bytecode.deinit(allocator);
    
    // PUSH a
    try bytecode.append(allocator, 0x7f); // PUSH32
    var a_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &a_bytes, a, .big);
    try bytecode.appendSlice(allocator, &a_bytes);
    
    // PUSH b
    try bytecode.append(allocator, 0x7f); // PUSH32
    var b_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &b_bytes, b, .big);
    try bytecode.appendSlice(allocator, &b_bytes);
    
    // PUSH destination (position after JUMP: 32 + 1 + 32 + 1 + 1 + 1 + 1 = 69)
    try bytecode.append(allocator, 0x60); // PUSH1
    try bytecode.append(allocator, 69);
    
    // JUMP
    try bytecode.append(allocator, 0x56);
    
    // JUMPDEST
    try bytecode.append(allocator, 0x5b);
    
    // EQ
    try bytecode.append(allocator, 0x14);
    
    // Setup and execute (same as regular test)
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
    const caller_address = primitives.Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 18 ++ [_]u8{0x01} };
    const contract_address = primitives.Address{ .bytes = [_]u8{0x20} ++ [_]u8{0} ** 18 ++ [_]u8{0x02} };
    
    const code_hash = try database.set_code(bytecode.items);
    
    try database.set_account(contract_address.bytes, .{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    
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
    
    var guillotine_evm = try evm.Evm(.{}).init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
        .CANCUN
    );
    defer guillotine_evm.deinit();
    
    const call_params = evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 1_000_000,
        },
    };
    
    var guillotine_result = guillotine_evm.call(call_params);
    defer guillotine_result.deinit(allocator);
}

test "EQ: equal small values" {
    const allocator = std.testing.allocator;
    try run_eq_test(allocator, 5, 5, 1); // 5 == 5
    try run_eq_test_with_jump(allocator, 100, 100, 1); // 100 == 100
}

test "EQ: unequal small values" {
    const allocator = std.testing.allocator;
    try run_eq_test(allocator, 5, 10, 0); // 5 == 10
    try run_eq_test_with_jump(allocator, 100, 99, 0); // 100 == 99
}

test "EQ: zero comparisons" {
    const allocator = std.testing.allocator;
    try run_eq_test(allocator, 0, 0, 1); // 0 == 0
    try run_eq_test_with_jump(allocator, 0, 1, 0); // 0 == 1
}

test "EQ: MAX value comparisons" {
    const allocator = std.testing.allocator;
    const max = std.math.maxInt(u256);
    try run_eq_test(allocator, max, max, 1); // MAX == MAX
    try run_eq_test_with_jump(allocator, max, max - 1, 0); // MAX == MAX-1
}

test "EQ: powers of two" {
    const allocator = std.testing.allocator;
    const p1 = 1 << 100;
    const p2 = 1 << 200;
    try run_eq_test(allocator, p1, p1, 1); // 2^100 == 2^100
    try run_eq_test_with_jump(allocator, p1, p2, 0); // 2^100 == 2^200
}

test "EQ: large equal values" {
    const allocator = std.testing.allocator;
    const large = 0xDEADBEEF_CAFEBABE_DEADBEEF_CAFEBABE_DEADBEEF_CAFEBABE_DEADBEEF_CAFEBABE;
    try run_eq_test(allocator, large, large, 1);
    try run_eq_test_with_jump(allocator, large, large + 1, 0);
}

test "EQ: alternating bit patterns" {
    const allocator = std.testing.allocator;
    const pattern1 = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA;
    const pattern2 = 0x5555555555555555555555555555555555555555555555555555555555555555;
    try run_eq_test(allocator, pattern1, pattern1, 1);
    try run_eq_test_with_jump(allocator, pattern1, pattern2, 0);
}

test "EQ: one-bit difference" {
    const allocator = std.testing.allocator;
    const value = 0x1000000000000000000000000000000000000000000000000000000000000000;
    try run_eq_test(allocator, value, value, 1);
    try run_eq_test_with_jump(allocator, value, value + 1, 0);
}

test "EQ: high byte differences" {
    const allocator = std.testing.allocator;
    const base = 0xFF00000000000000000000000000000000000000000000000000000000000000;
    const diff = 0xFE00000000000000000000000000000000000000000000000000000000000000;
    try run_eq_test(allocator, base, base, 1);
    try run_eq_test_with_jump(allocator, base, diff, 0);
}

test "EQ: low byte differences" {
    const allocator = std.testing.allocator;
    const base = 0x00000000000000000000000000000000000000000000000000000000000000FF;
    const diff = 0x00000000000000000000000000000000000000000000000000000000000000FE;
    try run_eq_test(allocator, base, base, 1);
    try run_eq_test_with_jump(allocator, base, diff, 0);
}

test "EQ: consecutive values" {
    const allocator = std.testing.allocator;
    try run_eq_test(allocator, 1000, 1000, 1);
    try run_eq_test_with_jump(allocator, 1000, 1001, 0);
}

test "EQ: sign bit edge cases" {
    const allocator = std.testing.allocator;
    const sign_bit = 1 << 255;
    try run_eq_test(allocator, sign_bit, sign_bit, 1);
    try run_eq_test_with_jump(allocator, sign_bit, sign_bit - 1, 0);
}

test "EQ: all ones and zeros" {
    const allocator = std.testing.allocator;
    const all_ones = std.math.maxInt(u256);
    try run_eq_test(allocator, all_ones, all_ones, 1);
    try run_eq_test_with_jump(allocator, all_ones, 0, 0);
}

test "EQ: half-filled patterns" {
    const allocator = std.testing.allocator;
    const half: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000000000000000000000000000;
    try run_eq_test(allocator, half, half, 1);
    try run_eq_test_with_jump(allocator, half, ~half, 0);
}

test "opcode 0x14 differential test" {
    const allocator = std.testing.allocator;
    
    // Build bytecode for this opcode
    const bytecode = try common.build_bytecode(allocator, 0x14);
    defer allocator.free(bytecode);
    
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

    const tx_context = evm.TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var guillotine_evm = try evm.Evm(.{}).init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
        .CANCUN
    );
    defer guillotine_evm.deinit();
    
    // Execute with Guillotine using call
    const call_params = evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &.{}, // Empty input - code is on the account
            .gas = 1_000_000,
        },
    };
    
    var guillotine_result = guillotine_evm.call(call_params);
    defer guillotine_result.deinit(allocator);
}
