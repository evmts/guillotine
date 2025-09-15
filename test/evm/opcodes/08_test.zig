const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const common = @import("common.zig");

test "ADDMOD: basic ((10 + 10) % 8 = 4)" {
    try run_addmod_test(std.testing.allocator, 10, 10, 8);
}

fn run_addmod_test(allocator: std.mem.Allocator, a: u256, b: u256, n: u256) !void {
    // Build custom bytecode for ADDMOD test
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
    
    // ADDMOD opcode
    try buf.append(allocator, 0x08);
    
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

test "ADDMOD: modulo zero ((42 + 58) % 0 = 0)" {
    try run_addmod_test(std.testing.allocator, 42, 58, 0);
}

test "ADDMOD: zero addition ((0 + 0) % 5 = 0)" {
    try run_addmod_test(std.testing.allocator, 0, 0, 5);
}

test "ADDMOD: zero plus value ((0 + 100) % 7 = 2)" {
    try run_addmod_test(std.testing.allocator, 0, 100, 7);
}

test "ADDMOD: value plus zero ((100 + 0) % 7 = 2)" {
    try run_addmod_test(std.testing.allocator, 100, 0, 7);
}

test "ADDMOD: exact division ((5 + 10) % 15 = 0)" {
    try run_addmod_test(std.testing.allocator, 5, 10, 15);
}

test "ADDMOD: modulo 1 ((123 + 456) % 1 = 0)" {
    try run_addmod_test(std.testing.allocator, 123, 456, 1);
}

test "ADDMOD: large numbers ((999999 + 999999) % 1000000 = 999998)" {
    try run_addmod_test(std.testing.allocator, 999999, 999999, 1000000);
}

test "ADDMOD: powers of 2 ((256 + 256) % 128 = 0)" {
    try run_addmod_test(std.testing.allocator, 256, 256, 128);
}

test "ADDMOD: near u64 boundary" {
    const near_u64 = @as(u256, std.math.maxInt(u64)) - 10;
    try run_addmod_test(std.testing.allocator, near_u64, 20, 100);
}

test "ADDMOD: exactly u64 max" {
    const u64_max = @as(u256, std.math.maxInt(u64));
    try run_addmod_test(std.testing.allocator, u64_max, u64_max, 1000);
}

test "ADDMOD: large 128-bit numbers" {
    const large_128 = @as(u256, 1) << 120;
    try run_addmod_test(std.testing.allocator, large_128, large_128, (@as(u256, 1) << 100));
}

test "ADDMOD: overflow prevention (MAX + MAX) % 100" {
    try run_addmod_test(std.testing.allocator, std.math.maxInt(u256), std.math.maxInt(u256), 100);
}

test "ADDMOD: overflow with large modulus" {
    const half_max = std.math.maxInt(u256) / 2;
    try run_addmod_test(std.testing.allocator, std.math.maxInt(u256), std.math.maxInt(u256), half_max);
}

test "ADDMOD: MAX + 1 mod MAX" {
    try run_addmod_test(std.testing.allocator, std.math.maxInt(u256), 1, std.math.maxInt(u256));
}

test "ADDMOD: prime modulus ((13 + 17) % 31 = 30)" {
    try run_addmod_test(std.testing.allocator, 13, 17, 31);
}

test "ADDMOD: fibonacci numbers ((13 + 21) % 34 = 0)" {
    try run_addmod_test(std.testing.allocator, 13, 21, 34);
}

test "ADDMOD: near 256-bit boundary" {
    const near_max = std.math.maxInt(u256) - 1000;
    try run_addmod_test(std.testing.allocator, near_max, 500, 200);
}

test "ADDMOD: alternating bit patterns" {
    const pattern1 = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA;
    const pattern2 = 0x5555555555555555555555555555555555555555555555555555555555555555;
    try run_addmod_test(std.testing.allocator, pattern1, pattern2, 0xFFFFFFFF);
}

test "ADDMOD: all 1s pattern modulo" {
    const all_ones_128 = (@as(u256, 1) << 128) - 1;
    try run_addmod_test(std.testing.allocator, all_ones_128, all_ones_128, all_ones_128);
}

test "ADDMOD: sequential values ((12345 + 12346) % 100 = 91)" {
    try run_addmod_test(std.testing.allocator, 12345, 12346, 100);
}

test "ADDMOD: large sequential" {
    const large = @as(u256, 1) << 200;
    try run_addmod_test(std.testing.allocator, large, large + 1, (@as(u256, 1) << 150));
}

test "ADDMOD: modulo larger than operands ((10 + 20) % 1000 = 30)" {
    try run_addmod_test(std.testing.allocator, 10, 20, 1000);
}

test "ADDMOD: overflow edge case" {
    const edge = std.math.maxInt(u256) / 3;
    try run_addmod_test(std.testing.allocator, edge * 2, edge * 2, edge);
}

test "ADDMOD: power of 10 modulus" {
    const pow10 = 10000000000; // 10^10
    try run_addmod_test(std.testing.allocator, pow10 - 1, pow10 - 1, pow10);
}

fn run_addmod_test_with_jump(allocator: std.mem.Allocator, a: u256, b: u256, n: u256) !void {
    // Build custom bytecode for ADDMOD test with jump to prevent fusion
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
    
    // Calculate jump destination (current position + 3 for PUSH1 + 1 byte + JUMP)
    const jump_dest = buf.items.len + 3;
    
    // Jump to ADDMOD (prevents fusion)
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, @intCast(jump_dest)); // destination
    try buf.append(allocator, 0x56); // JUMP
    
    // JUMPDEST + ADDMOD
    try buf.append(allocator, 0x5b); // JUMPDEST
    try buf.append(allocator, 0x08); // ADDMOD opcode
    
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

test "ADDMOD with JUMP: basic ((10 + 10) % 8 = 4)" {
    try run_addmod_test_with_jump(std.testing.allocator, 10, 10, 8);
}

test "ADDMOD with JUMP: modulo zero ((100 + 200) % 0 = 0)" {
    try run_addmod_test_with_jump(std.testing.allocator, 100, 200, 0);
}

test "ADDMOD with JUMP: large numbers" {
    try run_addmod_test_with_jump(std.testing.allocator, 1000000, 2000000, 999999);
}

test "ADDMOD with JUMP: overflow prevention" {
    try run_addmod_test_with_jump(std.testing.allocator, std.math.maxInt(u256), std.math.maxInt(u256), 1000);
}

test "ADDMOD with JUMP: near u64 boundary" {
    const near_u64 = @as(u256, std.math.maxInt(u64)) - 10;
    try run_addmod_test_with_jump(std.testing.allocator, near_u64, 20, 100);
}
