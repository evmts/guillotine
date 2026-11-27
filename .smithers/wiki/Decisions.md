---
title: Architectural Decision Records
tags: [decisions, adr]
---

# Architectural Decision Records

Key engineering trade-offs behind Guillotine, with the rejected alternatives preserved so future contributors and agents do not revisit settled dead ends.

## ADR-001: Dispatch Schedule and Tailcall Engine Over Switch Loop

- **Decision**: Preprocess bytecode into 8-byte `Dispatch.Item` schedules and jump between handlers via `@call(.always_tail)` (`[[Dispatch-Engine]]`).
- **Rejected alternative**: Traditional `while (pc < code.len) switch (opcode)` interpreter.
- **Why**: Single switch dispatch suffers indirect branch misprediction and repeated stack/gas checks per opcode. Pre-validating basic blocks once shifts overhead out of hot loops and yields `1.43x` over `revm` on classic workloads.

## ADR-002: Stock Zig 0.17.1 `preserve_none` Over Compiler Fork

- **Decision**: Standardize on stock Zig `0.17.1` with native `preserve_none` handlers and 4x `u64` top-of-stack register caching.
- **Rejected alternative**: Maintaining a custom Zig/LLVM compiler fork for tailcall calling conventions.
- **Why**: A compiler fork breaks downstream `zig fetch` adoption and doubles CI maintenance. Stock Zig `0.17.1` ships native `preserve_none` directly.

## ADR-003: Dual Zean + Hand-Authored Lean 4 Formal Verification

- **Decision**: Pair direct Zig `0.17.1` AIR extraction (`okcontract/zean` -> Lean `4.35.0`) with a hand-authored executable Lean reference spec, Bitwuzla/Z3 SMT proofs, and LLVM IR checks (`[[Formal-Verification]]`).
- **Rejected alternative**: Relying on EEST state tests alone, or hand-translating Zig kernels into Lean manually.
- **Why**: Manual translation risks model-to-code drift; Zean proves properties on the actual Zig AIR emitted for `src/core/verified_ops.zig`, while the executable Lean spec covers full EVM semantics via `116,384` differential vectors.

## ADR-004: Separate `evmts/guillotine-mini` From the Performance Engine

- **Decision**: Keep `src/tracer/minimal_evm.zig` as the focused in-repo differential oracle and host the standalone educational reference EVM in `evmts/guillotine-mini` (`[[Mythical-History]]`).
- **Rejected alternative**: Maintaining a duplicated `mini/` workspace tree inside `evmts/guillotine`.
- **Why**: Eliminated dangling submodules, duplicate build steps, and documentation drift before `v0.1.0`.

## ADR-005: Split Read/Write Cloud Object Store Credentials

- **Decision**: Configure `.smithers/WORKSPACE.ts` with separate `SMITHERS_CACHE_READ_TOKEN` and `SMITHERS_CACHE_WRITE_TOKEN` secrets pointing at `https://build.smithers.sh` (`[[Trust-Model-and-Factory]]`).
- **Rejected alternative**: Sharing a single read-write cache token across PRs, or disabling remote caching for contributors.
- **Why**: Contributors enjoy fast cache hits on untrusted runs while cache writes stay strictly confined to trusted `main` and maintainer-controlled sandboxes, preventing cache poisoning.

## Related Pages

- [[Overview]]
- [[Mythical-History]]
- [[Dispatch-Engine]]
- [[Formal-Verification]]
- [[Trust-Model-and-Factory]]
