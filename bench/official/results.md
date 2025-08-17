# EVM Benchmark Comparison Results

## Summary

**Test Runs per Case**: 2 (EthereumJS: 1)
**EVMs Compared**: Guillotine (Zig ReleaseFast), Guillotine (Call2 Interpreter), Guillotine (Zig ReleaseSmall), REVM (Rust), EthereumJS (JavaScript), Geth (Go), evmone (C++)
**Timestamp**: 1755469111 (Unix epoch)

## Overall Performance Summary (Per Run)

| Test Case | Zig-Fast | Zig-Call2 | Zig-Small | REVM | EthereumJS | Geth | evmone |
|-----------|----------|-----------|-----------|------|------------|------|--------|
| erc20-approval-transfer   | 5.44 ms | 4.96 ms | 7.92 ms | 5.19 ms | 433.40 ms | 9.88 ms | 3.81 ms |
| erc20-mint                | 4.58 ms | 4.25 ms | 6.93 ms | 4.12 ms | 448.58 ms | 8.71 ms | 2.38 ms |
| erc20-transfer            | 6.88 ms | 6.29 ms | 10.12 ms | 6.61 ms | 567.23 ms | 12.88 ms | 4.42 ms |
| ten-thousand-hashes       | 3.10 ms | 1.53 ms | 2.65 ms | 1.77 ms | 322.34 ms | 5.01 ms | 1.34 ms |
| snailtracer               | 97.86 ms | 57.48 ms | 105.28 ms | 36.79 ms | 3.06 s | 111.24 ms | 25.63 ms |

## Detailed Performance Comparison

### erc20-approval-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 5.44 ms | 5.44 ms | 5.38 ms | 5.50 ms | 82.36 μs |            20 |
| Guillotine (Call2) | 4.96 ms | 4.96 ms | 4.94 ms | 4.98 ms | 34.48 μs |            20 |
| Guillotine (Zig Small) | 7.92 ms | 7.92 ms | 7.70 ms | 8.15 ms | 315.73 μs |            20 |
| REVM        | 5.19 ms | 5.19 ms | 5.19 ms | 5.20 ms | 6.58 μs |            20 |
| EthereumJS  | 433.40 ms | 433.40 ms | 429.50 ms | 437.31 ms | 5.52 ms |             1 |
| Geth        | 9.88 ms | 9.88 ms | 9.88 ms | 9.89 ms | 5.33 μs |            20 |
| evmone      | 3.81 ms | 3.81 ms | 3.79 ms | 3.82 ms | 23.75 μs |            20 |

### erc20-mint

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 4.58 ms | 4.58 ms | 4.56 ms | 4.61 ms | 37.22 μs |            20 |
| Guillotine (Call2) | 4.25 ms | 4.25 ms | 4.24 ms | 4.26 ms | 12.59 μs |            20 |
| Guillotine (Zig Small) | 6.93 ms | 6.93 ms | 6.88 ms | 6.98 ms | 71.43 μs |            20 |
| REVM        | 4.12 ms | 4.12 ms | 4.11 ms | 4.14 ms | 20.63 μs |            20 |
| EthereumJS  | 448.58 ms | 448.58 ms | 445.23 ms | 451.93 ms | 4.74 ms |             1 |
| Geth        | 8.71 ms | 8.71 ms | 8.68 ms | 8.74 ms | 41.93 μs |            20 |
| evmone      | 2.38 ms | 2.38 ms | 2.37 ms | 2.39 ms | 8.01 μs |            20 |

### erc20-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 6.88 ms | 6.88 ms | 6.86 ms | 6.90 ms | 26.20 μs |            20 |
| Guillotine (Call2) | 6.29 ms | 6.29 ms | 6.26 ms | 6.31 ms | 31.15 μs |            20 |
| Guillotine (Zig Small) | 10.12 ms | 10.12 ms | 10.07 ms | 10.16 ms | 65.20 μs |            20 |
| REVM        | 6.61 ms | 6.61 ms | 6.59 ms | 6.63 ms | 31.16 μs |            20 |
| EthereumJS  | 567.23 ms | 567.23 ms | 566.04 ms | 568.42 ms | 1.69 ms |             1 |
| Geth        | 12.88 ms | 12.88 ms | 12.85 ms | 12.91 ms | 41.72 μs |            20 |
| evmone      | 4.42 ms | 4.42 ms | 4.40 ms | 4.44 ms | 26.76 μs |            20 |

### ten-thousand-hashes

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 3.10 ms | 3.10 ms | 3.05 ms | 3.14 ms | 62.24 μs |            20 |
| Guillotine (Call2) | 1.53 ms | 1.53 ms | 1.52 ms | 1.55 ms | 19.81 μs |            20 |
| Guillotine (Zig Small) | 2.65 ms | 2.65 ms | 2.64 ms | 2.65 ms | 1.08 μs |            20 |
| REVM        | 1.77 ms | 1.77 ms | 1.73 ms | 1.82 ms | 63.00 μs |            20 |
| EthereumJS  | 322.34 ms | 322.34 ms | 321.72 ms | 322.97 ms | 879.91 μs |             1 |
| Geth        | 5.01 ms | 5.01 ms | 4.95 ms | 5.07 ms | 84.32 μs |            20 |
| evmone      | 1.34 ms | 1.34 ms | 1.33 ms | 1.35 ms | 17.94 μs |            20 |

### snailtracer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 97.86 ms | 97.86 ms | 97.02 ms | 98.71 ms | 1.19 ms |             2 |
| Guillotine (Call2) | 57.48 ms | 57.48 ms | 57.05 ms | 57.91 ms | 612.24 μs |             2 |
| Guillotine (Zig Small) | 105.28 ms | 105.28 ms | 105.16 ms | 105.41 ms | 176.20 μs |             2 |
| REVM        | 36.79 ms | 36.79 ms | 36.76 ms | 36.83 ms | 47.99 μs |             2 |
| EthereumJS  | 3.06 s | 3.06 s | 3.06 s | 3.06 s | 0.00 μs |             1 |
| Geth        | 111.24 ms | 111.24 ms | 111.16 ms | 111.31 ms | 104.78 μs |             2 |
| evmone      | 25.63 ms | 25.63 ms | 25.43 ms | 25.83 ms | 284.88 μs |             2 |


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
