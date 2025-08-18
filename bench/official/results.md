# EVM Benchmark Comparison Results

## Summary

**Test Runs per Case**: 2 (EthereumJS: 1)
**EVMs Compared**: Guillotine (Zig ReleaseFast), Guillotine (Call2 Interpreter), Guillotine (Zig ReleaseSmall), REVM (Rust), EthereumJS (JavaScript), Geth (Go), evmone (C++)
**Timestamp**: 1755463158 (Unix epoch)

## Overall Performance Summary (Per Run)

| Test Case | Zig-Fast | Zig-Call2 | Zig-Small | REVM | EthereumJS | Geth | evmone |
|-----------|----------|-----------|-----------|------|------------|------|--------|
| erc20-approval-transfer   | 5.82 ms | 4.95 ms | 7.48 ms | 5.12 ms | 424.62 ms | 10.06 ms | 3.83 ms |
| erc20-mint                | 4.70 ms | 4.11 ms | 6.96 ms | 4.10 ms | 443.49 ms | 8.77 ms | 2.45 ms |
| erc20-transfer            | 6.92 ms | 6.18 ms | 10.20 ms | 6.54 ms | 555.16 ms | 12.96 ms | 4.49 ms |
| ten-thousand-hashes       | 3.10 ms | 1.84 ms | 2.79 ms | 1.82 ms | 318.07 ms | 5.05 ms | 1.37 ms |
| snailtracer               | 96.60 ms | 54.33 ms | 104.79 ms | 36.45 ms | 3.08 s | 112.21 ms | 27.04 ms |

## Detailed Performance Comparison

### erc20-approval-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 5.82 ms | 5.82 ms | 5.70 ms | 5.93 ms | 160.98 μs |            20 |
| Guillotine (Call2) | 4.95 ms | 4.95 ms | 4.89 ms | 5.02 ms | 89.37 μs |            20 |
| Guillotine (Zig Small) | 7.48 ms | 7.48 ms | 7.43 ms | 7.53 ms | 73.23 μs |            20 |
| REVM        | 5.12 ms | 5.12 ms | 5.12 ms | 5.12 ms | 0.46 μs |            20 |
| EthereumJS  | 424.62 ms | 424.62 ms | 424.49 ms | 424.74 ms | 178.34 μs |             1 |
| Geth        | 10.06 ms | 10.06 ms | 9.98 ms | 10.15 ms | 123.53 μs |            20 |
| evmone      | 3.83 ms | 3.83 ms | 3.79 ms | 3.88 ms | 63.95 μs |            20 |

### erc20-mint

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 4.70 ms | 4.70 ms | 4.63 ms | 4.77 ms | 95.06 μs |            20 |
| Guillotine (Call2) | 4.11 ms | 4.11 ms | 4.08 ms | 4.13 ms | 40.74 μs |            20 |
| Guillotine (Zig Small) | 6.96 ms | 6.96 ms | 6.94 ms | 6.99 ms | 36.53 μs |            20 |
| REVM        | 4.10 ms | 4.10 ms | 4.07 ms | 4.14 ms | 49.56 μs |            20 |
| EthereumJS  | 443.49 ms | 443.49 ms | 443.22 ms | 443.76 ms | 380.31 μs |             1 |
| Geth        | 8.77 ms | 8.77 ms | 8.74 ms | 8.79 ms | 34.13 μs |            20 |
| evmone      | 2.45 ms | 2.45 ms | 2.44 ms | 2.46 ms | 9.31 μs |            20 |

### erc20-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 6.92 ms | 6.92 ms | 6.91 ms | 6.93 ms | 13.23 μs |            20 |
| Guillotine (Call2) | 6.18 ms | 6.18 ms | 6.14 ms | 6.23 ms | 61.51 μs |            20 |
| Guillotine (Zig Small) | 10.20 ms | 10.20 ms | 10.16 ms | 10.24 ms | 57.11 μs |            20 |
| REVM        | 6.54 ms | 6.54 ms | 6.52 ms | 6.56 ms | 28.48 μs |            20 |
| EthereumJS  | 555.16 ms | 555.16 ms | 553.85 ms | 556.48 ms | 1.86 ms |             1 |
| Geth        | 12.96 ms | 12.96 ms | 12.90 ms | 13.01 ms | 83.33 μs |            20 |
| evmone      | 4.49 ms | 4.49 ms | 4.49 ms | 4.49 ms | 0.52 μs |            20 |

### ten-thousand-hashes

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 3.10 ms | 3.10 ms | 3.09 ms | 3.12 ms | 16.58 μs |            20 |
| Guillotine (Call2) | 1.84 ms | 1.84 ms | 1.72 ms | 1.97 ms | 174.19 μs |            20 |
| Guillotine (Zig Small) | 2.79 ms | 2.79 ms | 2.77 ms | 2.81 ms | 26.16 μs |            20 |
| REVM        | 1.82 ms | 1.82 ms | 1.76 ms | 1.87 ms | 75.41 μs |            20 |
| EthereumJS  | 318.07 ms | 318.07 ms | 315.63 ms | 320.52 ms | 3.45 ms |             1 |
| Geth        | 5.05 ms | 5.05 ms | 4.98 ms | 5.11 ms | 92.46 μs |            20 |
| evmone      | 1.37 ms | 1.37 ms | 1.35 ms | 1.38 ms | 25.08 μs |            20 |

### snailtracer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 96.60 ms | 96.60 ms | 96.49 ms | 96.72 ms | 162.25 μs |             2 |
| Guillotine (Call2) | 54.33 ms | 54.33 ms | 54.15 ms | 54.51 ms | 254.65 μs |             2 |
| Guillotine (Zig Small) | 104.79 ms | 104.79 ms | 104.22 ms | 105.36 ms | 804.27 μs |             2 |
| REVM        | 36.45 ms | 36.45 ms | 35.61 ms | 37.29 ms | 1.19 ms |             2 |
| EthereumJS  | 3.08 s | 3.08 s | 3.08 s | 3.08 s | 0.00 μs |             1 |
| Geth        | 112.21 ms | 112.21 ms | 111.26 ms | 113.16 ms | 1.34 ms |             2 |
| evmone      | 27.04 ms | 27.04 ms | 26.87 ms | 27.22 ms | 248.37 μs |             2 |


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
