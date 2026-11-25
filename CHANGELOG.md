# Changelog

All notable changes to Guillotine will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0-alpha.1] - 2026-11-25

First alpha release preparing the Zig package, native C FFI libraries, `@tevm/guillotine` Bun FFI SDK, and `guillotine.tevm.sh` documentation site.

### Added

- **Native ARM64 JIT Tier (opt-in)**: Zero-dependency ARM64 direct JIT (`src/jit/`, `src/jit_bridge.zig`), gated behind `EvmConfig.enable_native_jit` (default `false`).
- **Incremental Smithers Benchmark DAG (#867)**: 16 benchmark suites (119 benchmarks) across 10 subsystem `PACKAGE.ts` declarations (`src/{stack,memory,bytecode,layer2,provider,storage,trie,eips_and_hardforks,tracer,preprocessor}/PACKAGE.ts`), 13 standalone `ReleaseFast` micro-benchmark suites (`bench/suites/*_bench.zig`), shared harness/reporter/baseline (`bench/micro.zig`, `bench/summary.mjs`, `bench/baseline.json`), and expanded `bench/workloads.zig` (40 opcodes, 9 contracts including `snailtracer`, 7 active precompiles) runnable via `zig build bench` and `smthrs test //bench:report`.
- **Prague & Osaka Hardfork Support**:
  - Wired `P256VERIFY` precompile at `0x100`, EIP-2935 mainnet history storage address and O(1) 256-slot `BLOCKHASH` ring buffer, EIP-2537 BLS12-381 precompile addresses, EIP-7610 nonempty-storage `CREATE`/`CREATE2` collision checks (`Database.has_storage`), and Layer 2 (Base & OP Stack) wiring (`zig build test-layer2`).
- **Official EEST State Test Runner**: Added pre-filled Ethereum Execution Spec Tests (EEST) runner (`specs/eest_runner.zig`, `zig build state-tests`) spanning Frontier through Osaka.
- **C FFI & `@tevm/guillotine` TypeScript (Bun FFI) SDK**:
  - Native shared (`libguillotine_ffi`) and static (`libguillotine_ffi_static`) libraries (`zig build shared`, `zig build static`) with C ABI header `sdks/c/include/guillotine.h`.
  - `@tevm/guillotine` TypeScript package (`sdks/typescript/`) over Bun FFI with multi-platform `prebuilds/<platform>-<arch>/` resolution and `GUILLOTINE_SKIP_NATIVE_BUILD=1` CI publish support.
- **Release & Publishing Infrastructure**:
  - Added `.github/workflows/release.yml` to build cross-platform `ReleaseFast` C FFI libraries (`darwin-arm64` and `linux-x64`), publish `@tevm/guillotine` to npm with provenance, and publish GitHub Releases with C FFI tarballs, `guillotine.h`, and `SHA256SUMS.txt`.
  - Added `scripts/release.sh` for semver validation, version syncing (`build.zig.zon`, `sdks/typescript/package.json`), `CHANGELOG.md` verification, and local preflight checks.
- **Documentation Site (`docs/`)**: Vocs documentation site for `guillotine.tevm.sh` covering architecture, execution models, hardforks, gas metering, state management, testing, benchmarks/JIT, and publishing.

### Performance

- **4.63x–7.46x geomean speedup across the Osaka benchmark suite** and **42.95 ms (5.48 Ggas/s)** on `snailtracer` under Prague with zero gas mismatches:
  - **Dispatch & Interpreter**: 8-byte untagged `Dispatch.Item` in `ReleaseFast`/`ReleaseSmall`, single-pass pre-sized `DispatchSchedule`, O(1) dense `JumpTable` with single-pass `packed_bitmap` and branchless binary search (`2.14x`), EVM-lifetime `AnalysisCache` / bounded `dispatch_cache`, per-depth pooled `Stack`/`Memory` with inline `MLOAD`/`MSTORE`/`MSTORE8` fast paths and zero-alloc `MCOPY`, cached quadratic memory gas, inline shallow calls eliminating per-call 64 MiB OS thread spawn (stack-hop only at deep recursion), full-word big-endian `CALLDATALOAD`, direct `EXTCODEHASH`, single-reduction `ADDMOD`/`MULMOD`, closed-form `EXP`, and fast untraced bytecode analysis (`4.5x–8.76x`).
  - **Cryptography & BigInt**: `std.crypto.ecc.Secp256k1` / Pseudo-Mersenne + Jacobian + Shamir `ECRECOVER` (**90.85x–153.66x** speedup), Knuth Algorithm D 256-bit division, adaptive Montgomery `MODEXP` with 4-bit sliding windows and even-modulus CRT, and BN254 multi-Miller loop + GLV G1 scalar multiplication.
  - **State, Gas & Layer 2**: O(1) append-only undo-log `Database` snapshots (**6.92x** `db-snapshot-revert`), O(1) `Journal` original-storage index, fold-hash + SplitMix64 `AccessList`/`Database`, 32-byte SIMD `tokens_in_calldata` (**31.78x**), O(1) `is_eip_active` (**36.01x**), sparse-reset `FastLZ` (**5.78x** on 68B payloads), and binary `[32]u8` trie node keys.

### Changed

- **DatabaseProxy Refactor (#630)**: Replaced value-copied `StaticDatabase` with comptime-parameterized `DatabaseProxy(mode, DatabaseType)` supporting `pass_through`, `static` (EIP-214 write rejection), and `lru` (atomic `flush()`) modes.
- **Frame & Dispatch Cleanup**: Decoupled `Frame` from `DefaultEvm` (#852), extracted `dispatch_next.zig` and shared address conversion helpers, replaced magic EVM limit and gas literals with named constants (#843), and standardized vendored `voltaire` dependency naming and commit-pinned Zig dependencies (`zbench`, `clap`).
- **Repository & Docs Alignment**: Aligned `README.md`, `CLAUDE.md`, `CONTRIBUTING.md`, `docs/`, `specs/README.md`, and `sdks/README.md` with actual `main` build steps, Zig 0.15.1+/0.15.2 toolchain requirements, and `EvmConfig` APIs; removed the duplicated `mini/` directory (maintained in its own repository `evmts/guillotine-mini`), 22 dead unreferenced Zig files, and stale build steps.

### Fixed

- **Consensus & EVM Execution**:
  - Enforced EIP-214 `WriteProtection` on `SSTORE`, `TSTORE`, `CREATE`, and `CREATE2` in static contexts.
  - Fixed `CALL`/`CALLCODE`/`DELEGATECALL`/`STATICCALL` (#842): cap `gas_param > maxInt(u64)`, skip memory checks on zero-length ranges, and return `OutOfGas` consistently on memory overflow; allowed 0-gas calls to empty accounts/EOAs.
  - Fixed `LOG0`–`LOG4`, `RETURN`, `REVERT`, `CODECOPY`, and `KECCAK256` zero-length offset handling and checked overflow guards preventing panics/crashes on extreme offsets.
  - Fixed `CREATE`/`CREATE2`: pass actual `caller` and `value` into `execute_init_code` (fixing `CALLER`/`CALLVALUE` in constructors), initialize `nonce = 1` before initcode on Spurious Dragon+ (EIP-161), populate `created_address`, preserve `REVERT` return data per EIP-211/EIP-140 (while clearing on success/exceptional failure), fix out-of-gas halting when opcode gas is unpayable, and fix EIP-7610 nonempty-storage collision detection.
  - Fixed call-depth off-by-one (`call_stack` sized to `max_call_depth + 1`, check `self.depth > config.max_call_depth`) so Yellow Paper depth 1024 executes and depth-exceeded `CREATE`/`CREATE2` refunds gas remaining after upfront creation charges.
  - Fixed `SELFDESTRUCT` EIP-2929 cold beneficiary (`2600`) and EIP-150/161 new-account (`25000`) dynamic gas (synced in `MinimalFrame`), immediate balance transfer/self-burn, and end-of-tx storage clearing and account deletion per EIP-6780.
  - Implemented Yellow Paper Section 9.4.1 right-zero-padding for truncated `PUSH1`–`PUSH32` immediates at EOF in `src/bytecode/bytecode.zig`.
  - Fixed `ECRECOVER` to return empty output on failure, enforce full-word `v ∈ {27, 28}`, and accept high `s` values (EIP-2 applies to transactions only).
  - Fixed `RETURNDATACOPY` u256 `offset + size` overflow panic.
  - Fixed `CALL`/`CALLCODE` insufficient-balance and max-depth sub-call gas refunds.
  - Unified `FrameCheckpoint` and `revertFrame()` rollback across logs, refunds, access lists, self-destructs, created contracts, and failed precompile value transfers; removed silent error swallowing.
  - Fixed `encode_account` RLP buffer overrun for single-byte values `>= 0x80` and native-endian nonce trimming that produced non-canonical state roots; fixed EIP-7702 `clear_delegation` empty-code behavior.
  - Fixed EIP-197 BN254 G2 `(c1, c0)` byte ordering, unblocking `BN254-pairing`, and aligned BLS12-381 `map-G1` address (`0x10`).
  - Fixed `MainnetEvmWithTracer` `ReleaseFast` tracing (`enable_tracer` config flag, skipping internal `BLOCK_BEGIN` steps, disabling validation trap on nested calls) so all 321 `@tevm/guillotine` TypeScript SDK tests pass.
  - Fixed `MinimalEvm` `SELFDESTRUCT` (#850), overlay checks in `account_exists`/`get_balance`/`get_nonce`/`get_code_hash`, and differential test memory safety (use-after-free and cleanup leaks).
  - Removed all non-platform-guard `error.SkipZigTest` stubs (#696) and replaced them with active unit/integration tests.
- **Spec Runner**: Fixed Prague execution under uncapped block gas limits and loop quota, secp256k1 sender derivation from `secretKey`, expectation index & Prague network filtering, JSON `//` comment skipping, EIP-7702 `authorizationList` processing, and LLL compilation (`def`/`for`/`while`/`if`/`when`/`unless`, `(lll ...)` meta-compilation, statement `POP`s, trailing `STOP`) in `specs/lll.zig` and `specs/assembler.zig` — bringing `zig build specs` from 1,031 failures → 581 → **38 failures (2,213 / 2,251 passing = 98.31%, 100% of `eest/prague`)**.
- **Fresh-Clone Builds & CI (#862, #863)**:
  - Fixed Voltaire `libcrypto_wrappers.a` build ordering via a generated `LazyPath` and explicit `--target-dir` so `zig build` succeeds from a fresh clone on macOS and Linux without a separate prebuild step; added regression test `.smithers/tests/voltaire-archive.test.mjs`.
  - Added macOS SDK probe in CI so Zig 0.15.2 links cleanly on `macos-26` GitHub Actions runners (avoiding arm64e-only SDK stubs).
  - Removed parallel `./build.sh` race in `lib/voltaire/lib/blst.zig` and fixed missing `errdefer` leak in `dispatch.zig`.

[Unreleased]: https://github.com/evmts/guillotine/compare/v0.1.0-alpha.1...HEAD
[0.1.0-alpha.1]: https://github.com/evmts/guillotine/releases/tag/v0.1.0-alpha.1
