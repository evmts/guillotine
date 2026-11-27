//! Zean loops-profile capture root for Guillotine's EVM JUMPDEST bytecode scanner.
const ops = @import("verified_ops.zig");

export fn is_valid_jumpdest_bytes(code: [*]const u8, len: usize, target: usize) bool {
    return ops.isValidJumpdestBytes(code, len, target);
}
