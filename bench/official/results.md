# EVM Benchmark Comparison Results

## Summary

**Test Runs per Case**: 1
**EVMs Compared**: Guillotine Call2 (Zig with tailcall dispatch), REVM (Rust), EthereumJS (JavaScript), Geth (Go), evmone (C++)
**Timestamp**: 1756603585 (Unix epoch)

## Overall Performance Summary (Per Run)

| Test Case | Zig-Call2 | REVM | EthereumJS | Geth | evmone |
|-----------|-----------|------|------------|------|--------|
| erc20-approval-transfer   | .{ .value =         0, .unit = .microseconds } | .{ .value = 6.395890700000001, .unit = .milliseconds } | .{ .value =          0, .unit = .microseconds } | .{ .value = 12.518542179999999, .unit = .milliseconds } | .{ .value = 4.6294716000000005, .unit = .milliseconds } |
| erc20-mint                | .{ .value =         0, .unit = .microseconds } | .{ .value = 5.031915400000001, .unit = .milliseconds } | .{ .value =          0, .unit = .microseconds } | .{ .value = 10.74502494, .unit = .milliseconds } | .{ .value = 3.8889704400000005, .unit = .milliseconds } |
| erc20-transfer            | .{ .value =         0, .unit = .microseconds } | .{ .value = 7.265388820000001, .unit = .milliseconds } | .{ .value =          0, .unit = .microseconds } | .{ .value = 15.382508399999999, .unit = .milliseconds } | .{ .value = 5.65009504, .unit = .milliseconds } |
| ten-thousand-hashes       | .{ .value =         0, .unit = .microseconds } | .{ .value = 2.4982341399999997, .unit = .milliseconds } | .{ .value =          0, .unit = .microseconds } | .{ .value = 7.78607346, .unit = .milliseconds } | .{ .value = 1.9732741999999996, .unit = .milliseconds } |
| snailtracer               | .{ .value =         0, .unit = .microseconds } | .{ .value = 32.3546341, .unit = .milliseconds } | .{ .value =          0, .unit = .microseconds } | .{ .value = 73.15247031999999, .unit = .milliseconds } | .{ .value = 22.65945622, .unit = .milliseconds } |

## Detailed Performance Comparison

### erc20-approval-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| REVM        | .{ .value = 6.395890700000001, .unit = .milliseconds } | .{ .value = 6.395890700000001, .unit = .milliseconds } | .{ .value = 6.395890700000001, .unit = .milliseconds } | .{ .value = 6.395890700000001, .unit = .milliseconds } | .{ .value =                 0, .unit = .microseconds } |             1 |
| Geth        | .{ .value = 12.518542179999999, .unit = .milliseconds } | .{ .value = 12.518542179999999, .unit = .milliseconds } | .{ .value = 12.518542179999999, .unit = .milliseconds } | .{ .value = 12.518542179999999, .unit = .milliseconds } | .{ .value =                 0, .unit = .microseconds } |             1 |
| evmone      | .{ .value = 4.6294716000000005, .unit = .milliseconds } | .{ .value = 4.6294716000000005, .unit = .milliseconds } | .{ .value = 4.6294716000000005, .unit = .milliseconds } | .{ .value = 4.6294716000000005, .unit = .milliseconds } | .{ .value =                 0, .unit = .microseconds } |             1 |

### erc20-mint

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| REVM        | .{ .value = 5.031915400000001, .unit = .milliseconds } | .{ .value = 5.031915400000001, .unit = .milliseconds } | .{ .value = 5.031915400000001, .unit = .milliseconds } | .{ .value = 5.031915400000001, .unit = .milliseconds } | .{ .value =                 0, .unit = .microseconds } |             1 |
| Geth        | .{ .value =    10.74502494, .unit = .milliseconds } | .{ .value =      10.74502494, .unit = .milliseconds } | .{ .value =   10.74502494, .unit = .milliseconds } | .{ .value =   10.74502494, .unit = .milliseconds } | .{ .value =                 0, .unit = .microseconds } |             1 |
| evmone      | .{ .value = 3.8889704400000005, .unit = .milliseconds } | .{ .value = 3.8889704400000005, .unit = .milliseconds } | .{ .value = 3.8889704400000005, .unit = .milliseconds } | .{ .value = 3.8889704400000005, .unit = .milliseconds } | .{ .value =                 0, .unit = .microseconds } |             1 |

### erc20-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| REVM        | .{ .value = 7.265388820000001, .unit = .milliseconds } | .{ .value = 7.265388820000001, .unit = .milliseconds } | .{ .value = 7.265388820000001, .unit = .milliseconds } | .{ .value = 7.265388820000001, .unit = .milliseconds } | .{ .value =                 0, .unit = .microseconds } |             1 |
| Geth        | .{ .value = 15.382508399999999, .unit = .milliseconds } | .{ .value = 15.382508399999999, .unit = .milliseconds } | .{ .value = 15.382508399999999, .unit = .milliseconds } | .{ .value = 15.382508399999999, .unit = .milliseconds } | .{ .value =                 0, .unit = .microseconds } |             1 |
| evmone      | .{ .value =     5.65009504, .unit = .milliseconds } | .{ .value =       5.65009504, .unit = .milliseconds } | .{ .value =    5.65009504, .unit = .milliseconds } | .{ .value =    5.65009504, .unit = .milliseconds } | .{ .value =                 0, .unit = .microseconds } |             1 |

### ten-thousand-hashes

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| REVM        | .{ .value = 2.4982341399999997, .unit = .milliseconds } | .{ .value = 2.4982341399999997, .unit = .milliseconds } | .{ .value = 2.4982341399999997, .unit = .milliseconds } | .{ .value = 2.4982341399999997, .unit = .milliseconds } | .{ .value =                 0, .unit = .microseconds } |             1 |
| Geth        | .{ .value =     7.78607346, .unit = .milliseconds } | .{ .value =       7.78607346, .unit = .milliseconds } | .{ .value =    7.78607346, .unit = .milliseconds } | .{ .value =    7.78607346, .unit = .milliseconds } | .{ .value =                 0, .unit = .microseconds } |             1 |
| evmone      | .{ .value = 1.9732741999999996, .unit = .milliseconds } | .{ .value = 1.9732741999999996, .unit = .milliseconds } | .{ .value = 1.9732741999999996, .unit = .milliseconds } | .{ .value = 1.9732741999999996, .unit = .milliseconds } | .{ .value =                 0, .unit = .microseconds } |             1 |

### snailtracer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| REVM        | .{ .value =     32.3546341, .unit = .milliseconds } | .{ .value =       32.3546341, .unit = .milliseconds } | .{ .value =    32.3546341, .unit = .milliseconds } | .{ .value =    32.3546341, .unit = .milliseconds } | .{ .value =                 0, .unit = .microseconds } |             1 |
| Geth        | .{ .value = 73.15247031999999, .unit = .milliseconds } | .{ .value = 73.15247031999999, .unit = .milliseconds } | .{ .value = 73.15247031999999, .unit = .milliseconds } | .{ .value = 73.15247031999999, .unit = .milliseconds } | .{ .value =                 0, .unit = .microseconds } |             1 |
| evmone      | .{ .value =    22.65945622, .unit = .milliseconds } | .{ .value =      22.65945622, .unit = .milliseconds } | .{ .value =   22.65945622, .unit = .milliseconds } | .{ .value =   22.65945622, .unit = .milliseconds } | .{ .value =                 0, .unit = .microseconds } |             1 |


## Notes

- **All times are normalized per individual execution run**
- Times are displayed in the most appropriate unit (μs, ms, or s)
- All implementations use optimized builds:
  - Zig (Call2): ReleaseFast with tailcall-based interpreter
  - Rust (REVM): --release
  - JavaScript (EthereumJS): JS runtime (bun or node)
  - Go (geth): -O3 optimizations
  - C++ (evmone): -O3 -march=native
- Lower values indicate better performance
- Each hyperfine run executes the contract multiple times internally (see Internal Runs column)
- These benchmarks measure the full execution time including contract deployment

---

*Generated by Guillotine Benchmark Orchestrator*
