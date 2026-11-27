---
title: TigerStyle Safety and Lighthouse Backpressure
tags: [safety, tigerstyle, uphill]
---

# TigerStyle Safety and Lighthouse Backpressure

Guillotine is financial execution infrastructure where a consensus bug or crash causes fund loss. Safety invariants are enforced both in code (`docs/dev/TIGERSTYLE.md`) and continuously through Uphill Lighthouse-style audit reports.

## Zero-Crash Contract

- **No crashes in production**: Every malformed input, OOM, stack limit, gas limit, or precompile failure returns a typed Zig error gracefully. `std.debug.assert` and `std.debug.print` are forbidden in production modules under `src/`.
- **No swallowed errors**: Empty `catch {}` blocks, silent fallbacks, and `error.NotImplemented` stubs are rejected in CI (`tigerstyle-check` and Uphill `safety` category).
- **Pre-validated `_unsafe` contract**: Functions suffixed `_unsafe` intentionally omit runtime bounds checks because `Dispatch` pre-validates basic-block stack depth and headroom upfront (`[[Dispatch-Engine]]`). `tracer.assert()` calls inside `_unsafe` helpers act as debug/test checks and never abort embedded FFI hosts (`guillotine_embedded = true`).
- **Loop bounds**: `SafetyCounter` (`src/internal/safety_counter.zig`) caps bytecode analysis loops at 1M iterations in Debug and ReleaseSafe. Gas bounds runtime execution.
- **Explicit ownership**: Every allocation pairs immediately with `defer` or `errdefer`.

## Continuous Lighthouse Backpressure (Uphill)

`.agents/uphill/uphill.yaml` scores six independent categories on a `0` to `100` Lighthouse scale (`90+` green, `50-89` amber, `0-49` red):

1. **Safety and TigerStyle**: Zero `@panic`/`unreachable`, zero forbidden debug calls, zero swallowed errors, assertion density, Rust FFI `.unwrap()` and `unsafe` boundaries.
2. **Style and Limits**: `zig fmt --check src/`, 70-line function bound, 120-column line bound, zero unresolved TODO markers.
3. **Footprint and Modularity**: 500-line file modularity target and 80 kB subsystem ceiling.
4. **Verification and Tests**: Zero `sorry`/`axiom` in Lean 4, proven Lean theorem count, SMT proof count, inline Zig test coverage.
5. **Documentation**: Zero broken local links across root docs, `docs/`, and `.smithers/wiki/`, plus `README.md` coverage for every `src/` subsystem.
6. **Smithers Factory**: Valid factory/home projections, shared cloud cache trust separation, Engineering Wiki freshness, release version lockstep, and workflow capability hygiene.

Run `uphill --compact` locally or generate the interactive Lighthouse HTML dashboard with `node .smithers/reports/audit.mjs --write` (published to `https://guillotine.tevm.sh/audit.html`).

## Related Pages

- [[Overview]]
- [[Dispatch-Engine]]
- [[Formal-Verification]]
- [[Trust-Model-and-Factory]]
