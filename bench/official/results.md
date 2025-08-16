# EVM Benchmark Comparison Results

## Summary

**Test Runs per Case**: 1
**EVMs Compared**: Guillotine (Zig ReleaseFast), Guillotine (Zig ReleaseSmall), REVM (Rust), EthereumJS (JavaScript), Geth (Go), evmone (C++)
**Timestamp**: 1755309528 (Unix epoch)

## Overall Performance Summary (Per Run)

| Test Case | Zig-Fast | Zig-Small | REVM | EthereumJS | Geth | evmone |
|-----------|----------|-----------|------|------------|------|--------|
| erc20-approval-transfer   | 6.58 ms | 10.11 ms | 7.18 ms | 445.24 ms | 15.71 ms | 5.77 ms |
| erc20-mint                | 6.36 ms | 9.82 ms | 6.05 ms | 460.97 ms | 13.42 ms | 4.27 ms |
| erc20-transfer            | 7.36 ms | 13.28 ms | 8.89 ms | 575.00 ms | 18.04 ms | 6.49 ms |
| ten-thousand-hashes       | 4.10 ms | 4.65 ms | 3.71 ms | 332.92 ms | 9.37 ms | 2.99 ms |
| snailtracer               | 0.00 μs | 0.00 μs | 39.43 ms | 3.27 s | 90.30 ms | 28.33 ms |

## Detailed Performance Comparison

### erc20-approval-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 6.58 ms | 6.58 ms | 6.58 ms | 6.58 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 10.11 ms | 10.11 ms | 10.11 ms | 10.11 ms | 0.00 μs |             1 |
| REVM        | 7.18 ms | 7.18 ms | 7.18 ms | 7.18 ms | 0.00 μs |             1 |
| EthereumJS  | 445.24 ms | 445.24 ms | 445.24 ms | 445.24 ms | 0.00 μs |             1 |
| Geth        | 15.71 ms | 15.71 ms | 15.71 ms | 15.71 ms | 0.00 μs |             1 |
| evmone      | 5.77 ms | 5.77 ms | 5.77 ms | 5.77 ms | 0.00 μs |             1 |

### erc20-mint

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 6.36 ms | 6.36 ms | 6.36 ms | 6.36 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 9.82 ms | 9.82 ms | 9.82 ms | 9.82 ms | 0.00 μs |             1 |
| REVM        | 6.05 ms | 6.05 ms | 6.05 ms | 6.05 ms | 0.00 μs |             1 |
| EthereumJS  | 460.97 ms | 460.97 ms | 460.97 ms | 460.97 ms | 0.00 μs |             1 |
| Geth        | 13.42 ms | 13.42 ms | 13.42 ms | 13.42 ms | 0.00 μs |             1 |
| evmone      | 4.27 ms | 4.27 ms | 4.27 ms | 4.27 ms | 0.00 μs |             1 |

### erc20-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 7.36 ms | 7.36 ms | 7.36 ms | 7.36 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 13.28 ms | 13.28 ms | 13.28 ms | 13.28 ms | 0.00 μs |             1 |
| REVM        | 8.89 ms | 8.89 ms | 8.89 ms | 8.89 ms | 0.00 μs |             1 |
| EthereumJS  | 575.00 ms | 575.00 ms | 575.00 ms | 575.00 ms | 0.00 μs |             1 |
| Geth        | 18.04 ms | 18.04 ms | 18.04 ms | 18.04 ms | 0.00 μs |             1 |
| evmone      | 6.49 ms | 6.49 ms | 6.49 ms | 6.49 ms | 0.00 μs |             1 |

### ten-thousand-hashes

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 4.10 ms | 4.10 ms | 4.10 ms | 4.10 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 4.65 ms | 4.65 ms | 4.65 ms | 4.65 ms | 0.00 μs |             1 |
| REVM        | 3.71 ms | 3.71 ms | 3.71 ms | 3.71 ms | 0.00 μs |             1 |
| EthereumJS  | 332.92 ms | 332.92 ms | 332.92 ms | 332.92 ms | 0.00 μs |             1 |
| Geth        | 9.37 ms | 9.37 ms | 9.37 ms | 9.37 ms | 0.00 μs |             1 |
| evmone      | 2.99 ms | 2.99 ms | 2.99 ms | 2.99 ms | 0.00 μs |             1 |

### snailtracer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| REVM        | 39.43 ms | 39.43 ms | 39.43 ms | 39.43 ms | 0.00 μs |             1 |
| EthereumJS  | 3.27 s | 3.27 s | 3.27 s | 3.27 s | 0.00 μs |             1 |
| Geth        | 90.30 ms | 90.30 ms | 90.30 ms | 90.30 ms | 0.00 μs |             1 |
| evmone      | 28.33 ms | 28.33 ms | 28.33 ms | 28.33 ms | 0.00 μs |             1 |


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
