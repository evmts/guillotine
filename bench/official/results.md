# EVM Benchmark Comparison Results

## Summary

**Test Runs per Case**: 1
**EVMs Compared**: Guillotine (Zig ReleaseFast), Guillotine (Zig ReleaseSmall), REVM (Rust), EthereumJS (JavaScript), Geth (Go), evmone (C++)
**Timestamp**: 1755303552 (Unix epoch)

## Overall Performance Summary (Per Run)

| Test Case | Zig-Fast | Zig-Small | REVM | EthereumJS | Geth | evmone |
|-----------|----------|-----------|------|------------|------|--------|
| erc20-approval-transfer   | 6.90 ms | 9.75 ms | 7.07 ms | 446.70 ms | 14.52 ms | 5.88 ms |
| erc20-mint                | 6.01 ms | 9.67 ms | 5.87 ms | 454.77 ms | 13.62 ms | 4.08 ms |
| erc20-transfer            | 7.59 ms | 11.60 ms | 8.90 ms | 577.17 ms | 18.21 ms | 6.20 ms |
| ten-thousand-hashes       | 3.58 ms | 4.08 ms | 3.28 ms | 334.68 ms | 9.33 ms | 3.16 ms |
| snailtracer               | 0.00 μs | 0.00 μs | 39.92 ms | 3.26 s | 88.74 ms | 27.53 ms |

## Detailed Performance Comparison

### erc20-approval-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 6.90 ms | 6.90 ms | 6.90 ms | 6.90 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 9.75 ms | 9.75 ms | 9.75 ms | 9.75 ms | 0.00 μs |             1 |
| REVM        | 7.07 ms | 7.07 ms | 7.07 ms | 7.07 ms | 0.00 μs |             1 |
| EthereumJS  | 446.70 ms | 446.70 ms | 446.70 ms | 446.70 ms | 0.00 μs |             1 |
| Geth        | 14.52 ms | 14.52 ms | 14.52 ms | 14.52 ms | 0.00 μs |             1 |
| evmone      | 5.88 ms | 5.88 ms | 5.88 ms | 5.88 ms | 0.00 μs |             1 |

### erc20-mint

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 6.01 ms | 6.01 ms | 6.01 ms | 6.01 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 9.67 ms | 9.67 ms | 9.67 ms | 9.67 ms | 0.00 μs |             1 |
| REVM        | 5.87 ms | 5.87 ms | 5.87 ms | 5.87 ms | 0.00 μs |             1 |
| EthereumJS  | 454.77 ms | 454.77 ms | 454.77 ms | 454.77 ms | 0.00 μs |             1 |
| Geth        | 13.62 ms | 13.62 ms | 13.62 ms | 13.62 ms | 0.00 μs |             1 |
| evmone      | 4.08 ms | 4.08 ms | 4.08 ms | 4.08 ms | 0.00 μs |             1 |

### erc20-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 7.59 ms | 7.59 ms | 7.59 ms | 7.59 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 11.60 ms | 11.60 ms | 11.60 ms | 11.60 ms | 0.00 μs |             1 |
| REVM        | 8.90 ms | 8.90 ms | 8.90 ms | 8.90 ms | 0.00 μs |             1 |
| EthereumJS  | 577.17 ms | 577.17 ms | 577.17 ms | 577.17 ms | 0.00 μs |             1 |
| Geth        | 18.21 ms | 18.21 ms | 18.21 ms | 18.21 ms | 0.00 μs |             1 |
| evmone      | 6.20 ms | 6.20 ms | 6.20 ms | 6.20 ms | 0.00 μs |             1 |

### ten-thousand-hashes

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 3.58 ms | 3.58 ms | 3.58 ms | 3.58 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 4.08 ms | 4.08 ms | 4.08 ms | 4.08 ms | 0.00 μs |             1 |
| REVM        | 3.28 ms | 3.28 ms | 3.28 ms | 3.28 ms | 0.00 μs |             1 |
| EthereumJS  | 334.68 ms | 334.68 ms | 334.68 ms | 334.68 ms | 0.00 μs |             1 |
| Geth        | 9.33 ms | 9.33 ms | 9.33 ms | 9.33 ms | 0.00 μs |             1 |
| evmone      | 3.16 ms | 3.16 ms | 3.16 ms | 3.16 ms | 0.00 μs |             1 |

### snailtracer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| REVM        | 39.92 ms | 39.92 ms | 39.92 ms | 39.92 ms | 0.00 μs |             1 |
| EthereumJS  | 3.26 s | 3.26 s | 3.26 s | 3.26 s | 0.00 μs |             1 |
| Geth        | 88.74 ms | 88.74 ms | 88.74 ms | 88.74 ms | 0.00 μs |             1 |
| evmone      | 27.53 ms | 27.53 ms | 27.53 ms | 27.53 ms | 0.00 μs |             1 |


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
