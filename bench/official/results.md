# EVM Benchmark Comparison Results

## Summary

**Test Runs per Case**: 2 (EthereumJS: 1)
**EVMs Compared**: Guillotine (Zig ReleaseFast), Guillotine (Call2 Interpreter), Guillotine (Zig ReleaseSmall), REVM (Rust), EthereumJS (JavaScript), Geth (Go), evmone (C++)
**Timestamp**: 1755470494 (Unix epoch)

## Overall Performance Summary (Per Run)

| Test Case | Zig-Fast | Zig-Call2 | Zig-Small | REVM | EthereumJS | Geth | evmone |
|-----------|----------|-----------|-----------|------|------------|------|--------|
| erc20-approval-transfer   | 5.34 ms | 4.91 ms | 7.49 ms | 5.15 ms | 427.08 ms | 9.84 ms | 3.79 ms |
| erc20-mint                | 4.51 ms | 4.30 ms | 6.87 ms | 4.14 ms | 459.84 ms | 8.60 ms | 2.37 ms |
| erc20-transfer            | 6.87 ms | 6.17 ms | 9.96 ms | 6.59 ms | 553.47 ms | 12.82 ms | 4.42 ms |
| ten-thousand-hashes       | 2.93 ms | 1.51 ms | 2.64 ms | 1.72 ms | 316.49 ms | 4.95 ms | 1.31 ms |
| snailtracer               | 94.13 ms | 53.64 ms | 115.33 ms | 35.27 ms | 3.02 s | 110.93 ms | 25.00 ms |

## Detailed Performance Comparison

### erc20-approval-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 5.34 ms | 5.34 ms | 5.33 ms | 5.36 ms | 17.42 μs |            20 |
| Guillotine (Call2) | 4.91 ms | 4.91 ms | 4.89 ms | 4.93 ms | 26.29 μs |            20 |
| Guillotine (Zig Small) | 7.49 ms | 7.49 ms | 7.46 ms | 7.51 ms | 33.35 μs |            20 |
| REVM        | 5.15 ms | 5.15 ms | 5.15 ms | 5.15 ms | 0.72 μs |            20 |
| EthereumJS  | 427.08 ms | 427.08 ms | 425.58 ms | 428.58 ms | 2.12 ms |             1 |
| Geth        | 9.84 ms | 9.84 ms | 9.77 ms | 9.90 ms | 93.37 μs |            20 |
| evmone      | 3.79 ms | 3.79 ms | 3.79 ms | 3.79 ms | 0.06 μs |            20 |

### erc20-mint

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 4.51 ms | 4.51 ms | 4.47 ms | 4.55 ms | 51.80 μs |            20 |
| Guillotine (Call2) | 4.30 ms | 4.30 ms | 4.29 ms | 4.31 ms | 19.50 μs |            20 |
| Guillotine (Zig Small) | 6.87 ms | 6.87 ms | 6.84 ms | 6.91 ms | 52.14 μs |            20 |
| REVM        | 4.14 ms | 4.14 ms | 4.12 ms | 4.15 ms | 19.76 μs |            20 |
| EthereumJS  | 459.84 ms | 459.84 ms | 454.91 ms | 464.77 ms | 6.97 ms |             1 |
| Geth        | 8.60 ms | 8.60 ms | 8.60 ms | 8.61 ms | 4.02 μs |            20 |
| evmone      | 2.37 ms | 2.37 ms | 2.37 ms | 2.37 ms | 0.71 μs |            20 |

### erc20-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 6.87 ms | 6.87 ms | 6.86 ms | 6.88 ms | 15.51 μs |            20 |
| Guillotine (Call2) | 6.17 ms | 6.17 ms | 6.17 ms | 6.18 ms | 4.58 μs |            20 |
| Guillotine (Zig Small) | 9.96 ms | 9.96 ms | 9.95 ms | 9.97 ms | 8.68 μs |            20 |
| REVM        | 6.59 ms | 6.59 ms | 6.57 ms | 6.60 ms | 15.33 μs |            20 |
| EthereumJS  | 553.47 ms | 553.47 ms | 552.63 ms | 554.31 ms | 1.18 ms |             1 |
| Geth        | 12.82 ms | 12.82 ms | 12.81 ms | 12.83 ms | 10.26 μs |            20 |
| evmone      | 4.42 ms | 4.42 ms | 4.40 ms | 4.45 ms | 41.31 μs |            20 |

### ten-thousand-hashes

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 2.93 ms | 2.93 ms | 2.93 ms | 2.94 ms | 8.40 μs |            20 |
| Guillotine (Call2) | 1.51 ms | 1.51 ms | 1.50 ms | 1.51 ms | 13.55 μs |            20 |
| Guillotine (Zig Small) | 2.64 ms | 2.64 ms | 2.63 ms | 2.64 ms | 13.31 μs |            20 |
| REVM        | 1.72 ms | 1.72 ms | 1.71 ms | 1.73 ms | 15.36 μs |            20 |
| EthereumJS  | 316.49 ms | 316.49 ms | 316.29 ms | 316.68 ms | 281.22 μs |             1 |
| Geth        | 4.95 ms | 4.95 ms | 4.91 ms | 4.99 ms | 53.91 μs |            20 |
| evmone      | 1.31 ms | 1.31 ms | 1.27 ms | 1.34 ms | 47.75 μs |            20 |

### snailtracer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 94.13 ms | 94.13 ms | 94.13 ms | 94.14 ms | 5.02 μs |             2 |
| Guillotine (Call2) | 53.64 ms | 53.64 ms | 53.52 ms | 53.76 ms | 163.21 μs |             2 |
| Guillotine (Zig Small) | 115.33 ms | 115.33 ms | 113.35 ms | 117.31 ms | 2.80 ms |             2 |
| REVM        | 35.27 ms | 35.27 ms | 35.03 ms | 35.50 ms | 330.78 μs |             2 |
| EthereumJS  | 3.02 s | 3.02 s | 3.02 s | 3.02 s | 0.00 μs |             1 |
| Geth        | 110.93 ms | 110.93 ms | 110.74 ms | 111.11 ms | 256.78 μs |             2 |
| evmone      | 25.00 ms | 25.00 ms | 24.90 ms | 25.09 ms | 134.51 μs |             2 |


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
