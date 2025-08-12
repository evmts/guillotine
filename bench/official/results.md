# EVM Benchmark Comparison Results

## Summary

**Test Runs per Case**: 1
**EVMs Compared**: Guillotine (Zig ReleaseFast), Guillotine (Zig ReleaseSmall), REVM (Rust), EthereumJS (JavaScript), Geth (Go), evmone (C++)
**Timestamp**: 1755017739 (Unix epoch)

## Overall Performance Summary (Per Run)

| Test Case | Zig-Fast | Zig-Small | REVM | EthereumJS | Geth | evmone |
|-----------|----------|-----------|------|------------|------|--------|
| erc20-approval-transfer   | 0.00 μs | 0.00 μs | 1.23 ms | 0.00 μs | 12.70 ms | 7.63 ms |
| erc20-mint                | 0.00 μs | 0.00 μs | 1.16 ms | 0.00 μs | 11.26 ms | 4.50 ms |
| erc20-transfer            | 0.00 μs | 0.00 μs | 1.18 ms | 0.00 μs | 14.93 ms | 5.69 ms |
| ten-thousand-hashes       | 0.00 μs | 0.00 μs | 1.25 ms | 0.00 μs | 8.36 ms | 5.29 ms |
| snailtracer               | 0.00 μs | 0.00 μs | 1.29 ms | 0.00 μs | 0.00 μs | 0.00 μs |

## Detailed Performance Comparison

### erc20-approval-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |             1 |
| Guillotine (Zig Small) | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |             1 |
| REVM        | 1.23 ms | 1.23 ms | 1.23 ms | 1.23 ms | 0.00 μs |             1 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |             1 |
| Geth        | 12.70 ms | 12.70 ms | 12.70 ms | 12.70 ms | 0.00 μs |             1 |
| evmone      | 7.63 ms | 7.63 ms | 7.63 ms | 7.63 ms | 0.00 μs |             1 |

### erc20-mint

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |             1 |
| Guillotine (Zig Small) | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |             1 |
| REVM        | 1.16 ms | 1.16 ms | 1.16 ms | 1.16 ms | 0.00 μs |             1 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |             1 |
| Geth        | 11.26 ms | 11.26 ms | 11.26 ms | 11.26 ms | 0.00 μs |             1 |
| evmone      | 4.50 ms | 4.50 ms | 4.50 ms | 4.50 ms | 0.00 μs |             1 |

### erc20-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |             1 |
| Guillotine (Zig Small) | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |             1 |
| REVM        | 1.18 ms | 1.18 ms | 1.18 ms | 1.18 ms | 0.00 μs |             1 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |             1 |
| Geth        | 14.93 ms | 14.93 ms | 14.93 ms | 14.93 ms | 0.00 μs |             1 |
| evmone      | 5.69 ms | 5.69 ms | 5.69 ms | 5.69 ms | 0.00 μs |             1 |

### ten-thousand-hashes

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |             1 |
| Guillotine (Zig Small) | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |             1 |
| REVM        | 1.25 ms | 1.25 ms | 1.25 ms | 1.25 ms | 0.00 μs |             1 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |             1 |
| Geth        | 8.36 ms | 8.36 ms | 8.36 ms | 8.36 ms | 0.00 μs |             1 |
| evmone      | 5.29 ms | 5.29 ms | 5.29 ms | 5.29 ms | 0.00 μs |             1 |

### snailtracer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |             1 |
| Guillotine (Zig Small) | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |             1 |
| REVM        | 1.29 ms | 1.29 ms | 1.29 ms | 1.29 ms | 0.00 μs |             1 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |             1 |
| Geth        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |             1 |
| evmone      | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |             1 |


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
