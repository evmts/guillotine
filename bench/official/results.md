# EVM Benchmark Comparison Results

## Summary

**Test Runs per Case**: 1
**EVMs Compared**: Guillotine (Zig ReleaseFast), Guillotine (Call2 Interpreter), Guillotine (Zig ReleaseSmall), REVM (Rust), EthereumJS (JavaScript), Geth (Go), evmone (C++)
**Timestamp**: 1755410268 (Unix epoch)

## Overall Performance Summary (Per Run)

| Test Case | Zig-Fast | Zig-Call2 | Zig-Small | REVM | EthereumJS | Geth | evmone |
|-----------|----------|-----------|-----------|------|------------|------|--------|
| erc20-approval-transfer   | 7.48 ms | 0.00 μs | 10.58 ms | 6.95 ms | 428.01 ms | 14.67 ms | 5.39 ms |
| erc20-mint                | 5.92 ms | 0.00 μs | 8.79 ms | 6.07 ms | 458.48 ms | 13.62 ms | 4.28 ms |
| erc20-transfer            | 7.86 ms | 0.00 μs | 11.88 ms | 8.18 ms | 559.59 ms | 17.12 ms | 6.28 ms |
| ten-thousand-hashes       | 3.11 ms | 15.60 ms | 3.68 ms | 3.29 ms | 327.33 ms | 8.77 ms | 3.09 ms |
| snailtracer               | 60.22 ms | 0.00 μs | 77.26 ms | 38.15 ms | 3.15 s | 89.09 ms | 27.30 ms |

## Detailed Performance Comparison

### erc20-approval-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 7.48 ms | 7.48 ms | 7.48 ms | 7.48 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 10.58 ms | 10.58 ms | 10.58 ms | 10.58 ms | 0.00 μs |             1 |
| REVM        | 6.95 ms | 6.95 ms | 6.95 ms | 6.95 ms | 0.00 μs |             1 |
| EthereumJS  | 428.01 ms | 428.01 ms | 428.01 ms | 428.01 ms | 0.00 μs |             1 |
| Geth        | 14.67 ms | 14.67 ms | 14.67 ms | 14.67 ms | 0.00 μs |             1 |
| evmone      | 5.39 ms | 5.39 ms | 5.39 ms | 5.39 ms | 0.00 μs |             1 |

### erc20-mint

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 5.92 ms | 5.92 ms | 5.92 ms | 5.92 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 8.79 ms | 8.79 ms | 8.79 ms | 8.79 ms | 0.00 μs |             1 |
| REVM        | 6.07 ms | 6.07 ms | 6.07 ms | 6.07 ms | 0.00 μs |             1 |
| EthereumJS  | 458.48 ms | 458.48 ms | 458.48 ms | 458.48 ms | 0.00 μs |             1 |
| Geth        | 13.62 ms | 13.62 ms | 13.62 ms | 13.62 ms | 0.00 μs |             1 |
| evmone      | 4.28 ms | 4.28 ms | 4.28 ms | 4.28 ms | 0.00 μs |             1 |

### erc20-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 7.86 ms | 7.86 ms | 7.86 ms | 7.86 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 11.88 ms | 11.88 ms | 11.88 ms | 11.88 ms | 0.00 μs |             1 |
| REVM        | 8.18 ms | 8.18 ms | 8.18 ms | 8.18 ms | 0.00 μs |             1 |
| EthereumJS  | 559.59 ms | 559.59 ms | 559.59 ms | 559.59 ms | 0.00 μs |             1 |
| Geth        | 17.12 ms | 17.12 ms | 17.12 ms | 17.12 ms | 0.00 μs |             1 |
| evmone      | 6.28 ms | 6.28 ms | 6.28 ms | 6.28 ms | 0.00 μs |             1 |

### ten-thousand-hashes

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 3.11 ms | 3.11 ms | 3.11 ms | 3.11 ms | 0.00 μs |             1 |
| Guillotine (Call2) | 15.60 ms | 15.60 ms | 15.60 ms | 15.60 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 3.68 ms | 3.68 ms | 3.68 ms | 3.68 ms | 0.00 μs |             1 |
| REVM        | 3.29 ms | 3.29 ms | 3.29 ms | 3.29 ms | 0.00 μs |             1 |
| EthereumJS  | 327.33 ms | 327.33 ms | 327.33 ms | 327.33 ms | 0.00 μs |             1 |
| Geth        | 8.77 ms | 8.77 ms | 8.77 ms | 8.77 ms | 0.00 μs |             1 |
| evmone      | 3.09 ms | 3.09 ms | 3.09 ms | 3.09 ms | 0.00 μs |             1 |

### snailtracer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 60.22 ms | 60.22 ms | 60.22 ms | 60.22 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 77.26 ms | 77.26 ms | 77.26 ms | 77.26 ms | 0.00 μs |             1 |
| REVM        | 38.15 ms | 38.15 ms | 38.15 ms | 38.15 ms | 0.00 μs |             1 |
| EthereumJS  | 3.15 s | 3.15 s | 3.15 s | 3.15 s | 0.00 μs |             1 |
| Geth        | 89.09 ms | 89.09 ms | 89.09 ms | 89.09 ms | 0.00 μs |             1 |
| evmone      | 27.30 ms | 27.30 ms | 27.30 ms | 27.30 ms | 0.00 μs |             1 |


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
