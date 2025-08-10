## Review: state/journal.zig (snapshot and revert)

### High-signal findings

- Journal entries cover storage, balance, nonce, code, logs, selfdestruct markers; revert walks entries in reverse and restores state; snapshots are O(1).

### Opportunities

- Avoid large payload copies (e.g., code blobs); store references/keys to DB.
- Consider per‑transaction arena allocation for entries to reduce allocator overhead and improve cache locality; clear at tx end.
- Integrate refund updates when SSTORE semantics are implemented; ensure revert unwinds refunds consistently.

### Action items

- [ ] Switch to referenced code payloads; add arena allocator for entries.
- [ ] Add refund integration and tests (with SSTORE).


