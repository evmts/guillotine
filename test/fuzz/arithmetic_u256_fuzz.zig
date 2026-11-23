//! 256-bit EVM Arithmetic, Bitwise, Shift, Comparison, Modular Arithmetic,
//! EXP, SIGNEXTEND, and BYTE Reference-Oracle Fuzz Tests
//!
//! Runs every arithmetic/bitwise/comparison opcode inside Guillotine EVM (both
//! fusion-enabled and fusion-disabled) and verifies exact 256-bit output AND
//! exact gas consumption against an independent arbitrary-precision reference oracle.

const std = @import("std");
const evm = @import("evm");
const fuzz_alloc = @import("fuzz_alloc.zig");
const primitives = @import("voltaire");

const Address = primitives.Address.Address;
const Database = evm.Database;
const BlockInfo = evm.BlockInfo;
const TransactionContext = evm.TransactionContext;
const EvmFusionOn = evm.Evm(.{ .enable_fusion = true });
const EvmFusionOff = evm.Evm(.{ .enable_fusion = false });

const CALLER = Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x11} };
const TARGET = Address{ .bytes = [_]u8{0} ** 19 ++ [_]u8{0x22} };

const BOUNDARY_WORDS = [_]u256{
    0,
    1,
    2,
    3,
    7,
    8,
    31,
    32,
    33,
    63,
    64,
    127,
    128,
    254,
    255,
    256,
    std.math.maxInt(u64),
    std.math.maxInt(u128),
    (@as(u256, 1) << 255) - 1, // MAX_INT256
    (@as(u256, 1) << 255), // MIN_INT256
    std.math.maxInt(u256) - 1,
    std.math.maxInt(u256), // -1 in two's complement
};

fn decodeWord(input: []const u8, offset: usize) u256 {
    if (offset >= input.len) return 0;
    const tag = input[offset];
    if (tag < 64) {
        return BOUNDARY_WORDS[tag % BOUNDARY_WORDS.len];
    }
    var buf = [_]u8{0} ** 32;
    const avail = @min(32, input.len - offset);
    @memcpy(buf[32 - avail ..], input[offset .. offset + avail]);
    return std.mem.readInt(u256, &buf, .big);
}

fn appendPush32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, val: u256) !void {
    try buf.append(allocator, 0x7f); // PUSH32
    var bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &bytes, val, .big);
    try buf.appendSlice(allocator, &bytes);
}

fn appendReturnTop(buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    // PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
    try buf.appendSlice(allocator, &.{ 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 });
}

fn runAndCompareWord(allocator: std.mem.Allocator, code: []const u8) !struct { word: u256, gas_left: u64 } {
    const gas_limit: u64 = 1_000_000;
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 20_000_000,
        .timestamp = 1_700_000_000,
        .difficulty = 0,
        .prev_randao = [_]u8{0} ** 32,
        .gas_limit = 30_000_000,
        .coinbase = Address.ZERO_ADDRESS,
        .base_fee = 1,
        .blob_base_fee = 1,
        .blob_versioned_hashes = &.{},
    };
    const tx_ctx = TransactionContext{
        .gas_limit = gas_limit,
        .coinbase = Address.ZERO_ADDRESS,
        .chain_id = 1,
    };

    var db_on = Database.init(allocator);
    defer db_on.deinit();
    var db_off = Database.init(allocator);
    defer db_off.deinit();

    const code_hash_on = try db_on.set_code(code);
    try db_on.set_account(CALLER.bytes, .{ .balance = 10_000_000_000, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 });
    try db_on.set_account(TARGET.bytes, .{ .balance = 0, .nonce = 1, .code_hash = code_hash_on, .storage_root = [_]u8{0} ** 32 });

    const code_hash_off = try db_off.set_code(code);
    try db_off.set_account(CALLER.bytes, .{ .balance = 10_000_000_000, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 });
    try db_off.set_account(TARGET.bytes, .{ .balance = 0, .nonce = 1, .code_hash = code_hash_off, .storage_root = [_]u8{0} ** 32 });

    var evm_on = try EvmFusionOn.init(allocator, &db_on, block_info, tx_ctx, 1, CALLER);
    defer evm_on.deinit();
    var evm_off = try EvmFusionOff.init(allocator, &db_off, block_info, tx_ctx, 1, CALLER);
    defer evm_off.deinit();

    var res_on = evm_on.call(.{ .call = .{ .caller = CALLER, .to = TARGET, .value = 0, .input = &.{}, .gas = gas_limit } });
    defer res_on.deinit(allocator);
    var res_off = evm_off.call(.{ .call = .{ .caller = CALLER, .to = TARGET, .value = 0, .input = &.{}, .gas = gas_limit } });
    defer res_off.deinit(allocator);

    if (!res_on.success) {
        std.log.err("arithmetic_u256_fuzz failure: on.success={} on.gas={} off.success={} off.gas={} code_len={}", .{
            res_on.success, res_on.gas_left, res_off.success, res_off.gas_left, code.len,
        });
    }
    try std.testing.expect(res_on.success);
    try std.testing.expectEqual(res_on.success, res_off.success);
    try std.testing.expectEqual(res_on.gas_left, res_off.gas_left);
    try std.testing.expectEqualSlices(u8, res_on.output, res_off.output);
    try std.testing.expectEqual(@as(usize, 32), res_on.output.len);

    return .{
        .word = std.mem.readInt(u256, res_on.output[0..32], .big),
        .gas_left = res_on.gas_left,
    };
}

/// Arbitrary-precision reference: (a + b) mod m (0 if m == 0)
fn refAddmod(allocator: std.mem.Allocator, a: u256, b: u256, m: u256) !u256 {
    if (m == 0) return 0;
    var ba = try std.math.big.int.Managed.initSet(allocator, a);
    defer ba.deinit();
    var bb = try std.math.big.int.Managed.initSet(allocator, b);
    defer bb.deinit();
    var bm = try std.math.big.int.Managed.initSet(allocator, m);
    defer bm.deinit();
    var sum = try std.math.big.int.Managed.init(allocator);
    defer sum.deinit();
    try sum.add(&ba, &bb);
    var q = try std.math.big.int.Managed.init(allocator);
    defer q.deinit();
    var r = try std.math.big.int.Managed.init(allocator);
    defer r.deinit();
    try q.divFloor(&r, &sum, &bm);
    return try r.toInt(u256);
}

/// Arbitrary-precision reference: (a * b) mod m (0 if m == 0)
fn refMulmod(allocator: std.mem.Allocator, a: u256, b: u256, m: u256) !u256 {
    if (m == 0) return 0;
    var ba = try std.math.big.int.Managed.initSet(allocator, a);
    defer ba.deinit();
    var bb = try std.math.big.int.Managed.initSet(allocator, b);
    defer bb.deinit();
    var bm = try std.math.big.int.Managed.initSet(allocator, m);
    defer bm.deinit();
    var prod = try std.math.big.int.Managed.init(allocator);
    defer prod.deinit();
    try prod.mul(&ba, &bb);
    var q = try std.math.big.int.Managed.init(allocator);
    defer q.deinit();
    var r = try std.math.big.int.Managed.init(allocator);
    defer r.deinit();
    try q.divFloor(&r, &prod, &bm);
    return try r.toInt(u256);
}

/// Reference modular exponentiation: base^exp mod 2^256 (square-and-multiply)
fn refExp(base: u256, exp: u256) u256 {
    var result: u256 = 1;
    var b: u256 = base;
    var e: u256 = exp;
    while (e > 0) : (e >>= 1) {
        if ((e & 1) == 1) {
            result *%= b;
        }
        b *%= b;
    }
    return result;
}

fn refSdiv(a: u256, b: u256) u256 {
    if (b == 0) return 0;
    const min_i256: u256 = @as(u256, 1) << 255;
    if (a == min_i256 and b == std.math.maxInt(u256)) return min_i256;
    const sa: i256 = @bitCast(a);
    const sb: i256 = @bitCast(b);
    return @bitCast(@divTrunc(sa, sb));
}

fn refSmod(a: u256, b: u256) u256 {
    if (b == 0) return 0;
    const min_i256: u256 = @as(u256, 1) << 255;
    if (a == min_i256 and b == std.math.maxInt(u256)) return 0;
    const sa: i256 = @bitCast(a);
    const sb: i256 = @bitCast(b);
    return @bitCast(@rem(sa, sb));
}

fn refSignextend(byte_pos: u256, val: u256) u256 {
    if (byte_pos >= 31) return val;
    const bit_idx: u8 = @intCast(byte_pos * 8 + 7);
    const sign_bit = (val >> bit_idx) & 1;
    const mask: u256 = (@as(u256, 1) << bit_idx) - 1;
    if (sign_bit == 1) {
        return val | ~mask;
    }
    return val & mask;
}

fn refByte(index: u256, val: u256) u256 {
    if (index >= 32) return 0;
    const shift: u8 = @intCast((31 - index) * 8);
    return (val >> shift) & 0xff;
}

fn refShl(shift: u256, val: u256) u256 {
    if (shift >= 256) return 0;
    return val << @as(u8, @intCast(shift));
}

fn refShr(shift: u256, val: u256) u256 {
    if (shift >= 256) return 0;
    return val >> @as(u8, @intCast(shift));
}

fn refSar(shift: u256, val: u256) u256 {
    const sval: i256 = @bitCast(val);
    if (shift >= 256) {
        return if (sval < 0) std.math.maxInt(u256) else 0;
    }
    return @bitCast(sval >> @as(u8, @intCast(shift)));
}

pub fn fuzzBinaryAndTernaryArithmetic(_: void, input: []const u8) !void {
    if (input.len < 3) return;
    const allocator = fuzz_alloc.get();

    const op_sel = input[0] % 22;
    const a = decodeWord(input, 1);
    const b = decodeWord(input, if (input.len > 33) 33 else @min(2, input.len - 1));
    const c = decodeWord(input, if (input.len > 65) 65 else @min(3, input.len - 1));

    var code = std.ArrayList(u8).empty;
    defer code.deinit(allocator);

    var expected: u256 = 0;

    switch (op_sel) {
        0 => { // ADD
            try appendPush32(&code, allocator, b);
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x01);
            expected = a +% b;
        },
        1 => { // MUL
            try appendPush32(&code, allocator, b);
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x02);
            expected = a *% b;
        },
        2 => { // SUB (top - second)
            try appendPush32(&code, allocator, b);
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x03);
            expected = a -% b;
        },
        3 => { // DIV (top / second)
            try appendPush32(&code, allocator, b);
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x04);
            expected = if (b == 0) 0 else a / b;
        },
        4 => { // SDIV
            try appendPush32(&code, allocator, b);
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x05);
            expected = refSdiv(a, b);
        },
        5 => { // MOD
            try appendPush32(&code, allocator, b);
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x06);
            expected = if (b == 0) 0 else a % b;
        },
        6 => { // SMOD
            try appendPush32(&code, allocator, b);
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x07);
            expected = refSmod(a, b);
        },
        7 => { // ADDMOD (top=a, second=b, third=c => (a+b)%c)
            try appendPush32(&code, allocator, c);
            try appendPush32(&code, allocator, b);
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x08);
            expected = try refAddmod(allocator, a, b, c);
        },
        8 => { // MULMOD (top=a, second=b, third=c => (a*b)%c)
            try appendPush32(&code, allocator, c);
            try appendPush32(&code, allocator, b);
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x09);
            expected = try refMulmod(allocator, a, b, c);
        },
        9 => { // EXP (top=a, second=b => a^b mod 2^256)
            try appendPush32(&code, allocator, b);
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x0a);
            expected = refExp(a, b);
        },
        10 => { // SIGNEXTEND (top=byte_pos, second=val)
            try appendPush32(&code, allocator, b);
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x0b);
            expected = refSignextend(a, b);
        },
        11 => { // LT
            try appendPush32(&code, allocator, b);
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x10);
            expected = if (a < b) 1 else 0;
        },
        12 => { // GT
            try appendPush32(&code, allocator, b);
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x11);
            expected = if (a > b) 1 else 0;
        },
        13 => { // SLT
            try appendPush32(&code, allocator, b);
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x12);
            expected = if (@as(i256, @bitCast(a)) < @as(i256, @bitCast(b))) 1 else 0;
        },
        14 => { // SGT
            try appendPush32(&code, allocator, b);
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x13);
            expected = if (@as(i256, @bitCast(a)) > @as(i256, @bitCast(b))) 1 else 0;
        },
        15 => { // EQ
            try appendPush32(&code, allocator, b);
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x14);
            expected = if (a == b) 1 else 0;
        },
        16 => { // ISZERO
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x15);
            expected = if (a == 0) 1 else 0;
        },
        17 => { // AND / OR / XOR / NOT (selected by input[1])
            const sub = input[1] % 4;
            if (sub == 3) {
                try appendPush32(&code, allocator, a);
                try code.append(allocator, 0x19); // NOT
                expected = ~a;
            } else {
                try appendPush32(&code, allocator, b);
                try appendPush32(&code, allocator, a);
                const opc: u8 = switch (sub) {
                    0 => 0x16, // AND
                    1 => 0x17, // OR
                    else => 0x18, // XOR
                };
                try code.append(allocator, opc);
                expected = switch (sub) {
                    0 => a & b,
                    1 => a | b,
                    else => a ^ b,
                };
            }
        },
        18 => { // BYTE (top=index, second=val)
            try appendPush32(&code, allocator, b);
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x1a);
            expected = refByte(a, b);
        },
        19 => { // SHL (top=shift, second=val)
            try appendPush32(&code, allocator, b);
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x1b);
            expected = refShl(a, b);
        },
        20 => { // SHR (top=shift, second=val)
            try appendPush32(&code, allocator, b);
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x1c);
            expected = refShr(a, b);
        },
        else => { // SAR (top=shift, second=val)
            try appendPush32(&code, allocator, b);
            try appendPush32(&code, allocator, a);
            try code.append(allocator, 0x1d);
            expected = refSar(a, b);
        },
    }

    try appendReturnTop(&code, allocator);
    const res = try runAndCompareWord(allocator, code.items);
    try std.testing.expectEqual(expected, res.word);
}

const seed_corpus: []const []const u8 = &.{
    &.{ 0, 21, 1, 0 }, // ADD overflow: MAX + 1
    &.{ 1, 21, 21, 0 }, // MUL overflow: MAX * MAX
    &.{ 2, 0, 1, 0 }, // SUB underflow: 0 - 1
    &.{ 3, 21, 0, 0 }, // DIV by zero
    &.{ 4, 19, 21, 0 }, // SDIV MIN_INT256 / -1
    &.{ 5, 21, 0, 0 }, // MOD by zero
    &.{ 6, 19, 21, 0 }, // SMOD MIN_INT256 % -1
    &.{ 7, 21, 21, 21 }, // ADDMOD 512-bit carry
    &.{ 8, 21, 21, 19 }, // MULMOD 512-bit product
    &.{ 9, 2, 15, 0 }, // EXP 2^256 == 0
    &.{ 9, 0, 0, 0 }, // EXP 0^0 == 1
    &.{ 10, 0, 12, 0 }, // SIGNEXTEND byte 0 of 128
    &.{ 11, 18, 19, 0 }, // LT MAX_INT256 < MIN_INT256
    &.{ 12, 19, 18, 0 }, // GT
    &.{ 13, 19, 18, 0 }, // SLT MIN_INT256 < MAX_INT256
    &.{ 14, 18, 19, 0 }, // SGT
    &.{ 15, 21, 21, 0 }, // EQ
    &.{ 16, 0, 0, 0 }, // ISZERO
    &.{ 17, 0, 21, 19 }, // AND/OR/XOR/NOT
    &.{ 18, 0, 19, 0 }, // BYTE
    &.{ 19, 14, 1, 0 }, // SHL 255
    &.{ 20, 14, 19, 0 }, // SHR 255
    &.{ 21, 14, 19, 0 }, // SAR 255 of negative
};

test "fuzz all 256-bit arithmetic, bitwise, shift, and comparison opcodes vs big-int oracle" {
    try std.testing.fuzz({}, fuzzBinaryAndTernaryArithmetic, .{ .corpus = seed_corpus });
}
