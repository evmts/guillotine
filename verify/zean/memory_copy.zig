//! Zean loops-profile capture root for Guillotine's bounded EVM byte copy.
const ops = @import("verified_ops.zig");

export fn copy_evm_bytes(dst: [*]u8, src: [*]const u8, len: usize) void {
    ops.copyEvmBytes(dst, src, len);
}
