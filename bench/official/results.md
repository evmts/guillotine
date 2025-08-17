# EVM Benchmark Comparison Results

## Summary

**Test Runs per Case**: 1
**EVMs Compared**: Guillotine (Zig ReleaseFast), Guillotine (Zig ReleaseSmall), REVM (Rust), EthereumJS (JavaScript), Geth (Go), evmone (C++)
**Timestamp**: 1755382255 (Unix epoch)

## Overall Performance Summary (Per Run)

| Test Case | Zig-Fast | Zig-Small | REVM | EthereumJS | Geth | evmone |
|-----------|----------|-----------|------|------------|------|--------|
| erc20-approval-transfer   | 7.64 ms | 10.84 ms | 6.74 ms | 429.24 ms | 14.66 ms | 5.40 ms |
| erc20-mint                | 6.19 ms | 8.98 ms | 5.78 ms | 446.29 ms | 12.75 ms | 3.90 ms |
| erc20-transfer            | 7.49 ms | 11.01 ms | 8.30 ms | 550.81 ms | 18.42 ms | 6.22 ms |
| ten-thousand-hashes       | 3.05 ms | 3.75 ms | 3.25 ms | 325.78 ms | 9.69 ms | 2.96 ms |
| snailtracer               | 0.00 μs | 0.00 μs | 36.68 ms | 3.11 s | 87.76 ms | 26.12 ms |

## Detailed Performance Comparison

### erc20-approval-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 7.64 ms | 7.64 ms | 7.64 ms | 7.64 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 10.84 ms | 10.84 ms | 10.84 ms | 10.84 ms | 0.00 μs |             1 |
| REVM        | 6.74 ms | 6.74 ms | 6.74 ms | 6.74 ms | 0.00 μs |             1 |
| EthereumJS  | 429.24 ms | 429.24 ms | 429.24 ms | 429.24 ms | 0.00 μs |             1 |
| Geth        | 14.66 ms | 14.66 ms | 14.66 ms | 14.66 ms | 0.00 μs |             1 |
| evmone      | 5.40 ms | 5.40 ms | 5.40 ms | 5.40 ms | 0.00 μs |             1 |

### erc20-mint

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 6.19 ms | 6.19 ms | 6.19 ms | 6.19 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 8.98 ms | 8.98 ms | 8.98 ms | 8.98 ms | 0.00 μs |             1 |
| REVM        | 5.78 ms | 5.78 ms | 5.78 ms | 5.78 ms | 0.00 μs |             1 |
| EthereumJS  | 446.29 ms | 446.29 ms | 446.29 ms | 446.29 ms | 0.00 μs |             1 |
| Geth        | 12.75 ms | 12.75 ms | 12.75 ms | 12.75 ms | 0.00 μs |             1 |
| evmone      | 3.90 ms | 3.90 ms | 3.90 ms | 3.90 ms | 0.00 μs |             1 |

### erc20-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 7.49 ms | 7.49 ms | 7.49 ms | 7.49 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 11.01 ms | 11.01 ms | 11.01 ms | 11.01 ms | 0.00 μs |             1 |
| REVM        | 8.30 ms | 8.30 ms | 8.30 ms | 8.30 ms | 0.00 μs |             1 |
| EthereumJS  | 550.81 ms | 550.81 ms | 550.81 ms | 550.81 ms | 0.00 μs |             1 |
| Geth        | 18.42 ms | 18.42 ms | 18.42 ms | 18.42 ms | 0.00 μs |             1 |
| evmone      | 6.22 ms | 6.22 ms | 6.22 ms | 6.22 ms | 0.00 μs |             1 |

### ten-thousand-hashes

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 3.05 ms | 3.05 ms | 3.05 ms | 3.05 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 3.75 ms | 3.75 ms | 3.75 ms | 3.75 ms | 0.00 μs |             1 |
| REVM        | 3.25 ms | 3.25 ms | 3.25 ms | 3.25 ms | 0.00 μs |             1 |
| EthereumJS  | 325.78 ms | 325.78 ms | 325.78 ms | 325.78 ms | 0.00 μs |             1 |
| Geth        | 9.69 ms | 9.69 ms | 9.69 ms | 9.69 ms | 0.00 μs |             1 |
| evmone      | 2.96 ms | 2.96 ms | 2.96 ms | 2.96 ms | 0.00 μs |             1 |

### snailtracer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| REVM        | 36.68 ms | 36.68 ms | 36.68 ms | 36.68 ms | 0.00 μs |             1 |
| EthereumJS  | 3.11 s | 3.11 s | 3.11 s | 3.11 s | 0.00 μs |             1 |
| Geth        | 87.76 ms | 87.76 ms | 87.76 ms | 87.76 ms | 0.00 μs |             1 |
| evmone      | 26.12 ms | 26.12 ms | 26.12 ms | 26.12 ms | 0.00 μs |             1 |


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
