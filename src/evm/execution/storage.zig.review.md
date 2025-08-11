## Review: execution/storage.zig (SLOAD/SSTORE/TLOAD/TSTORE)

### High-signal findings

- ✅ SSTORE fully implements EIP-2200/3529 semantics via `storage_costs.calculateSstoreCost` with complete (original, current, new) tracking
- ✅ Cold/warm access costs properly implemented per EIP-2929
- ✅ Refund calculations with proper delta handling (positive/negative)
- ✅ SLOAD applies warm/cold pricing correctly
- ✅ TLOAD/TSTORE transient storage implemented with constant costs
- ✅ Comprehensive storage cost pre-computation table for O(1) lookups

### Implementation details verified

- `calculateSstoreCost()` in storage_costs.zig handles all hardfork variations
- Proper original/current/new value tracking for gas calculation
- Istanbul sentry gas check (2300) prevents reentrancy
- Cold slot tracking with access list integration
- Refund delta application with bounds checking

### Remaining gaps

- Journal/revert paths: ensure refund adjustments integrate correctly with nested calls
- Add explicit fork gating for EIP-1153 (transient storage) in handlers

### Tests

- Add comprehensive transition matrix tests for all SSTORE state transitions
- Add refund accounting tests comparing against official test vectors
- Test journaling/revert behavior with nested calls

### Action items

- [ ] Add SSTORE transition matrix tests covering all state changes
- [ ] Add fork gating for TLOAD/TSTORE (EIP-1153/Cancun)
- [ ] Verify journal integration for refund tracking

### Comparison to evmone/revm

- Semantics are in place; remaining work is validation breadth (tests) and journaling correctness under reverts.

