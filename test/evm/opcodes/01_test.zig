const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const common = @import("common.zig");

test "ADD: basic (2 + 3 = 5)" {
    try run_add_test(std.testing.allocator, 2, 3);
}

fn run_add_test(allocator: std.mem.Allocator, a: u256, b: u256) !void {
    // Build custom bytecode for ADD test
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    
    // Push a
    if (a == 0) {
        try buf.append(allocator, 0x5f); // PUSH0
    } else {
        var tmp: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &tmp, a, .big);
        const first_non_zero = std.mem.indexOfNonePos(u8, &tmp, 0, &[_]u8{0}) orelse 32;
        const slice = tmp[first_non_zero..];
        if (slice.len > 0 and slice.len <= 32) {
            const op: u8 = 0x60 + @as(u8, @intCast(slice.len - 1));
            try buf.append(allocator, op);
            try buf.appendSlice(allocator, slice);
        }
    }
    
    // Push b
    if (b == 0) {
        try buf.append(allocator, 0x5f); // PUSH0
    } else {
        var tmp: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &tmp, b, .big);
        const first_non_zero = std.mem.indexOfNonePos(u8, &tmp, 0, &[_]u8{0}) orelse 32;
        const slice = tmp[first_non_zero..];
        if (slice.len > 0 and slice.len <= 32) {
            const op: u8 = 0x60 + @as(u8, @intCast(slice.len - 1));
            try buf.append(allocator, op);
            try buf.appendSlice(allocator, slice);
        }
    }
    
    // ADD opcode
    try buf.append(allocator, 0x01);
    
    // Store result and return
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, 0x00); // 0 (memory offset)
    try buf.append(allocator, 0x52); // MSTORE
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, 0x20); // 32 (length)
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, 0x00); // 0 (offset)
    try buf.append(allocator, 0xf3); // RETURN
    
    const bytecode = try buf.toOwnedSlice(allocator);
    defer allocator.free(bytecode);
    
    // Setup Guillotine EVM
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
    const caller_address = primitives.Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 18 ++ [_]u8{0x01} };
    const contract_address = primitives.Address{ .bytes = [_]u8{0x20} ++ [_]u8{0} ** 18 ++ [_]u8{0x02} };
    
    const code_hash = try database.set_code(bytecode);
    
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

test "ADD: zero addition (0 + 0 = 0)" {
    try run_add_test(std.testing.allocator, 0, 0);
}

test "ADD: add zero to number (42 + 0 = 42)" {
    try run_add_test(std.testing.allocator, 42, 0);
}

test "ADD: add number to zero (0 + 100 = 100)" {
    try run_add_test(std.testing.allocator, 0, 100);
}

test "ADD: small numbers (10 + 20 = 30)" {
    try run_add_test(std.testing.allocator, 10, 20);
}

test "ADD: larger numbers (1000 + 2000 = 3000)" {
    try run_add_test(std.testing.allocator, 1000, 2000);
}

test "ADD: power of 2 (256 + 256 = 512)" {
    try run_add_test(std.testing.allocator, 256, 256);
}

test "ADD: near u64 boundary" {
    const near_u64 = @as(u256, std.math.maxInt(u64)) - 10;
    try run_add_test(std.testing.allocator, near_u64, 20);
}

test "ADD: exactly u64 max" {
    const u64_max = @as(u256, std.math.maxInt(u64));
    try run_add_test(std.testing.allocator, u64_max, 1);
}

test "ADD: large 128-bit numbers" {
    const large_128 = @as(u256, 1) << 120;
    try run_add_test(std.testing.allocator, large_128, large_128);
}

test "ADD: overflow to exactly zero (MAX + 1 = 0)" {
    try run_add_test(std.testing.allocator, std.math.maxInt(u256), 1);
}

test "ADD: overflow with wrap (MAX + 2 = 1)" {
    try run_add_test(std.testing.allocator, std.math.maxInt(u256), 2);
}

test "ADD: overflow with larger values (MAX + 100 = 99)" {
    try run_add_test(std.testing.allocator, std.math.maxInt(u256), 100);
}

test "ADD: half MAX + half MAX = MAX - 1" {
    const half_max = std.math.maxInt(u256) / 2;
    try run_add_test(std.testing.allocator, half_max, half_max);
}

test "ADD: MAX - 1 + 1 = MAX" {
    try run_add_test(std.testing.allocator, std.math.maxInt(u256) - 1, 1);
}

test "ADD: MAX - 1 + 2 = 0 (overflow)" {
    try run_add_test(std.testing.allocator, std.math.maxInt(u256) - 1, 2);
}

test "ADD: large overflow (MAX/2 + MAX = MAX/2 - 1)" {
    const half_max = std.math.maxInt(u256) / 2;
    try run_add_test(std.testing.allocator, half_max, std.math.maxInt(u256));
}

test "ADD: prime numbers" {
    try run_add_test(std.testing.allocator, 997, 1009);
}

test "ADD: fibonacci numbers" {
    try run_add_test(std.testing.allocator, 13, 21);
}

test "ADD: powers of 2" {
    const pow_128 = @as(u256, 1) << 128;
    const pow_129 = @as(u256, 1) << 129;
    try run_add_test(std.testing.allocator, pow_128, pow_129);
}

test "ADD: near 256-bit boundary" {
    const near_max = std.math.maxInt(u256) - 1000;
    try run_add_test(std.testing.allocator, near_max, 500);
}

test "ADD: alternating bit patterns" {
    const pattern1 = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA;
    const pattern2 = 0x5555555555555555555555555555555555555555555555555555555555555555;
    try run_add_test(std.testing.allocator, pattern1, pattern2);
}

test "ADD: all 1s pattern" {
    const all_ones_128 = (@as(u256, 1) << 128) - 1;
    try run_add_test(std.testing.allocator, all_ones_128, all_ones_128);
}

test "ADD: sequential values" {
    try run_add_test(std.testing.allocator, 12345, 12346);
}

test "ADD: large sequential" {
    const large = @as(u256, 1) << 200;
    try run_add_test(std.testing.allocator, large, large + 1);
}

fn run_add_test_with_jump(allocator: std.mem.Allocator, a: u256, b: u256) !void {
    // Build custom bytecode for ADD test with jump to prevent fusion
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    
    // Push a
    if (a == 0) {
        try buf.append(allocator, 0x5f); // PUSH0
    } else {
        var tmp: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &tmp, a, .big);
        const first_non_zero = std.mem.indexOfNonePos(u8, &tmp, 0, &[_]u8{0}) orelse 32;
        const slice = tmp[first_non_zero..];
        if (slice.len > 0 and slice.len <= 32) {
            const op: u8 = 0x60 + @as(u8, @intCast(slice.len - 1));
            try buf.append(allocator, op);
            try buf.appendSlice(allocator, slice);
        }
    }
    
    // Push b
    if (b == 0) {
        try buf.append(allocator, 0x5f); // PUSH0
    } else {
        var tmp: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &tmp, b, .big);
        const first_non_zero = std.mem.indexOfNonePos(u8, &tmp, 0, &[_]u8{0}) orelse 32;
        const slice = tmp[first_non_zero..];
        if (slice.len > 0 and slice.len <= 32) {
            const op: u8 = 0x60 + @as(u8, @intCast(slice.len - 1));
            try buf.append(allocator, op);
            try buf.appendSlice(allocator, slice);
        }
    }
    
    // Calculate jump destination (current position + 3 for PUSH1 + 1 byte + JUMP)
    const jump_dest = buf.items.len + 3;
    
    // Jump to ADD (prevents fusion)
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, @intCast(jump_dest)); // destination
    try buf.append(allocator, 0x56); // JUMP
    
    // JUMPDEST + ADD
    try buf.append(allocator, 0x5b); // JUMPDEST
    try buf.append(allocator, 0x01); // ADD opcode
    
    // Store result and return
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, 0x00); // 0 (memory offset)
    try buf.append(allocator, 0x52); // MSTORE
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, 0x20); // 32 (length)
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, 0x00); // 0 (offset)
    try buf.append(allocator, 0xf3); // RETURN
    
    const bytecode = try buf.toOwnedSlice(allocator);
    defer allocator.free(bytecode);
    
    // Setup Guillotine EVM
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
    const caller_address = primitives.Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 18 ++ [_]u8{0x01} };
    const contract_address = primitives.Address{ .bytes = [_]u8{0x20} ++ [_]u8{0} ** 18 ++ [_]u8{0x02} };
    
    const code_hash = try database.set_code(bytecode);
    
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

test "ADD with JUMP: basic (2 + 3 = 5)" {
    try run_add_test_with_jump(std.testing.allocator, 2, 3);
}

test "ADD with JUMP: zero addition (0 + 0 = 0)" {
    try run_add_test_with_jump(std.testing.allocator, 0, 0);
}

test "ADD with JUMP: large numbers" {
    try run_add_test_with_jump(std.testing.allocator, 1000000, 2000000);
}

test "ADD with JUMP: overflow (MAX + 1 = 0)" {
    try run_add_test_with_jump(std.testing.allocator, std.math.maxInt(u256), 1);
}

test "ADD with JUMP: near u64 boundary" {
    const near_u64 = @as(u256, std.math.maxInt(u64)) - 10;
    try run_add_test_with_jump(std.testing.allocator, near_u64, 20);
}