//! Zean memory-profile capture roots for Guillotine's in-place 256-bit EVM stack kernels.
const ops = @import("verified_ops.zig");

export fn stack_push_add_top(top: *u256, imm: *const u256) void {
    ops.stackPushAddTop(top, imm.*);
}

export fn stack_push_sub_top(top: *u256, imm: *const u256) void {
    ops.stackPushSubTop(top, imm.*);
}

export fn stack_push_mul_top(top: *u256, imm: *const u256) void {
    ops.stackPushMulTop(top, imm.*);
}

export fn stack_push_and_top(top: *u256, imm: *const u256) void {
    ops.stackPushAndTop(top, imm.*);
}

export fn stack_push_xor_top(top: *u256, imm: *const u256) void {
    ops.stackPushXorTop(top, imm.*);
}

export fn stack_swap1_top(top: [*]u256) void {
    ops.stackSwap1Top(top);
}
