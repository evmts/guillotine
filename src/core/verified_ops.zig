//! Pure, zero-cost (`inline`) verifiable cores for Guillotine EVM hot paths.
//!
//! Design rules (for direct LLVM 20 IR, Bitwuzla/Z3 SMT, Lean 4, and Zig 0.17 Zean compatibility):
//! - No allocators, no `*anyopaque`, no indirect function pointers, no tracer/logging side effects.
//! - Every optimized `Fast` routine has a clear `Ref` specification routine verified directly on
//!   Zig's emitted `-OReleaseFast` LLVM 20 IR via `verify/llvm/llvm_ir_verify.py` (Bitwuzla + Z3)
//!   and machine-checked in `verify/lean/` (Lean 4).
const std = @import("std");

/// Result of checking whether a basic block's entry stack height satisfies `[min_stack, cap - max_stack]`.
pub const BlockStackResult = enum(u8) {
    ok = 0,
    underflow = 1,
    overflow = 2,
};

/// Single-source-of-truth basic-block stack & static-gas accumulator.
/// Shared by frame-entry analysis (`dispatch.zig`), JUMPDEST analysis (`bytecode.zig`),
/// and untaken-JUMPI fallthrough block analysis so all block boundaries obey the exact
/// same proven inductive invariant (`GuillotineVerify.BasicBlock.block_sound`).
pub const BlockAccumulator = struct {
    gas: u64 = 0,
    stack_effect: i32 = 0,
    /// Minimum signed prefix height reached (<= 0). Required incoming stack depth is `-min_stack`.
    min_stack: i32 = 0,
    /// Maximum signed prefix height reached (>= 0). Required spare stack headroom is `max_stack`.
    max_stack: i32 = 0,

    pub inline fn addGas(self: *BlockAccumulator, cost: u64) void {
        self.gas +|= cost;
    }

    /// Record a standard opcode that pops `inputs` items and pushes `outputs` items.
    pub inline fn stepRegular(self: *BlockAccumulator, inputs: u8, outputs: u8, gas: u64) void {
        self.gas +|= gas;
        self.stack_effect -= @as(i32, inputs);
        if (self.stack_effect < self.min_stack) self.min_stack = self.stack_effect;
        self.stack_effect += @as(i32, outputs);
        if (self.stack_effect > self.max_stack) self.max_stack = self.stack_effect;
    }

    /// Record DUPn (`n` in 1..16): requires `n` items on stack, pushes 1 item (net +1).
    pub inline fn stepDup(self: *BlockAccumulator, n: u8, gas: u64) void {
        self.gas +|= gas;
        const min_req = self.stack_effect - @as(i32, n);
        if (min_req < self.min_stack) self.min_stack = min_req;
        self.stack_effect += 1;
        if (self.stack_effect > self.max_stack) self.max_stack = self.stack_effect;
    }

    /// Record SWAPn (`n` in 1..16): requires `n + 1` items on stack, net 0.
    pub inline fn stepSwap(self: *BlockAccumulator, n: u8, gas: u64) void {
        self.gas +|= gas;
        const min_req = self.stack_effect - @as(i32, n) - 1;
        if (min_req < self.min_stack) self.min_stack = min_req;
    }

    /// Record a PUSH opcode: 0 inputs, 1 output.
    pub inline fn stepPush(self: *BlockAccumulator, gas: u64) void {
        self.gas +|= gas;
        self.stack_effect += 1;
        if (self.stack_effect > self.max_stack) self.max_stack = self.stack_effect;
    }

    /// Required incoming stack depth, saturated safely into `u16` (no panicking `@intCast`).
    /// Any requirement exceeding `stack_capacity + 1` is clamped to `maxInt(u16)` so entry
    /// validation deterministically rejects the impossible block as `StackUnderflow`.
    pub inline fn requiredMinStack(self: BlockAccumulator) u16 {
        if (self.min_stack >= 0) return 0;
        const needed: u32 = @intCast(-self.min_stack);
        return @intCast(@min(needed, std.math.maxInt(u16)));
    }

    /// Required peak stack headroom, saturated safely into `u16` (no panicking `@intCast`).
    pub inline fn requiredMaxStack(self: BlockAccumulator) u16 {
        if (self.max_stack <= 0) return 0;
        const headroom: u32 = @intCast(self.max_stack);
        return @intCast(@min(headroom, std.math.maxInt(u16)));
    }

    /// Required incoming stack depth saturated into `i16` for existing `DispatchMetadata` fields.
    pub inline fn requiredMinStackI16(self: BlockAccumulator) i16 {
        if (self.min_stack >= 0) return 0;
        const needed: u32 = @intCast(-self.min_stack);
        return @intCast(@min(needed, @as(u32, std.math.maxInt(i16))));
    }

    /// Required peak stack headroom saturated into `i16` for existing `DispatchMetadata` fields.
    pub inline fn requiredMaxStackI16(self: BlockAccumulator) i16 {
        if (self.max_stack <= 0) return 0;
        const headroom: u32 = @intCast(self.max_stack);
        return @intCast(@min(headroom, @as(u32, std.math.maxInt(i16))));
    }

    /// Saturating `u32` gas for compact metadata storage.
    pub inline fn clampedGasU32(self: BlockAccumulator) u32 {
        return @intCast(@min(self.gas, @as(u64, std.math.maxInt(u32))));
    }
};

/// Reference basic-block stack guard status code (`0 = ok`, `1 = underflow`, `2 = overflow`).
pub inline fn blockStackGuardRefCode(
    size: u32,
    min_stack: u16,
    max_stack: u16,
    comptime stack_capacity: u32,
) u8 {
    if (size < @as(u32, min_stack)) return 1;
    if (@as(u64, size) + @as(u64, max_stack) > @as(u64, stack_capacity)) return 2;
    return 0;
}

/// Reference basic-block stack guard (matches existing `handlers_jump.zig` & `frame.zig` semantics).
pub inline fn blockStackGuardRef(
    size: u32,
    min_stack: u16,
    max_stack: u16,
    comptime stack_capacity: u32,
) BlockStackResult {
    return @fromBackingInt(@intCast(blockStackGuardRefCode(size, min_stack, max_stack, stack_capacity)));
}

/// Fast single-branch basic-block stack guard status code (`0 = ok`, `1 = underflow`, `2 = overflow`).
/// When `min_stack + max_stack <= stack_capacity`, the fast path is a single unsigned
/// range check `(size -% min_stack) <= (stack_capacity - min_stack - max_stack)` on the
/// hot path, only disambiguating underflow vs overflow on the cold error path.
pub inline fn blockStackGuardFastCode(
    size: u32,
    min_stack: u16,
    max_stack: u16,
    comptime stack_capacity: u32,
) u8 {
    const min_u: u32 = min_stack;
    const max_u: u32 = max_stack;
    const needed: u32 = min_u + max_u;
    if (needed <= stack_capacity) {
        if (size -% min_u <= stack_capacity - needed) {
            @branchHint(.likely);
            return 0;
        }
    }
    return if (size < min_u) 1 else 2;
}

/// Fast single-branch basic-block stack guard.
pub inline fn blockStackGuardFast(
    size: u32,
    min_stack: u16,
    max_stack: u16,
    comptime stack_capacity: u32,
) BlockStackResult {
    return @fromBackingInt(@intCast(blockStackGuardFastCode(size, min_stack, max_stack, stack_capacity)));
}

/// Reference memory bounds check (matches original 2-step + overflow check in `handlers_memory.zig`).
pub inline fn checkMemoryBoundsRef(offset: u256, size: u64, comptime memory_limit: u64) bool {
    const max_usize: u256 = std.math.maxInt(u64);
    if (offset > max_usize) return false;
    const off_u: u64 = @intCast(offset);
    const res = @addWithOverflow(off_u, size);
    if (res[1] != 0) return false;
    return res[0] <= memory_limit;
}

/// Verified single-compare memory bounds check:
/// `∀ offset:u256, size:u64. checkMemoryBoundsFast(offset, size, L) == checkMemoryBoundsRef(offset, size, L)`
/// For comptime `size <= memory_limit` (e.g. MLOAD/MSTORE `size = 32`, MSTORE8 `size = 1`),
/// this compiles to a SINGLE `offset <= (L - size)` comparison with zero branches!
pub inline fn checkMemoryBoundsFast(offset: u256, size: u64, comptime memory_limit: u64) bool {
    if (size > memory_limit) return false;
    return offset <= @as(u256, memory_limit - size);
}

/// Word-aligns a byte offset up to the next 32-byte boundary (overflow-free for `n <= 0xFFFFFF`).
pub inline fn alignUp32(n: u32) u32 {
    return (n + 31) & ~@as(u32, 31);
}

/// Reference word count `ceil(byte_size / 32)` for `byte_size <= 0xFFFFFF`.
pub inline fn memoryWordCountRef(byte_size: u32) u64 {
    const b: u64 = byte_size;
    return if (b == 0) 0 else ((b - 1) / 32) + 1;
}

/// Fast shift-based word count `ceil(byte_size / 32)` for all `u32` inputs.
pub inline fn memoryWordCountFast(byte_size: u32) u64 {
    return (@as(u64, byte_size) + 31) >> 5;
}

/// Quadratic EVM memory gas cost: `3 * words + floor(words^2 / 512)`.
/// Proven overflow-free in `u64` for all `words <= 524_288` (i.e. `memory_limit <= 0xFFFFFF` = 16 MiB),
/// where max cost = `538_443_776 < 2^30 << 2^63`.
pub inline fn memoryGasCost(words: u64) u64 {
    return (words * 3) + ((words * words) >> 9);
}

/// Reference EXP exponent byte-length calculation (the original 32-iteration loop).
pub inline fn expGasByteLenRef(exp: u256) u32 {
    var byte_size: u32 = 0;
    var temp = exp;
    while (temp > 0) : (temp >>= 8) {
        byte_size += 1;
    }
    return byte_size;
}

/// Verified branchless EXP exponent byte-length using `@clz`:
/// - When `exp == 0`: `@clz(0) == 256` -> `(263 - 256) >> 3 == 7 >> 3 == 0`.
/// - When `exp > 0`: `bitlen = 256 - @clz(exp)` -> `(bitlen + 7) >> 3 == (263 - @clz(exp)) >> 3`.
/// Proven bit-exact for ALL `2^256` inputs!
pub inline fn expGasByteLenFast(exp: u256) u32 {
    return (@as(u32, 263) - @as(u32, @clz(exp))) >> 3;
}

/// Reference EVM SIGNEXTEND (Yellow Paper).
pub inline fn signextendRef(ext: u256, value: u256) u256 {
    if (ext >= 31) return value;
    const byte_index: u8 = @intCast(ext);
    const bit_index: u8 = byte_index * 8 + 7;
    const sign_bit_mask = @as(u256, 1) << bit_index;
    const is_negative = (value & sign_bit_mask) != 0;
    const value_mask = (@as(u256, 1) << bit_index) - 1;
    if (is_negative) {
        return value | ~value_mask;
    } else {
        return value & value_mask;
    }
}

/// Verified branchless EVM SIGNEXTEND via arithmetic shift:
/// Shifts the sign bit at `8*ext + 7` to bit 255, then arithmetic-right-shifts back.
/// Eliminates the data-dependent sign branch!
pub inline fn signextendFast(ext: u256, value: u256) u256 {
    if (ext >= 31) return value;
    const byte_index: u8 = @truncate(ext);
    const shift: u8 = 248 - (byte_index << 3);
    const signed: i256 = @bitCast(value << shift);
    return @bitCast(signed >> shift);
}

/// Reference EVM SAR (EIP-145).
pub inline fn sarRef(shift: u256, value: u256) u256 {
    const value_signed: i256 = @bitCast(value);
    if (shift >= 256) {
        return if (value_signed < 0) std.math.maxInt(u256) else 0;
    }
    const shift_amt: u8 = @intCast(shift);
    return @bitCast(value_signed >> shift_amt);
}

/// Verified branchless EVM SAR:
/// Since `i256 >> 255` produces `-1` for all negative values and `0` for all non-negative
/// values, clamping shift to `255` handles `shift >= 256` identically with zero branch!
pub inline fn sarFast(shift: u256, value: u256) u256 {
    const value_signed: i256 = @bitCast(value);
    const shift_amt: u8 = if (shift >= 255) 255 else @truncate(shift);
    return @bitCast(value_signed >> shift_amt);
}

/// Reference EVM BYTE opcode.
pub inline fn byteRef(index: u256, value: u256) u256 {
    if (index >= 32) return 0;
    const byte_index: u8 = @intCast(index);
    const shift_bits: u8 = (31 - byte_index) * 8;
    return (value >> shift_bits) & 0xFF;
}

/// Verified EVM BYTE opcode with `@truncate` (no panicking `@intCast`).
pub inline fn byteFast(index: u256, value: u256) u256 {
    if (index >= 32) return 0;
    const byte_index: u8 = @truncate(index);
    const shift_bits: u8 = (31 - byte_index) << 3;
    return (value >> shift_bits) & 0xFF;
}

/// Reference EVM CLZ (EIP-7939).
pub inline fn clzRef(value: u256) u256 {
    if (value == 0) return 256;
    return @as(u256, @clz(value));
}

/// Verified branchless EVM CLZ (`@clz(@as(u256, 0)) == 256` directly in Zig/LLVM).
pub inline fn clzFast(value: u256) u256 {
    return @as(u256, @clz(value));
}

/// Branchless two's-complement magnitude & sign mask helper for SDIV/SMOD.
/// Given `top`, `second`, and `unsigned_quotient = wrapping_div(|top|, |second|)` (where `wrapping_div(x, 0) == 0`),
/// produces the exact EVM SDIV result for ALL `2^512` inputs — including `second == 0` AND `MIN_SIGNED / -1`!
pub inline fn sdivFromUnsignedQuotient(top: u256, second: u256, unsigned_quotient: u256) u256 {
    const top_sign = top >> 255;
    const second_sign = second >> 255;
    const result_sign = top_sign ^ second_sign;
    const result_mask = @as(u256, 0) -% result_sign;
    return (unsigned_quotient ^ result_mask) -% result_mask;
}

/// Branchless two's-complement absolute value (`|x|` as `u256`, with `|MIN_SIGNED| == MIN_SIGNED`).
pub inline fn absTwoComp(x: u256) u256 {
    const sign = x >> 255;
    const mask = @as(u256, 0) -% sign;
    return (x ^ mask) -% mask;
}

/// Branchless sign re-application for SMOD:
/// Given `top` and `unsigned_rem = wrapping_rem(|top|, |second|)` (where `wrapping_rem(x, 0) == 0`),
/// produces the exact EVM SMOD result for ALL `2^512` inputs — including `second == 0` AND `MIN_SIGNED % -1`!
pub inline fn smodFromUnsignedRem(top: u256, unsigned_rem: u256) u256 {
    const top_sign = top >> 255;
    const top_mask = @as(u256, 0) -% top_sign;
    return (unsigned_rem ^ top_mask) -% top_mask;
}

/// Reference dense jump table bounds check (`dest <= maxInt(PcType)` then `dest < dense_len`).
pub inline fn denseJumpInBoundsRef(dest: u256, dense_len: u32, comptime PcType: type) bool {
    if (dest > std.math.maxInt(PcType)) return false;
    const dest_pc: u32 = @intCast(dest);
    return dest_pc < dense_len;
}

/// Verified single-compare dense jump bounds check (valid whenever `dense_len <= maxInt(PcType) + 1`).
pub inline fn denseJumpInBoundsFast(dest: u256, dense_len: u32) bool {
    return dest < @as(u256, dense_len);
}

/// Pure, zero-allocation EVM JUMPDEST validator (Yellow Paper Section 9.4.3).
/// Walks `code[0..len]`, skipping PUSH1 (0x60)..PUSH32 (0x7f) immediate bytes without
/// ever reading past `len` even on truncated PUSH instructions at the end of bytecode.
pub inline fn isValidJumpdestBytes(code: [*]const u8, len: usize, target: usize) bool {
    if (target >= len) return false;
    var pc: usize = 0;
    while (pc < len) {
        const op = code[pc];
        if (pc == target) return op == 0x5b;
        if (op >= 0x60 and op <= 0x7f) {
            const push_len: usize = @as(usize, op - 0x60) + 1;
            const step: usize = push_len + 1;
            if (step > len - pc) return false;
            pc += step;
        } else {
            pc += 1;
        }
    }
    return false;
}

/// Pure, overflow-free binary search over a sorted jump-table PC array `pcs[0..len]`.
pub inline fn bsearchJumpTableU32(pcs: [*]const u32, len: usize, target: u32) bool {
    var lo: usize = 0;
    var hi: usize = len;
    while (lo < hi) {
        const mid = lo + ((hi - lo) >> 1);
        const entry = pcs[mid];
        if (entry == target) return true;
        if (entry < target) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return false;
}

/// Pure bounded EVM byte copy for non-overlapping slices `src[0..len] -> dst[0..len]`.
pub inline fn copyEvmBytes(dst: [*]u8, src: [*]const u8, len: usize) void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        dst[i] = src[i];
    }
}

/// Pure in-place EVM fused PUSH + ADD on the live top stack slot `top[0]`.
pub inline fn stackPushAddTop(top: *u256, imm: u256) void {
    top.* = imm +% top.*;
}

/// Pure in-place EVM fused PUSH + SUB (`imm -% top`) on the live top stack slot `top[0]`.
pub inline fn stackPushSubTop(top: *u256, imm: u256) void {
    top.* = imm -% top.*;
}

/// Pure in-place EVM fused PUSH + MUL on the live top stack slot `top[0]`.
pub inline fn stackPushMulTop(top: *u256, imm: u256) void {
    top.* = imm *% top.*;
}

/// Pure in-place EVM fused PUSH + AND on the live top stack slot `top[0]`.
pub inline fn stackPushAndTop(top: *u256, imm: u256) void {
    top.* = imm & top.*;
}

/// Pure in-place EVM fused PUSH + XOR on the live top stack slot `top[0]`.
pub inline fn stackPushXorTop(top: *u256, imm: u256) void {
    top.* = imm ^ top.*;
}

/// Pure in-place EVM SWAP1 on the top two stack slots `top[0]` and `top[1]`.
pub inline fn stackSwap1Top(top: [*]u256) void {
    const a = top[0];
    const b = top[1];
    top[0] = b;
    top[1] = a;
}

/// Deduct `cost` of dynamic gas from `gas_remaining`, or return null when the frame
/// cannot pay. `GasType` is the frame's signed gas type (`i32` or `i64`).
///
/// The comparison is made in `u64` before `cost` is narrowed, so a cost wider than
/// `GasType` (a saturated `maxInt(u64)` memory expansion, a 2^31 cost against an `i32`
/// frame) can neither trap in a checked build nor wrap in an unchecked one.
/// Specification (proved in `charge_gas_checked_i32` / `charge_gas_checked_i64`):
///   result == gas_remaining - cost  when 0 <= cost <= gas_remaining (as integers),
///   result == null                  otherwise; a non-null result is in [0, gas_remaining].
pub inline fn chargeGasChecked(comptime GasType: type, gas_remaining: GasType, cost: u64) ?GasType {
    if (gas_remaining < 0) return null;
    const available: u64 = @intCast(gas_remaining);
    if (cost > available) return null;
    return gas_remaining - @as(GasType, @intCast(cost));
}

/// Sum of two dynamic gas costs, saturating at `maxInt(u64)`. A saturated sum is
/// unpayable by `chargeGasChecked` for every `GasType`, so it always ends in out-of-gas.
pub inline fn saturatingGasSum(first: u64, second: u64) u64 {
    return first +| second;
}

/// EIP-4844 blob fee `blob_gas * fee_per_blob_gas`, or null when the product does not
/// fit in 256 bits. An overflowing fee is unpayable; it is never clamped.
pub inline fn checkedBlobGasCost(blob_gas: u64, fee_per_blob_gas: u256) ?u256 {
    const product = @mulWithOverflow(@as(u256, blob_gas), fee_per_blob_gas);
    if (product[1] != 0) return null;
    return product[0];
}

/// Bytes the bytecode analyzer may address past the end of the code: one PUSH32
/// immediate (32 bytes) plus the one-past-the-end offset.
pub const pc_headroom: u32 = 33;

/// Width in bits (8, 12, 16 or 32) of the smallest program counter type that can
/// hold `max_code + pc_headroom`. A fork before Shanghai has no initcode size limit
/// (EIP-3860), so `unbounded_initcode` always selects 32 bits.
/// The sum is computed in `u64`: `max_code + 33` cannot wrap for any `u32`.
pub inline fn pcTypeWidthBits(max_code: u32, unbounded_initcode: bool) u8 {
    if (unbounded_initcode) return 32;
    const needed: u64 = @as(u64, max_code) + pc_headroom;
    if (needed <= std.math.maxInt(u8)) return 8;
    if (needed <= std.math.maxInt(u12)) return 12;
    if (needed <= std.math.maxInt(u16)) return 16;
    return 32;
}

/// True when code of `code_len` bytes, plus the analyzer's lookahead, is addressable
/// by a program counter whose largest value is `pc_max`. Subtracting on the limit
/// side keeps the check exact for every `u64` length (`code_len + 33` could wrap).
pub inline fn codeFitsPc(code_len: u64, pc_max: u64) bool {
    if (pc_max < pc_headroom) return false;
    return code_len <= pc_max - pc_headroom;
}

/// Required incoming stack depth of a block whose lowest signed prefix height is
/// `min_stack` (<= 0 for real blocks), saturated into `u16`. Total: every `i32`,
/// `minInt(i32)` included, has a result and nothing traps.
pub inline fn saturatingMinStackU16(min_stack: i32) u16 {
    if (min_stack >= 0) return 0;
    const needed: u32 = @intCast(-@as(i64, min_stack));
    return @intCast(@min(needed, @as(u32, std.math.maxInt(u16))));
}

/// Required peak stack headroom of a block whose highest signed prefix height is
/// `max_stack`, saturated into `u16`.
pub inline fn saturatingMaxStackU16(max_stack: i32) u16 {
    if (max_stack <= 0) return 0;
    const headroom: u32 = @intCast(max_stack);
    return @intCast(@min(headroom, @as(u32, std.math.maxInt(u16))));
}

/// One step of a block's signed stack height: `height - inputs + outputs`, with both
/// the intermediate and the result saturating in `i32`. Returns the height after
/// the pops (for the minimum) and after the pushes (for the maximum).
pub inline fn stackEffectStep(height: i32, inputs: u8, outputs: u8) struct { low: i32, high: i32 } {
    const low = height -| @as(i32, inputs);
    return .{ .low = low, .high = low +| @as(i32, outputs) };
}
// ====== UNIT TESTS ======

const testing = std.testing;

test "verified_ops: chargeGasChecked pays exactly or refuses, for i32 and i64" {
    inline for (.{ i32, i64 }) |GasType| {
        const max: GasType = std.math.maxInt(GasType);
        try testing.expectEqual(@as(?GasType, 0), chargeGasChecked(GasType, 0, 0));
        try testing.expectEqual(@as(?GasType, null), chargeGasChecked(GasType, 0, 1));
        try testing.expectEqual(@as(?GasType, 0), chargeGasChecked(GasType, 100, 100));
        try testing.expectEqual(@as(?GasType, null), chargeGasChecked(GasType, 100, 101));
        try testing.expectEqual(@as(?GasType, 0), chargeGasChecked(GasType, max, @intCast(max)));
        try testing.expectEqual(@as(?GasType, null), chargeGasChecked(GasType, max, @as(u64, @intCast(max)) + 1));
        try testing.expectEqual(@as(?GasType, null), chargeGasChecked(GasType, max, std.math.maxInt(u64)));
        try testing.expectEqual(@as(?GasType, null), chargeGasChecked(GasType, -1, 0));
        try testing.expectEqual(@as(?GasType, null), chargeGasChecked(GasType, std.math.minInt(GasType), 0));
    }
    // A cost that fits u32 but not i32 is refused, not narrowed.
    try testing.expectEqual(@as(?i32, null), chargeGasChecked(i32, std.math.maxInt(i32), 1 << 31));
}

test "verified_ops: saturatingGasSum never wraps" {
    const max = std.math.maxInt(u64);
    try testing.expectEqual(@as(u64, 5), saturatingGasSum(2, 3));
    try testing.expectEqual(@as(u64, max), saturatingGasSum(max, 1));
    try testing.expectEqual(@as(u64, max), saturatingGasSum(max, max));
    try testing.expectEqual(@as(?i64, null), chargeGasChecked(i64, std.math.maxInt(i64), saturatingGasSum(max, 3)));
}

test "verified_ops: checkedBlobGasCost rejects overflow instead of clamping" {
    const max = std.math.maxInt(u256);
    try testing.expectEqual(@as(?u256, 0), checkedBlobGasCost(0, max));
    try testing.expectEqual(@as(?u256, max), checkedBlobGasCost(1, max));
    try testing.expectEqual(@as(?u256, null), checkedBlobGasCost(2, max));
    try testing.expectEqual(@as(?u256, 131072 * 7), checkedBlobGasCost(131072, 7));
    // 2^17 * 2^239 = 2^256 overflows; one less fits.
    try testing.expectEqual(@as(?u256, null), checkedBlobGasCost(131072, @as(u256, 1) << 239));
    try testing.expectEqual(@as(?u256, 131072 * ((@as(u256, 1) << 239) - 1)), checkedBlobGasCost(131072, (@as(u256, 1) << 239) - 1));
}

test "verified_ops: pcTypeWidthBits accounts for the 33-byte headroom" {
    try testing.expectEqual(@as(u8, 8), pcTypeWidthBits(0, false));
    try testing.expectEqual(@as(u8, 8), pcTypeWidthBits(222, false));
    try testing.expectEqual(@as(u8, 12), pcTypeWidthBits(223, false));
    try testing.expectEqual(@as(u8, 12), pcTypeWidthBits(255, false));
    try testing.expectEqual(@as(u8, 12), pcTypeWidthBits(4062, false));
    try testing.expectEqual(@as(u8, 16), pcTypeWidthBits(4063, false));
    try testing.expectEqual(@as(u8, 16), pcTypeWidthBits(49152, false));
    try testing.expectEqual(@as(u8, 16), pcTypeWidthBits(65502, false));
    try testing.expectEqual(@as(u8, 32), pcTypeWidthBits(65503, false));
    try testing.expectEqual(@as(u8, 32), pcTypeWidthBits(65535, false));
    try testing.expectEqual(@as(u8, 32), pcTypeWidthBits(std.math.maxInt(u32), false));
    try testing.expectEqual(@as(u8, 32), pcTypeWidthBits(1, true));
    try testing.expectEqual(@as(u8, 32), pcTypeWidthBits(49152, true));
}

test "verified_ops: codeFitsPc is exact at every boundary and never wraps" {
    try testing.expect(codeFitsPc(222, std.math.maxInt(u8)));
    try testing.expect(!codeFitsPc(223, std.math.maxInt(u8)));
    try testing.expect(codeFitsPc(65502, std.math.maxInt(u16)));
    try testing.expect(!codeFitsPc(65503, std.math.maxInt(u16)));
    try testing.expect(codeFitsPc(65503, std.math.maxInt(u32)));
    try testing.expect(codeFitsPc(std.math.maxInt(u32) - 33, std.math.maxInt(u32)));
    try testing.expect(!codeFitsPc(std.math.maxInt(u32) - 32, std.math.maxInt(u32)));
    try testing.expect(!codeFitsPc(std.math.maxInt(u64), std.math.maxInt(u32)));
    try testing.expect(!codeFitsPc(std.math.maxInt(u64), std.math.maxInt(u64)));
    try testing.expect(!codeFitsPc(0, 32));
    try testing.expect(codeFitsPc(0, 33));
}

test "verified_ops: saturatingMinStackU16 and saturatingMaxStackU16 are total" {
    try testing.expectEqual(@as(u16, 0), saturatingMinStackU16(0));
    try testing.expectEqual(@as(u16, 0), saturatingMinStackU16(7));
    try testing.expectEqual(@as(u16, 6), saturatingMinStackU16(-6));
    try testing.expectEqual(@as(u16, 65535), saturatingMinStackU16(-65535));
    try testing.expectEqual(@as(u16, 65535), saturatingMinStackU16(-65536));
    try testing.expectEqual(@as(u16, 65535), saturatingMinStackU16(-65538));
    try testing.expectEqual(@as(u16, 65535), saturatingMinStackU16(std.math.minInt(i32)));
    try testing.expectEqual(@as(u16, 0), saturatingMaxStackU16(-3));
    try testing.expectEqual(@as(u16, 1024), saturatingMaxStackU16(1024));
    try testing.expectEqual(@as(u16, 65535), saturatingMaxStackU16(65536));
    try testing.expectEqual(@as(u16, 65535), saturatingMaxStackU16(std.math.maxInt(i32)));
}

test "verified_ops: stackEffectStep saturates at both ends of i32" {
    const step = stackEffectStep(0, 6, 0);
    try testing.expectEqual(@as(i32, -6), step.low);
    try testing.expectEqual(@as(i32, -6), step.high);
    const floor = stackEffectStep(std.math.minInt(i32) + 2, 17, 1);
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), floor.low);
    try testing.expectEqual(@as(i32, std.math.minInt(i32) + 1), floor.high);
    const ceiling = stackEffectStep(std.math.maxInt(i32), 0, 1);
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), ceiling.high);
}

test "verified_ops: expGasByteLenFast matches expGasByteLenRef on boundary values" {
    const cases = [_]u256{
        0,
        1,
        0xFF,
        0x100,
        0xFFFF,
        0x10000,
        (@as(u256, 1) << 128) - 1,
        @as(u256, 1) << 128,
        @as(u256, 1) << 255,
        std.math.maxInt(u256),
    };
    for (cases) |e| {
        try testing.expectEqual(expGasByteLenRef(e), expGasByteLenFast(e));
    }
}

test "verified_ops: signextendFast matches signextendRef on boundary values" {
    const exts = [_]u256{ 0, 1, 7, 15, 30, 31, 32, 255, std.math.maxInt(u256) };
    const vals = [_]u256{
        0,
        0x7F,
        0x80,
        0xFF,
        0x7FFF,
        0x8000,
        (@as(u256, 1) << 255),
        std.math.maxInt(u256),
        0x123456789ABCDEF0,
    };
    for (exts) |ext| {
        for (vals) |v| {
            try testing.expectEqual(signextendRef(ext, v), signextendFast(ext, v));
        }
    }
}

test "verified_ops: sarFast matches sarRef on boundary values" {
    const shifts = [_]u256{ 0, 1, 7, 64, 128, 254, 255, 256, 512, std.math.maxInt(u256) };
    const vals = [_]u256{ 0, 1, 0x7FFF, (@as(u256, 1) << 255), (@as(u256, 1) << 255) | 1, std.math.maxInt(u256) };
    for (shifts) |sh| {
        for (vals) |v| {
            try testing.expectEqual(sarRef(sh, v), sarFast(sh, v));
        }
    }
}

test "verified_ops: blockStackGuardFast matches blockStackGuardRef exhaustively on edges" {
    const sizes = [_]u32{ 0, 1, 2, 10, 512, 1022, 1023, 1024 };
    const mins = [_]u16{ 0, 1, 2, 16, 1024, 1025, 2000 };
    const maxs = [_]u16{ 0, 1, 2, 16, 1024, 1025, 2000 };
    for (sizes) |s| {
        for (mins) |mn| {
            for (maxs) |mx| {
                try testing.expectEqual(
                    blockStackGuardRef(s, mn, mx, 1024),
                    blockStackGuardFast(s, mn, mx, 1024),
                );
            }
        }
    }
}

test "verified_ops: checkMemoryBoundsFast matches checkMemoryBoundsRef" {
    const offsets = [_]u256{ 0, 1, 0xFFFFDF, 0xFFFFE0, 0xFFFFFE, 0xFFFFFF, 0x1000000, std.math.maxInt(u64), std.math.maxInt(u256) };
    const sizes = [_]u64{ 0, 1, 32, 64, 0xFFFFFF, 0x1000000, std.math.maxInt(u64) };
    for (offsets) |o| {
        for (sizes) |s| {
            try testing.expectEqual(
                checkMemoryBoundsRef(o, s, 0xFFFFFF),
                checkMemoryBoundsFast(o, s, 0xFFFFFF),
            );
        }
    }
}

test "verified_ops: isValidJumpdestBytes skips PUSH immediates and truncated PUSH" {
    // PUSH1 0x5b (fake JUMPDEST inside immediate), JUMPDEST (real at pc=2), PUSH32 truncated at pc=3
    const code = [_]u8{ 0x60, 0x5b, 0x5b, 0x7f, 0x5b };
    try testing.expect(!isValidJumpdestBytes(&code, code.len, 0));
    try testing.expect(!isValidJumpdestBytes(&code, code.len, 1));
    try testing.expect(isValidJumpdestBytes(&code, code.len, 2));
    try testing.expect(!isValidJumpdestBytes(&code, code.len, 3));
    try testing.expect(!isValidJumpdestBytes(&code, code.len, 4));
    try testing.expect(!isValidJumpdestBytes(&code, code.len, 5));
}

test "verified_ops: bsearchJumpTableU32 finds present and rejects absent PCs" {
    const pcs = [_]u32{ 2, 7, 19, 42, 100 };
    try testing.expect(bsearchJumpTableU32(&pcs, pcs.len, 2));
    try testing.expect(bsearchJumpTableU32(&pcs, pcs.len, 19));
    try testing.expect(bsearchJumpTableU32(&pcs, pcs.len, 100));
    try testing.expect(!bsearchJumpTableU32(&pcs, pcs.len, 0));
    try testing.expect(!bsearchJumpTableU32(&pcs, pcs.len, 8));
    try testing.expect(!bsearchJumpTableU32(&pcs, pcs.len, 101));
    try testing.expect(!bsearchJumpTableU32(&pcs, 0, 2));
}

test "verified_ops: copyEvmBytes and stack fused top operations" {
    const src = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    var dst = [_]u8{ 0, 0, 0, 0 };
    copyEvmBytes(&dst, &src, src.len);
    try testing.expectEqualSlices(u8, &src, &dst);

    var stack = [_]u256{ 10, 20 };
    stackPushAddTop(&stack[0], 5);
    try testing.expectEqual(@as(u256, 15), stack[0]);
    stackSwap1Top(&stack);
    try testing.expectEqual(@as(u256, 20), stack[0]);
    try testing.expectEqual(@as(u256, 15), stack[1]);
}
