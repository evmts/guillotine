# EVM Benchmark Comparison Results

## Summary

**Test Runs per Case**: 1
**EVMs Compared**: Guillotine (Zig ReleaseFast), Guillotine (Zig ReleaseSmall), REVM (Rust), EthereumJS (JavaScript), Geth (Go), evmone (C++)
**Timestamp**: 1755082794 (Unix epoch)

## Overall Performance Summary (Per Run)

| Test Case | Zig-Fast | Zig-Small | REVM | EthereumJS | Geth | evmone |
|-----------|----------|-----------|------|------------|------|--------|
| erc20-approval-transfer   | 2.85 ms | 2.76 ms | 7.09 ms | 45.45 ms | 14.48 ms | 5.83 ms |
| erc20-mint                | 2.79 ms | 2.54 ms | 6.53 ms | 43.58 ms | 13.09 ms | 4.31 ms |
| erc20-transfer            | 2.94 ms | 3.55 ms | 8.55 ms | 44.34 ms | 18.44 ms | 6.92 ms |
| ten-thousand-hashes       | 1.46 ms | 1.70 ms | 3.41 ms | 46.89 ms | 9.71 ms | 2.94 ms |
| snailtracer               | 43.79 ms | 43.93 ms | 39.63 ms | 45.09 ms | 93.54 ms | 28.79 ms |

## Detailed Performance Comparison

### erc20-approval-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 2.85 ms | 2.85 ms | 2.85 ms | 2.85 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 2.76 ms | 2.76 ms | 2.76 ms | 2.76 ms | 0.00 μs |             1 |
| REVM        | 7.09 ms | 7.09 ms | 7.09 ms | 7.09 ms | 0.00 μs |             1 |
| EthereumJS  | 45.45 ms | 45.45 ms | 45.45 ms | 45.45 ms | 0.00 μs |             1 |
| Geth        | 14.48 ms | 14.48 ms | 14.48 ms | 14.48 ms | 0.00 μs |             1 |
| evmone      | 5.83 ms | 5.83 ms | 5.83 ms | 5.83 ms | 0.00 μs |             1 |

### erc20-mint

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 2.79 ms | 2.79 ms | 2.79 ms | 2.79 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 2.54 ms | 2.54 ms | 2.54 ms | 2.54 ms | 0.00 μs |             1 |
| REVM        | 6.53 ms | 6.53 ms | 6.53 ms | 6.53 ms | 0.00 μs |             1 |
| EthereumJS  | 43.58 ms | 43.58 ms | 43.58 ms | 43.58 ms | 0.00 μs |             1 |
| Geth        | 13.09 ms | 13.09 ms | 13.09 ms | 13.09 ms | 0.00 μs |             1 |
| evmone      | 4.31 ms | 4.31 ms | 4.31 ms | 4.31 ms | 0.00 μs |             1 |

### erc20-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 2.94 ms | 2.94 ms | 2.94 ms | 2.94 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 3.55 ms | 3.55 ms | 3.55 ms | 3.55 ms | 0.00 μs |             1 |
| REVM        | 8.55 ms | 8.55 ms | 8.55 ms | 8.55 ms | 0.00 μs |             1 |
| EthereumJS  | 44.34 ms | 44.34 ms | 44.34 ms | 44.34 ms | 0.00 μs |             1 |
| Geth        | 18.44 ms | 18.44 ms | 18.44 ms | 18.44 ms | 0.00 μs |             1 |
| evmone      | 6.92 ms | 6.92 ms | 6.92 ms | 6.92 ms | 0.00 μs |             1 |

### ten-thousand-hashes

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 1.46 ms | 1.46 ms | 1.46 ms | 1.46 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 1.70 ms | 1.70 ms | 1.70 ms | 1.70 ms | 0.00 μs |             1 |
| REVM        | 3.41 ms | 3.41 ms | 3.41 ms | 3.41 ms | 0.00 μs |             1 |
| EthereumJS  | 46.89 ms | 46.89 ms | 46.89 ms | 46.89 ms | 0.00 μs |             1 |
| Geth        | 9.71 ms | 9.71 ms | 9.71 ms | 9.71 ms | 0.00 μs |             1 |
| evmone      | 2.94 ms | 2.94 ms | 2.94 ms | 2.94 ms | 0.00 μs |             1 |

### snailtracer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 43.79 ms | 43.79 ms | 43.79 ms | 43.79 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 43.93 ms | 43.93 ms | 43.93 ms | 43.93 ms | 0.00 μs |             1 |
| REVM        | 39.63 ms | 39.63 ms | 39.63 ms | 39.63 ms | 0.00 μs |             1 |
| EthereumJS  | 45.09 ms | 45.09 ms | 45.09 ms | 45.09 ms | 0.00 μs |             1 |
| Geth        | 93.54 ms | 93.54 ms | 93.54 ms | 93.54 ms | 0.00 μs |             1 |
| evmone      | 28.79 ms | 28.79 ms | 28.79 ms | 28.79 ms | 0.00 μs |             1 |


## Notes

- **All times are normalized per individual execution run**
- Times are displayed in the most appropriate unit (μs, ms, or s)
- All implementations use optimized builds:
  - Zig (Fast): ReleaseFast
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
