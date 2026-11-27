//! Root module for Guillotine's Merkle Patricia Trie (MPT).

pub const trie = @import("trie.zig");
pub const merkle_trie = @import("merkle_trie.zig");
pub const hash_builder = @import("hash_builder_complete.zig");
pub const proof = @import("proof.zig");
pub const optimized_branch = @import("optimized_branch.zig");
pub const node_cache = @import("node_cache.zig");

pub const MerkleTrie = merkle_trie.MerkleTrie;
pub const TrieNode = trie.TrieNode;
pub const HashBuilder = hash_builder.HashBuilder;
pub const ProofNodes = proof.ProofNodes;
pub const ProofRetainer = proof.ProofRetainer;
pub const CompactBranchNode = optimized_branch.CompactBranchNode;
pub const NodeCache = node_cache.NodeCache;

pub const TrieError = trie.TrieError;
pub const ProofError = proof.ProofError;

pub const key_to_nibbles = trie.key_to_nibbles;
pub const nibbles_to_key = trie.nibbles_to_key;

test "trie root re-exports nibble conversion helpers" {
    const std = @import("std");
    const allocator = std.testing.allocator;
    const nibbles = try key_to_nibbles(allocator, &[_]u8{ 0xab, 0xcd });
    defer allocator.free(nibbles);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xa, 0xb, 0xc, 0xd }, nibbles);
}
