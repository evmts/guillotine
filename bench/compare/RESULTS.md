# Guillotine Cross-EVM Benchmark Report

**Generated:** 2026-11-26T08:26:24.421Z  
**Hardware:** Apple M3 Max (16 cores, 64 GB RAM), Darwin 25.2.0 (arm64)  
**Guillotine commit:** `c61c6e3144ff`  
**Compilers:** Zig `0.15.2` · Rust `rustc 1.100.0 (0ef1bc386 2026-11-09)` · C++ `Apple clang version 17.0.0 (clang-1700.6.4.2)` · Go `go version go1.26.0 darwin/arm64` · LLVM `23.1.6` (evm2-jit) / `22.1.8` (revmc)

> **Methodology & Fairness Guarantee:** All engines run **in-process** with zero CLI startup overhead, strictly sequentially on the same machine, against the **exact same canonical JSON workloads** (21 fixtures verbatim from `alloy-rs/evm2@e80df9c46a82` + 4 targeted hot-loop workloads). Gas accounting is **enabled** and tracing is **disabled** for every engine. Every timed sample must pass a **0-tolerance differential verification gate** (`success == true`, exact `gas_used` match, byte-for-byte `output` match). Any mismatched cell is disqualified (`MISMATCH`) rather than reported.

## Pinned Engine Versions

| Engine | Language | Tier | Source / Pinned Revision | Build Flags |
| :--- | :--- | :--- | :--- | :--- |
| **Guillotine** (`guillotine`) | Zig | interpreter | local (evmts/guillotine) @ `c61c6e3144ff` | -OReleaseFast (native CPU, LLVM backend) |
| **Guillotine (no fusion)** (`guillotine-nofusion`) | Zig | interpreter | local (evmts/guillotine) @ `c61c6e3144ff` | -OReleaseFast (native CPU, LLVM backend) |
| **Guillotine JIT** (`guillotine-jit`) | Zig | jit | local (evmts/guillotine) @ `c61c6e3144ff` | -OReleaseFast (native CPU, LLVM backend) |
| **evm2** (`evm2`) | Rust | interpreter | https://github.com/alloy-rs/evm2 @ `e80df9c46a82` | opt-level=3, lto=thin, codegen-units=1, panic=abort, RUSTFLAGS='-C target-cpu=native' |
| **evm2 JIT** (`evm2-jit`) | Rust | jit | https://github.com/alloy-rs/evm2 @ `e80df9c46a82` | opt-level=3, lto=thin, codegen-units=1, panic=abort, RUSTFLAGS='-C target-cpu=native' |
| **revm** (`revm`) | Rust | interpreter | https://github.com/bluealloy/revm @ `61eb0f231227` | opt-level=3, lto=thin, codegen-units=1, panic=abort, RUSTFLAGS='-C target-cpu=native' |
| **revmc** (`revmc`) | Rust | jit | https://github.com/paradigmxyz/revmc @ `6860b6f7bbda` | opt-level=3, lto=thin, codegen-units=1, panic=abort, RUSTFLAGS='-C target-cpu=native' |
| **evmone (Advanced)** (`evmone-advanced`) | C++ | interpreter | https://github.com/ipsilon/evmone @ `ba22a659174e` (v0.25.0) | -DCMAKE_BUILD_TYPE=Release -O3 -mcpu=native -DEVMONE_PRECOMPILES_LIBSECP256K1=ON |
| **evmone (Baseline)** (`evmone-baseline`) | C++ | interpreter | https://github.com/ipsilon/evmone @ `ba22a659174e` (v0.25.0) | -DCMAKE_BUILD_TYPE=Release -O3 -mcpu=native -DEVMONE_PRECOMPILES_LIBSECP256K1=ON |
| **ethrex (LEVM)** (`ethrex-levm`) | Rust | interpreter | https://github.com/lambdaclass/ethrex @ `fc7d69250d1a` | opt-level=3, lto=thin, codegen-units=1, panic=abort, RUSTFLAGS='-C target-cpu=native' |
| **gevm** (`gevm`) | Go | interpreter | https://github.com/Giulio2002/gevm @ `42d4e2f3f205` | go build (default optimized Go 1.26) |
| **geth** (`geth`) | Go | interpreter | https://github.com/ethereum/go-ethereum @ `bbafd66b66f5` | go build (default optimized Go 1.26) |

## 1. Headline Summary — Warm Steady-State Interpreters (Geometric Mean Speedup)

Higher is faster (`> 1.00×` means faster than baseline). Only workloads passing the 0-tolerance gas + output verification gate on **both** the engine and baseline are included.

| Engine | Lang | Overall vs `revm` | Overall vs `evm2` | Classic (7) vs `revm` | Mainnet DeFi (9) vs `revm` | Precompiles (5) vs `revm` | Hot-Loops (4) vs `revm` |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| **evm2** | Rust | **1.13×** (25) | 1.00× | 1.09× | 1.01× | 1.33× | 1.25× |
| **revm** | Rust | **1.00×** (25) | 0.89× | 1.00× | 1.00× | 1.00× | 1.00× |
| **gevm** | Go | **0.98×** (25) | 0.87× | 0.93× | 1.02× | 1.14× | 0.80× |
| **ethrex (LEVM)** | Rust | **0.78×** (25) | 0.69× | 0.80× | 0.70× | 0.88× | 0.81× |
| **evmone (Baseline)** | C++ | **0.77×** (25) | 0.68× | 0.94× | 0.45× | 1.11× | 1.13× |
| **evmone (Advanced)** | C++ | **0.50×** (25) | 0.45× | 0.77× | 0.18× | 1.11× | 0.87× |
| **geth** | Go | **0.32×** (25) | 0.29× | 0.37× | 0.17× | 0.70× | 0.42× |
| **Guillotine** | Zig | **0.30×** (24) | 0.27× | 0.47× | 0.13× | 0.30× | 0.94× |
| **Guillotine (no fusion)** | Zig | **0.30×** (24) | 0.26× | 0.46× | 0.13× | 0.30× | 0.90× |

## 2. Warm Steady-State Latency (Interpreters, Median per TX)

Bytecode pre-loaded/analyzed where supported; fresh clean state snapshot per transaction (no state accumulation). Lower is faster. Fastest verified interpreter per row is **bold**.

| Workload | Cat | Fork | Gas | Guillotine | evm2 | revm | evmone (Advanced) | evmone (Baseline) | ethrex (LEVM) | gevm | geth | Guillotine vs `revm` | Guillotine vs `evm2` |
| :--- | :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `snailtracer` | classic | CANCUN | 205,087,902 | **57.05 ms** | 65.16 ms | 82.38 ms | 106.86 ms | 75.27 ms | 81.47 ms | 92.82 ms | 140.88 ms | 1.44× | 1.14× |
| `erc20_transfer` | classic | OSAKA | 13,529,850 | 5.49 ms | **5.26 ms** | 5.84 ms | 10.18 ms | 9.96 ms | 7.69 ms | 7.32 ms | 15.51 ms | 1.06× | 0.96× |
| `hash_10k` | classic | OSAKA | 2,572,907 | **3.04 ms** | 3.05 ms | 3.32 ms | 3.15 ms | 3.40 ms | 3.83 ms | 3.94 ms | 7.51 ms | 1.09× | 1.00× |
| `fibonacci` | classic | OSAKA | 84,203 | **47.46 µs** | 51.04 µs | 56.67 µs | 54.04 µs | 55.46 µs | 58.79 µs | 59.96 µs | 91.83 µs | 1.19× | 1.08× |
| `factorial` | classic | OSAKA | 87,203 | 50.98 µs | **49.29 µs** | 57.96 µs | 52.63 µs | 55.63 µs | 60.54 µs | 63.00 µs | 90.92 µs | 1.14× | 0.97× |
| `bswap64` | classic | OSAKA | 21,986 | 32.08 µs | **1.63 µs** | 1.79 µs | 3.00 µs | 1.83 µs | 2.60 µs | 1.71 µs | 8.54 µs | 0.06× | 0.05× |
| `counter` | classic | OSAKA | 43,363 | 29.88 µs | 1.42 µs | 1.17 µs | 2.33 µs | 1.21 µs | 2.38 µs | **1.04 µs** | 9.19 µs | 0.04× | 0.05× |
| `weth` | mainnet | OSAKA | 51,318 | 30.96 µs | **2.83 µs** | 3.00 µs | 10.88 µs | 5.17 µs | 4.38 µs | 2.94 µs | 14.08 µs | 0.10× | 0.09× |
| `usdc_proxy` | mainnet | OSAKA | 25,644 | 30.73 µs | 1.63 µs | 1.50 µs | 7.00 µs | 2.21 µs | 2.79 µs | **1.38 µs** | 12.15 µs | 0.05× | 0.05× |
| `fiat_token` | mainnet | OSAKA | 23,445 | 30.77 µs | 1.50 µs | 1.29 µs | 42.38 µs | 12.46 µs | 2.21 µs | **1.08 µs** | 21.67 µs | 0.04× | 0.05× |
| `uniswap_v2_pair` | mainnet | OSAKA | 23,568 | 30.54 µs | 1.63 µs | 1.46 µs | 23.96 µs | 6.71 µs | 2.29 µs | **1.29 µs** | 14.58 µs | 0.05× | 0.05× |
| `uniswap_v3_pool` | mainnet | OSAKA | 79,765 | 54.33 µs | **16.92 µs** | 19.46 µs | 93.42 µs | 33.46 µs | 22.00 µs | 23.50 µs | 71.15 µs | 0.36× | 0.31× |
| `seaport` | mainnet | OSAKA | 24,051 | 32.71 µs | 1.67 µs | 1.58 µs | 72.25 µs | 15.67 µs | 2.50 µs | **1.50 µs** | 25.21 µs | 0.05× | 0.05× |
| `curve_stableswap` | mainnet | CANCUN | 157,780 | 87.75 µs | **84.21 µs** | 97.58 µs | 135.63 µs | 93.04 µs | 100.73 µs | 109.17 µs | 175.13 µs | 1.11× | 0.96× |
| `burntpix` | mainnet | CANCUN | 92,399,448 | **50.56 ms** | 56.12 ms | 66.93 ms | 82.43 ms | 66.27 ms | 68.24 ms | 77.10 ms | 121.07 ms | 1.32× | 1.11× |
| `push0_proxy` | mainnet | OSAKA | 23,652 | 25.04 µs | 1.29 µs | 1.21 µs | 1.54 µs | **833 ns** | 2.17 µs | 1.00 µs | 8.67 µs | 0.05× | 0.05× |
| `precompile_ecrecover` | precompile | OSAKA | 25,676 | 215.33 µs | 30.33 µs | 30.46 µs | **30.04 µs** | 30.13 µs | 31.29 µs | 30.17 µs | 35.79 µs | 0.14× | 0.14× |
| `precompile_sha256` | precompile | OSAKA | 61,900 | 25.67 µs | **1.29 µs** | 1.75 µs | 1.42 µs | 1.42 µs | 5.25 µs | 1.58 µs | 6.79 µs | 0.07× | 0.05× |
| `precompile_modexp` | precompile | OSAKA | 3,699,628 | 1.87 ms | **1.05 ms** | 2.42 ms | 1.57 ms | 1.57 ms | 1.55 ms | 1.60 ms | 1.60 ms | 1.30× | 0.56× |
| `precompile_bn254_pairing` | precompile | OSAKA | 140,120 | 1.25 ms | **627.88 µs** | 790.69 µs | 973.67 µs | 970.48 µs | 657.17 µs | 807.94 µs | 840.85 µs | 0.63× | 0.50× |
| `precompile_bls12_381` | precompile | OSAKA | 29,320 | MISMATCH | 4.79 µs | 5.00 µs | 4.67 µs | 4.67 µs | 5.71 µs | **4.29 µs** | 9.42 µs | — | — |
| `loop_arithmetic` | opcode | OSAKA | 154,141 | 164.29 µs | **135.40 µs** | 177.04 µs | 138.73 µs | 147.38 µs | 214.79 µs | 202.83 µs | 265.90 µs | 1.08× | 0.82× |
| `loop_memory` | opcode | OSAKA | 143,910 | **76.29 µs** | 111.94 µs | 132.69 µs | 108.25 µs | 135.17 µs | 125.10 µs | 170.60 µs | 284.90 µs | 1.74× | 1.47× |
| `loop_storage` | opcode | OSAKA | 427,409 | 164.63 µs | 72.17 µs | 82.48 µs | 76.73 µs | **71.54 µs** | 103.67 µs | 86.56 µs | 401.69 µs | 0.50× | 0.44× |
| `loop_staticcall` | opcode | OSAKA | 68,576 | 95.54 µs | **56.58 µs** | 79.19 µs | 232.60 µs | 66.23 µs | 125.73 µs | 123.65 µs | 168.62 µs | 0.83× | 0.59× |

## 3. Cold First-Run Latency (Includes Bytecode Analysis + EVM Init)

Every sample constructs a fresh EVM with unanalyzed raw bytecode (empty dispatch/jumpdest cache), fairly measuring single-shot / cold-contract cost.

| Engine | Overall Cold vs `revm` | Overall Cold vs `evm2` | Classic | Mainnet DeFi | Precompiles | Hot-Loops |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| **gevm** | **1.36×** | 1.10× | 1.21× | 1.98× | 1.26× | 0.80× |
| **evm2** | **1.24×** | 1.00× | 1.28× | 1.16× | 1.40× | 1.17× |
| **revm** | **1.00×** | 0.81× | 1.00× | 1.00× | 1.00× | 1.00× |
| **evmone (Baseline)** | **0.90×** | 0.73× | 1.01× | 0.69× | 1.08× | 1.07× |
| **evmone (Advanced)** | **0.65×** | 0.53× | 0.91× | 0.34× | 1.08× | 0.85× |
| **ethrex (LEVM)** | **0.46×** | 0.37× | 0.76× | 0.18× | 0.93× | 0.69× |
| **geth** | **0.35×** | 0.28× | 0.40× | 0.22× | 0.63× | 0.38× |
| **Guillotine** | **0.24×** | 0.19× | 0.48× | 0.07× | 0.28× | 0.75× |
| **Guillotine (no fusion)** | **0.24×** | 0.19× | 0.46× | 0.08× | 0.28× | 0.74× |

| Workload | Cat | Guillotine | evm2 | revm | evmone (Advanced) | evmone (Baseline) | ethrex (LEVM) | gevm | geth |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `snailtracer` | classic | **61.62 ms** | 68.39 ms | 83.69 ms | 100.44 ms | 72.13 ms | 81.03 ms | 91.90 ms | 139.45 ms |
| `erc20_transfer` | classic | 5.70 ms | **5.27 ms** | 6.31 ms | 9.95 ms | 9.50 ms | 7.29 ms | 7.00 ms | 15.58 ms |
| `hash_10k` | classic | **3.08 ms** | 3.27 ms | 5.40 ms | 3.67 ms | 3.46 ms | 4.45 ms | 4.37 ms | 8.52 ms |
| `fibonacci` | classic | 74.25 µs | **55.60 µs** | 64.04 µs | 59.38 µs | 61.50 µs | 65.13 µs | 65.04 µs | 104.85 µs |
| `factorial` | classic | 69.90 µs | 59.98 µs | 74.69 µs | **57.63 µs** | 62.48 µs | 67.79 µs | 68.75 µs | 109.35 µs |
| `bswap64` | classic | 57.83 µs | 2.25 µs | 3.04 µs | 4.29 µs | 3.50 µs | 8.21 µs | **1.92 µs** | 14.02 µs |
| `counter` | classic | 50.00 µs | 2.00 µs | 2.42 µs | 3.58 µs | 2.88 µs | 6.92 µs | **1.13 µs** | 21.48 µs |
| `weth` | mainnet | 91.23 µs | 4.04 µs | 4.88 µs | 12.77 µs | 7.23 µs | 30.73 µs | **3.27 µs** | 26.96 µs |
| `usdc_proxy` | mainnet | 75.21 µs | 2.71 µs | 3.06 µs | 8.85 µs | 3.88 µs | 21.42 µs | **1.46 µs** | 25.17 µs |
| `fiat_token` | mainnet | 277.13 µs | 6.35 µs | 6.88 µs | 43.71 µs | 16.19 µs | 143.21 µs | **1.35 µs** | 34.52 µs |
| `uniswap_v2_pair` | mainnet | 165.19 µs | 4.04 µs | 4.71 µs | 27.17 µs | 8.85 µs | 73.85 µs | **1.60 µs** | 28.52 µs |
| `uniswap_v3_pool` | mainnet | 417.04 µs | 24.02 µs | 28.48 µs | 100.69 µs | 39.73 µs | 172.65 µs | **23.50 µs** | 97.98 µs |
| `seaport` | mainnet | 493.56 µs | 7.71 µs | 8.38 µs | 77.00 µs | 20.02 µs | 158.31 µs | **1.73 µs** | 49.63 µs |
| `curve_stableswap` | mainnet | 167.04 µs | **86.25 µs** | 102.42 µs | 144.19 µs | 96.60 µs | 158.00 µs | 110.94 µs | 211.58 µs |
| `burntpix` | mainnet | **55.76 ms** | 57.04 ms | 66.18 ms | 79.18 ms | 64.37 ms | 68.48 ms | 77.30 ms | 121.04 ms |
| `push0_proxy` | mainnet | 45.35 µs | 1.75 µs | 2.23 µs | 2.54 µs | 2.33 µs | 4.52 µs | **1.04 µs** | 15.48 µs |
| `precompile_ecrecover` | precompile | 230.02 µs | 30.92 µs | 31.42 µs | 31.13 µs | 31.23 µs | 32.48 µs | **30.25 µs** | 41.33 µs |
| `precompile_sha256` | precompile | 45.77 µs | 1.67 µs | 2.71 µs | 2.42 µs | 2.38 µs | 6.13 µs | **1.63 µs** | 10.67 µs |
| `precompile_modexp` | precompile | 1.89 ms | **1.05 ms** | 2.43 ms | 1.58 ms | 1.58 ms | 1.56 ms | 1.60 ms | 1.62 ms |
| `precompile_bn254_pairing` | precompile | 1.26 ms | **628.94 µs** | 782.35 µs | 972.17 µs | 983.25 µs | 649.38 µs | 890.10 µs | 962.90 µs |
| `precompile_bls12_381` | precompile | MISMATCH | 5.17 µs | 5.88 µs | 5.67 µs | 5.71 µs | 6.71 µs | **4.33 µs** | 13.71 µs |
| `loop_arithmetic` | opcode | 180.48 µs | 135.77 µs | 175.60 µs | **130.73 µs** | 139.83 µs | 200.31 µs | 182.69 µs | 259.73 µs |
| `loop_memory` | opcode | **95.08 µs** | 107.21 µs | 122.10 µs | 109.65 µs | 125.15 µs | 128.35 µs | 160.60 µs | 280.98 µs |
| `loop_storage` | opcode | 175.06 µs | **69.52 µs** | 71.31 µs | 71.42 µs | 71.54 µs | 144.23 µs | 78.56 µs | 455.96 µs |
| `loop_staticcall` | opcode | 113.44 µs | **58.56 µs** | 72.29 µs | 207.27 µs | 67.94 µs | 128.58 µs | 116.38 µs | 164.17 µs |

## 4. Tier 2 — JIT / Native Compilers (Compile Time + Warm Execution)

Reported strictly separately from interpreters. Shows **one-time compile cost** alongside **warm steady-state execution latency**. Note that Guillotine's zero-dependency ARM64 JIT only compiles pure side-effect-free contracts and transparently falls back to its interpreter for stateful contracts (marked `interp fallback`).

| Workload | Guillotine Interp | Guillotine JIT (run / compile) | `evm2` Interp | `evm2-jit` LLVM 23 (run / compile) | `revmc` LLVM 22 (run / compile) |
| :--- | ---: | ---: | ---: | ---: | ---: |
| `snailtracer` | 57.05 ms | 58.32 ms *(interp fallback)* | 65.16 ms | **22.17 ms** / 2.00 s | **19.53 ms** / 6.51 s |
| `erc20_transfer` | 5.49 ms | 5.45 ms *(interp fallback)* | 5.26 ms | **3.73 ms** / 174.82 ms | **3.67 ms** / 250.46 ms |
| `hash_10k` | 3.04 ms | 3.03 ms *(interp fallback)* | 3.05 ms | **2.05 ms** / 30.67 ms | **2.05 ms** / 16.89 ms |
| `fibonacci` | 47.46 µs | **39.75 µs** / 63.54 µs | 51.04 µs | **2.04 µs** / 17.52 ms | **2.00 µs** / 10.29 ms |
| `factorial` | 50.98 µs | **43.21 µs** / 47.83 µs | 49.29 µs | **4.38 µs** / 17.85 ms | **4.25 µs** / 9.51 ms |
| `bswap64` | 32.08 µs | 25.58 µs *(interp fallback)* | 1.63 µs | **1.04 µs** / 23.26 ms | **917 ns** / 18.87 ms |
| `counter` | 29.88 µs | 26.21 µs *(interp fallback)* | 1.42 µs | **1.29 µs** / 21.17 ms | **916 ns** / 13.19 ms |
| `weth` | 30.96 µs | 27.96 µs *(interp fallback)* | 2.83 µs | **2.25 µs** / 151.27 ms | **1.96 µs** / 156.40 ms |
| `usdc_proxy` | 30.73 µs | 25.58 µs *(interp fallback)* | 1.63 µs | **1.42 µs** / 75.76 ms | **1.25 µs** / 95.64 ms |
| `fiat_token` | 30.77 µs | 26.77 µs *(interp fallback)* | 1.50 µs | **1.33 µs** / 1.99 s | **1.00 µs** / 1.10 s |
| `uniswap_v2_pair` | 30.54 µs | 28.00 µs *(interp fallback)* | 1.63 µs | **1.46 µs** / 965.51 ms | **1.17 µs** / 613.91 ms |
| `uniswap_v3_pool` | 54.33 µs | 40.17 µs *(interp fallback)* | 16.92 µs | **5.75 µs** / 3.33 s | **5.54 µs** / 1.56 s |
| `seaport` | 32.71 µs | 26.50 µs *(interp fallback)* | 1.67 µs | **1.50 µs** / 7.62 s | **1.29 µs** / 2.88 s |
| `curve_stableswap` | 87.75 µs | 80.25 µs *(interp fallback)* | 84.21 µs | **24.63 µs** / 359.24 ms | **23.58 µs** / 349.34 ms |
| `burntpix` | 50.56 ms | 49.16 ms *(interp fallback)* | 56.12 ms | **7.68 ms** / 2.15 s | **8.81 ms** / 3.87 s |
| `push0_proxy` | 25.04 µs | 27.96 µs *(interp fallback)* | 1.29 µs | **1.33 µs** / 17.01 ms | **1.17 µs** / 9.18 ms |
| `loop_arithmetic` | 164.29 µs | **2.13 ms** / 150.33 µs | 135.40 µs | **92.40 µs** / 18.86 ms | **97.38 µs** / 12.35 ms |
| `loop_memory` | 76.29 µs | **71.46 µs** / 31.79 µs | 111.94 µs | **16.08 µs** / 18.56 ms | **17.96 µs** / 9.81 ms |
| `loop_storage` | 164.63 µs | 167.79 µs *(interp fallback)* | 72.17 µs | **52.67 µs** / 20.51 ms | **58.02 µs** / 12.60 ms |
| `loop_staticcall` | 95.54 µs | **104.31 µs** / 10.13 µs | 56.58 µs | **54.90 µs** / 23.90 ms | **64.81 µs** / 13.89 ms |

## 5. Differential Verification Audit

⚠️ **Some engines had execution failures or gas/output discrepancies on specific workloads (excluded from geomean rankings above):**

| Workload | Fork | Canonical Gas | Output Bytes | Verified Runs | Status / Discrepancies |
| :--- | :--- | ---: | ---: | ---: | :--- |
| `snailtracer` | CANCUN | 205,087,902 | 96 | 21/21 | ✅ Exact match |
| `erc20_transfer` | OSAKA | 13,529,850 | 0 | 21/21 | ✅ Exact match |
| `hash_10k` | OSAKA | 2,572,907 | 32 | 21/21 | ✅ Exact match |
| `fibonacci` | OSAKA | 84,203 | 32 | 21/21 | ✅ Exact match |
| `factorial` | OSAKA | 87,203 | 32 | 21/21 | ✅ Exact match |
| `bswap64` | OSAKA | 21,986 | 96 | 21/21 | ✅ Exact match |
| `counter` | OSAKA | 43,363 | 0 | 21/21 | ✅ Exact match |
| `weth` | OSAKA | 51,318 | 32 | 21/21 | ✅ Exact match |
| `usdc_proxy` | OSAKA | 25,644 | 0 | 21/21 | ✅ Exact match |
| `fiat_token` | OSAKA | 23,445 | 32 | 21/21 | ✅ Exact match |
| `uniswap_v2_pair` | OSAKA | 23,568 | 96 | 21/21 | ✅ Exact match |
| `uniswap_v3_pool` | OSAKA | 79,765 | 256 | 21/21 | ✅ Exact match |
| `seaport` | OSAKA | 24,051 | 128 | 21/21 | ✅ Exact match |
| `curve_stableswap` | CANCUN | 157,780 | 32 | 21/21 | ✅ Exact match |
| `burntpix` | CANCUN | 92,399,448 | 192288 | 21/21 | ✅ Exact match |
| `push0_proxy` | OSAKA | 23,652 | 0 | 21/21 | ✅ Exact match |
| `precompile_ecrecover` | OSAKA | 25,676 | 32 | 18/18 | ✅ Exact match |
| `precompile_sha256` | OSAKA | 61,900 | 32 | 18/18 | ✅ Exact match |
| `precompile_modexp` | OSAKA | 3,699,628 | 256 | 18/18 | ✅ Exact match |
| `precompile_bn254_pairing` | OSAKA | 140,120 | 32 | 18/18 | ✅ Exact match |
| `precompile_bls12_381` | OSAKA | 29,320 | 128 | 14/18 | `guillotine` (warm): output mismatch: got 0x00000000000000000000000000000000..., canonical 0x00000000000000000000000000000000...<br>`guillotine-nofusion` (warm): output mismatch: got 0x00000000000000000000000000000000..., canonical 0x00000000000000000000000000000000...<br>`guillotine` (cold): output mismatch: got 0x00000000000000000000000000000000..., canonical 0x00000000000000000000000000000000...<br>`guillotine-nofusion` (cold): output mismatch: got 0x00000000000000000000000000000000..., canonical 0x00000000000000000000000000000000... |
| `loop_arithmetic` | OSAKA | 154,141 | 32 | 21/21 | ✅ Exact match |
| `loop_memory` | OSAKA | 143,910 | 32 | 21/21 | ✅ Exact match |
| `loop_storage` | OSAKA | 427,409 | 32 | 21/21 | ✅ Exact match |
| `loop_staticcall` | OSAKA | 68,576 | 32 | 21/21 | ✅ Exact match |

## Caveats & Notes

- **Platform note (`category-labs/monad`):** Monad's C++ execution engine explicitly requires Linux + `libstdc++` + `-march=x86-64-v3` and cannot build natively on Apple Silicon macOS. It is omitted on macOS ARM64 runs.
- **`evmone` return output:** `evmone::state::TransactionReceipt` does not expose top-level return bytes on the receipt struct; `evmone` is verified on `EVMC_SUCCESS` and exact `gas_used`, while all other engines are verified on `success`, exact `gas_used`, and byte-for-byte `output_hex`.
- **`evmone` bytecode analysis:** `evmone` does not cache analyzed bytecode across separate `evmc_execute` calls, so its warm and cold latencies reflect its native single-pass per-call analysis design.
- **Reproducing:** Run `node bench/compare/run.mjs` from the repository root. See `bench/compare/README.md` for full build instructions.
