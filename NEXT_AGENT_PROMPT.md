# NEXT AGENT PROMPT — Guillotine EVM (Mission-Critical)

This prompt hands off the current state and a precise plan to take the repo to completion per CLAUDE.md’s zero‑tolerance standards. You must work from the repo root and verify every change with `zig build && zig build test-opcodes` unless modifying only .md files.

## Objective

Deliver a production-ready, fully verified Guillotine EVM build:
- All builds succeed without warnings.
- All opcode differential tests pass without error logs.
- Full test matrix is green (unit, integration, specs as configured).
- No memory safety issues; no error swallowing; no stubs; no commented-out code changes.
- Documentation of verification artifacts (results, code quality, memory safety, performance baseline, final report), following the spirit of FINISHING_PROMPT.md.

## Quick Start (Run From Repo Root)

- Build: `zig build`
- Opcode tests: `zig build test-opcodes`
- Unit tests (filtering possible): `zig build test-unit -Dtest-filter='<pattern>'`
- Integration tests: `zig build test-integration`
- Specs: `zig build specs`

## Current Status Snapshot

- Build: currently succeeds after local dependency patching (see “Local cache patch” below).
- `zig build test-opcodes`: compiles, but exits non-zero due to 6 tests that log runtime errors (details below). All 623 tests themselves report “passed 1/1”, but the test runner flags the error-level logs and fails the step.
- Unit tests focused on preprocessor/dispatch were in flux; I made targeted fixes in `src/preprocessor/dispatch_test.zig`, but this revealed that the test harness’s custom TestFrame type diverged from the production preprocessor expectations (FrameType API). See “Blockers”.

## Important Changes I Made

1) Test harness updates (compile drift fixes)
- File: `src/preprocessor/dispatch_test.zig`
  - Updated handler array type to element type (not pointer-to-pointer): `[256]TestFrameComplete.OpcodeHandler`.
  - Dropped obsolete 3rd arg from `Bytecode.init(...)` calls (now 2-arg or tracer variant).
  - Updated `TestDispatch.init()` call sites to pass the required tracer param (set to `null`).
  - Updated `createJumpTable(...)` call sites to pass `dispatch_items.items` (prev. API now expects `[]const Item`).
  - Added a minimal `FrameConfig` and `Dispatch` alias to satisfy newer preprocessor references (temporary; see proper fix below).

2) Local cache patch to primitives (BN254) to unblock build
- Patched Zig cache only (not vendored into repo!) at:
  - `$HOME/.cache/zig/p/guillotine_primitives-0.1.0-<hash>/src/crypto/bn254.zig`
  - `$HOME/.cache/zig/p/guillotine_primitives-0.1.0-<hash>/src/crypto/bn254/pairing.zig`
- Fixes:
  - Remove `try` before `.isInfinity()` (it returns `bool`).
  - Unwrap error-union from `mulByInt` before calling `.toAffine()`.
  - `pairing(...)` returns error-union; `try` it before `mul(&pair_result)`.
  - `G2.toAffine()` returns plain `G2` (no `try`).
- Rationale: Build was failing in the dependency due to type/signature drift; this unblocked `zig build` and allowed running opcode tests. NOTE: This is ephemeral and must be made reproducible (see Plan → Phase 1).

## Blockers and Root Causes

1) Ephemeral dependency patching (BN254 in primitives)
- Current repo depends on a tarball of `primitives` via `build.zig.zon`.
- The local fixes live only in Zig’s global cache. They will be lost on clean installations and are not reviewable.
- Root cause: Upstream API/signature mismatches around BN254 affine checks and pairing return types.

2) Opcode differential tests fail due to logged errors
- `zig build test-opcodes` shows 6 failing steps although each individual Zig test reports “1/1 passed”. The test runner fails on error-level logs:
  - 0xf6: InvalidOpcode
  - 0x3e: ReturnDataNotAvailable
  - 0xf2: OutOfGas
  - 0xfe: InvalidOpcode
  - 0xfa: OutOfGas
  - 0xf7: InvalidOpcode
- Root cause: Expected runtime outcomes (e.g., invalid opcode or OOG) are being logged at error-level by the differential harness or its test runner, causing the overall step failure. We must either (a) lower log level for expected outcomes, or (b) update the assertions to treat these as pass conditions without emitting error logs.

3) Preprocessor unit test harness divergence
- `src/preprocessor/dispatch_test.zig` defines a minimal TestFrame type, but the production preprocessor now imports `frame/frame_handlers.zig` to resolve synthetic handlers at comptime. That brings in expectations on FrameType (e.g., `gas_remaining`, `beforeInstruction`, tracer wiring, and other Frame APIs) which the test harness does not provide.
- Root cause: Preprocessor evolved to rely on Frame internals (for synthetic handlers and validation), making the old standalone TestFrame insufficient. Tests must be updated to use the real `Frame(FrameConfig{...})` or provide a matching surface.

## Things Tried (and Results)

- Rewrote portions of `src/preprocessor/dispatch_test.zig` to align signatures and call sites with the updated preprocessor and bytecode APIs. This progressed compilation but then triggered broader compile failures because the TestFrame no longer satisfies the FrameType interface expected by `frame_handlers.zig` and synthetic handler machinery.
- Ran `zig build test-unit -Dtest-filter='trie'`: still compiles unrelated modules and surfaced many errors in Frame/Synthetic handler expectations from preprocessor tests. Conclusion: the unit test harness must be refactored to use the actual `Frame(FrameConfig)`.
- Executed `zig build test-opcodes`: after local BN254 cache patching, all opcodes compile and run, but 6 steps fail due to error-level logs even though each test reports “passed”. Conclusion: fix test harness logging/expectations for known error-returning flows.

## Plan (Phased)

Phase 1: Vendor primitives patch (make builds reproducible)
- Action:
  - Create a vendored copy of `primitives` inside `lib/primitives` (or a fork submodule) containing BN254 fixes applied in the cache.
  - Update `build.zig.zon` to point `.primitives` to a local `path` instead of remote `url/hash`.
  - Ensure `src/modules.build.zig` continues to import via `b.dependency("primitives", ...)` and resolves to the local module.
- Verify: `zig build && zig build test-opcodes` (should compile without touching the Zig cache).
- Acceptance: No warnings; same behavior as with cache patch.

Phase 2: Fix preprocessor unit tests to use real Frame
- Action:
  - Replace the custom TestFrame in `src/preprocessor/dispatch_test.zig` with the actual `Frame` type:
    - `const Frame = @import("../frame/frame.zig").Frame(.{ .DatabaseType = @import("../storage/memory_database.zig").MemoryDatabase });`
  - Update references to use `Frame.Dispatch`, `Frame.opcode_handlers`, `Frame.PcType`, etc.
  - Provide minimal construction setup where needed (allocator, trivial database, trivial evm pointer) or refactor tests to avoid runtime interpret calls when not needed.
  - If any tracer validations are inlined for Debug/Safe builds, ensure the `Frame`’s EVM/tracer context is constructed in tests (or disable validation for this test scope by using a non-validating configuration if available).
- Verify: `zig build test-unit -Dtest-filter='Dispatch'` (or filter to the specific preprocessor tests).
- Acceptance: All unit tests in this file compile and pass without touching production code paths or introducing stubs.

Phase 3: Resolve opcode differential “logged errors”
- Action (choose the least-invasive that meets zero tolerance):
  1) Preferred: Adjust per-opcode tests (in `test/evm/opcodes/*_test.zig`) to treat expected failures (InvalidOpcode, OutOfGas, ReturnDataNotAvailable) as success conditions without logging at error level. Use assertions instead of `log.error` for expected outcomes.
  2) Alternative: Modify test runner to ignore error-level logs when the test itself passes. Only do this if (1) is infeasible; otherwise it weakens the signal.
  - Validate specific offenders: 0xf6, 0xf7, 0xfe (invalid); 0xf2, 0xfa (call paths OOG); 0x3e (RETURNDATASIZE before any return data).
- Verify: `zig build test-opcodes` returns success; no red steps, no error-level logs from expected conditions.
- Acceptance: All opcode tests pass cleanly; no error logs for expected error outcomes.

Phase 4: Full matrix, quality, and reports
- Action:
  - Run: `zig build test` (aggregated), `zig build specs`, `zig build test-integration`, and any configured synthetic/fusions tests.
  - Produce and commit reports:
    - `TEST_RESULTS.md`: enumerate targets run and outcomes.
    - `BUILD_STATUS.md`: which build artifacts/steps succeed; warn-free verification.
    - `CODE_QUALITY_REPORT.md`: zero-tolerance audit (no stubs, no error-swallowing, no commented-out code changes, no `std.debug.assert`, etc.).
    - `MEMORY_SAFETY_REPORT.md`: summarize allocations, ownership patterns, any sanitizer/allocator checks done.
    - `PERFORMANCE_BASELINE.md`: run available benchmarks or representative tests; record times and environment.
    - `VERIFICATION_REPORT.md`: final sign-off on mission-critical readiness.
- Verify: Rerun at least `zig build` and `zig build test-opcodes` after report commits.
- Acceptance: All green; docs complete and accurate.

## Notes and Constraints (from CLAUDE.md)

- Always run from repo root.
- Use tracer.assert for assertions; never `std.debug.assert` in modules.
- Never swallow errors with `catch {}` or similar; either handle or propagate.
- ArrayList in Zig 0.15.1 is unmanaged; all operations must pass allocator.
- CRASHES ARE SECURITY BUGS. Ensure handlers and prevalidation prevent crashes; return errors gracefully.

## Known Files of Interest

- `build.zig` — orchestrates modules, libs, and test steps.
- `build.zig.zon` — dependencies; change `.primitives` to a local `path` for vendoring.
- `src/modules.build.zig` — module wiring; ensure it still resolves vendored primitives.
- `src/preprocessor/dispatch.zig` — preprocessor; imports `frame_handlers.zig` for synthetic handlers.
- `src/preprocessor/dispatch_test.zig` — unit tests; must be refactored to use real `Frame`.
- `test/evm/opcodes/*.zig` — differential tests; adjust expectations/logging for expected error conditions.

## Exact Issues Observed (for quick repro)

1) Pre-patch build failure (in dependency):
```
/.../primitives-0.1.0-.../src/crypto/bn254.zig:417:37: error: expected error union type, found 'bool' (try isInfinity)
/.../bn254.zig:458:37: error: no field or member function named 'toAffine' in <error-union of G1>
/.../bn254.zig:533:29: error: expected *const Fp12Mont, found *const <error-union Fp12Mont> (pairing)
/.../bn254/pairing.zig:32:36: error: expected error union type, found 'bn254.G2' (try toAffine)
```

2) After local cache patch, opcode differentials with error logs (step fails):
```
opcode 0xf6: InvalidOpcode
opcode 0x3e: ReturnDataNotAvailable
opcode 0xf2: OutOfGas
opcode 0xfe: InvalidOpcode
opcode 0xfa: OutOfGas
opcode 0xf7: InvalidOpcode
```

3) Preprocessor unit tests drift:
- Custom TestFrame in `src/preprocessor/dispatch_test.zig` lacks fields/methods expected by synthetic handler machinery (`frame_handlers.zig`), e.g. `gas_remaining`, `beforeInstruction`, tracer coupling, etc.

## Guardrails

- Don’t add stubs or ignore errors.
- Don’t mutate Zig cache for fixes; vendor patches into the repo and point the build to them.
- Keep changes minimal and cohesive; focus on the blockers above.
- After each code change: `zig build && zig build test-opcodes`.

## Deliverables Checklist

- [ ] Vendored primitives with BN254 fixes; reproducible build.
- [ ] Preprocessor unit tests use `Frame(...)` or fully conformant test frame.
- [ ] `zig build test-opcodes` green without error logs.
- [ ] Full test matrix executed; all passing (or documented if subset enforced by build config).
- [ ] Reports committed: TEST_RESULTS.md, BUILD_STATUS.md, CODE_QUALITY_REPORT.md, MEMORY_SAFETY_REPORT.md, PERFORMANCE_BASELINE.md, VERIFICATION_REPORT.md.

