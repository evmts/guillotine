# EVM Benchmark Comparison Results

## Summary

**Test Runs per Case**: 2 (EthereumJS: 1)
**EVMs Compared**: Guillotine (Zig ReleaseFast), Guillotine (Call2 Interpreter), Guillotine (Zig ReleaseSmall), REVM (Rust), EthereumJS (JavaScript), Geth (Go), evmone (C++)
**Timestamp**: 1755448104 (Unix epoch)

## Overall Performance Summary (Per Run)

| Test Case | Zig-Fast | Zig-Call2 | Zig-Small | REVM | EthereumJS | Geth | evmone |
|-----------|----------|-----------|-----------|------|------------|------|--------|
| erc20-approval-transfer   | 5.47 ms | 5.27 ms | 7.48 ms | 5.12 ms | 422.88 ms | 9.95 ms | 3.79 ms |
| erc20-mint                | 4.80 ms | 4.28 ms | 7.00 ms | 4.08 ms | 439.16 ms | 8.67 ms | 2.35 ms |
| erc20-transfer            | 7.01 ms | 6.57 ms | 10.15 ms | 6.50 ms | 560.50 ms | 12.86 ms | 4.38 ms |
| ten-thousand-hashes       | 3.17 ms | 2.31 ms | 2.74 ms | 1.75 ms | 315.27 ms | 4.92 ms | 1.48 ms |
| snailtracer               | 95.66 ms | 62.39 ms | 104.98 ms | 35.51 ms | 3.07 s | 110.83 ms | 25.88 ms |

## Detailed Performance Comparison

### erc20-approval-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 5.47 ms | 5.47 ms | 5.44 ms | 5.50 ms | 47.06 μs |            20 |
| Guillotine (Call2) | 5.27 ms | 5.27 ms | 5.24 ms | 5.29 ms | 40.94 μs |            20 |
| Guillotine (Zig Small) | 7.48 ms | 7.48 ms | 7.46 ms | 7.50 ms | 27.54 μs |            20 |
| REVM        | 5.12 ms | 5.12 ms | 5.11 ms | 5.13 ms | 14.23 μs |            20 |
| EthereumJS  | 422.88 ms | 422.88 ms | 421.61 ms | 424.15 ms | 1.80 ms |             1 |
| Geth        | 9.95 ms | 9.95 ms | 9.91 ms | 10.00 ms | 66.91 μs |            20 |
| evmone      | 3.79 ms | 3.79 ms | 3.78 ms | 3.79 ms | 8.41 μs |            20 |

### erc20-mint

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 4.80 ms | 4.80 ms | 4.74 ms | 4.85 ms | 75.49 μs |            20 |
| Guillotine (Call2) | 4.28 ms | 4.28 ms | 4.26 ms | 4.30 ms | 27.25 μs |            20 |
| Guillotine (Zig Small) | 7.00 ms | 7.00 ms | 6.95 ms | 7.05 ms | 66.08 μs |            20 |
| REVM        | 4.08 ms | 4.08 ms | 4.08 ms | 4.08 ms | 2.22 μs |            20 |
| EthereumJS  | 439.16 ms | 439.16 ms | 439.02 ms | 439.30 ms | 198.58 μs |             1 |
| Geth        | 8.67 ms | 8.67 ms | 8.62 ms | 8.72 ms | 74.30 μs |            20 |
| evmone      | 2.35 ms | 2.35 ms | 2.32 ms | 2.39 ms | 45.46 μs |            20 |

### erc20-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 7.01 ms | 7.01 ms | 6.97 ms | 7.06 ms | 65.26 μs |            20 |
| Guillotine (Call2) | 6.57 ms | 6.57 ms | 6.56 ms | 6.58 ms | 10.50 μs |            20 |
| Guillotine (Zig Small) | 10.15 ms | 10.15 ms | 10.12 ms | 10.18 ms | 44.32 μs |            20 |
| REVM        | 6.50 ms | 6.50 ms | 6.46 ms | 6.54 ms | 54.43 μs |            20 |
| EthereumJS  | 560.50 ms | 560.50 ms | 553.03 ms | 567.98 ms | 10.57 ms |             1 |
| Geth        | 12.86 ms | 12.86 ms | 12.85 ms | 12.87 ms | 12.95 μs |            20 |
| evmone      | 4.38 ms | 4.38 ms | 4.37 ms | 4.39 ms | 18.75 μs |            20 |

### ten-thousand-hashes

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 3.17 ms | 3.17 ms | 3.14 ms | 3.21 ms | 52.31 μs |            20 |
| Guillotine (Call2) | 2.31 ms | 2.31 ms | 2.28 ms | 2.34 ms | 40.46 μs |            20 |
| Guillotine (Zig Small) | 2.74 ms | 2.74 ms | 2.69 ms | 2.79 ms | 71.83 μs |            20 |
| REVM        | 1.75 ms | 1.75 ms | 1.74 ms | 1.75 ms | 5.29 μs |            20 |
| EthereumJS  | 315.27 ms | 315.27 ms | 315.18 ms | 315.36 ms | 127.66 μs |             1 |
| Geth        | 4.92 ms | 4.92 ms | 4.90 ms | 4.94 ms | 26.40 μs |            20 |
| evmone      | 1.48 ms | 1.48 ms | 1.47 ms | 1.48 ms | 10.45 μs |            20 |

### snailtracer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 95.66 ms | 95.66 ms | 95.21 ms | 96.10 ms | 627.73 μs |             2 |
| Guillotine (Call2) | 62.39 ms | 62.39 ms | 62.00 ms | 62.78 ms | 556.52 μs |             2 |
| Guillotine (Zig Small) | 104.98 ms | 104.98 ms | 104.91 ms | 105.05 ms | 96.90 μs |             2 |
| REVM        | 35.51 ms | 35.51 ms | 34.86 ms | 36.15 ms | 910.33 μs |             2 |
| EthereumJS  | 3.07 s | 3.07 s | 3.07 s | 3.07 s | 0.00 μs |             1 |
| Geth        | 110.83 ms | 110.83 ms | 110.32 ms | 111.34 ms | 723.99 μs |             2 |
| evmone      | 25.88 ms | 25.88 ms | 25.34 ms | 26.41 ms | 758.96 μs |             2 |


## Notes

- **All times are normalized per individual execution run**
- Times are displayed in the most appropriate unit (μs, ms, or s)
- All implementations use optimized builds:
  - Zig (Fast): ReleaseFast
  - Zig (Call2): ReleaseFast with tailcall-based interpreter
  - Zig (Small): ReleaseSmall
  - Rust (REVM): --release
  - JavaScript (EthereumJS): Bun runtime
  - Go (geth): -O3 optimizations
  - C++ (evmone): -O3 -march=native
- Lower values indicate better performance
- Each hyperfine run executes the contract multiple times internally (see Internal Runs column)
- These benchmarks measure the full execution time including contract deployment

---

*Generated by Guillotine Benchmark Orchestrator*
