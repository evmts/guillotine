# Changelog

All notable changes to Guillotine are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Performance

Measured with the ReleaseFast benchmark runner against Wave 1 `main` (`40683f91`, pinned x86_64 Linux,
6 symmetric runs): ~1.4x geometric mean over 41 workloads (~1.5x EVM-only), up to 2.8x on warm SSTORE
and 2.4x on cold SSTORE.

- A transaction no longer rewrites the 1,025-entry call stack, re-inserts the fork's precompiles
  into the access list, or asks the kernel for its thread id.
- The call arena keeps at most its configured capacity after an oversized transaction (with safe warm
  re-seeding on non-shrinking allocators).
- SLOAD and SSTORE hash a slot once (`storage/slot_hash.zig`, 4-limb multiply-fold + SplitMix64
  avalanche) and record state-dump touches once per transaction. `SlotStore` keeps the per-address
  non-zero count; an overwrite never allocates.
- RETURN, REVERT, and CREATE hand their arena copy to the result; CALL/CALLCODE reuse preflight account
  lookups; the return-data buffer is reused.
- Static jumps enter their successor block from the jump handler; the schedule owns one
  bucket-table jump table.
- Frame memory keeps its address and size inline (`MemoryConfig.flat`), and an MSTORE that grows
  in-capacity pooled memory stays on the register ABI with zero allocator/memset spills.
- `simulate()` skips clean overlay tables on both reads and clears.
- Cached analyses keep no per-byte bitmap; the dispatch cache finds a free slot through a bitmap.

### Added

- `EvmConfig.track_state_dump` (default `true`): `false` compiles state-dump tracking out and makes
  `Evm.dumpState` return `error.StateDumpDisabled`.
- `verified_ops`: `mulmodDirect`, `mulmodRef`, `mulmodU64`, `pushDivU64`, `pushDivRef` and the
  free-slot bitmap helpers, with new SMT theorems.

### Changed

- `DispatchSchedule.jump_table` replaces `Dispatch.createJumpTable` and `DispatchSchedule.jumpdests`.
- `GrowingArenaAllocator.resetRetainCapacity` returns `void`: it can no longer fail.
- `Database.storage_slot_counts` is gone; use `Database.storage.nonZeroCount(address)`.
- `CallResult.accessed_addresses` lists the fork's precompiles first.

### Fixed

- `verify/smt/run_smt_suite.py` parses the multi-line `LOG0..LOG4` table entry; its opcode audit
  failed on it and the suite exited 1.

## [0.1.1] - 2026-11-27

### Fixed
- Resolved Wave 1 consensus, safety, and C ABI hardening items (EIP-161 state clearing, EIP-3607 transaction admission, thread-safe C FFI handle borrow registry, and expanded SMT/fuzz coverage).
- Updated C SDK `test_basic_call` to originate top-level calls from an EOA while asserting EIP-3607 rejection when the caller holds deployed bytecode.
- Enabled npm OIDC Trusted Publishing (Node 24 / npm 11+) for `@tevm/guillotine` with Sigstore provenance.
## [0.1.0] - 2026-11-25

First tagged release: the Zig package, the C FFI shared libraries, the
`@tevm/guillotine` Bun FFI SDK, and the `guillotine.tevm.sh` documentation site.

### Highlights

| Area | Result |
| --- | --- |
| Toolchain | Stock Zig 0.17.1 with native `preserve_none` tail-call dispatch. No compiler fork is required. |
| Official EEST state tests | 66,652 / 66,652 (100.00%) across all 14 mainnet hardforks, Frontier through Osaka, with fusions on and with fusions off |
| Lean 4 differential fuzzing | 116,384 / 116,384 (100.00%) Zig-to-Lean 4.32.0 vectors |
| SMT proofs | 32 / 32 theorems proved |
| `contract/snailtracer` (x86_64 Linux) | 37.86 ms (6.21 GGas/s), 1.25x faster than revm (47.21 ms) |
| Precompiles | ECRECOVER 0.171 ms (182x faster), MODEXP-256 2.82 µs, BN254-mul 8.16 µs |
| Layer 2 | Full Base L2 / OP Stack, Bedrock through Jovian (pre-Azul), on the real EVM engine |
| SDKs | Zig package (`dep.module("evm")`), C FFI (`libguillotine_ffi` + `guillotine.h`), TypeScript Bun FFI (`@tevm/guillotine`, 340 / 340 tests), and the Custom SDK Builder skill |

### Release assets

| Asset | Contents |
| --- | --- |
| `libguillotine_ffi.so` | C FFI shared library, Linux x86_64, glibc >= 2.28 |
| `libguillotine_ffi.dylib` | C FFI shared library, macOS arm64 |
| `guillotine.h` | C header |
| `SHA256SUMS.txt` | SHA-256 checksums of the files above |

The static archive (`zig build static`) is not shipped: it does not bundle
`libblst`, `libcrypto_wrappers` or `libckzg`, so it cannot be linked alone.

### Added

- **Zig package.** `build.zig` exports the public modules `evm`, `voltaire` and
  `layer2` with `b.addModule`. Consumers run
  `zig fetch --save=guillotine https://github.com/evmts/guillotine/archive/refs/tags/v0.1.0.tar.gz`
  and import `guillotine.module("evm")`.
- **Official EEST state test runner.** `specs/eest_runner.zig` and
  `zig build state-tests` run the pre-filled `tests@v21.0.3` fixtures, which
  `scripts/fetch-eest-fixtures.sh` downloads and checks against a pinned
  SHA-256. CI asserts 66,652 / 66,652 with fusions on and off.
- **Formal verification.** `zig build verify` runs LLVM IR checks, SMT-LIB2
  proofs (`verify/smt`) and an executable Lean 4 reference EVM and Layer 2 spec
  (`verify/lean`). `zig build test-lean-diff` fuzzes Zig against Lean.
- **Base L2 / OP Stack.** `src/layer2/` implements fee, deposit and precompile
  rules for Bedrock through Jovian, and `src/layer2/evm_host.zig` executes them
  on the real `Evm` engine. Run `zig build test-layer2`.
- **Prague and Osaka.** `P256VERIFY` at `0x100` (EIP-7951), `CLZ` (EIP-7939),
  EIP-2537 BLS12-381 addresses, EIP-2935 history storage, EIP-7623 calldata
  pricing, EIP-7702 delegation, EIP-7610 collision checks, and the Osaka
  ModExp limits and pricing (EIP-7823, EIP-7883).
- **C FFI and TypeScript SDK.** `libguillotine_ffi` (`zig build shared`) with
  the header `sdks/c/include/guillotine.h`, and `@tevm/guillotine`
  (`sdks/typescript/`), a Bun FFI package with `darwin-arm64` and `linux-x64`
  prebuilds.
- **Custom SDK Builder skill.** `.agents/skills/guillotine-sdk-builder/SKILL.md`
  and `docs/building-custom-sdks.md` generate bindings for other languages over
  the C ABI.
- **In-repo benchmarks.** `zig build bench` runs a self-contained ReleaseFast
  suite of opcodes, contracts (including snailtracer) and precompiles.
- **Native ARM64 JIT library.** `src/jit/` compiles side-effect-free EVM
  bytecode to AArch64 machine code with a bounded LRU `JitCache`. It depends
  only on Zig `std` and is not wired into `Evm`. Run `zig build test-jit`.
- **Fuzzing.** `zig build test-fuzz` runs the Zig fuzz corpus and
  `zig build fuzz-campaign -Doptimize=ReleaseSafe -- --seconds=N --threads=M`
  runs a multi-threaded cross-subsystem campaign.
- **Release workflow.** `.github/workflows/release.yml` builds the shared
  libraries on macOS arm64 and Linux x86_64 (`-Dtarget=x86_64-linux-gnu.2.28`),
  runs the C and TypeScript SDK tests against them, publishes the GitHub
  Release with `SHA256SUMS.txt`, and publishes `@tevm/guillotine` to npm with
  provenance once the `NPM_TOKEN` secret exists. Every job requests
  least-privilege permissions.

### Changed

- **Toolchain.** Upgraded to stock Zig 0.17.1. Handlers use the native
  `preserve_none` calling convention for register-passing tail-call dispatch.
- **Dispatch.** 8-byte `Dispatch.Item`, inline `PUSH9`-`PUSH32`, an EVM-lifetime
  `DispatchCache`, and removal of 13 dead fusions.
- **Performance.** A rewritten ECRECOVER (182x faster), SIMD calldata token
  counting, faster MODEXP and BN254, O(1) journal revert and O(1) database
  snapshots.
- **`DatabaseProxy` (#630).** Replaced `static_wrappers` with a comptime
  `DatabaseProxy` supporting `pass_through`, `static` and `lru` modes.
- **Named limits (#843).** Replaced EVM limit and gas literals with named
  constants.
- **`zig build test`** now runs the unit, opcode, integration, Layer 2,
  precompile, fusion, ModExp and fuzz suites.
- **CI.** Linux runs `test-integration` and a 5-second `fuzz-campaign`; macOS
  arm64 runs `test-jit`. Workflow inputs reach shell scripts only through `env:`.

### Removed

- **The duplicated `mini/` tree** and `docs/mini/`, with the `test-mini*` build
  steps. MinimalEvm, the in-repo reference interpreter, lives in
  `src/tracer/minimal_evm.zig`. The standalone readable reference EVM is the
  separate repository [`evmts/guillotine-mini`](https://github.com/evmts/guillotine-mini).
- Unreferenced Zig files and commented-out build steps.

### Fixed

- Every crash found by the EEST and Lean differential runs, including
  SIGSEGVs in the EEST suite and an overflow crash found by Lean fuzzing.
- EIP-2200 `SSTORE` gas, the cold `SSTORE` surcharge, truncated `PUSH`
  immediates, EIP-3860 `CREATE` limits, `CREATE`/`CREATE2` nonces, EIP-161,
  EIP-6780, EIP-7623, EIP-7702 and `PREVRANDAO`.
- BLAKE2F, BN254, BLS12-381 and EIP-4844 precompile results.
- `EXTCODEHASH` denial of service and MinimalFrame parity with the dispatch
  engine.
- C FFI handle, leak and isolation bugs; handles are now monotonic.
- A 4.4 GB frame-stack leak (`FrameStackPool`), KZG initialization on Cancun
  and later, and host-failure atomicity.
- Fresh-clone builds: `zig build` now builds Voltaire's Rust archive itself on
  macOS and Linux.

[Unreleased]: https://github.com/evmts/guillotine/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/evmts/guillotine/releases/tag/v0.1.0
