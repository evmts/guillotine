const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const common = @import("common.zig");

test "MUL: basic (5 * 2 = 10)" {
    try run_mul_test(std.testing.allocator, 5, 2);
}

fn run_mul_test(allocator: std.mem.Allocator, a: u256, b: u256) !void {
    // Build custom bytecode for MUL test
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
    
    // MUL opcode
    try buf.append(allocator, 0x02);
    
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

test "MUL: zero multiplication (0 * 0 = 0)" {
    try run_mul_test(std.testing.allocator, 0, 0);
}

test "MUL: multiply by zero (42 * 0 = 0)" {
    try run_mul_test(std.testing.allocator, 42, 0);
}

test "MUL: zero times number (0 * 100 = 0)" {
    try run_mul_test(std.testing.allocator, 0, 100);
}

test "MUL: multiply by one (123 * 1 = 123)" {
    try run_mul_test(std.testing.allocator, 123, 1);
}

test "MUL: one times number (1 * 456 = 456)" {
    try run_mul_test(std.testing.allocator, 1, 456);
}

test "MUL: small numbers (7 * 8 = 56)" {
    try run_mul_test(std.testing.allocator, 7, 8);
}

test "MUL: larger numbers (100 * 200 = 20000)" {
    try run_mul_test(std.testing.allocator, 100, 200);
}

test "MUL: powers of 2 (256 * 256 = 65536)" {
    try run_mul_test(std.testing.allocator, 256, 256);
}

test "MUL: near u64 boundary" {
    const near_u64 = @as(u256, std.math.maxInt(u32));
    try run_mul_test(std.testing.allocator, near_u64, 2);
}

test "MUL: exactly u64 max times 2" {
    const u64_max = @as(u256, std.math.maxInt(u64));
    try run_mul_test(std.testing.allocator, u64_max, 2);
}

test "MUL: large 128-bit multiplication" {
    const large_128 = @as(u256, 1) << 64;
    try run_mul_test(std.testing.allocator, large_128, large_128);
}

test "MUL: overflow wrapping (MAX * 2)" {
    try run_mul_test(std.testing.allocator, std.math.maxInt(u256), 2);
}

test "MUL: overflow with larger values (MAX * MAX)" {
    try run_mul_test(std.testing.allocator, std.math.maxInt(u256), std.math.maxInt(u256));
}

test "MUL: half MAX times 2" {
    const half_max = std.math.maxInt(u256) / 2;
    try run_mul_test(std.testing.allocator, half_max, 2);
}

test "MUL: square numbers (12 * 12 = 144)" {
    try run_mul_test(std.testing.allocator, 12, 12);
}

test "MUL: prime numbers (13 * 17 = 221)" {
    try run_mul_test(std.testing.allocator, 13, 17);
}

test "MUL: fibonacci numbers (13 * 21 = 273)" {
    try run_mul_test(std.testing.allocator, 13, 21);
}

test "MUL: power of 2 shifts" {
    const pow_16 = @as(u256, 1) << 16;
    const pow_32 = @as(u256, 1) << 32;
    try run_mul_test(std.testing.allocator, pow_16, pow_32);
}

test "MUL: near 256-bit boundary" {
    const near_max = std.math.maxInt(u256) / 3;
    try run_mul_test(std.testing.allocator, near_max, 3);
}

test "MUL: alternating bit patterns" {
    const pattern1 = 0xAAAAAAAAAAAAAAAA;
    const pattern2 = 0x5555555555555555;
    try run_mul_test(std.testing.allocator, pattern1, pattern2);
}

test "MUL: all 1s in lower 64 bits" {
    const all_ones_64 = (@as(u256, 1) << 64) - 1;
    try run_mul_test(std.testing.allocator, all_ones_64, 2);
}

test "MUL: sequential values (99 * 100 = 9900)" {
    try run_mul_test(std.testing.allocator, 99, 100);
}

test "MUL: large sequential" {
    const large = @as(u256, 1) << 100;
    try run_mul_test(std.testing.allocator, large, large + 1);
}

test "MUL: edge case with overflow" {
    const edge = (@as(u256, 1) << 128) - 1;
    try run_mul_test(std.testing.allocator, edge, edge);
}

fn run_mul_test_with_jump(allocator: std.mem.Allocator, a: u256, b: u256) !void {
    // Build custom bytecode for MUL test with jump to prevent fusion
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
    
    // Jump to MUL (prevents fusion)
    // First calculate the jump destination
    // We need PUSH1 (1) + dest byte (1) + JUMP (1) + JUMPDEST (1) = 4 bytes ahead
    const jump_dest = buf.items.len + 4;
    
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, @intCast(jump_dest)); // destination
    try buf.append(allocator, 0x56); // JUMP
    
    // Invalid opcode (should never be executed)
    try buf.append(allocator, 0xfe); // INVALID
    
    // JUMPDEST + MUL
    try buf.append(allocator, 0x5b); // JUMPDEST
    try buf.append(allocator, 0x02); // MUL opcode
    
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

test "MUL with JUMP: basic (5 * 2 = 10)" {
    try run_mul_test_with_jump(std.testing.allocator, 5, 2);
}

test "MUL with JUMP: zero multiplication (0 * 0 = 0)" {
    try run_mul_test_with_jump(std.testing.allocator, 0, 0);
}

test "MUL with JUMP: large numbers" {
    try run_mul_test_with_jump(std.testing.allocator, 100000, 200000);
}

test "MUL with JUMP: overflow (MAX * 2)" {
    try run_mul_test_with_jump(std.testing.allocator, std.math.maxInt(u256), 2);
}

test "MUL with JUMP: near u64 boundary" {
    const near_u64 = @as(u256, std.math.maxInt(u32));
    try run_mul_test_with_jump(std.testing.allocator, near_u64, 3);
}
