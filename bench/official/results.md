# EVM Benchmark Comparison Results

## Summary

**Test Runs per Case**: 2 (EthereumJS: 1)
**EVMs Compared**: Guillotine (Zig ReleaseFast), Guillotine (Call2 Interpreter), Guillotine (Zig ReleaseSmall), REVM (Rust), EthereumJS (JavaScript), Geth (Go), evmone (C++)
**Timestamp**: 1755464467 (Unix epoch)

## Overall Performance Summary (Per Run)

| Test Case | Zig-Fast | Zig-Call2 | Zig-Small | REVM | EthereumJS | Geth | evmone |
|-----------|----------|-----------|-----------|------|------------|------|--------|
| erc20-approval-transfer   | 5.47 ms | 4.95 ms | 7.46 ms | 5.18 ms | 423.99 ms | 9.95 ms | 3.82 ms |
| erc20-mint                | 4.74 ms | 4.12 ms | 6.94 ms | 4.13 ms | 439.97 ms | 8.98 ms | 2.44 ms |
| erc20-transfer            | 7.10 ms | 6.29 ms | 10.16 ms | 6.59 ms | 551.50 ms | 12.86 ms | 4.44 ms |
| ten-thousand-hashes       | 3.10 ms | 1.62 ms | 2.64 ms | 1.97 ms | 315.41 ms | 5.31 ms | 1.45 ms |
| snailtracer               | 96.39 ms | 54.36 ms | 104.81 ms | 39.49 ms | 3.04 s | 110.79 ms | 25.54 ms |

## Detailed Performance Comparison

### erc20-approval-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 5.47 ms | 5.47 ms | 5.46 ms | 5.48 ms | 13.18 μs |            20 |
| Guillotine (Call2) | 4.95 ms | 4.95 ms | 4.93 ms | 4.96 ms | 26.19 μs |            20 |
| Guillotine (Zig Small) | 7.46 ms | 7.46 ms | 7.39 ms | 7.53 ms | 103.49 μs |            20 |
| REVM        | 5.18 ms | 5.18 ms | 5.18 ms | 5.18 ms | 0.64 μs |            20 |
| EthereumJS  | 423.99 ms | 423.99 ms | 423.77 ms | 424.22 ms | 319.70 μs |             1 |
| Geth        | 9.95 ms | 9.95 ms | 9.89 ms | 10.02 ms | 92.78 μs |            20 |
| evmone      | 3.82 ms | 3.82 ms | 3.80 ms | 3.84 ms | 23.11 μs |            20 |

### erc20-mint

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 4.74 ms | 4.74 ms | 4.69 ms | 4.79 ms | 71.62 μs |            20 |
| Guillotine (Call2) | 4.12 ms | 4.12 ms | 4.11 ms | 4.14 ms | 25.18 μs |            20 |
| Guillotine (Zig Small) | 6.94 ms | 6.94 ms | 6.93 ms | 6.95 ms | 13.87 μs |            20 |
| REVM        | 4.13 ms | 4.13 ms | 4.12 ms | 4.14 ms | 16.10 μs |            20 |
| EthereumJS  | 439.97 ms | 439.97 ms | 436.03 ms | 443.91 ms | 5.57 ms |             1 |
| Geth        | 8.98 ms | 8.98 ms | 8.65 ms | 9.30 ms | 460.51 μs |            20 |
| evmone      | 2.44 ms | 2.44 ms | 2.39 ms | 2.48 ms | 64.02 μs |            20 |

### erc20-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 7.10 ms | 7.10 ms | 7.03 ms | 7.16 ms | 93.05 μs |            20 |
| Guillotine (Call2) | 6.29 ms | 6.29 ms | 6.26 ms | 6.32 ms | 42.95 μs |            20 |
| Guillotine (Zig Small) | 10.16 ms | 10.16 ms | 10.14 ms | 10.19 ms | 37.14 μs |            20 |
| REVM        | 6.59 ms | 6.59 ms | 6.54 ms | 6.64 ms | 73.89 μs |            20 |
| EthereumJS  | 551.50 ms | 551.50 ms | 550.55 ms | 552.45 ms | 1.35 ms |             1 |
| Geth        | 12.86 ms | 12.86 ms | 12.85 ms | 12.86 ms | 2.73 μs |            20 |
| evmone      | 4.44 ms | 4.44 ms | 4.42 ms | 4.46 ms | 27.35 μs |            20 |

### ten-thousand-hashes

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 3.10 ms | 3.10 ms | 3.08 ms | 3.11 ms | 23.88 μs |            20 |
| Guillotine (Call2) | 1.62 ms | 1.62 ms | 1.51 ms | 1.73 ms | 157.37 μs |            20 |
| Guillotine (Zig Small) | 2.64 ms | 2.64 ms | 2.64 ms | 2.65 ms | 8.35 μs |            20 |
| REVM        | 1.97 ms | 1.97 ms | 1.82 ms | 2.12 ms | 210.51 μs |            20 |
| EthereumJS  | 315.41 ms | 315.41 ms | 315.26 ms | 315.55 ms | 207.80 μs |             1 |
| Geth        | 5.31 ms | 5.31 ms | 5.04 ms | 5.58 ms | 381.86 μs |            20 |
| evmone      | 1.45 ms | 1.45 ms | 1.37 ms | 1.52 ms | 108.89 μs |            20 |

### snailtracer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 96.39 ms | 96.39 ms | 96.32 ms | 96.45 ms | 95.64 μs |             2 |
| Guillotine (Call2) | 54.36 ms | 54.36 ms | 54.33 ms | 54.38 ms | 29.82 μs |             2 |
| Guillotine (Zig Small) | 104.81 ms | 104.81 ms | 104.32 ms | 105.30 ms | 692.11 μs |             2 |
| REVM        | 39.49 ms | 39.49 ms | 39.40 ms | 39.58 ms | 121.06 μs |             2 |
| EthereumJS  | 3.04 s | 3.04 s | 3.04 s | 3.04 s | 0.00 μs |             1 |
| Geth        | 110.79 ms | 110.79 ms | 110.54 ms | 111.05 ms | 360.34 μs |             2 |
| evmone      | 25.54 ms | 25.54 ms | 24.95 ms | 26.12 ms | 823.79 μs |             2 |


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
