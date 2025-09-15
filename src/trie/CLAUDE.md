# CLAUDE.md - Trie Module

## MISSION CRITICAL: Merkle Patricia Trie Implementation
**Trie bugs corrupt state roots and cause consensus failures.** Must maintain cryptographic security and deterministic results.

## Merkle Patricia Trie Structure
- **State Root**: Cryptographic commitment to entire world state
- **Storage Root**: Per-account storage commitment
- **Transaction Root**: Commitment to all transactions in block
- **Receipt Root**: Commitment to all transaction receipts

## Key Responsibilities
- **Node Encoding**: RLP encoding/decoding of trie nodes
- **Path Compression**: Efficient storage of sparse tries
- **Hash Computation**: Keccak-256 hashing of trie nodes
- **Proof Generation**: Merkle proofs for state verification
- **Cache Management**: Efficient node caching and persistence

## Critical Operations
```zig
// Trie insert must maintain deterministic structure
pub fn insert(trie: *Trie, key: []const u8, value: []const u8) !void {
    const encoded_key = encode_path(key);
    const node = try trie.root.insert(encoded_key, value);
    trie.root = node;
    trie.hash_cache.clear(); // Invalidate cached hashes
}

// Hash computation must be deterministic and secure
pub fn compute_root_hash(trie: *const Trie) [32]u8 {
    return trie.root.compute_hash();
}
```

## Node Types (EIP-838)
- **Branch Node**: 16 children + optional value
- **Extension Node**: Path compression for common prefixes
- **Leaf Node**: Terminal node containing value
- **Empty Node**: Represents null/empty state

## Critical Safety Requirements
- All trie operations must be deterministic
- Hash computation must use Keccak-256 consistently
- Node encoding must follow RLP specification exactly
- Path encoding must handle nibble alignment correctly
- Trie structure must remain balanced and canonical

## Performance & Security
- **Optimization**: Lazy hash computation with caching, node deduplication, efficient path compression
- **Security**: Prevent hash collision attacks, deterministic branch ordering, validate inputs
- **Memory**: Pool temporary objects, database batching for persistence

## Testing & Emergency
- **Testing**: All node combinations, Ethereum test vectors, property-based invariants, large state trees, fuzzing
- **Emergency**: State corruption detection/recovery, consistency validation, hash mismatch investigation

**The trie is backbone of Ethereum's state security. Any corruption compromises entire blockchain state.**