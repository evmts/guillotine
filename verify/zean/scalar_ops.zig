//! Zean scalar-profile capture roots for Guillotine's `src/core/verified_ops.zig`.
//!
//! Captured directly from Zig 0.17.1 AIR into `verify/lean/GuillotineZean/ScalarOps/Generated.lean`.
const ops = @import("verified_ops.zig");

export fn align_up_32(n: u32) u32 {
    return ops.alignUp32(n);
}

export fn memory_word_count_fast(byte_size: u32) u64 {
    return ops.memoryWordCountFast(byte_size);
}

export fn memory_gas_cost(words: u64) u64 {
    return ops.memoryGasCost(words);
}

export fn block_stack_guard_fast(size: u32, min_stack: u16, max_stack: u16) u8 {
    return ops.blockStackGuardFastCode(size, min_stack, max_stack, 1024);
}

export fn block_stack_guard_ref(size: u32, min_stack: u16, max_stack: u16) u8 {
    return ops.blockStackGuardRefCode(size, min_stack, max_stack, 1024);
}
