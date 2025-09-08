# Differential Findings: system handlers (CALL-family) and related tests

This document summarizes issues identified while running `zig build test` and analyzing the failing differential tests under `test/differential/system_handlers_test.zig`.

Scope: Guillotine EVM (dispatch-based Frame) vs MinimalEvm (reference/tracer) for system handlers and nearby paths.

## Summary of Failing Cases (from the suite)

- differential: DELEGATECALL preserves msg.sender and value
  - Gas usage mismatch: MinimalEvm=21086 vs Guillotine=31140

- differential: STATICCALL restrictions
  - Gas usage mismatch: MinimalEvm=23673 vs Guillotine=21190
  - GPA leak detected (precompile output not freed)

- differential: RETURN with large data
  - Contract deployment returned no runtime code (deployment path)

- differential: REVERT with error data
  - Guillotine execution failed (tracing=true)

- differential: nested CALL depth limit
  - Mismatch; likely caused by CALL-family metering differences

- differential: RETURNDATASIZE and RETURNDATACOPY
  - Mismatch + GPA leak (see precompile allocator bug)

- differential: gas edge cases
  - Mismatch + GPA leak (see precompile allocator bug)

In addition, MinimalEvm step-by-step trace is not exported, hence the recurring warning: “MinimalEvm tracing not available, skipping trace comparison (Guillotine has N steps)”—this is expected at present and not an error in itself.

## Issue 1 — Allocator ownership mismatch (precompile CallResult deallocation)

Symptoms:

- GPA leak logs (example):
  - Leak at `src/precompiles/precompiles.zig:257:39` in `execute_sha256` (32-byte alloc)
  - Call chain via `precompiles.execute_precompile(...)` → `evm.executePrecompileInline(...)` → system handler

Root cause:

- Precompiles allocate their output with the EVM’s allocator (inside `Evm.executePrecompileInline`, calls into `precompiles.execute_precompile(self.allocator, ...)`).
- System handlers deinit a returned `CallResult` using the Frame’s arena allocator via `self.getAllocator()`:
  - `src/instructions/handlers_system.zig`: in `call`, `delegatecall`, `staticcall`, and `authcall` paths, we do `defer result.deinit(self.getAllocator());`.
  - The Frame arena allocator is different from the EVM allocator used to allocate the output. In Zig, freeing with the wrong allocator is undefined; with the arena, `free` is typically a no-op → leak.

Impact:

- Memory leaks and potential undefined behavior in `CallResult.deinit()` (freeing slices using the wrong allocator).

Fix direction:

- Ensure `CallResult.deinit()` uses the allocator that owns its fields.
  - Easiest surgical fix: in system handlers, replace `self.getAllocator()` with the EVM’s allocator, e.g. `self.getEvm().allocator` (or add a helper) when deinitializing results received from EVM.
  - Longer-term: carry an owning allocator pointer inside `CallResult` or standardize allocation to the Frame arena for transient outputs that are known to be deinitialized there.

## Issue 2 — CALL-family dynamic gas metering diverges from MinimalEvm

Observed mismatches in CALL/DELEGATECALL/STATICCALL tests, with differences of ~2.6k and ~10k gas depending on case.

Findings:

1) Missing EIP-2929 cold/warm account access charge in handlers

- MinimalEvm (reference) charges account access cost (cold/warm) before forwarding gas:
  - `src/tracer/minimal_frame.zig`
    - CALL (0xf1) ~1040–1140: calls `self.getEvm().access_address(call_address)` and `consumeGas(access_cost)`.
    - DELEGATECALL (0xf4) ~1260–1350: similar.
    - STATICCALL (0xfa) ~1490–1550: similar.
- Guillotine system handlers (`src/instructions/handlers_system.zig`) do not subtract this access cost before computing forwardable gas or performing the call.

2) Memory expansion cost for writing call return data is not charged

- MinimalEvm charges a memory expansion cost before writing the callee’s return data into caller memory:
  - e.g. CALL: `mem_cost_out = self.memoryExpansionCost(end_bytes_callcopy); try self.consumeGas(mem_cost_out);`
- Guillotine handlers perform `ensure_capacity` and `set_data` for the output region without subtracting any gas. This undercharges the caller in paths that write return data.

3) Ordering around the 63/64 rule differs

- MinimalEvm consumes base + access costs first, then computes available gas to forward as `min(gas_limit, remaining - remaining/64)`.
- Guillotine handlers compute the 63/64 cap directly from the current `gas_remaining` before accounting for access and (missing) dynamic costs. This makes the forwarded amount and total accounting diverge.

Evidence:

- “STATICCALL restrictions” test: MinimalEvm=23673 vs Guillotine=21190 → we undercharge (missing cold-access and/or memory-expansion copy costs).
- “DELEGATECALL preserves msg.sender and value” test: MinimalEvm=21086 vs Guillotine=31140 → we overcharge in aggregate; combined with the ordering differences and pre-charged block gas, the net effect is higher total consumption on our side.

Fix direction:

- In system handlers for CALL/DELEGATECALL/STATICCALL:
  - Charge EIP-2929 account access (via `self.getEvm().access_address(addr)`) before computing the 63/64 forwardable cap.
  - Charge a memory expansion cost before copying return data into the caller’s memory (no per-word copy charge, just expansion).
  - Ensure total ordering matches MinimalEvm semantics: static base + dynamic access costs first, then cap forwarded gas, then, after the call, apply only the callee’s used portion to the caller’s gas.

## Issue 3 — Deployment (init-code) path returns empty runtime code in a case

Symptoms:

- “RETURN with large data”: deployment bytecode detected (`CODECOPY` + `RETURN`), but `deployContractGuillotine` reports `error.NoRuntimeCode` (returned runtime code length is zero).

Hypothesis (supported by surrounding behavior):

- The init code’s memory writes and/or memory expansion costs are not aligned with MinimalEvm’s expectations, leading to empty output at `RETURN` time. Given Issue 2 (missing dynamic memory expansion costs for write/copy paths), the init-code path might not be expanding or copying data as expected before `RETURN`.

Fix direction:

- First, address Issue 2. Then add targeted debug around `handlers_context.codecopy` and `handlers_system.return` to log memory end, expansion cost, and computed output length during init-code execution.

## Issue 4 — RETURNDATASIZE and RETURNDATACOPY mismatches (plus leaks)

Observations:

- Mismatch coincides with the allocator leak (Issue 1) and the missing memory-expansion charge for post-call output (Issue 2).
- The implementations of `RETURNDATASIZE`/`RETURNDATACOPY` themselves look structurally correct (`src/instructions/handlers_context.zig`), but they operate on `frame.output`. If earlier call handling produced incorrect/empty/over-allocated return data, these opcodes will diverge as a consequence.

Fix direction:

- Fix Issue 1 and Issue 2 and re-run differential tests. If residual mismatches persist, instrument the return-data boundaries (offset/length checks) to see if the caller writes and copies match MinimalEvm’s expected lengths.

## Issue 5 — Nested CALL depth limit test fails

Observations:

- The nested call test recurses with decreasing gas. MinimalEvm enforces depth with `frames.items.len >= 1024`; Guillotine enforces via `self.depth >= config.max_call_depth`.
- Given the other CALL-family metering differences, recursive behavior may terminate earlier/later, yielding divergence. There is no positive evidence of a MinimalEvm `inner_call` bug; single-level CALL tests pass and we added a demo that shows `inner_call` returning data as expected.

Fix direction:

- Re-run this test after correcting Issue 2 metering. If still failing, compare the per-level forwarded gas and gas-left across recursion to pinpoint where the divergence begins.

## Non-issues / current limitations

- MinimalEvm step tracing:
  - Warnings like “MinimalEvm tracing not available, skipping trace comparison (Guillotine has N steps)” are expected—per-step MinimalEvm traces are not exported yet. Differential runner falls back to comparing result/gas/output and previewing Guillotine steps in some cases.

## Additional context and evidence

- Dispatch first-block gas:
  - Logs show `first_block_gas` metadata applied (e.g., `Found first_block_gas with gas=121`). Static costs are batched per basic block. Ensure this pre-charge aligns with MinimalEvm’s per-op base costs so we don’t double- or under-count when reconciling dynamic charges.

- Passing evidence of MinimalEvm `inner_call` correctness:
  - We added a demo to the “differential: minimal CALL” test that sets code at `0x42`, issues a CALL from a caller bytecode, and prints:
    - `MinimalEvm inner_call demo → success=true, gas_used=..., out_len=32`
    - `MinimalEvm demo output: 0000...00002a`
  - This confirms MinimalFrame → MinimalEvm.inner_call executes and returns expected data for simple cases.

## Recommended next steps

1) Fix allocator mismatch in system handlers:
   - Replace `result.deinit(self.getAllocator())` with `result.deinit(self.getEvm().allocator)` (or equivalent accessor).

2) Implement CALL-family dynamic metering parity:
   - Charge EIP-2929 access cost before forward-cap.
   - Charge memory expansion when writing return data after calls.
   - Align 63/64 cap ordering with MinimalEvm.

3) Re-run tests, then focus on the deployment path if “NoRuntimeCode” persists.

4) If needed, add temporary debug logs (guarded by `std.testing.log_level`) around:
   - `handlers_context.codecopy`
   - `handlers_system.return` / `revert`
   - CALL-family handlers right before/after writing outputs

5) Longer term: consider carrying allocator ownership in `CallResult` to avoid category errors, and/or consolidating allocation strategy for outputs in one place.

