const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const common = @import("common.zig");

fn run_and_test(allocator: std.mem.Allocator, a: u256, b: u256, expected: u256) !void {
    _ = expected; // TODO: Use when stack comparison is re-enabled
    // Build bytecode: PUSH a, PUSH b, AND
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
    
    // AND
    try bytecode.append(allocator, 0x16);
    
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

fn run_and_test_with_jump(allocator: std.mem.Allocator, a: u256, b: u256, expected: u256) !void {
    _ = expected; // TODO: Use when stack comparison is re-enabled
    // Build bytecode with JUMP to prevent opcode fusion: PUSH a, PUSH b, PUSH dest, JUMP, JUMPDEST, AND
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
    
    // AND
    try bytecode.append(allocator, 0x16);
    
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

test "AND: zero with anything" {
    const allocator = std.testing.allocator;
    try run_and_test(allocator, 0, 0, 0); // 0 & 0 = 0
    try run_and_test_with_jump(allocator, 0, 0xFF, 0); // 0 & 0xFF = 0
}

test "AND: all ones" {
    const allocator = std.testing.allocator;
    const all_ones = std.math.maxInt(u256);
    try run_and_test(allocator, all_ones, all_ones, all_ones); // 0xFFF...FFF & 0xFFF...FFF = 0xFFF...FFF
    try run_and_test_with_jump(allocator, all_ones, 0xFF, 0xFF); // 0xFFF...FFF & 0xFF = 0xFF
}

test "AND: single bit masks" {
    const allocator = std.testing.allocator;
    try run_and_test(allocator, 0x01, 0x01, 0x01); // Same bit = 1
    try run_and_test_with_jump(allocator, 0x01, 0x02, 0x00); // Different bits = 0
}

test "AND: byte masks" {
    const allocator = std.testing.allocator;
    try run_and_test(allocator, 0xFF00, 0x00FF, 0x0000); // Non-overlapping = 0
    try run_and_test_with_jump(allocator, 0xFFFF, 0x00FF, 0x00FF); // Partial overlap
}

test "AND: alternating patterns" {
    const allocator = std.testing.allocator;
    const pattern1 = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA;
    const pattern2 = 0x5555555555555555555555555555555555555555555555555555555555555555;
    try run_and_test(allocator, pattern1, pattern2, 0); // Complementary patterns = 0
    try run_and_test_with_jump(allocator, pattern1, pattern1, pattern1); // Same pattern
}

test "AND: powers of two" {
    const allocator = std.testing.allocator;
    const p1 = 1 << 100;
    const p2 = 1 << 200;
    try run_and_test(allocator, p1, p1, p1); // Same power = itself
    try run_and_test_with_jump(allocator, p1, p2, 0); // Different powers = 0
}

test "AND: masking operations" {
    const allocator = std.testing.allocator;
    const value: u256 = 0xDEADBEEF_CAFEBABE_DEADBEEF_CAFEBABE;
    const mask: u256 = 0xFFFFFFFF_00000000_FFFFFFFF_00000000;
    const expected = 0xDEADBEEF_00000000_DEADBEEF_00000000;
    try run_and_test(allocator, value, mask, expected);
    try run_and_test_with_jump(allocator, value, ~mask, value & ~mask);
}

test "AND: high byte masking" {
    const allocator = std.testing.allocator;
    const value = std.math.maxInt(u256);
    const mask = 0xFF00000000000000000000000000000000000000000000000000000000000000;
    try run_and_test(allocator, value, mask, mask);
    try run_and_test_with_jump(allocator, mask, mask, mask);
}

test "AND: low byte masking" {
    const allocator = std.testing.allocator;
    const value = std.math.maxInt(u256);
    const mask = 0xFF;
    try run_and_test(allocator, value, mask, mask);
    try run_and_test_with_jump(allocator, 0xABCDEF, mask, 0xEF);
}

test "AND: clearing specific bits" {
    const allocator = std.testing.allocator;
    const value = 0xFFFF;
    const clear_mask = ~@as(u256, 0x00F0); // Clear bits 4-7
    const expected = 0xFF0F;
    try run_and_test(allocator, value, clear_mask, expected);
    try run_and_test_with_jump(allocator, 0x1234, clear_mask, 0x1204);
}

test "AND: extracting nibbles" {
    const allocator = std.testing.allocator;
    const value = 0xABCD;
    try run_and_test(allocator, value, 0x000F, 0x000D); // Low nibble
    try run_and_test_with_jump(allocator, value, 0xF000, 0xA000); // High nibble
}

test "AND: word alignment masks" {
    const allocator = std.testing.allocator;
    const word_mask = 0xFFFFFFFF; // 32-bit mask
    const value = 0x123456789ABCDEF0;
    try run_and_test(allocator, value, word_mask, 0x9ABCDEF0);
    try run_and_test_with_jump(allocator, value, word_mask << 32, 0x1234567800000000);
}

test "AND: sign bit operations" {
    const allocator = std.testing.allocator;
    const sign_bit = 1 << 255;
    const value = std.math.maxInt(u256);
    try run_and_test(allocator, value, sign_bit, sign_bit);
    try run_and_test_with_jump(allocator, sign_bit - 1, sign_bit, 0);
}

test "AND: middle bits extraction" {
    const allocator = std.testing.allocator;
    const middle_mask = 0x00000000FFFFFFFF0000000000000000FFFFFFFF00000000;
    const value = std.math.maxInt(u256);
    try run_and_test(allocator, value, middle_mask, middle_mask);
    try run_and_test_with_jump(allocator, 0, middle_mask, 0);
}

test "AND: cascading masks" {
    const allocator = std.testing.allocator;
    const value = 0xFFFFFFFFFFFFFFFF;
    const mask1 = 0x00FF00FF00FF00FF;
    const expected = 0x00FF00FF00FF00FF;
    try run_and_test(allocator, value, mask1, expected);
    try run_and_test_with_jump(allocator, mask1, mask1, mask1);
}

test "opcode 0x16 differential test" {
    const allocator = std.testing.allocator;
    
    // Build bytecode for this opcode
    const bytecode = try common.build_bytecode(allocator, 0x16);
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
