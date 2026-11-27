//! Zean loops-profile capture root for Guillotine's jump-table binary search.
const ops = @import("verified_ops.zig");

export fn bsearch_jump_table_u32(pcs: [*]const u32, len: usize, target: u32) bool {
    return ops.bsearchJumpTableU32(pcs, len, target);
}
