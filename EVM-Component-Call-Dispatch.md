## Component Review: Call Dispatch and Execution Orchestration

### Scope (key files)

- `src/evm/execution/system.zig` — CALL, CALLCODE, DELEGATECALL, STATICCALL, CREATE, CREATE2, SELFDESTRUCT
- `src/evm/evm/call_contract.zig`, `src/evm/evm/staticcall_contract.zig`, `src/evm/evm/call_result.zig`, `src/evm/call_executor.zig` (orchestrating helpers)
- `src/evm/return_data.zig`, `src/evm/created_contracts.zig`, `src/evm/self_destruct.zig`
- `src/evm/call_frame_stack.zig` — call journaling/snapshots
- `src/evm/host.zig` — host interface for external execution

### What’s working well

- EIP‑150 forwarding and stipend logic are implemented with thorough tests, including nested call edge cases.
- Clear separation of concerns: system opcode handlers compute memory expansion BEFORE expanding memory; gas is charged up front; state changes are guarded by snapshots for revert.
- EIP‑2929 warm/cold account access is applied for CALL‑family and SELFDESTRUCT beneficiary checks, with good unit coverage.
- Return data propagation: return buffers are written back to memory respecting requested sizes; zero‑filling remainder when output < requested is correct.

### Opportunities

1) Memory access pre‑validation and sizing
- Idea: Lift common sizing (args_end, ret_end) to decode time (analysis) and carry as immediates in the instruction stream when operands are immediate or previously known. At runtime, this avoids redundant u256→usize casts, additions, and bounds checks.

2) Gas math consolidation
- Factor shared patterns (base + memory expansion + warm/cold + new account + forwarding) into tiny inline helpers per call type to reduce duplicated branches and improve predictability.

3) Return data copies
- When bounds are pre‑validated, write directly using `copyForwards` from output to memory slice. Reserve `set_data_bounded` for defensive paths. Bench for wins.

4) Depth checks
- Depth limiting is correctly enforced. Consider early‑exit fast checks (depth >= MAX) before any other work to reduce dead‑end overhead.

5) Host interface fast path
- If the Host sometimes calls back into our VM (same process), introduce an in‑process fast path (no FFI/adapter overhead) for common patterns.

### Correctness nits

- Ensure all static‑context restrictions short‑circuit prior to any memory expansion (a few paths already do; audit for consistency across all system ops).
- For CREATE/CREATE2, make sure gas reservation and final gas refund math precisely match spec (tests look good; keep parity when refactoring).

### Bench/observability

- Add a targeted microbench: CALL with varying args/ret sizes (0, 32, 1024) × warm/cold × value/no‑value. Track cycles per call and branch miss deltas.
- Add counters (guarded in non‑release) for: cold vs warm calls, average forwarded gas, memory expansion bytes, and average return copy bytes.

### Actionable checklist

- [ ] Extract shared gas math into inline helpers; verify no code size bloat in ReleaseFast.
- [ ] Pre‑validate args/ret bounds in analysis when possible; attach to instruction.
- [ ] Add CALL family microbench matrix; compare pre/post refactor.
- [ ] Early static‑context short‑circuit in all system ops.

### Comparison to evmone and revm

- evmone (advanced): Pushes more sizing/gas computation to decode time; reduces runtime branching. Recommendation above closes this gap. Its block‑based validation is comparable to ours.
- revm: Very strong and precise SSTORE/CREATE semantics and journaling; CALL math parity is expected. Our forwarding/stipend coverage matches; optimizing memory sizing and copy paths will make throughput comparable on call‑heavy traces.


