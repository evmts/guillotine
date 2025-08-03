# EVM Benchmark Comparison Results

## Summary

**Test Runs per Case**: 10 (EthereumJS: 2)
**EVMs Compared**: Guillotine (Zig), REVM (Rust), EthereumJS (JavaScript), Geth (Go), evmone (C++)
**Timestamp**: 1754260667 (Unix epoch)

## Performance Comparison

### erc20-approval-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 5.91 ms | 5.91 ms | 5.89 ms | 5.93 ms | 14.58 μs |           100 |
| REVM        | 18.95 μs | 18.83 μs | 18.50 μs | 19.87 μs | 0.38 μs |           100 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |            10 |
| Geth        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| evmone      | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |

### erc20-mint

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 4.50 ms | 4.50 ms | 4.48 ms | 4.52 ms | 13.01 μs |           100 |
| REVM        | 18.84 μs | 18.86 μs | 18.38 μs | 19.17 μs | 0.20 μs |           100 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |            10 |
| Geth        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| evmone      | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |

### erc20-transfer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 7.27 ms | 7.27 ms | 7.22 ms | 7.32 ms | 26.75 μs |           100 |
| REVM        | 18.87 μs | 18.92 μs | 18.55 μs | 19.24 μs | 0.22 μs |           100 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |            10 |
| Geth        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| evmone      | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |

### ten-thousand-hashes

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 2.74 ms | 2.74 ms | 2.71 ms | 2.76 ms | 16.21 μs |           100 |
| REVM        | 17.05 μs | 16.96 μs | 16.54 μs | 17.91 μs | 0.46 μs |           100 |
| EthereumJS  | 11.88 ms | 11.86 ms | 11.77 ms | 12.05 ms | 78.69 μs |            10 |
| Geth        | 47.05 μs | 46.46 μs | 44.29 μs | 51.05 μs | 2.23 μs |           100 |
| evmone      | 17.50 μs | 17.40 μs | 16.79 μs | 18.90 μs | 0.57 μs |           100 |

### snailtracer

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 206.20 ms | 206.21 ms | 205.28 ms | 207.09 ms | 549.72 μs |            10 |
| REVM        | 165.01 μs | 164.84 μs | 160.60 μs | 173.57 μs | 4.07 μs |            10 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |             1 |
| Geth        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |            10 |
| evmone      | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |            10 |

### opcodes-arithmetic

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 17.13 μs | 17.06 μs | 16.66 μs | 18.47 μs | 0.53 μs |           100 |
| REVM        | 17.14 μs | 17.09 μs | 16.73 μs | 17.63 μs | 0.31 μs |           100 |
| EthereumJS  | 11.82 ms | 11.84 ms | 11.65 ms | 11.99 ms | 108.74 μs |            10 |
| Geth        | 45.46 μs | 44.72 μs | 42.85 μs | 49.41 μs | 2.21 μs |           100 |
| evmone      | 16.89 μs | 17.01 μs | 16.05 μs | 17.42 μs | 0.46 μs |           100 |

### opcodes-arithmetic-advanced

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 17.52 μs | 17.41 μs | 16.78 μs | 18.69 μs | 0.58 μs |           100 |
| REVM        | 16.94 μs | 16.88 μs | 16.44 μs | 17.83 μs | 0.47 μs |           100 |
| EthereumJS  | 11.85 ms | 11.86 ms | 11.64 ms | 12.01 ms | 118.81 μs |            10 |
| Geth        | 47.48 μs | 47.74 μs | 45.12 μs | 49.90 μs | 1.64 μs |           100 |
| evmone      | 17.68 μs | 17.37 μs | 16.58 μs | 21.03 μs | 1.25 μs |           100 |

### opcodes-bitwise

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 16.84 μs | 16.79 μs | 16.01 μs | 17.62 μs | 0.46 μs |           100 |
| REVM        | 17.49 μs | 17.33 μs | 17.01 μs | 18.18 μs | 0.41 μs |           100 |
| EthereumJS  | 11.82 ms | 11.88 ms | 11.54 ms | 12.10 ms | 176.87 μs |            10 |
| Geth        | 46.34 μs | 46.39 μs | 44.53 μs | 48.31 μs | 1.36 μs |           100 |
| evmone      | 17.37 μs | 17.54 μs | 16.50 μs | 18.30 μs | 0.61 μs |           100 |

### opcodes-block-1

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 21.69 μs | 21.61 μs | 21.20 μs | 22.52 μs | 0.39 μs |           100 |
| REVM        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |            10 |
| Geth        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| evmone      | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |

### opcodes-block-2

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 19.97 μs | 19.99 μs | 19.31 μs | 20.44 μs | 0.34 μs |           100 |
| REVM        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |            10 |
| Geth        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| evmone      | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |

### opcodes-comparison

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 16.81 μs | 16.69 μs | 16.38 μs | 17.81 μs | 0.45 μs |           100 |
| REVM        | 17.25 μs | 17.20 μs | 16.89 μs | 17.69 μs | 0.27 μs |           100 |
| EthereumJS  | 11.84 ms | 11.84 ms | 11.65 ms | 12.10 ms | 143.37 μs |            10 |
| Geth        | 45.63 μs | 44.94 μs | 43.77 μs | 50.04 μs | 2.04 μs |           100 |
| evmone      | 17.15 μs | 17.11 μs | 16.74 μs | 17.66 μs | 0.33 μs |           100 |

### opcodes-control

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 23.38 μs | 23.31 μs | 22.57 μs | 24.56 μs | 0.61 μs |           100 |
| REVM        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |            10 |
| Geth        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| evmone      | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |

### opcodes-crypto

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 19.87 μs | 19.55 μs | 19.12 μs | 21.47 μs | 0.74 μs |           100 |
| REVM        | 416.36 μs | 416.46 μs | 414.01 μs | 419.01 μs | 1.73 μs |           100 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |            10 |
| Geth        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| evmone      | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |

### opcodes-data

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 18.08 μs | 17.88 μs | 17.54 μs | 18.98 μs | 0.48 μs |           100 |
| REVM        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |            10 |
| Geth        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| evmone      | 53.55 μs | 53.47 μs | 52.88 μs | 54.42 μs | 0.52 μs |           100 |

### opcodes-dup

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 16.88 μs | 16.85 μs | 16.20 μs | 17.75 μs | 0.50 μs |           100 |
| REVM        | 17.26 μs | 17.28 μs | 16.48 μs | 18.23 μs | 0.49 μs |           100 |
| EthereumJS  | 11.79 ms | 11.77 ms | 11.55 ms | 12.03 ms | 140.59 μs |            10 |
| Geth        | 45.99 μs | 45.81 μs | 44.84 μs | 47.48 μs | 0.96 μs |           100 |
| evmone      | 16.88 μs | 16.65 μs | 16.27 μs | 18.16 μs | 0.60 μs |           100 |

### opcodes-environmental-1

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 16.68 μs | 16.60 μs | 15.99 μs | 17.30 μs | 0.50 μs |           100 |
| REVM        | 16.94 μs | 16.99 μs | 16.43 μs | 17.36 μs | 0.32 μs |           100 |
| EthereumJS  | 11.81 ms | 11.79 ms | 11.71 ms | 12.05 ms | 95.27 μs |            10 |
| Geth        | 48.02 μs | 47.81 μs | 46.56 μs | 50.71 μs | 1.20 μs |           100 |
| evmone      | 16.71 μs | 16.78 μs | 15.71 μs | 17.65 μs | 0.59 μs |           100 |

### opcodes-environmental-2

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 23.42 μs | 23.42 μs | 22.78 μs | 24.69 μs | 0.52 μs |           100 |
| REVM        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |            10 |
| Geth        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| evmone      | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |

### opcodes-jump-basic

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 14.34 μs | 14.32 μs | 13.54 μs | 15.72 μs | 0.64 μs |           100 |
| REVM        | 17.61 μs | 17.27 μs | 16.64 μs | 19.43 μs | 1.02 μs |           100 |
| EthereumJS  | 11.71 ms | 11.73 ms | 11.58 ms | 11.86 ms | 103.04 μs |            10 |
| Geth        | 46.45 μs | 46.68 μs | 43.99 μs | 49.80 μs | 1.88 μs |           100 |
| evmone      | 16.89 μs | 16.99 μs | 15.99 μs | 17.84 μs | 0.66 μs |           100 |

### opcodes-memory

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 17.89 μs | 17.72 μs | 17.26 μs | 18.80 μs | 0.60 μs |           100 |
| REVM        | 16.97 μs | 16.96 μs | 16.56 μs | 17.31 μs | 0.22 μs |           100 |
| EthereumJS  | 11.78 ms | 11.78 ms | 11.70 ms | 11.85 ms | 45.98 μs |            10 |
| Geth        | 46.99 μs | 45.99 μs | 44.14 μs | 53.12 μs | 2.91 μs |           100 |
| evmone      | 18.41 μs | 17.40 μs | 16.77 μs | 23.49 μs | 2.16 μs |           100 |

### opcodes-push-pop

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 16.92 μs | 16.84 μs | 16.41 μs | 17.31 μs | 0.30 μs |           100 |
| REVM        | 17.17 μs | 17.14 μs | 16.74 μs | 17.87 μs | 0.38 μs |           100 |
| EthereumJS  | 11.76 ms | 11.73 ms | 11.56 ms | 12.02 ms | 143.68 μs |            10 |
| Geth        | 46.23 μs | 46.45 μs | 43.05 μs | 49.18 μs | 2.05 μs |           100 |
| evmone      | 17.38 μs | 17.24 μs | 16.33 μs | 19.68 μs | 0.90 μs |           100 |

### opcodes-storage-cold

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 17.40 μs | 17.35 μs | 16.63 μs | 18.43 μs | 0.54 μs |           100 |
| REVM        | 17.13 μs | 17.04 μs | 16.73 μs | 17.66 μs | 0.30 μs |           100 |
| EthereumJS  | 11.87 ms | 11.93 ms | 11.62 ms | 12.03 ms | 158.42 μs |            10 |
| Geth        | 46.26 μs | 45.76 μs | 43.30 μs | 49.72 μs | 2.34 μs |           100 |
| evmone      | 17.86 μs | 17.62 μs | 16.81 μs | 19.60 μs | 1.00 μs |           100 |

### opcodes-storage-warm

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 16.67 μs | 16.57 μs | 16.14 μs | 17.43 μs | 0.48 μs |           100 |
| REVM        | 17.08 μs | 17.06 μs | 16.72 μs | 17.66 μs | 0.27 μs |           100 |
| EthereumJS  | 11.84 ms | 11.86 ms | 11.71 ms | 11.97 ms | 94.97 μs |            10 |
| Geth        | 45.15 μs | 45.50 μs | 42.96 μs | 46.50 μs | 1.25 μs |           100 |
| evmone      | 16.89 μs | 16.80 μs | 16.27 μs | 17.51 μs | 0.38 μs |           100 |

### opcodes-swap

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 16.87 μs | 16.92 μs | 16.10 μs | 17.55 μs | 0.49 μs |           100 |
| REVM        | 17.74 μs | 17.58 μs | 17.15 μs | 18.67 μs | 0.56 μs |           100 |
| EthereumJS  | 11.65 ms | 11.65 ms | 11.40 ms | 11.99 ms | 189.85 μs |            10 |
| Geth        | 47.13 μs | 46.73 μs | 44.21 μs | 51.06 μs | 2.62 μs |           100 |
| evmone      | 16.73 μs | 16.66 μs | 16.28 μs | 17.52 μs | 0.42 μs |           100 |

### precompile-blake2f

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 18.51 μs | 18.41 μs | 18.22 μs | 19.27 μs | 0.33 μs |           100 |
| REVM        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |            10 |
| Geth        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| evmone      | 33.97 μs | 33.76 μs | 32.67 μs | 37.24 μs | 1.29 μs |           100 |

### precompile-bn256add

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 29.86 μs | 29.69 μs | 29.25 μs | 31.43 μs | 0.70 μs |           100 |
| REVM        | 240.49 μs | 240.39 μs | 239.55 μs | 241.67 μs | 0.75 μs |           100 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |            10 |
| Geth        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| evmone      | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |

### precompile-bn256mul

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 22.05 μs | 22.11 μs | 21.77 μs | 22.24 μs | 0.16 μs |           100 |
| REVM        | 246.23 μs | 245.93 μs | 244.77 μs | 250.60 μs | 1.67 μs |           100 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |            10 |
| Geth        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| evmone      | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |

### precompile-bn256pairing

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 88.96 μs | 88.83 μs | 87.76 μs | 90.99 μs | 1.03 μs |           100 |
| REVM        | 30.08 μs | 30.08 μs | 29.64 μs | 30.56 μs | 0.33 μs |           100 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |            10 |
| Geth        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| evmone      | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |

### precompile-ecrecover

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 17.67 μs | 17.57 μs | 16.63 μs | 18.63 μs | 0.62 μs |           100 |
| REVM        | 342.80 μs | 341.80 μs | 340.28 μs | 348.92 μs | 2.57 μs |           100 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |            10 |
| Geth        | 88.11 μs | 89.12 μs | 84.60 μs | 91.21 μs | 2.63 μs |           100 |
| evmone      | 21.64 μs | 21.64 μs | 21.32 μs | 22.00 μs | 0.23 μs |           100 |

### precompile-identity

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 52.67 μs | 52.95 μs | 50.58 μs | 54.99 μs | 1.49 μs |           100 |
| REVM        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |            10 |
| Geth        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| evmone      | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |

### precompile-modexp

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 17.67 μs | 17.68 μs | 17.29 μs | 18.06 μs | 0.22 μs |           100 |
| REVM        | 49.47 μs | 49.65 μs | 48.35 μs | 50.74 μs | 0.75 μs |           100 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |            10 |
| Geth        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| evmone      | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |

### precompile-ripemd160

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 15.76 μs | 15.74 μs | 15.07 μs | 16.90 μs | 0.48 μs |           100 |
| REVM        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |            10 |
| Geth        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| evmone      | 28.75 μs | 28.70 μs | 28.01 μs | 29.94 μs | 0.57 μs |           100 |

### precompile-sha256

| EVM | Mean (per run) | Median (per run) | Min (per run) | Max (per run) | Std Dev (per run) | Internal Runs |
|-----|----------------|------------------|---------------|---------------|-------------------|---------------|
| Guillotine  | 15.53 μs | 15.55 μs | 15.19 μs | 16.01 μs | 0.27 μs |           100 |
| REVM        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| EthereumJS  | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |            10 |
| Geth        | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |
| evmone      | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |           100 |

## Overall Performance Summary (Per Run)

| Test Case | Guillotine | REVM | EthereumJS | Geth | evmone |
|-----------|------------|------|------------|------|--------|
| erc20-approval-transfer   | 5.91 ms | 18.95 μs | 0.00 μs | 0.00 μs | 0.00 μs |
| erc20-mint                | 4.50 ms | 18.84 μs | 0.00 μs | 0.00 μs | 0.00 μs |
| erc20-transfer            | 7.27 ms | 18.87 μs | 0.00 μs | 0.00 μs | 0.00 μs |
| ten-thousand-hashes       | 2.74 ms | 17.05 μs | 11.88 ms | 47.05 μs | 17.50 μs |
| snailtracer               | 206.20 ms | 165.01 μs | 0.00 μs | 0.00 μs | 0.00 μs |
| opcodes-arithmetic        | 17.13 μs | 17.14 μs | 11.82 ms | 45.46 μs | 16.89 μs |
| opcodes-arithmetic-advanced | 17.52 μs | 16.94 μs | 11.85 ms | 47.48 μs | 17.68 μs |
| opcodes-bitwise           | 16.84 μs | 17.49 μs | 11.82 ms | 46.34 μs | 17.37 μs |
| opcodes-block-1           | 21.69 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |
| opcodes-block-2           | 19.97 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |
| opcodes-comparison        | 16.81 μs | 17.25 μs | 11.84 ms | 45.63 μs | 17.15 μs |
| opcodes-control           | 23.38 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |
| opcodes-crypto            | 19.87 μs | 416.36 μs | 0.00 μs | 0.00 μs | 0.00 μs |
| opcodes-data              | 18.08 μs | 0.00 μs | 0.00 μs | 0.00 μs | 53.55 μs |
| opcodes-dup               | 16.88 μs | 17.26 μs | 11.79 ms | 45.99 μs | 16.88 μs |
| opcodes-environmental-1   | 16.68 μs | 16.94 μs | 11.81 ms | 48.02 μs | 16.71 μs |
| opcodes-environmental-2   | 23.42 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |
| opcodes-jump-basic        | 14.34 μs | 17.61 μs | 11.71 ms | 46.45 μs | 16.89 μs |
| opcodes-memory            | 17.89 μs | 16.97 μs | 11.78 ms | 46.99 μs | 18.41 μs |
| opcodes-push-pop          | 16.92 μs | 17.17 μs | 11.76 ms | 46.23 μs | 17.38 μs |
| opcodes-storage-cold      | 17.40 μs | 17.13 μs | 11.87 ms | 46.26 μs | 17.86 μs |
| opcodes-storage-warm      | 16.67 μs | 17.08 μs | 11.84 ms | 45.15 μs | 16.89 μs |
| opcodes-swap              | 16.87 μs | 17.74 μs | 11.65 ms | 47.13 μs | 16.73 μs |
| precompile-blake2f        | 18.51 μs | 0.00 μs | 0.00 μs | 0.00 μs | 33.97 μs |
| precompile-bn256add       | 29.86 μs | 240.49 μs | 0.00 μs | 0.00 μs | 0.00 μs |
| precompile-bn256mul       | 22.05 μs | 246.23 μs | 0.00 μs | 0.00 μs | 0.00 μs |
| precompile-bn256pairing   | 88.96 μs | 30.08 μs | 0.00 μs | 0.00 μs | 0.00 μs |
| precompile-ecrecover      | 17.67 μs | 342.80 μs | 0.00 μs | 88.11 μs | 21.64 μs |
| precompile-identity       | 52.67 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |
| precompile-modexp         | 17.67 μs | 49.47 μs | 0.00 μs | 0.00 μs | 0.00 μs |
| precompile-ripemd160      | 15.76 μs | 0.00 μs | 0.00 μs | 0.00 μs | 28.75 μs |
| precompile-sha256         | 15.53 μs | 0.00 μs | 0.00 μs | 0.00 μs | 0.00 μs |

## Notes

- **All times are normalized per individual execution run**
- Times are displayed in the most appropriate unit (μs, ms, or s)
- All implementations use optimized builds:
  - Zig: ReleaseFast
  - Rust (REVM): --release
  - JavaScript (EthereumJS): Bun runtime
  - Go (geth): -O3 optimizations
  - C++ (evmone): -O3 -march=native
- Lower values indicate better performance
- Each hyperfine run executes the contract multiple times internally (see Internal Runs column)
- These benchmarks measure the full execution time including contract deployment

---

*Generated by Guillotine Benchmark Orchestrator*
