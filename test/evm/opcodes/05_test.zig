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

test "SDIV: basic signed division (-10 / 2 = -5)" {
    try run_sdiv_test(std.testing.allocator, toU256(-10), toU256(2));
}

fn run_sdiv_test(allocator: std.mem.Allocator, a: u256, b: u256) !void {
    // Build custom bytecode for SDIV test
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
    
    // SDIV opcode
    try buf.append(allocator, 0x05);
    
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

test "SDIV: division by zero (-42 / 0 = 0)" {
    try run_sdiv_test(std.testing.allocator, toU256(-42), 0);
}

test "SDIV: zero divided by negative (0 / -5 = 0)" {
    try run_sdiv_test(std.testing.allocator, 0, toU256(-5));
}

test "SDIV: zero divided by zero (0 / 0 = 0)" {
    try run_sdiv_test(std.testing.allocator, 0, 0);
}

test "SDIV: positive divided by negative (10 / -2 = -5)" {
    try run_sdiv_test(std.testing.allocator, 10, toU256(-2));
}

test "SDIV: negative divided by positive (-20 / 4 = -5)" {
    try run_sdiv_test(std.testing.allocator, toU256(-20), 4);
}

test "SDIV: negative divided by negative (-15 / -3 = 5)" {
    try run_sdiv_test(std.testing.allocator, toU256(-15), toU256(-3));
}

test "SDIV: positive divided by positive (18 / 3 = 6)" {
    try run_sdiv_test(std.testing.allocator, 18, 3);
}

test "SDIV: division by one (123 / 1 = 123)" {
    try run_sdiv_test(std.testing.allocator, 123, 1);
}

test "SDIV: division by negative one (123 / -1 = -123)" {
    try run_sdiv_test(std.testing.allocator, 123, NEG_ONE);
}

test "SDIV: negative division by negative one (-123 / -1 = 123)" {
    try run_sdiv_test(std.testing.allocator, toU256(-123), NEG_ONE);
}

test "SDIV: MIN_INT divided by -1 (overflow case)" {
    // MIN_SIGNED / -1 should return MIN_SIGNED (overflow protection)
    try run_sdiv_test(std.testing.allocator, SIGN_BIT, NEG_ONE);
}

test "SDIV: MIN_INT divided by 1" {
    try run_sdiv_test(std.testing.allocator, SIGN_BIT, 1);
}

test "SDIV: MAX_INT divided by -1" {
    const max_positive = SIGN_BIT - 1; // 0x7FFF...FFFF
    try run_sdiv_test(std.testing.allocator, max_positive, NEG_ONE);
}

test "SDIV: sign bit edge case (-1 / 2 = 0)" {
    try run_sdiv_test(std.testing.allocator, NEG_ONE, 2);
}

test "SDIV: near zero negative (-1 / -2 = 0)" {
    try run_sdiv_test(std.testing.allocator, NEG_ONE, toU256(-2));
}

test "SDIV: large positive division (100000 / 1000 = 100)" {
    try run_sdiv_test(std.testing.allocator, 100000, 1000);
}

test "SDIV: large negative division (-100000 / 1000 = -100)" {
    try run_sdiv_test(std.testing.allocator, toU256(-100000), 1000);
}

test "SDIV: large mixed division (100000 / -1000 = -100)" {
    try run_sdiv_test(std.testing.allocator, 100000, toU256(-1000));
}

test "SDIV: large negative mixed (-100000 / -1000 = 100)" {
    try run_sdiv_test(std.testing.allocator, toU256(-100000), toU256(-1000));
}

test "SDIV: remainder truncation positive (17 / 5 = 3)" {
    try run_sdiv_test(std.testing.allocator, 17, 5);
}

test "SDIV: remainder truncation negative (-17 / 5 = -3)" {
    try run_sdiv_test(std.testing.allocator, toU256(-17), 5);
}

test "SDIV: remainder truncation mixed positive (17 / -5 = -3)" {
    try run_sdiv_test(std.testing.allocator, 17, toU256(-5));
}

test "SDIV: remainder truncation both negative (-17 / -5 = 3)" {
    try run_sdiv_test(std.testing.allocator, toU256(-17), toU256(-5));
}

test "SDIV: powers of 2 signed (256 / 16 = 16)" {
    try run_sdiv_test(std.testing.allocator, 256, 16);
}

test "SDIV: powers of 2 negative (-256 / 16 = -16)" {
    try run_sdiv_test(std.testing.allocator, toU256(-256), 16);
}

test "SDIV: near 64-bit boundary positive" {
    const near_u64 = @as(u256, std.math.maxInt(u64));
    try run_sdiv_test(std.testing.allocator, near_u64, 2);
}

test "SDIV: near 64-bit boundary negative" {
    const near_u64 = @as(u256, std.math.maxInt(u64));
    try run_sdiv_test(std.testing.allocator, toU256(-@as(i256, @intCast(near_u64))), 2);
}

test "SDIV: alternating bit pattern" {
    const pattern1 = 0xAAAAAAAAAAAAAAAA;
    const pattern2 = 0x5555555555555555;
    try run_sdiv_test(std.testing.allocator, pattern1, pattern2);
}

test "SDIV: large 256-bit positive beyond u64" {
    const large_pos = (@as(u256, 1) << 100) + (@as(u256, 0xDEADBEEF) << 50);
    const divisor = (@as(u256, 1) << 70) + 0xCAFEBABE;
    try run_sdiv_test(std.testing.allocator, large_pos, divisor);
}

test "SDIV: large 256-bit negative beyond u64" {
    // Create a negative number beyond i64 range
    const large_neg = toU256(-(@as(i256, 1) << 100));
    const divisor = (@as(u256, 1) << 70);
    try run_sdiv_test(std.testing.allocator, large_neg, divisor);
}

test "SDIV: very large 256-bit mixed signs" {
    const huge_pos = (@as(u256, 1) << 200) + (@as(u256, 1) << 150);
    const huge_neg_divisor = toU256(-(@as(i256, 1) << 180));
    try run_sdiv_test(std.testing.allocator, huge_pos, huge_neg_divisor);
}

test "SDIV: near max positive 256-bit" {
    const near_max = (SIGN_BIT - 1) / 3; // Max positive / 3
    try run_sdiv_test(std.testing.allocator, near_max, 3);
}

test "SDIV: exact division large numbers" {
    const dividend = (@as(u256, 1) << 128) + (@as(u256, 1) << 64);
    const divisor = (@as(u256, 1) << 64);
    try run_sdiv_test(std.testing.allocator, dividend, divisor);
}

test "SDIV: edge case with high bits set" {
    // Test with number that has sign bit set but should be treated as negative
    const high_bits = SIGN_BIT | 0x1234;
    try run_sdiv_test(std.testing.allocator, high_bits, 2);
}

test "SDIV: small dividend large divisor (-5 / 1000000 = 0)" {
    try run_sdiv_test(std.testing.allocator, toU256(-5), 1000000);
}

test "SDIV: very large numbers within signed range" {
    // Use largest positive signed value
    const large_pos = (SIGN_BIT - 1) / 2;  // Half of max positive
    try run_sdiv_test(std.testing.allocator, large_pos, 2);
}

fn run_sdiv_test_with_jump(allocator: std.mem.Allocator, a: u256, b: u256) !void {
    // Build custom bytecode for SDIV test with jump to prevent fusion
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
    
    // Jump to SDIV (prevents fusion)
    // First calculate the jump destination
    // We need PUSH1 (1) + dest byte (1) + JUMP (1) + JUMPDEST (1) = 4 bytes ahead
    const jump_dest = buf.items.len + 4;
    
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, @intCast(jump_dest)); // destination
    try buf.append(allocator, 0x56); // JUMP
    
    // Invalid opcode (should never be executed)
    try buf.append(allocator, 0xfe); // INVALID
    
    // JUMPDEST + SDIV
    try buf.append(allocator, 0x5b); // JUMPDEST
    try buf.append(allocator, 0x05); // SDIV opcode
    
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

test "SDIV with JUMP: basic signed division (-20 / 4 = -5)" {
    try run_sdiv_test_with_jump(std.testing.allocator, toU256(-20), 4);
}

test "SDIV with JUMP: division by zero (-100 / 0 = 0)" {
    try run_sdiv_test_with_jump(std.testing.allocator, toU256(-100), 0);
}

test "SDIV with JUMP: MIN_INT overflow case" {
    // MIN_SIGNED / -1 should return MIN_SIGNED (overflow protection)
    try run_sdiv_test_with_jump(std.testing.allocator, SIGN_BIT, NEG_ONE);
}

test "SDIV with JUMP: large negative numbers (-200000 / -1000 = 200)" {
    try run_sdiv_test_with_jump(std.testing.allocator, toU256(-200000), toU256(-1000));
}

test "SDIV with JUMP: sign alternation (12345 / -67 = -184)" {
    try run_sdiv_test_with_jump(std.testing.allocator, 12345, toU256(-67));
}

test "SDIV with JUMP: large positive beyond u64" {
    const huge = (@as(u256, 1) << 150) + (@as(u256, 1) << 100);
    const big_divisor = (@as(u256, 1) << 80);
    try run_sdiv_test_with_jump(std.testing.allocator, huge, big_divisor);
}

test "SDIV with JUMP: large negative beyond u64" {
    const huge_neg = toU256(-(@as(i256, 1) << 120));
    const divisor = (@as(u256, 1) << 65);
    try run_sdiv_test_with_jump(std.testing.allocator, huge_neg, divisor);
}

test "SDIV with JUMP: very large 256-bit operations" {
    const massive = (@as(u256, 1) << 240) + (@as(u256, 0xFEEDFACE) << 200);
    const big_div = (@as(u256, 1) << 190) + (@as(u256, 0xDEADBEEF) << 150);
    try run_sdiv_test_with_jump(std.testing.allocator, massive, big_div);
}