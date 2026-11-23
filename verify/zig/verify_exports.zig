//! C-ABI export harness for direct LLVM 20 IR formal verification (`zig build verify-ir`).
//!
//! Compiles Guillotine's actual `src/verified_ops.zig` functions under `-fllvm -OReleaseFast`
//! to LLVM 20 IR (`.ll`), where `verify/llvm/llvm_ir_verify.py` verifies every `<name>_ref` vs
//! `<name>_fast` pair for:
//!   1. Bit-exact functional equivalence across ALL inputs (256-bit bitvectors).
//!   2. Zero LLVM poison / UB under `-OReleaseFast` (Alive2 value-level poison semantics).
const std = @import("std");
const ops = @import("verified_ops");

/// 256-bit ABI wrapper (passed via `ptr` in aarch64/x86_64 C ABI, loaded as two i128 halves).
pub const U256Abi = extern struct {
    lo: u128,
    hi: u128,
};

inline fn fromAbi(x: U256Abi) u256 {
    return (@as(u256, x.hi) << 128) | @as(u256, x.lo);
}

// ============================================================================
// 1. Memory bounds checks (dynamic size, MLOAD/MSTORE size=32, MSTORE8 size=1)
// ============================================================================

export fn check_memory_bounds_dyn_ref(offset: U256Abi, size: u64) bool {
    return ops.checkMemoryBoundsRef(fromAbi(offset), size, 0xFFFFFF);
}
export fn check_memory_bounds_dyn_fast(offset: U256Abi, size: u64) bool {
    return ops.checkMemoryBoundsFast(fromAbi(offset), size, 0xFFFFFF);
}

export fn check_memory_bounds_word32_ref(offset: U256Abi) bool {
    return ops.checkMemoryBoundsRef(fromAbi(offset), 32, 0xFFFFFF);
}
export fn check_memory_bounds_word32_fast(offset: U256Abi) bool {
    return ops.checkMemoryBoundsFast(fromAbi(offset), 32, 0xFFFFFF);
}

export fn check_memory_bounds_byte1_ref(offset: U256Abi) bool {
    return ops.checkMemoryBoundsRef(fromAbi(offset), 1, 0xFFFFFF);
}
export fn check_memory_bounds_byte1_fast(offset: U256Abi) bool {
    return ops.checkMemoryBoundsFast(fromAbi(offset), 1, 0xFFFFFF);
}

// ============================================================================
// 2. Memory word-count & word-alignment (for byte_size <= 0xFFFFFF)
// ============================================================================

export fn memory_word_count_ref(byte_size: u32) u64 {
    return ops.memoryWordCountRef(byte_size);
}
export fn memory_word_count_fast(byte_size: u32) u64 {
    return ops.memoryWordCountFast(byte_size);
}

export fn align_up_32_ref(n: u32) u32 {
    if (n > 0xFFFFFF) return 0;
    const rem = n % 32;
    return if (rem == 0) n else n + (32 - rem);
}
export fn align_up_32_fast(n: u32) u32 {
    if (n > 0xFFFFFF) return 0;
    return ops.alignUp32(n);
}

// ============================================================================
// 3. Basic-block stack guard (single unsigned range check vs two-sided check)
// ============================================================================

export fn block_stack_guard_ref(size: u32, min_stack: u16, max_stack: u16) u8 {
    return @intFromEnum(ops.blockStackGuardRef(size, min_stack, max_stack, 1024));
}
export fn block_stack_guard_fast(size: u32, min_stack: u16, max_stack: u16) u8 {
    return @intFromEnum(ops.blockStackGuardFast(size, min_stack, max_stack, 1024));
}

// ============================================================================
// 4. Dense jump table single-compare bounds check (dense_len <= maxInt(u16)+1)
// ============================================================================

export fn dense_jump_bounds_u16_ref(dest: U256Abi, dense_len_raw: u32) bool {
    const dense_len: u32 = @min(dense_len_raw, @as(u32, std.math.maxInt(u16)) + 1);
    return ops.denseJumpInBoundsRef(fromAbi(dest), dense_len, u16);
}
export fn dense_jump_bounds_u16_fast(dest: U256Abi, dense_len_raw: u32) bool {
    const dense_len: u32 = @min(dense_len_raw, @as(u32, std.math.maxInt(u16)) + 1);
    return ops.denseJumpInBoundsFast(fromAbi(dest), dense_len);
}

export fn dense_jump_bounds_u32_ref(dest: U256Abi, dense_len: u32) bool {
    return ops.denseJumpInBoundsRef(fromAbi(dest), dense_len, u32);
}
export fn dense_jump_bounds_u32_fast(dest: U256Abi, dense_len: u32) bool {
    return ops.denseJumpInBoundsFast(fromAbi(dest), dense_len);
}

// ============================================================================
// 5. Branchless 256-bit EVM arithmetic & bitwise cores (lo128 + hi128 outputs)
//    We verify both 128-bit halves (lo and hi) independently so the entire 256-bit
//    output is proven bit-exact in LLVM 20 IR!
// ============================================================================

export fn signextend_lo_ref(ext: U256Abi, val: U256Abi) u128 {
    return @truncate(ops.signextendRef(fromAbi(ext), fromAbi(val)));
}
export fn signextend_lo_fast(ext: U256Abi, val: U256Abi) u128 {
    return @truncate(ops.signextendFast(fromAbi(ext), fromAbi(val)));
}

export fn signextend_hi_ref(ext: U256Abi, val: U256Abi) u128 {
    return @truncate(ops.signextendRef(fromAbi(ext), fromAbi(val)) >> 128);
}
export fn signextend_hi_fast(ext: U256Abi, val: U256Abi) u128 {
    return @truncate(ops.signextendFast(fromAbi(ext), fromAbi(val)) >> 128);
}

export fn sar_lo_ref(shift: U256Abi, val: U256Abi) u128 {
    return @truncate(ops.sarRef(fromAbi(shift), fromAbi(val)));
}
export fn sar_lo_fast(shift: U256Abi, val: U256Abi) u128 {
    return @truncate(ops.sarFast(fromAbi(shift), fromAbi(val)));
}

export fn sar_hi_ref(shift: U256Abi, val: U256Abi) u128 {
    return @truncate(ops.sarRef(fromAbi(shift), fromAbi(val)) >> 128);
}
export fn sar_hi_fast(shift: U256Abi, val: U256Abi) u128 {
    return @truncate(ops.sarFast(fromAbi(shift), fromAbi(val)) >> 128);
}

export fn byte_lo_ref(idx: U256Abi, val: U256Abi) u128 {
    return @truncate(ops.byteRef(fromAbi(idx), fromAbi(val)));
}
export fn byte_lo_fast(idx: U256Abi, val: U256Abi) u128 {
    return @truncate(ops.byteFast(fromAbi(idx), fromAbi(val)));
}

export fn byte_hi_ref(idx: U256Abi, val: U256Abi) u128 {
    return @truncate(ops.byteRef(fromAbi(idx), fromAbi(val)) >> 128);
}
export fn byte_hi_fast(idx: U256Abi, val: U256Abi) u128 {
    return @truncate(ops.byteFast(fromAbi(idx), fromAbi(val)) >> 128);
}

export fn clz_lo_ref(val: U256Abi) u128 {
    return @truncate(ops.clzRef(fromAbi(val)));
}
export fn clz_lo_fast(val: U256Abi) u128 {
    return @truncate(ops.clzFast(fromAbi(val)));
}

export fn clz_hi_ref(val: U256Abi) u128 {
    return @truncate(ops.clzRef(fromAbi(val)) >> 128);
}
export fn clz_hi_fast(val: U256Abi) u128 {
    return @truncate(ops.clzFast(fromAbi(val)) >> 128);
}

// ============================================================================
// 6. EXP exponent byte length (unrolled spec vs branchless @clz)
// ============================================================================

export fn exp_gas_byte_len_ref(exp: U256Abi) u32 {
    const v = fromAbi(exp);
    var byte_size: u32 = 0;
    inline for (0..32) |i| {
        if ((v >> @as(u8, @intCast(i * 8))) != 0) {
            byte_size = @intCast(i + 1);
        }
    }
    return byte_size;
}
export fn exp_gas_byte_len_fast(exp: U256Abi) u32 {
    return ops.expGasByteLenFast(fromAbi(exp));
}

// ============================================================================
// 7. Branchless two's-complement abs & sign application (SDIV/SMOD core)
// ============================================================================

export fn abs_two_comp_lo_ref(x: U256Abi) u128 {
    const v = fromAbi(x);
    const s: i256 = @bitCast(v);
    const r: u256 = if (s < 0) (@as(u256, 0) -% v) else v;
    return @truncate(r);
}
export fn abs_two_comp_lo_fast(x: U256Abi) u128 {
    return @truncate(ops.absTwoComp(fromAbi(x)));
}

export fn abs_two_comp_hi_ref(x: U256Abi) u128 {
    const v = fromAbi(x);
    const s: i256 = @bitCast(v);
    const r: u256 = if (s < 0) (@as(u256, 0) -% v) else v;
    return @truncate(r >> 128);
}
export fn abs_two_comp_hi_fast(x: U256Abi) u128 {
    return @truncate(ops.absTwoComp(fromAbi(x)) >> 128);
}

export fn sdiv_sign_lo_ref(top: U256Abi, sec: U256Abi, quot: U256Abi) u128 {
    const t: i256 = @bitCast(fromAbi(top));
    const s: i256 = @bitCast(fromAbi(sec));
    const q = fromAbi(quot);
    const neg = (t < 0) != (s < 0);
    const r = if (neg) (@as(u256, 0) -% q) else q;
    return @truncate(r);
}
export fn sdiv_sign_lo_fast(top: U256Abi, sec: U256Abi, quot: U256Abi) u128 {
    return @truncate(ops.sdivFromUnsignedQuotient(fromAbi(top), fromAbi(sec), fromAbi(quot)));
}

export fn sdiv_sign_hi_ref(top: U256Abi, sec: U256Abi, quot: U256Abi) u128 {
    const t: i256 = @bitCast(fromAbi(top));
    const s: i256 = @bitCast(fromAbi(sec));
    const q = fromAbi(quot);
    const neg = (t < 0) != (s < 0);
    const r = if (neg) (@as(u256, 0) -% q) else q;
    return @truncate(r >> 128);
}
export fn sdiv_sign_hi_fast(top: U256Abi, sec: U256Abi, quot: U256Abi) u128 {
    return @truncate(ops.sdivFromUnsignedQuotient(fromAbi(top), fromAbi(sec), fromAbi(quot)) >> 128);
}

export fn smod_sign_lo_ref(top: U256Abi, rem: U256Abi) u128 {
    const t: i256 = @bitCast(fromAbi(top));
    const q = fromAbi(rem);
    const r = if (t < 0) (@as(u256, 0) -% q) else q;
    return @truncate(r);
}
export fn smod_sign_lo_fast(top: U256Abi, rem: U256Abi) u128 {
    return @truncate(ops.smodFromUnsignedRem(fromAbi(top), fromAbi(rem)));
}

export fn smod_sign_hi_ref(top: U256Abi, rem: U256Abi) u128 {
    const t: i256 = @bitCast(fromAbi(top));
    const q = fromAbi(rem);
    const r = if (t < 0) (@as(u256, 0) -% q) else q;
    return @truncate(r >> 128);
}
export fn smod_sign_hi_fast(top: U256Abi, rem: U256Abi) u128 {
    return @truncate(ops.smodFromUnsignedRem(fromAbi(top), fromAbi(rem)) >> 128);
}
