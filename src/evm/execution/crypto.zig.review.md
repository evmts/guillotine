## Review: execution/crypto.zig (KECCAK256 / SHA3)

### High-signal findings

- Uses tiered stack buffers for small/medium/large inputs (`SMALL_BUFFER_SIZE=64`, `MEDIUM_BUFFER_SIZE=256`, `LARGE_BUFFER_SIZE=1024`) and falls back to hashing directly from memory for larger inputs. This minimizes heap traffic and improves cache locality on common paths.
- Performs robust bounds checks before memory access:
  - Validates `offset`/`size` fit in `usize` and checks `offset + size` with `std.math.add` to catch overflow.
  - Rejects ranges that exceed `MAX_MEMORY_SIZE`.
- Memory is expanded via `ensure_context_capacity` prior to hashing; data is then read using `get_slice`.
- Properly computes dynamic gas for hashing as `6 * word_size` where `word_size = (size + 31) / 32`.
- Correctly handles `size == 0` using the canonical `keccak256("")` constant and appends the u256 result.
- Converts the 32-byte digest to `u256` via `std.mem.readInt(u256, &hash, .big)`, which matches EVM big-endian semantics.
- Debug logging provides stack pre-pop inspection and shows data slices and results; should be gated out in release.

### Gaps and TODOs observed in code

- Hot-path `Log.debug` calls inside opcode execution will inhibit inlining in release unless gated. These should be compiled out under ReleaseFast.
- The buffer tiers are helpful, but the identical hashing logic is repeated three times; could be simplified while preserving stack allocation behavior.
- Analysis already has hooks for immediate-size KECCAK paths; this opcode can benefit when analysis precomputes size (e.g., `.keccak_immediate_size`). Ensure parity between analysis-time hints and this handler.

### Opportunities

- Gate logging with a compile-time check (e.g., `if (comptime SAFE)`) or build flag to ensure zero cost in ReleaseFast.
- When analysis precomputes an immediate `size`, skip division and redundant checks here by using the specialized immediate-size path, or by branching early.
- Consider a single helper to choose buffer tier and call Keccak to reduce repetition; keep stack allocation behavior intact.
- Add tests for boundary cases: `size == 0`, `offset + size` overflow, maximum allowed `end`, and large inputs that bypass stack buffers.

### Action items

- [ ] Guard all debug logging in hot paths so it compiles out in ReleaseFast.
- [ ] Integrate with analysis-time immediate-size path for KECCAK when available to remove divisions/branches at runtime.
- [ ] Refactor the three buffer branches to a small helper to avoid duplication (preserve stack allocation and no-alloc behavior).
- [ ] Add explicit tests for: zero-size hash, large-size hash, out-of-bounds/overflow, and gas accounting for various sizes.

### Correctness notes

- Zero-size path uses the canonical empty hash constant and avoids memory reads, which is correct and efficient.
- Gas is charged before memory access and hashing; dynamic cost derives from words, matching Yellow Paper rules.
- Bounds checks and `ensure_context_capacity` precede reads, preventing undefined behavior.

### Comparison to evmone/revm

- evmone also optimizes small-size hashing; analysis-time specialization can close remaining gaps. With logging gated and immediate-size integration, runtime cost should be near parity.


