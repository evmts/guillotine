//! Zean memory-profile capture roots for Guillotine's 256-bit EVM arithmetic & bounds kernels.
//!
//! `u256` values cross the C ABI by pointer (`*const u256` / `*u256`, 32-byte size, 16-byte align),
//! matching Zean's native `u256` memory layout.
const ops = @import("verified_ops.zig");

export fn check_memory_bounds_fast(offset: *const u256, size: u64) bool {
    return ops.checkMemoryBoundsFast(offset.*, size, 0xFFFFFF);
}

export fn check_memory_bounds_word32_fast(offset: *const u256) bool {
    return ops.checkMemoryBoundsFast(offset.*, 32, 0xFFFFFF);
}

export fn check_memory_bounds_byte1_fast(offset: *const u256) bool {
    return ops.checkMemoryBoundsFast(offset.*, 1, 0xFFFFFF);
}

export fn dense_jump_bounds_fast(dest: *const u256, dense_len: u32) bool {
    return ops.denseJumpInBoundsFast(dest.*, dense_len);
}

export fn dense_jump_bounds_u16_ref(dest: *const u256, dense_len_raw: u32) bool {
    const dense_len: u32 = @min(dense_len_raw, 65536);
    return ops.denseJumpInBoundsRef(dest.*, dense_len, u16);
}

export fn dense_jump_bounds_u32_ref(dest: *const u256, dense_len: u32) bool {
    return ops.denseJumpInBoundsRef(dest.*, dense_len, u32);
}

export fn abs_two_comp(x: *const u256, out: *u256) void {
    out.* = ops.absTwoComp(x.*);
}

export fn sdiv_sign_apply(top: *const u256, second: *const u256, unsigned_quotient: *const u256, out: *u256) void {
    out.* = ops.sdivFromUnsignedQuotient(top.*, second.*, unsigned_quotient.*);
}

export fn smod_sign_apply(top: *const u256, unsigned_rem: *const u256, out: *u256) void {
    out.* = ops.smodFromUnsignedRem(top.*, unsigned_rem.*);
}

export fn byte_ref(index: *const u256, value: *const u256, out: *u256) void {
    out.* = ops.byteRef(index.*, value.*);
}
