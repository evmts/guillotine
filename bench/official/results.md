# EVM Benchmark Comparison Results

## Summary

**Test Runs per Case**: 1
**EVMs Compared**: Guillotine (Zig ReleaseFast), Guillotine (Zig ReleaseSmall), REVM (Rust), EthereumJS (JavaScript), Geth (Go), evmone (C++)
**Timestamp**: 1755301163 (Unix epoch)

## Overall Performance Summary (Per Run)

| Test Case | Zig-Fast | Zig-Small | REVM | EthereumJS | Geth | evmone |
|-----------|----------|-----------|------|------------|------|--------|
| erc20-approval-transfer   | 6.82 ms | 9.78 ms | 7.06 ms | 449.30 ms | 15.29 ms | 5.63 ms |
| erc20-mint                | 6.10 ms | 9.31 ms | 5.95 ms | 454.69 ms | 15.31 ms | 4.46 ms |
| erc20-transfer            | 7.26 ms | 11.77 ms | 8.48 ms | 590.51 ms | 18.70 ms | 6.01 ms |
| ten-thousand-hashes       | 3.24 ms | 4.71 ms | 3.38 ms | 326.57 ms | 9.35 ms | 2.95 ms |
| snailtracer               | 0.00 μs | 0.00 μs | 40.55 ms | 3.30 s | 89.35 ms | 27.69 ms |

## Detailed Performance Comparison

### erc20-approval-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 6.82 ms | 6.82 ms | 6.82 ms | 6.82 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 9.78 ms | 9.78 ms | 9.78 ms | 9.78 ms | 0.00 μs |             1 |
| REVM        | 7.06 ms | 7.06 ms | 7.06 ms | 7.06 ms | 0.00 μs |             1 |
| EthereumJS  | 449.30 ms | 449.30 ms | 449.30 ms | 449.30 ms | 0.00 μs |             1 |
| Geth        | 15.29 ms | 15.29 ms | 15.29 ms | 15.29 ms | 0.00 μs |             1 |
| evmone      | 5.63 ms | 5.63 ms | 5.63 ms | 5.63 ms | 0.00 μs |             1 |

### erc20-mint

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 6.10 ms | 6.10 ms | 6.10 ms | 6.10 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 9.31 ms | 9.31 ms | 9.31 ms | 9.31 ms | 0.00 μs |             1 |
| REVM        | 5.95 ms | 5.95 ms | 5.95 ms | 5.95 ms | 0.00 μs |             1 |
| EthereumJS  | 454.69 ms | 454.69 ms | 454.69 ms | 454.69 ms | 0.00 μs |             1 |
| Geth        | 15.31 ms | 15.31 ms | 15.31 ms | 15.31 ms | 0.00 μs |             1 |
| evmone      | 4.46 ms | 4.46 ms | 4.46 ms | 4.46 ms | 0.00 μs |             1 |

### erc20-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 7.26 ms | 7.26 ms | 7.26 ms | 7.26 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 11.77 ms | 11.77 ms | 11.77 ms | 11.77 ms | 0.00 μs |             1 |
| REVM        | 8.48 ms | 8.48 ms | 8.48 ms | 8.48 ms | 0.00 μs |             1 |
| EthereumJS  | 590.51 ms | 590.51 ms | 590.51 ms | 590.51 ms | 0.00 μs |             1 |
| Geth        | 18.70 ms | 18.70 ms | 18.70 ms | 18.70 ms | 0.00 μs |             1 |
| evmone      | 6.01 ms | 6.01 ms | 6.01 ms | 6.01 ms | 0.00 μs |             1 |

### ten-thousand-hashes

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 3.24 ms | 3.24 ms | 3.24 ms | 3.24 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 4.71 ms | 4.71 ms | 4.71 ms | 4.71 ms | 0.00 μs |             1 |
| REVM        | 3.38 ms | 3.38 ms | 3.38 ms | 3.38 ms | 0.00 μs |             1 |
| EthereumJS  | 326.57 ms | 326.57 ms | 326.57 ms | 326.57 ms | 0.00 μs |             1 |
| Geth        | 9.35 ms | 9.35 ms | 9.35 ms | 9.35 ms | 0.00 μs |             1 |
| evmone      | 2.95 ms | 2.95 ms | 2.95 ms | 2.95 ms | 0.00 μs |             1 |

### snailtracer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| REVM        | 40.55 ms | 40.55 ms | 40.55 ms | 40.55 ms | 0.00 μs |             1 |
| EthereumJS  | 3.30 s | 3.30 s | 3.30 s | 3.30 s | 0.00 μs |             1 |
| Geth        | 89.35 ms | 89.35 ms | 89.35 ms | 89.35 ms | 0.00 μs |             1 |
| evmone      | 27.69 ms | 27.69 ms | 27.69 ms | 27.69 ms | 0.00 μs |             1 |


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
