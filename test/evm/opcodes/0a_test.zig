const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const common = @import("common.zig");

test "EXP: basic (2 ^ 3 = 8)" {
    try run_exp_test(std.testing.allocator, 2, 3);
}

fn run_exp_test(allocator: std.mem.Allocator, base: u256, exponent: u256) !void {
    // Build custom bytecode for EXP test
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    
    // Push base
    if (base == 0) {
        try buf.append(allocator, 0x5f); // PUSH0
    } else {
        var tmp: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &tmp, base, .big);
        const first_non_zero = std.mem.indexOfNonePos(u8, &tmp, 0, &[_]u8{0}) orelse 32;
        const slice = tmp[first_non_zero..];
        if (slice.len > 0 and slice.len <= 32) {
            const op: u8 = 0x60 + @as(u8, @intCast(slice.len - 1));
            try buf.append(allocator, op);
            try buf.appendSlice(allocator, slice);
        }
    }
    
    // Push exponent
    if (exponent == 0) {
        try buf.append(allocator, 0x5f); // PUSH0
    } else {
        var tmp: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &tmp, exponent, .big);
        const first_non_zero = std.mem.indexOfNonePos(u8, &tmp, 0, &[_]u8{0}) orelse 32;
        const slice = tmp[first_non_zero..];
        if (slice.len > 0 and slice.len <= 32) {
            const op: u8 = 0x60 + @as(u8, @intCast(slice.len - 1));
            try buf.append(allocator, op);
            try buf.appendSlice(allocator, slice);
        }
    }
    
    // EXP opcode
    try buf.append(allocator, 0x0a);
    
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
        .gas_limit = 10_000_000, // Higher gas limit for EXP
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
            .gas = 10_000_000, // Higher gas for EXP
        },
    };
    
    var guillotine_result = guillotine_evm.call(call_params);
    defer guillotine_result.deinit(allocator);
}

test "EXP: zero to any power (0 ^ 100 = 0)" {
    try run_exp_test(std.testing.allocator, 0, 100);
}

test "EXP: zero to zero power (0 ^ 0 = 1)" {
    try run_exp_test(std.testing.allocator, 0, 0);
}

test "EXP: any to zero power (100 ^ 0 = 1)" {
    try run_exp_test(std.testing.allocator, 100, 0);
}

test "EXP: one to any power (1 ^ 100 = 1)" {
    try run_exp_test(std.testing.allocator, 1, 100);
}

test "EXP: any to one power (123 ^ 1 = 123)" {
    try run_exp_test(std.testing.allocator, 123, 1);
}

test "EXP: powers of two (2 ^ 8 = 256)" {
    try run_exp_test(std.testing.allocator, 2, 8);
}

test "EXP: square (10 ^ 2 = 100)" {
    try run_exp_test(std.testing.allocator, 10, 2);
}

test "EXP: cube (5 ^ 3 = 125)" {
    try run_exp_test(std.testing.allocator, 5, 3);
}

test "EXP: large base small exp (1000 ^ 2 = 1000000)" {
    try run_exp_test(std.testing.allocator, 1000, 2);
}

test "EXP: power of 2 base (256 ^ 2 = 65536)" {
    try run_exp_test(std.testing.allocator, 256, 2);
}

test "EXP: 2 to the 16 (2 ^ 16 = 65536)" {
    try run_exp_test(std.testing.allocator, 2, 16);
}

test "EXP: 2 to the 32" {
    try run_exp_test(std.testing.allocator, 2, 32);
}

test "EXP: 2 to the 64" {
    try run_exp_test(std.testing.allocator, 2, 64);
}

test "EXP: 2 to the 128" {
    try run_exp_test(std.testing.allocator, 2, 128);
}

test "EXP: 2 to the 255 (near max bit position)" {
    try run_exp_test(std.testing.allocator, 2, 255);
}

test "EXP: 2 to the 256 (overflows to 0)" {
    try run_exp_test(std.testing.allocator, 2, 256);
}

test "EXP: 3 to small powers" {
    try run_exp_test(std.testing.allocator, 3, 5);
}

test "EXP: 10 to the 10" {
    try run_exp_test(std.testing.allocator, 10, 10);
}

test "EXP: 10 to the 18 (wei to ether)" {
    try run_exp_test(std.testing.allocator, 10, 18);
}

test "EXP: overflow with large base and exp" {
    try run_exp_test(std.testing.allocator, 999, 999);
}

test "EXP: near u64 max base" {
    const near_u64 = @as(u256, std.math.maxInt(u64)) - 10;
    try run_exp_test(std.testing.allocator, near_u64, 2);
}

test "EXP: MAX base with exp 1" {
    try run_exp_test(std.testing.allocator, std.math.maxInt(u256), 1);
}

test "EXP: MAX base with exp 2 (overflow)" {
    try run_exp_test(std.testing.allocator, std.math.maxInt(u256), 2);
}

test "EXP: alternating bit pattern" {
    const pattern = 0xAAAAAAAAAAAAAAAA;
    try run_exp_test(std.testing.allocator, pattern, 2);
}

test "EXP: prime number powers" {
    try run_exp_test(std.testing.allocator, 13, 7);
}

test "EXP: fibonacci base and exp" {
    try run_exp_test(std.testing.allocator, 13, 8);
}

test "EXP: large exponent causing overflow" {
    try run_exp_test(std.testing.allocator, 2, 257);
}

test "EXP: edge case 255 ^ 2" {
    try run_exp_test(std.testing.allocator, 255, 2);
}

test "EXP: edge case 256 ^ 3" {
    try run_exp_test(std.testing.allocator, 256, 3);
}

fn run_exp_test_with_jump(allocator: std.mem.Allocator, base: u256, exponent: u256) !void {
    // Build custom bytecode for EXP test with jump to prevent fusion
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    
    // Push base
    if (base == 0) {
        try buf.append(allocator, 0x5f); // PUSH0
    } else {
        var tmp: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &tmp, base, .big);
        const first_non_zero = std.mem.indexOfNonePos(u8, &tmp, 0, &[_]u8{0}) orelse 32;
        const slice = tmp[first_non_zero..];
        if (slice.len > 0 and slice.len <= 32) {
            const op: u8 = 0x60 + @as(u8, @intCast(slice.len - 1));
            try buf.append(allocator, op);
            try buf.appendSlice(allocator, slice);
        }
    }
    
    // Push exponent
    if (exponent == 0) {
        try buf.append(allocator, 0x5f); // PUSH0
    } else {
        var tmp: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &tmp, exponent, .big);
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
    
    // Jump to EXP (prevents fusion)
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, @intCast(jump_dest)); // destination
    try buf.append(allocator, 0x56); // JUMP
    
    // JUMPDEST + EXP
    try buf.append(allocator, 0x5b); // JUMPDEST
    try buf.append(allocator, 0x0a); // EXP opcode
    
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
        .gas_limit = 10_000_000,
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
            .gas = 10_000_000,
        },
    };
    
    var guillotine_result = guillotine_evm.call(call_params);
    defer guillotine_result.deinit(allocator);
}

test "EXP with JUMP: basic (2 ^ 3 = 8)" {
    try run_exp_test_with_jump(std.testing.allocator, 2, 3);
}

test "EXP with JUMP: zero to zero (0 ^ 0 = 1)" {
    try run_exp_test_with_jump(std.testing.allocator, 0, 0);
}

test "EXP with JUMP: large power of 2" {
    try run_exp_test_with_jump(std.testing.allocator, 2, 100);
}

test "EXP with JUMP: overflow case" {
    try run_exp_test_with_jump(std.testing.allocator, std.math.maxInt(u256), 3);
}

test "EXP with JUMP: 10 to the 18" {
    try run_exp_test_with_jump(std.testing.allocator, 10, 18);
}
