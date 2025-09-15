const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const common = @import("common.zig");

// Helper function to convert signed integer to two's complement u256
fn toU256(value: i256) u256 {
    if (value >= 0) {
        return @as(u256, @intCast(value));
    } else {
        return @as(u256, @bitCast(value));
    }
}

// Constants for testing
const SIGN_BIT: u256 = @as(u256, 1) << 255;
const MIN_SIGNED_I256: i256 = -(@as(i256, 1) << 255);
const MAX_SIGNED_I256: i256 = (@as(i256, 1) << 255) - 1;
const NEG_ONE: u256 = std.math.maxInt(u256); // 0xFFFFFFFF...FFFF

test "SMOD: basic positive (10 % 3 = 1)" {
    try run_smod_test(std.testing.allocator, toU256(10), toU256(3));
}

fn run_smod_test(allocator: std.mem.Allocator, a: u256, b: u256) !void {
    // Build custom bytecode for SMOD test
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    
    // Push a (first operand)
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
    
    // Push b (second operand)
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
    
    // SMOD opcode
    try buf.append(allocator, 0x07);
    
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

test "SMOD: negative dividend (-10 % 3 = -1)" {
    try run_smod_test(std.testing.allocator, toU256(-10), toU256(3));
}

test "SMOD: negative divisor (10 % -3 = 1)" {
    try run_smod_test(std.testing.allocator, toU256(10), toU256(-3));
}

test "SMOD: both negative (-10 % -3 = -1)" {
    try run_smod_test(std.testing.allocator, toU256(-10), toU256(-3));
}

test "SMOD: modulo by zero (42 % 0 = 0)" {
    try run_smod_test(std.testing.allocator, toU256(42), 0);
}

test "SMOD: negative modulo by zero (-42 % 0 = 0)" {
    try run_smod_test(std.testing.allocator, toU256(-42), 0);
}

test "SMOD: zero modulo positive (0 % 5 = 0)" {
    try run_smod_test(std.testing.allocator, 0, toU256(5));
}

test "SMOD: zero modulo negative (0 % -5 = 0)" {
    try run_smod_test(std.testing.allocator, 0, toU256(-5));
}

test "SMOD: zero modulo zero (0 % 0 = 0)" {
    try run_smod_test(std.testing.allocator, 0, 0);
}

test "SMOD: modulo by one (123 % 1 = 0)" {
    try run_smod_test(std.testing.allocator, toU256(123), 1);
}

test "SMOD: modulo by negative one (123 % -1 = 0)" {
    try run_smod_test(std.testing.allocator, toU256(123), NEG_ONE);
}

test "SMOD: negative modulo by negative one (-123 % -1 = 0)" {
    try run_smod_test(std.testing.allocator, toU256(-123), NEG_ONE);
}

test "SMOD: exact division remainder (15 % 5 = 0)" {
    try run_smod_test(std.testing.allocator, toU256(15), toU256(5));
}

test "SMOD: negative exact division (-15 % 5 = 0)" {
    try run_smod_test(std.testing.allocator, toU256(-15), toU256(5));
}

test "SMOD: positive remainder (17 % 5 = 2)" {
    try run_smod_test(std.testing.allocator, toU256(17), toU256(5));
}

test "SMOD: negative remainder (-17 % 5 = -2)" {
    try run_smod_test(std.testing.allocator, toU256(-17), toU256(5));
}

test "SMOD: positive remainder negative divisor (17 % -5 = 2)" {
    try run_smod_test(std.testing.allocator, toU256(17), toU256(-5));
}

test "SMOD: both negative remainder (-17 % -5 = -2)" {
    try run_smod_test(std.testing.allocator, toU256(-17), toU256(-5));
}

test "SMOD: large positive numbers (100000 % 999 = 100)" {
    try run_smod_test(std.testing.allocator, toU256(100000), toU256(999));
}

test "SMOD: large negative numbers (-100000 % 999 = -100)" {
    try run_smod_test(std.testing.allocator, toU256(-100000), toU256(999));
}

test "SMOD: large mixed signs (100000 % -999 = 100)" {
    try run_smod_test(std.testing.allocator, toU256(100000), toU256(-999));
}

test "SMOD: powers of 2 (256 % 16 = 0)" {
    try run_smod_test(std.testing.allocator, toU256(256), toU256(16));
}

test "SMOD: negative powers of 2 (-256 % 16 = 0)" {
    try run_smod_test(std.testing.allocator, toU256(-256), toU256(16));
}

test "SMOD: near 64-bit boundary positive" {
    const near_i64 = @as(i256, std.math.maxInt(i64)) - 100;
    try run_smod_test(std.testing.allocator, toU256(near_i64), toU256(1000));
}

test "SMOD: near 64-bit boundary negative" {
    const near_i64 = @as(i256, std.math.minInt(i64)) + 100;
    try run_smod_test(std.testing.allocator, toU256(near_i64), toU256(1000));
}

test "SMOD: MIN_INT modulo -1" {
    // MIN_SIGNED % -1 should return 0
    try run_smod_test(std.testing.allocator, SIGN_BIT, NEG_ONE);
}

test "SMOD: MIN_INT modulo 2" {
    try run_smod_test(std.testing.allocator, SIGN_BIT, 2);
}

test "SMOD: MAX_INT modulo large number" {
    const max_positive = SIGN_BIT - 1;
    const large_mod = (@as(u256, 1) << 100);
    try run_smod_test(std.testing.allocator, max_positive, large_mod);
}

test "SMOD: alternating bit patterns" {
    const pattern1 = 0xAAAAAAAAAAAAAAAA;
    const pattern2 = 0x5555555555555555;
    try run_smod_test(std.testing.allocator, pattern1, pattern2);
}

test "SMOD: edge case with sign bit" {
    const high_bits = SIGN_BIT | 0x1234;
    try run_smod_test(std.testing.allocator, high_bits, 100);
}

test "SMOD: large 256-bit positive beyond u64" {
    const large_pos = (@as(u256, 1) << 100) + (@as(u256, 0xDEADBEEF) << 50);
    const divisor = (@as(u256, 1) << 70) + 0xCAFEBABE;
    try run_smod_test(std.testing.allocator, large_pos, divisor);
}

test "SMOD: large 256-bit negative beyond i64" {
    const large_neg = toU256(-(@as(i256, 1) << 100));
    const divisor = (@as(u256, 1) << 70);
    try run_smod_test(std.testing.allocator, large_neg, divisor);
}

test "SMOD: very large 256-bit mixed signs" {
    const huge_pos = (@as(u256, 1) << 200) + (@as(u256, 1) << 150);
    const huge_neg_divisor = toU256(-(@as(i256, 1) << 180));
    try run_smod_test(std.testing.allocator, huge_pos, huge_neg_divisor);
}

test "SMOD: near max positive 256-bit" {
    const near_max = (SIGN_BIT - 1) - 1000;
    const divisor = (@as(u256, 1) << 128) + 12345;
    try run_smod_test(std.testing.allocator, near_max, divisor);
}

test "SMOD: consecutive numbers (100 % 99 = 1)" {
    try run_smod_test(std.testing.allocator, toU256(100), toU256(99));
}

test "SMOD: negative consecutive (-100 % -99 = -1)" {
    try run_smod_test(std.testing.allocator, toU256(-100), toU256(-99));
}

fn run_smod_test_with_jump(allocator: std.mem.Allocator, a: u256, b: u256) !void {
    // Build custom bytecode for SMOD test with jump to prevent fusion
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    
    // Push a (first operand)
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
    
    // Push b (second operand)
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
    
    // Jump to SMOD (prevents fusion)
    const jump_dest = buf.items.len + 4;
    
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, @intCast(jump_dest)); // destination
    try buf.append(allocator, 0x56); // JUMP
    
    // Invalid opcode (should never be executed)
    try buf.append(allocator, 0xfe); // INVALID
    
    // JUMPDEST + SMOD
    try buf.append(allocator, 0x5b); // JUMPDEST
    try buf.append(allocator, 0x07); // SMOD opcode
    
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

test "SMOD with JUMP: basic signed modulo (-20 % 7 = -6)" {
    try run_smod_test_with_jump(std.testing.allocator, toU256(-20), toU256(7));
}

test "SMOD with JUMP: modulo by zero (-100 % 0 = 0)" {
    try run_smod_test_with_jump(std.testing.allocator, toU256(-100), 0);
}

test "SMOD with JUMP: MIN_INT edge case" {
    try run_smod_test_with_jump(std.testing.allocator, SIGN_BIT, toU256(1000));
}

test "SMOD with JUMP: large negative numbers (-200000 % -999 = -200)" {
    try run_smod_test_with_jump(std.testing.allocator, toU256(-200000), toU256(-999));
}

test "SMOD with JUMP: sign alternation (12345 % -67 = 31)" {
    try run_smod_test_with_jump(std.testing.allocator, toU256(12345), toU256(-67));
}

test "SMOD with JUMP: large positive beyond u64" {
    const huge = (@as(u256, 1) << 150) + (@as(u256, 1) << 100);
    const big_divisor = (@as(u256, 1) << 80);
    try run_smod_test_with_jump(std.testing.allocator, huge, big_divisor);
}

test "SMOD with JUMP: large negative beyond i64" {
    const huge_neg = toU256(-(@as(i256, 1) << 120));
    const divisor = (@as(u256, 1) << 65);
    try run_smod_test_with_jump(std.testing.allocator, huge_neg, divisor);
}

test "SMOD with JUMP: very large 256-bit operations" {
    const massive = (@as(u256, 1) << 240) + (@as(u256, 0xFEEDFACE) << 200);
    const big_mod = (@as(u256, 1) << 190) + (@as(u256, 0xDEADBEEF) << 150);
    try run_smod_test_with_jump(std.testing.allocator, massive, big_mod);
}
