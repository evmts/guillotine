# Cross-EVM Apples-to-Apples Benchmarks

Reproducible, in-process cross-EVM benchmark harness comparing **Guillotine** against the fastest modern EVM implementations, including the revm/alloy team's new **`alloy-rs/evm2`**, **`bluealloy/revm`**, **`ipsilon/evmone`** (Advanced & Baseline), **`lambdaclass/ethrex` (LEVM)**, **`Giulio2002/gevm`**, **`ethereum/go-ethereum` (geth)**, and the native JIT tier (**Guillotine ARM64 JIT**, **`evm2-jit`**, **`revmc`**).

## Design Principles for Legitimacy

1. **Zero CLI startup overhead:** Every engine runs **in-process** with a high-resolution monotonic clock wrapping only the EVM transaction execution. No `hyperfine` per-tx process-spawn inflation.
2. **Non-cherry-picked public fixtures:** 21 of 25 workloads are pulled verbatim from [`alloy-rs/evm2`](https://github.com/alloy-rs/evm2) (`data/*.json`, pinned SHA in `versions.json`), spanning classic compute benchmarks (`snailtracer`, `erc20_transfer`, `hash_10k`, `fibonacci`, `factorial`, `bswap64`, `counter`), real Mainnet DeFi contracts (`weth`, `usdc_proxy`, `fiat_token`, `uniswap_v2_pair`, `uniswap_v3_pool`, `seaport`, `curve_stableswap`, `burntpix`, `push0_proxy`), and precompiles (`ecrecover`, `sha256`, `modexp`, `bn254_pairing`, `bls12_381`), plus 4 targeted hot-loop workloads (`loop_arithmetic`, `loop_memory`, `loop_storage`, `loop_staticcall`).
3. **0-tolerance differential verification gate:** Every timed sample on every engine is verified against canonical consensus for `success == true`, **exact `gas_used`** (0-gas tolerance), and **byte-for-byte `output_hex`** (where exposed). Any engine that diverges or fails on a workload is explicitly marked `MISMATCH` / `FAILED`, excluded from geometric means, and reported in the audit table.
4. **Warm vs. Cold separation:**
   - **Warm steady-state:** Bytecode is pre-loaded/analyzed where supported; every measured transaction starts from an identical clean pre-state snapshot (zero state accumulation).
   - **Cold first-run:** Every sample starts from a fresh EVM instance with raw unanalyzed bytecode (empty dispatch/jumpdest caches), fairly capturing upfront analysis cost on short-lived contracts such as Seaport.
5. **Strict tier separation for JIT compilers:** Native compilers (`guillotine-jit`, `evm2-jit`, `revmc`) are reported in their own Tier 2 table showing **both** one-time compile time and warm execution time, and explicitly flagging when a JIT falls back to its interpreter.
6. **Comparable native compiler optimization:** Zig (`-OReleaseFast`, native CPU), Rust (`opt-level=3`, `lto=thin`, `codegen-units=1`, `panic=abort`, `-C target-cpu=native`), C++ `evmone` (`-O3 -mcpu=native` + libsecp256k1), Go (`go build`).
7. **Geometric means, not arithmetic averages:** Category and overall speedups use the geometric mean of per-workload ratios so one long-running workload (`snailtracer`) cannot dominate the aggregate score.

## Quick Start

From the repository root:

```sh
# 1. Fetch canonical workloads & build all engine binaries
chmod +x bench/compare/build-all.sh
./bench/compare/build-all.sh

# 2. Run the full suite (warm + cold + jit) sequentially on an idle machine
node bench/compare/run.mjs

# 3. Filter to a subset or single mode
node bench/compare/run.mjs --filter snailtracer --modes warm,jit
node bench/compare/run.mjs --modes warm --engines guillotine,evm2,revm,evmone-advanced
```

Outputs are written to:
- `bench/compare/results/latest.json` — full machine-readable dataset (including raw per-sample timings and environment provenance; gitignored)
- `bench/compare/RESULTS.md` — Markdown comparison tables and differential verification audit
- `bench/compare/report.html` — self-contained interactive HTML report

## Notes on Platform & Engine Specifics

- **`category-labs/monad`:** Explicitly requires Linux, `libstdc++`, and `-march=x86-64-v3`, so it cannot run natively on Apple Silicon macOS.
- **`evmone`:** `evmone::state::TransactionReceipt` does not expose top-level return data bytes on the receipt struct, so `evmone` is verified on `EVMC_SUCCESS` and exact `gas_used`. `evmone` also performs single-pass analysis per `evmc_execute` call without cross-call caching.
- **Guillotine JIT (`enable_native_jit = true`):** Zero-dependency ARM64 direct emitter (`src/jit/`) that compiles only side-effect-free pure-compute contracts and transparently falls back to the dispatch-schedule interpreter for stateful contracts.
