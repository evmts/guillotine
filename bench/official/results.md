# EVM Benchmark Comparison Results

## Summary

**Test Runs per Case**: 1
**EVMs Compared**: Guillotine (Zig ReleaseFast), Guillotine (Call2 Interpreter), Guillotine (Zig ReleaseSmall), REVM (Rust), EthereumJS (JavaScript), Geth (Go), evmone (C++)
**Timestamp**: 1755404198 (Unix epoch)

## Overall Performance Summary (Per Run)

| Test Case | Zig-Fast | Zig-Call2 | Zig-Small | REVM | EthereumJS | Geth | evmone |
|-----------|----------|-----------|-----------|------|------------|------|--------|
| erc20-approval-transfer   | 7.05 ms | 0.00 μs | 9.40 ms | 6.91 ms | 438.64 ms | 14.59 ms | 5.77 ms |
| erc20-mint                | 5.19 ms | 0.00 μs | 9.83 ms | 6.97 ms | 469.02 ms | 12.65 ms | 4.15 ms |
| erc20-transfer            | 7.51 ms | 0.00 μs | 12.97 ms | 9.63 ms | 556.84 ms | 17.92 ms | 6.10 ms |
| ten-thousand-hashes       | 3.04 ms | 0.00 μs | 4.39 ms | 3.29 ms | 323.81 ms | 9.98 ms | 2.67 ms |
| snailtracer               | 61.66 ms | 0.00 μs | 78.80 ms | 39.34 ms | 3.11 s | 86.85 ms | 27.43 ms |

## Detailed Performance Comparison

### erc20-approval-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 7.05 ms | 7.05 ms | 7.05 ms | 7.05 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 9.40 ms | 9.40 ms | 9.40 ms | 9.40 ms | 0.00 μs |             1 |
| REVM        | 6.91 ms | 6.91 ms | 6.91 ms | 6.91 ms | 0.00 μs |             1 |
| EthereumJS  | 438.64 ms | 438.64 ms | 438.64 ms | 438.64 ms | 0.00 μs |             1 |
| Geth        | 14.59 ms | 14.59 ms | 14.59 ms | 14.59 ms | 0.00 μs |             1 |
| evmone      | 5.77 ms | 5.77 ms | 5.77 ms | 5.77 ms | 0.00 μs |             1 |

### erc20-mint

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 5.19 ms | 5.19 ms | 5.19 ms | 5.19 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 9.83 ms | 9.83 ms | 9.83 ms | 9.83 ms | 0.00 μs |             1 |
| REVM        | 6.97 ms | 6.97 ms | 6.97 ms | 6.97 ms | 0.00 μs |             1 |
| EthereumJS  | 469.02 ms | 469.02 ms | 469.02 ms | 469.02 ms | 0.00 μs |             1 |
| Geth        | 12.65 ms | 12.65 ms | 12.65 ms | 12.65 ms | 0.00 μs |             1 |
| evmone      | 4.15 ms | 4.15 ms | 4.15 ms | 4.15 ms | 0.00 μs |             1 |

### erc20-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 7.51 ms | 7.51 ms | 7.51 ms | 7.51 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 12.97 ms | 12.97 ms | 12.97 ms | 12.97 ms | 0.00 μs |             1 |
| REVM        | 9.63 ms | 9.63 ms | 9.63 ms | 9.63 ms | 0.00 μs |             1 |
| EthereumJS  | 556.84 ms | 556.84 ms | 556.84 ms | 556.84 ms | 0.00 μs |             1 |
| Geth        | 17.92 ms | 17.92 ms | 17.92 ms | 17.92 ms | 0.00 μs |             1 |
| evmone      | 6.10 ms | 6.10 ms | 6.10 ms | 6.10 ms | 0.00 μs |             1 |

### ten-thousand-hashes

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 3.04 ms | 3.04 ms | 3.04 ms | 3.04 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 4.39 ms | 4.39 ms | 4.39 ms | 4.39 ms | 0.00 μs |             1 |
| REVM        | 3.29 ms | 3.29 ms | 3.29 ms | 3.29 ms | 0.00 μs |             1 |
| EthereumJS  | 323.81 ms | 323.81 ms | 323.81 ms | 323.81 ms | 0.00 μs |             1 |
| Geth        | 9.98 ms | 9.98 ms | 9.98 ms | 9.98 ms | 0.00 μs |             1 |
| evmone      | 2.67 ms | 2.67 ms | 2.67 ms | 2.67 ms | 0.00 μs |             1 |

### snailtracer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine (Zig Fast) | 61.66 ms | 61.66 ms | 61.66 ms | 61.66 ms | 0.00 μs |             1 |
| Guillotine (Zig Small) | 78.80 ms | 78.80 ms | 78.80 ms | 78.80 ms | 0.00 μs |             1 |
| REVM        | 39.34 ms | 39.34 ms | 39.34 ms | 39.34 ms | 0.00 μs |             1 |
| EthereumJS  | 3.11 s | 3.11 s | 3.11 s | 3.11 s | 0.00 μs |             1 |
| Geth        | 86.85 ms | 86.85 ms | 86.85 ms | 86.85 ms | 0.00 μs |             1 |
| evmone      | 27.43 ms | 27.43 ms | 27.43 ms | 27.43 ms | 0.00 μs |             1 |


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
