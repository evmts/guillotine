# Guillotine Cross-EVM Benchmark Report

**Generated:** 2026-11-26T09:59:39.941Z  
**Hardware:** Apple M3 Max (16 cores, 64 GB RAM), Darwin 25.2.0 (arm64)  
**Guillotine commit:** `d325db700205`  
**Compilers:** Zig `0.17.1` · Rust `rustc 1.100.0 (0ef1bc386 2026-11-09)` · C++ `Apple clang version 17.0.0 (clang-1700.6.4.2)` · Go `go version go1.26.0 darwin/arm64` · LLVM `23.1.6` (evm2-jit) / `22.1.8` (revmc)

> **Methodology & Fairness Guarantee:** All engines run **in-process** with zero CLI startup overhead, strictly sequentially on the same machine, against the **exact same canonical JSON workloads** (21 fixtures verbatim from `alloy-rs/evm2@e80df9c46a82` + 4 targeted hot-loop workloads). Gas accounting is **enabled** and tracing is **disabled** for every engine. Every timed sample must pass a **0-tolerance differential verification gate** (`success == true`, exact `gas_used` match, byte-for-byte `output` match). Any mismatched cell is disqualified (`MISMATCH`) rather than reported.

## Pinned Engine Versions

| Engine | Language | Tier | Source / Pinned Revision | Build Flags |
| :--- | :--- | :--- | :--- | :--- |
| **Guillotine** (`guillotine`) | Zig | interpreter | local (evmts/guillotine) @ `d325db700205` | -OReleaseFast (native CPU, LLVM backend) |
| **Guillotine (no fusion)** (`guillotine-nofusion`) | Zig | interpreter | local (evmts/guillotine) @ `d325db700205` | -OReleaseFast (native CPU, LLVM backend) |
| **Guillotine JIT** (`guillotine-jit`) | Zig | jit | local (evmts/guillotine) @ `d325db700205` | -OReleaseFast (native CPU, LLVM backend) |
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
| **evm2** | Rust | **1.12×** (25) | 1.00× | 1.10× | 1.01× | 1.33× | 1.15× |
| **Guillotine** | Zig | **1.00×** (25) | 0.90× | 1.43× | 0.98× | 0.61× | 1.04× |
| **revm** | Rust | **1.00×** (25) | 0.89× | 1.00× | 1.00× | 1.00× | 1.00× |
| **gevm** | Go | **0.99×** (25) | 0.89× | 0.98× | 1.02× | 1.14× | 0.79× |
| **Guillotine (no fusion)** | Zig | **0.89×** (25) | 0.79× | 1.21× | 0.81× | 0.61× | 1.00× |
| **ethrex (LEVM)** | Rust | **0.77×** (25) | 0.69× | 0.84× | 0.67× | 0.89× | 0.76× |
| **evmone (Baseline)** | C++ | **0.76×** (25) | 0.68× | 0.94× | 0.44× | 1.11× | 1.09× |
| **evmone (Advanced)** | C++ | **0.51×** (25) | 0.46× | 0.82× | 0.18× | 1.11× | 0.84× |
| **geth** | Go | **0.31×** (25) | 0.28× | 0.41× | 0.15× | 0.68× | 0.41× |

## 2. Warm Steady-State Latency (Interpreters, Median per TX)

Bytecode pre-loaded/analyzed where supported; fresh clean state snapshot per transaction (no state accumulation). Lower is faster. Fastest verified interpreter per row is **bold**.

| Workload | Cat | Fork | Gas | Guillotine | evm2 | revm | evmone (Advanced) | evmone (Baseline) | ethrex (LEVM) | gevm | geth | Guillotine vs `revm` | Guillotine vs `evm2` |
| :--- | :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `snailtracer` | classic | CANCUN | 205,087,902 | **55.53 ms** | 64.75 ms | 81.67 ms | 100.13 ms | 70.53 ms | 80.80 ms | 92.29 ms | 137.01 ms | 1.47× | 1.17× |
| `erc20_transfer` | classic | OSAKA | 13,529,850 | 6.51 ms | **5.24 ms** | 5.80 ms | 9.87 ms | 9.43 ms | 7.27 ms | 6.91 ms | 15.46 ms | 0.89× | 0.81× |
| `hash_10k` | classic | OSAKA | 2,572,907 | **2.91 ms** | 3.86 ms | 4.40 ms | 3.16 ms | 3.40 ms | 3.73 ms | 3.94 ms | 7.54 ms | 1.51× | 1.33× |
| `fibonacci` | classic | OSAKA | 84,203 | **17.71 µs** | 51.04 µs | 58.71 µs | 54.50 µs | 55.67 µs | 58.58 µs | 60.38 µs | 89.88 µs | 3.32× | 2.88× |
| `factorial` | classic | OSAKA | 87,203 | **17.79 µs** | 49.29 µs | 60.02 µs | 51.73 µs | 55.69 µs | 61.42 µs | 63.35 µs | 90.13 µs | 3.37× | 2.77× |
| `bswap64` | classic | OSAKA | 21,986 | 1.96 µs | **1.58 µs** | 1.71 µs | 2.92 µs | 1.79 µs | 2.58 µs | 1.75 µs | 8.08 µs | 0.87× | 0.81× |
| `counter` | classic | OSAKA | 43,363 | 1.83 µs | 1.40 µs | 1.17 µs | 2.25 µs | 1.83 µs | 2.38 µs | **980 ns** | 7.83 µs | 0.64× | 0.76× |
| `weth` | mainnet | OSAKA | 51,318 | 3.46 µs | **2.75 µs** | 2.88 µs | 10.54 µs | 5.13 µs | 4.33 µs | 2.92 µs | 14.71 µs | 0.83× | 0.80× |
| `usdc_proxy` | mainnet | OSAKA | 25,644 | 1.75 µs | 1.63 µs | **1.46 µs** | 6.96 µs | 2.29 µs | 3.00 µs | 1.46 µs | 23.46 µs | 0.83× | 0.93× |
| `fiat_token` | mainnet | OSAKA | 23,445 | 1.79 µs | 1.46 µs | 1.29 µs | 42.29 µs | 12.42 µs | 2.08 µs | **1.08 µs** | 21.94 µs | 0.72× | 0.81× |
| `uniswap_v2_pair` | mainnet | OSAKA | 23,568 | 1.79 µs | 1.58 µs | 1.46 µs | 23.48 µs | 6.67 µs | 2.25 µs | **1.25 µs** | 14.42 µs | 0.81× | 0.88× |
| `uniswap_v3_pool` | mainnet | OSAKA | 79,765 | **11.40 µs** | 16.71 µs | 19.38 µs | 92.42 µs | 33.46 µs | 21.73 µs | 22.83 µs | 69.63 µs | 1.70× | 1.47× |
| `seaport` | mainnet | OSAKA | 24,051 | 2.08 µs | 1.75 µs | 1.69 µs | 71.96 µs | 15.63 µs | 2.38 µs | **1.50 µs** | 24.29 µs | 0.81× | 0.84× |
| `curve_stableswap` | mainnet | CANCUN | 157,780 | **83.83 µs** | 84.50 µs | 97.33 µs | 136.08 µs | 108.17 µs | 143.90 µs | 108.50 µs | 288.60 µs | 1.16× | 1.01× |
| `burntpix` | mainnet | CANCUN | 92,399,448 | **35.42 ms** | 53.65 ms | 65.83 ms | 78.59 ms | 63.54 ms | 68.33 ms | 77.51 ms | 121.02 ms | 1.86× | 1.51× |
| `push0_proxy` | mainnet | OSAKA | 23,652 | 1.67 µs | 1.29 µs | 1.17 µs | 1.50 µs | **834 ns** | 2.25 µs | 1.00 µs | 9.31 µs | 0.70× | 0.78× |
| `precompile_ecrecover` | precompile | OSAKA | 25,676 | 177.48 µs | 30.38 µs | 30.54 µs | **30.08 µs** | 30.10 µs | 31.21 µs | 30.17 µs | 36.17 µs | 0.17× | 0.17× |
| `precompile_sha256` | precompile | OSAKA | 61,900 | 2.08 µs | **1.29 µs** | 1.71 µs | 1.42 µs | 1.42 µs | 5.21 µs | 1.54 µs | 6.96 µs | 0.82× | 0.62× |
| `precompile_modexp` | precompile | OSAKA | 3,699,628 | 1.81 ms | **1.05 ms** | 2.42 ms | 1.57 ms | 1.57 ms | 1.56 ms | 1.61 ms | 1.76 ms | 1.33× | 0.58× |
| `precompile_bn254_pairing` | precompile | OSAKA | 140,120 | 1.22 ms | **628.21 µs** | 822.85 µs | 966.83 µs | 968.75 µs | 643.54 µs | 834.50 µs | 843.23 µs | 0.68× | 0.52× |
| `precompile_bls12_381` | precompile | OSAKA | 29,320 | 7.42 µs | 4.75 µs | 5.00 µs | 4.71 µs | 4.67 µs | 5.71 µs | **4.25 µs** | 9.42 µs | 0.67× | 0.64× |
| `loop_arithmetic` | opcode | OSAKA | 154,141 | 132.46 µs | 131.00 µs | 171.92 µs | **129.60 µs** | 140.96 µs | 198.69 µs | 184.50 µs | 252.13 µs | 1.30× | 0.99× |
| `loop_memory` | opcode | OSAKA | 143,910 | **67.38 µs** | 109.04 µs | 120.42 µs | 106.33 µs | 124.50 µs | 135.58 µs | 156.46 µs | 264.17 µs | 1.79× | 1.62× |
| `loop_storage` | opcode | OSAKA | 427,409 | 113.73 µs | 70.58 µs | 74.48 µs | 71.02 µs | **69.71 µs** | 98.54 µs | 78.00 µs | 363.06 µs | 0.65× | 0.62× |
| `loop_staticcall` | opcode | OSAKA | 68,576 | 84.04 µs | **56.19 µs** | 64.94 µs | 207.04 µs | 57.38 µs | 113.56 µs | 116.63 µs | 152.44 µs | 0.77× | 0.67× |

## 3. Cold First-Run Latency (Includes Bytecode Analysis + EVM Init)

Every sample constructs a fresh EVM with unanalyzed raw bytecode (empty dispatch/jumpdest cache), fairly measuring single-shot / cold-contract cost.

| Engine | Overall Cold vs `revm` | Overall Cold vs `evm2` | Classic | Mainnet DeFi | Precompiles | Hot-Loops |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| **gevm** | **1.33×** | 1.09× | 1.12× | 1.99× | 1.23× | 0.80× |
| **evm2** | **1.23×** | 1.00× | 1.20× | 1.18× | 1.40× | 1.18× |
| **revm** | **1.00×** | 0.82× | 1.00× | 1.00× | 1.00× | 1.00× |
| **evmone (Baseline)** | **0.89×** | 0.73× | 0.93× | 0.72× | 1.07× | 1.08× |
| **evmone (Advanced)** | **0.64×** | 0.52× | 0.85× | 0.34× | 1.07× | 0.85× |
| **ethrex (LEVM)** | **0.46×** | 0.37× | 0.71× | 0.18× | 0.93× | 0.69× |
| **geth** | **0.35×** | 0.29× | 0.38× | 0.23× | 0.63× | 0.38× |
| **Guillotine** | **0.27×** | 0.22× | 0.65× | 0.06× | 0.39× | 0.91× |
| **Guillotine (no fusion)** | **0.25×** | 0.20× | 0.56× | 0.06× | 0.40× | 0.88× |

| Workload | Cat | Guillotine | evm2 | revm | evmone (Advanced) | evmone (Baseline) | ethrex (LEVM) | gevm | geth |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `snailtracer` | classic | **56.94 ms** | 64.90 ms | 82.25 ms | 100.15 ms | 71.34 ms | 80.95 ms | 91.43 ms | 138.09 ms |
| `erc20_transfer` | classic | 6.82 ms | **5.22 ms** | 6.44 ms | 9.88 ms | 9.42 ms | 7.28 ms | 6.91 ms | 15.50 ms |
| `hash_10k` | classic | **2.99 ms** | 3.05 ms | 3.31 ms | 3.13 ms | 3.40 ms | 3.74 ms | 3.94 ms | 7.49 ms |
| `fibonacci` | classic | **33.83 µs** | 51.44 µs | 57.50 µs | 54.94 µs | 56.63 µs | 60.35 µs | 61.31 µs | 95.02 µs |
| `factorial` | classic | **34.52 µs** | 49.81 µs | 60.77 µs | 53.85 µs | 57.54 µs | 62.38 µs | 63.75 µs | 97.94 µs |
| `bswap64` | classic | 26.79 µs | 2.13 µs | 2.75 µs | 3.94 µs | 3.25 µs | 7.65 µs | **1.75 µs** | 14.75 µs |
| `counter` | classic | 21.25 µs | 1.88 µs | 2.29 µs | 3.38 µs | 2.67 µs | 6.46 µs | **1.04 µs** | 15.71 µs |
| `weth` | mainnet | 91.98 µs | 3.71 µs | 4.54 µs | 11.65 µs | 6.58 µs | 25.46 µs | **3.00 µs** | 24.38 µs |
| `usdc_proxy` | mainnet | 56.81 µs | 2.46 µs | 2.90 µs | 8.21 µs | 3.73 µs | 18.10 µs | **1.38 µs** | 20.88 µs |
| `fiat_token` | mainnet | 599.54 µs | 5.96 µs | 6.63 µs | 43.65 µs | 13.83 µs | 140.04 µs | **1.23 µs** | 32.79 µs |
| `uniswap_v2_pair` | mainnet | 309.04 µs | 4.10 µs | 4.67 µs | 24.77 µs | 8.13 µs | 71.73 µs | **1.33 µs** | 21.98 µs |
| `uniswap_v3_pool` | mainnet | 792.63 µs | **21.67 µs** | 24.94 µs | 95.10 µs | 35.08 µs | 166.92 µs | 23.83 µs | 92.85 µs |
| `seaport` | mainnet | 800.67 µs | 6.88 µs | 7.81 µs | 73.19 µs | 16.94 µs | 152.17 µs | **1.67 µs** | 36.17 µs |
| `curve_stableswap` | mainnet | 234.77 µs | **85.19 µs** | 100.83 µs | 138.15 µs | 95.06 µs | 142.50 µs | 108.85 µs | 202.42 µs |
| `burntpix` | mainnet | **38.83 ms** | 53.34 ms | 65.81 ms | 77.86 ms | 63.90 ms | 68.68 ms | 76.64 ms | 120.23 ms |
| `push0_proxy` | mainnet | 16.52 µs | 1.75 µs | 2.21 µs | 2.50 µs | 2.33 µs | 4.67 µs | **1.04 µs** | 18.08 µs |
| `precompile_ecrecover` | precompile | 188.69 µs | 30.75 µs | 31.33 µs | 31.35 µs | 31.29 µs | 32.29 µs | **30.38 µs** | 41.58 µs |
| `precompile_sha256` | precompile | 12.69 µs | 1.67 µs | 2.58 µs | 2.38 µs | 2.42 µs | 6.08 µs | **1.63 µs** | 10.54 µs |
| `precompile_modexp` | precompile | 1.84 ms | **1.06 ms** | 2.42 ms | 1.57 ms | 1.57 ms | 1.55 ms | 1.60 ms | 1.61 ms |
| `precompile_bn254_pairing` | precompile | 1.23 ms | **630.04 µs** | 807.79 µs | 968.19 µs | 970.96 µs | 652.23 µs | 947.90 µs | 984.27 µs |
| `precompile_bls12_381` | precompile | 17.90 µs | 5.15 µs | 5.88 µs | 5.75 µs | 5.71 µs | 6.75 µs | **4.33 µs** | 13.46 µs |
| `loop_arithmetic` | opcode | 146.58 µs | 131.44 µs | 176.50 µs | **128.52 µs** | 139.77 µs | 203.35 µs | 181.04 µs | 264.75 µs |
| `loop_memory` | opcode | **81.17 µs** | 107.29 µs | 121.13 µs | 107.52 µs | 123.60 µs | 127.23 µs | 166.12 µs | 272.81 µs |
| `loop_storage` | opcode | 139.96 µs | **70.27 µs** | 74.52 µs | 71.88 µs | 71.63 µs | 145.15 µs | 77.58 µs | 440.08 µs |
| `loop_staticcall` | opcode | 96.58 µs | **58.83 µs** | 69.90 µs | 213.33 µs | 66.50 µs | 131.56 µs | 115.98 µs | 167.73 µs |

## 4. Tier 2 — JIT / Native Compilers (Compile Time + Warm Execution)

Reported strictly separately from interpreters. Shows **one-time compile cost** alongside **warm steady-state execution latency**. Note that Guillotine's zero-dependency ARM64 JIT only compiles pure side-effect-free contracts and transparently falls back to its interpreter for stateful contracts (marked `interp fallback`).

| Workload | Guillotine Interp | Guillotine JIT (run / compile) | `evm2` Interp | `evm2-jit` LLVM 23 (run / compile) | `revmc` LLVM 22 (run / compile) |
| :--- | ---: | ---: | ---: | ---: | ---: |
| `snailtracer` | 55.53 ms | 55.42 ms *(interp fallback)* | 64.75 ms | **20.31 ms** / 1.94 s | **19.31 ms** / 6.57 s |
| `erc20_transfer` | 6.51 ms | 6.50 ms *(interp fallback)* | 5.24 ms | **3.73 ms** / 323.11 ms | **3.69 ms** / 257.18 ms |
| `hash_10k` | 2.91 ms | 2.91 ms *(interp fallback)* | 3.86 ms | **2.06 ms** / 29.95 ms | **2.07 ms** / 15.87 ms |
| `fibonacci` | 17.71 µs | 17.67 µs *(interp fallback)* | 51.04 µs | **2.08 µs** / 17.38 ms | **2.00 µs** / 10.91 ms |
| `factorial` | 17.79 µs | 17.83 µs *(interp fallback)* | 49.29 µs | **4.42 µs** / 20.31 ms | **4.29 µs** / 10.30 ms |
| `bswap64` | 1.96 µs | 1.96 µs *(interp fallback)* | 1.58 µs | **1.04 µs** / 24.27 ms | **917 ns** / 19.40 ms |
| `counter` | 1.83 µs | 1.88 µs *(interp fallback)* | 1.40 µs | **1.21 µs** / 21.57 ms | **958 ns** / 12.37 ms |
| `weth` | 3.46 µs | 3.46 µs *(interp fallback)* | 2.75 µs | **2.17 µs** / 150.37 ms | **2.00 µs** / 155.22 ms |
| `usdc_proxy` | 1.75 µs | 1.79 µs *(interp fallback)* | 1.63 µs | **1.38 µs** / 75.82 ms | **1.13 µs** / 93.46 ms |
| `fiat_token` | 1.79 µs | 1.79 µs *(interp fallback)* | 1.46 µs | **1.33 µs** / 2.04 s | **1.04 µs** / 1.25 s |
| `uniswap_v2_pair` | 1.79 µs | 1.88 µs *(interp fallback)* | 1.58 µs | **1.33 µs** / 909.03 ms | **1.00 µs** / 564.04 ms |
| `uniswap_v3_pool` | 11.40 µs | 11.46 µs *(interp fallback)* | 16.71 µs | **5.71 µs** / 3.33 s | **5.54 µs** / 1.54 s |
| `seaport` | 2.08 µs | 2.08 µs *(interp fallback)* | 1.75 µs | **1.46 µs** / 8.53 s | **1.25 µs** / 2.44 s |
| `curve_stableswap` | 83.83 µs | 83.98 µs *(interp fallback)* | 84.50 µs | **23.71 µs** / 342.48 ms | **23.75 µs** / 346.36 ms |
| `burntpix` | 35.42 ms | 35.23 ms *(interp fallback)* | 53.65 ms | **7.60 ms** / 2.31 s | **8.80 ms** / 3.76 s |
| `push0_proxy` | 1.67 µs | 1.79 µs *(interp fallback)* | 1.29 µs | **1.42 µs** / 48.68 ms | **1.13 µs** / 9.67 ms |
| `loop_arithmetic` | 132.46 µs | 159.75 µs *(interp fallback)* | 131.00 µs | **103.29 µs** / 23.55 ms | **104.33 µs** / 17.29 ms |
| `loop_memory` | 67.38 µs | 74.92 µs *(interp fallback)* | 109.04 µs | **15.67 µs** / 18.12 ms | **17.63 µs** / 9.01 ms |
| `loop_storage` | 113.73 µs | 188.77 µs *(interp fallback)* | 70.58 µs | **73.54 µs** / 28.07 ms | **60.38 µs** / 13.39 ms |
| `loop_staticcall` | 84.04 µs | 90.46 µs *(interp fallback)* | 56.19 µs | **56.38 µs** / 40.38 ms | **63.92 µs** / 14.76 ms |

## 5. Differential Verification Audit

✅ **All engines matched identically on `success`, exact `gas_used`, and byte-for-byte `output` across every workload and mode.**

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
| `precompile_bls12_381` | OSAKA | 29,320 | 128 | 18/18 | ✅ Exact match |
| `loop_arithmetic` | OSAKA | 154,141 | 32 | 21/21 | ✅ Exact match |
| `loop_memory` | OSAKA | 143,910 | 32 | 21/21 | ✅ Exact match |
| `loop_storage` | OSAKA | 427,409 | 32 | 21/21 | ✅ Exact match |
| `loop_staticcall` | OSAKA | 68,576 | 32 | 21/21 | ✅ Exact match |

## Caveats & Notes

- **Platform note (`category-labs/monad`):** Monad's C++ execution engine explicitly requires Linux + `libstdc++` + `-march=x86-64-v3` and cannot build natively on Apple Silicon macOS. It is omitted on macOS ARM64 runs.
- **`evmone` return output:** `evmone::state::TransactionReceipt` does not expose top-level return bytes on the receipt struct; `evmone` is verified on `EVMC_SUCCESS` and exact `gas_used`, while all other engines are verified on `success`, exact `gas_used`, and byte-for-byte `output_hex`.
- **`evmone` bytecode analysis:** `evmone` does not cache analyzed bytecode across separate `evmc_execute` calls, so its warm and cold latencies reflect its native single-pass per-call analysis design.
- **Reproducing:** Run `node bench/compare/run.mjs` from the repository root. See `bench/compare/README.md` for full build instructions.
