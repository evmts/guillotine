const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const common = @import("common.zig");

test "MULMOD: basic ((10 * 10) % 8 = 4)" {
    try run_mulmod_test(std.testing.allocator, 10, 10, 8);
}

fn run_mulmod_test(allocator: std.mem.Allocator, a: u256, b: u256, n: u256) !void {
    // Build custom bytecode for MULMOD test
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
    
    // Push n (modulus)
    if (n == 0) {
        try buf.append(allocator, 0x5f); // PUSH0
    } else {
        var tmp: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &tmp, n, .big);
        const first_non_zero = std.mem.indexOfNonePos(u8, &tmp, 0, &[_]u8{0}) orelse 32;
        const slice = tmp[first_non_zero..];
        if (slice.len > 0 and slice.len <= 32) {
            const op: u8 = 0x60 + @as(u8, @intCast(slice.len - 1));
            try buf.append(allocator, op);
            try buf.appendSlice(allocator, slice);
        }
    }
    
    // MULMOD opcode
    try buf.append(allocator, 0x09);
    
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

test "MULMOD: modulo zero ((42 * 58) % 0 = 0)" {
    try run_mulmod_test(std.testing.allocator, 42, 58, 0);
}

test "MULMOD: zero multiplication ((0 * 0) % 5 = 0)" {
    try run_mulmod_test(std.testing.allocator, 0, 0, 5);
}

test "MULMOD: zero times value ((0 * 100) % 7 = 0)" {
    try run_mulmod_test(std.testing.allocator, 0, 100, 7);
}

test "MULMOD: value times zero ((100 * 0) % 7 = 0)" {
    try run_mulmod_test(std.testing.allocator, 100, 0, 7);
}

test "MULMOD: one times value ((1 * 100) % 7 = 2)" {
    try run_mulmod_test(std.testing.allocator, 1, 100, 7);
}

test "MULMOD: exact division ((5 * 3) % 15 = 0)" {
    try run_mulmod_test(std.testing.allocator, 5, 3, 15);
}

test "MULMOD: modulo 1 ((123 * 456) % 1 = 0)" {
    try run_mulmod_test(std.testing.allocator, 123, 456, 1);
}

test "MULMOD: large numbers ((99999 * 99999) % 1000000 = 9999800001 % 1000000)" {
    try run_mulmod_test(std.testing.allocator, 99999, 99999, 1000000);
}

test "MULMOD: powers of 2 ((256 * 256) % 128 = 0)" {
    try run_mulmod_test(std.testing.allocator, 256, 256, 128);
}

test "MULMOD: near u64 boundary" {
    const near_u64 = @as(u256, std.math.maxInt(u32));
    try run_mulmod_test(std.testing.allocator, near_u64, 2, 100);
}

test "MULMOD: exactly u64 max" {
    const u64_max = @as(u256, std.math.maxInt(u64));
    try run_mulmod_test(std.testing.allocator, u64_max, 2, 1000);
}

test "MULMOD: large 128-bit numbers" {
    const large_64 = @as(u256, 1) << 64;
    try run_mulmod_test(std.testing.allocator, large_64, large_64, (@as(u256, 1) << 100));
}

test "MULMOD: overflow prevention (MAX * MAX) % 100" {
    try run_mulmod_test(std.testing.allocator, std.math.maxInt(u256), std.math.maxInt(u256), 100);
}

test "MULMOD: overflow with large modulus" {
    const half_max = std.math.maxInt(u256) / 2;
    try run_mulmod_test(std.testing.allocator, std.math.maxInt(u256), 2, half_max);
}

test "MULMOD: MAX * 1 mod MAX" {
    try run_mulmod_test(std.testing.allocator, std.math.maxInt(u256), 1, std.math.maxInt(u256));
}

test "MULMOD: prime modulus ((13 * 17) % 31 = 4)" {
    try run_mulmod_test(std.testing.allocator, 13, 17, 31);
}

test "MULMOD: fibonacci numbers ((13 * 21) % 34 = 1)" {
    try run_mulmod_test(std.testing.allocator, 13, 21, 34);
}

test "MULMOD: near 256-bit boundary" {
    const near_max = std.math.maxInt(u256) / 3;
    try run_mulmod_test(std.testing.allocator, near_max, 2, 200);
}

test "MULMOD: alternating bit patterns" {
    const pattern1 = 0xAAAAAAAAAAAAAAAA;
    const pattern2 = 0x5555555555555555;
    try run_mulmod_test(std.testing.allocator, pattern1, pattern2, 0xFFFFFFFF);
}

test "MULMOD: all 1s pattern modulo" {
    const all_ones_64 = (@as(u256, 1) << 64) - 1;
    try run_mulmod_test(std.testing.allocator, all_ones_64, 2, all_ones_64);
}

test "MULMOD: sequential values ((99 * 100) % 100 = 0)" {
    try run_mulmod_test(std.testing.allocator, 99, 100, 100);
}

test "MULMOD: large sequential" {
    const large = @as(u256, 1) << 100;
    try run_mulmod_test(std.testing.allocator, large, large + 1, (@as(u256, 1) << 150));
}

test "MULMOD: modulo larger than operands ((10 * 20) % 1000 = 200)" {
    try run_mulmod_test(std.testing.allocator, 10, 20, 1000);
}

test "MULMOD: square numbers ((12 * 12) % 13 = 1)" {
    try run_mulmod_test(std.testing.allocator, 12, 12, 13);
}

test "MULMOD: overflow edge case" {
    const edge = std.math.maxInt(u256) / 3;
    try run_mulmod_test(std.testing.allocator, edge, 3, edge);
}

test "MULMOD: power of 10 modulus" {
    const pow10 = 10000000000; // 10^10
    try run_mulmod_test(std.testing.allocator, pow10 / 100, pow10 / 100, pow10);
}

test "MULMOD: edge case with quotient 1" {
    const edge = (@as(u256, 1) << 128) - 1;
    try run_mulmod_test(std.testing.allocator, edge, edge, edge);
}

fn run_mulmod_test_with_jump(allocator: std.mem.Allocator, a: u256, b: u256, n: u256) !void {
    // Build custom bytecode for MULMOD test with jump to prevent fusion
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
    
    // Push n (modulus)
    if (n == 0) {
        try buf.append(allocator, 0x5f); // PUSH0
    } else {
        var tmp: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &tmp, n, .big);
        const first_non_zero = std.mem.indexOfNonePos(u8, &tmp, 0, &[_]u8{0}) orelse 32;
        const slice = tmp[first_non_zero..];
        if (slice.len > 0 and slice.len <= 32) {
            const op: u8 = 0x60 + @as(u8, @intCast(slice.len - 1));
            try buf.append(allocator, op);
            try buf.appendSlice(allocator, slice);
        }
    }
    
    // Jump to MULMOD (prevents fusion)
    // First calculate the jump destination
    // We need PUSH1 (1) + dest byte (1) + JUMP (1) + JUMPDEST (1) = 4 bytes ahead
    const jump_dest = buf.items.len + 4;
    
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, @intCast(jump_dest)); // destination
    try buf.append(allocator, 0x56); // JUMP
    
    // Invalid opcode (should never be executed)
    try buf.append(allocator, 0xfe); // INVALID
    
    // JUMPDEST + MULMOD
    try buf.append(allocator, 0x5b); // JUMPDEST
    try buf.append(allocator, 0x09); // MULMOD opcode
    
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

test "MULMOD with JUMP: basic ((10 * 10) % 8 = 4)" {
    try run_mulmod_test_with_jump(std.testing.allocator, 10, 10, 8);
}

test "MULMOD with JUMP: modulo zero ((100 * 200) % 0 = 0)" {
    try run_mulmod_test_with_jump(std.testing.allocator, 100, 200, 0);
}

test "MULMOD with JUMP: large numbers" {
    try run_mulmod_test_with_jump(std.testing.allocator, 100000, 200000, 999999);
}

test "MULMOD with JUMP: overflow prevention" {
    try run_mulmod_test_with_jump(std.testing.allocator, std.math.maxInt(u256), std.math.maxInt(u256), 1000);
}

test "MULMOD with JUMP: near u64 boundary" {
    const near_u64 = @as(u256, std.math.maxInt(u32));
    try run_mulmod_test_with_jump(std.testing.allocator, near_u64, 3, 100);
}
