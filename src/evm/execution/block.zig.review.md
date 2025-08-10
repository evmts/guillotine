## Review: execution/block.zig (BLOCKHASH/COINBASE/TIMESTAMP/NUMBER/PREVRANDAO/GASLIMIT/CHAINID/BASEFEE/BLOBHASH/BLOBBASEFEE)

### High-signal findings

- Reads are context/host provided; semantics depend on hardfork features (e.g., PREVRANDAO in post‑merge).

### Opportunities

- Ensure hardfork gating is strictly applied and has tests for availability/non‑availability per fork.
- Add tests verifying PREVRANDAO behavior and BASEFEE under London.

### Action items

- [ ] Add fork‑specific tests for each env var opcode.

### Comparison to evmone/revm

- Parity expected with adequate gating tests.


