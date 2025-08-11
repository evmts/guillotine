## Review: execution/system.zig (CALL/CREATE/SELFDESTRUCT family)

### High-signal findings

- Correct application of EIP‑150 (63/64 rule) and stipend logic, with solid tests including nested calls and low‑gas edge cases.
- Memory expansion cost charged before expansion; args/ret slices obtained afterward—this sequence is correct and consistent in most paths.
- EIP‑2929 warm/cold address cost included for calls and selfdestruct beneficiary; depth limit checks short‑circuit behavior appropriately.

### Opportunities

1) SSTORE integration (cross‑file, system flows)
- With SSTORE semantics implemented in storage, audit CREATE/CALL flows to ensure journal/refund unwinding is correct across nested frames and reverts.

2) Pre‑validation in analysis
- Precompute args_end/ret_end (when operands are known) and attach to instructions to avoid repeated u256→usize casts/additions.

3) Return copy fast path
- When bounds are pre‑validated, copy directly from output to memory slice with `copyForwards` and skip extra checks.

4) Early static‑context exits
- In every write‑affecting opcode (CREATE/SELFDESTRUCT), ensure static‑context guards execute before any other work (audit indicates this is mostly true).

### Tests/benches

- Add microbench matrix for CALL (args/ret sizes × warm/cold × value/no‑value). Track cycles/op.
- Add CREATE/CREATE2 benches with varying init code sizes and salts.

### Action items

- [ ] Audit refund/journaling interactions across CALL/CREATE and REVERT.
- [ ] Pre‑validate and embed args/ret sizes for decode‑time known cases.
- [ ] Add CALL/CREATE microbench suite.

### Comparison to evmone/revm

- evmone: Moves more work to decode time; our proposals close that gap. Behavioral parity on CALL/CREATE flows expected when SSTORE is implemented.
- revm: Excellent storage semantics and journaling; once we match SSTORE/refunds, throughput on call‑heavy paths should be competitive.

