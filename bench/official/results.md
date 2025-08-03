# EVM Benchmark Comparison Results

## Summary

**Test Runs per Case**: 1
**EVMs Compared**: Guillotine (Zig), REVM (Rust), EthereumJS (JavaScript), Geth (Go), evmone (C++)
**Timestamp**: 1754252738 (Unix epoch)

## Performance Comparison

### erc20-approval-transfer

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |     60.70 |       60.70 |    60.70 |    60.70 |        0.00 |
| REVM        |     54.82 |       54.82 |    54.82 |    54.82 |        0.00 |
| EthereumJS  |   3493.40 |     3493.40 |  3493.40 |  3493.40 |        0.00 |
| Geth        |    111.60 |      111.60 |   111.60 |   111.60 |        0.00 |
| evmone      |      1.62 |        1.62 |     1.62 |     1.62 |        0.00 |

### erc20-mint

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |     45.64 |       45.64 |    45.64 |    45.64 |        0.00 |
| REVM        |     43.26 |       43.26 |    43.26 |    43.26 |        0.00 |
| EthereumJS  |   3710.54 |     3710.54 |  3710.54 |  3710.54 |        0.00 |
| Geth        |     98.91 |       98.91 |    98.91 |    98.91 |        0.00 |
| evmone      |      1.60 |        1.60 |     1.60 |     1.60 |        0.00 |

### erc20-transfer

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |     73.79 |       73.79 |    73.79 |    73.79 |        0.00 |
| REVM        |     68.71 |       68.71 |    68.71 |    68.71 |        0.00 |
| EthereumJS  |   5133.61 |     5133.61 |  5133.61 |  5133.61 |        0.00 |
| Geth        |    148.67 |      148.67 |   148.67 |   148.67 |        0.00 |
| evmone      |      1.62 |        1.62 |     1.62 |     1.62 |        0.00 |

### ten-thousand-hashes

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |     28.80 |       28.80 |    28.80 |    28.80 |        0.00 |
| REVM        |     18.86 |       18.86 |    18.86 |    18.86 |        0.00 |
| EthereumJS  |   2218.82 |     2218.82 |  2218.82 |  2218.82 |        0.00 |
| Geth        |     55.08 |       55.08 |    55.08 |    55.08 |        0.00 |
| evmone      |      1.60 |        1.60 |     1.60 |     1.60 |        0.00 |

### snailtracer

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |   2061.34 |     2061.34 |  2061.34 |  2061.34 |        0.00 |
| REVM        |    708.68 |      708.68 |   708.68 |   708.68 |        0.00 |
| EthereumJS  |   3707.36 |     3707.36 |  3707.36 |  3707.36 |        0.00 |
| Geth        |    818.76 |      818.76 |   818.76 |   818.76 |        0.00 |
| evmone      |      1.74 |        1.74 |     1.74 |     1.74 |        0.00 |

### opcodes-arithmetic

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      1.39 |        1.39 |     1.39 |     1.39 |        0.00 |
| Guillotine  |      1.44 |        1.44 |     1.44 |     1.44 |        0.00 |
| REVM        |      1.52 |        1.52 |     1.52 |     1.52 |        0.00 |
| REVM        |      1.53 |        1.53 |     1.53 |     1.53 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| evmone      |      1.65 |        1.65 |     1.65 |     1.65 |        0.00 |
| evmone      |      1.60 |        1.60 |     1.60 |     1.60 |        0.00 |

### opcodes-arithmetic-advanced

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      1.39 |        1.39 |     1.39 |     1.39 |        0.00 |
| REVM        |      1.52 |        1.52 |     1.52 |     1.52 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| evmone      |      1.65 |        1.65 |     1.65 |     1.65 |        0.00 |

### opcodes-bitwise

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      1.37 |        1.37 |     1.37 |     1.37 |        0.00 |
| REVM        |      1.54 |        1.54 |     1.54 |     1.54 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| evmone      |      1.58 |        1.58 |     1.58 |     1.58 |        0.00 |

### opcodes-block-1

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      2.06 |        2.06 |     2.06 |     2.06 |        0.00 |
| REVM        |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |      7.25 |        7.25 |     7.25 |     7.25 |        0.00 |
| evmone      |      2.24 |        2.24 |     2.24 |     2.24 |        0.00 |

### opcodes-block-2

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      1.99 |        1.99 |     1.99 |     1.99 |        0.00 |
| REVM        |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |      6.88 |        6.88 |     6.88 |     6.88 |        0.00 |
| evmone      |      2.15 |        2.15 |     2.15 |     2.15 |        0.00 |

### opcodes-comparison

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      1.48 |        1.48 |     1.48 |     1.48 |        0.00 |
| REVM        |      1.53 |        1.53 |     1.53 |     1.53 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| evmone      |      1.59 |        1.59 |     1.59 |     1.59 |        0.00 |

### opcodes-control

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      2.24 |        2.24 |     2.24 |     2.24 |        0.00 |
| REVM        |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |      8.66 |        8.66 |     8.66 |     8.66 |        0.00 |
| evmone      |      2.58 |        2.58 |     2.58 |     2.58 |        0.00 |

### opcodes-crypto

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      1.96 |        1.96 |     1.96 |     1.96 |        0.00 |
| REVM        |      2.09 |        2.09 |     2.09 |     2.09 |        0.00 |
| EthereumJS  |    138.66 |      138.66 |   138.66 |   138.66 |        0.00 |
| Geth        |     10.10 |       10.10 |    10.10 |    10.10 |        0.00 |
| evmone      |      1.82 |        1.82 |     1.82 |     1.82 |        0.00 |

### opcodes-data

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      1.79 |        1.79 |     1.79 |     1.79 |        0.00 |
| REVM        |      1.91 |        1.91 |     1.91 |     1.91 |        0.00 |
| EthereumJS  |    131.41 |      131.41 |   131.41 |   131.41 |        0.00 |
| Geth        |      6.54 |        6.54 |     6.54 |     6.54 |        0.00 |
| evmone      |      1.91 |        1.91 |     1.91 |     1.91 |        0.00 |

### opcodes-dup

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      1.49 |        1.49 |     1.49 |     1.49 |        0.00 |
| REVM        |      1.57 |        1.57 |     1.57 |     1.57 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| evmone      |      1.63 |        1.63 |     1.63 |     1.63 |        0.00 |

### opcodes-environmental-1

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      1.40 |        1.40 |     1.40 |     1.40 |        0.00 |
| REVM        |      1.62 |        1.62 |     1.62 |     1.62 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| evmone      |      1.61 |        1.61 |     1.61 |     1.61 |        0.00 |

### opcodes-environmental-2

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      2.33 |        2.33 |     2.33 |     2.33 |        0.00 |
| REVM        |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |      8.43 |        8.43 |     8.43 |     8.43 |        0.00 |
| evmone      |      2.53 |        2.53 |     2.53 |     2.53 |        0.00 |

### opcodes-jump-basic

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      1.39 |        1.39 |     1.39 |     1.39 |        0.00 |
| REVM        |      1.48 |        1.48 |     1.48 |     1.48 |        0.00 |
| EthereumJS  |    119.43 |      119.43 |   119.43 |   119.43 |        0.00 |
| Geth        |      4.12 |        4.12 |     4.12 |     4.12 |        0.00 |
| evmone      |      1.74 |        1.74 |     1.74 |     1.74 |        0.00 |

### opcodes-memory

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      1.38 |        1.38 |     1.38 |     1.38 |        0.00 |
| REVM        |      1.50 |        1.50 |     1.50 |     1.50 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| evmone      |      1.59 |        1.59 |     1.59 |     1.59 |        0.00 |

### opcodes-push-pop

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      1.44 |        1.44 |     1.44 |     1.44 |        0.00 |
| REVM        |      1.53 |        1.53 |     1.53 |     1.53 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| evmone      |      1.57 |        1.57 |     1.57 |     1.57 |        0.00 |

### opcodes-storage-cold

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      1.52 |        1.52 |     1.52 |     1.52 |        0.00 |
| REVM        |      1.52 |        1.52 |     1.52 |     1.52 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| evmone      |      1.68 |        1.68 |     1.68 |     1.68 |        0.00 |

### opcodes-storage-warm

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      1.38 |        1.38 |     1.38 |     1.38 |        0.00 |
| REVM        |      1.53 |        1.53 |     1.53 |     1.53 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| evmone      |      1.52 |        1.52 |     1.52 |     1.52 |        0.00 |

### opcodes-swap

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      1.46 |        1.46 |     1.46 |     1.46 |        0.00 |
| REVM        |      1.54 |        1.54 |     1.54 |     1.54 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| evmone      |      1.59 |        1.59 |     1.59 |     1.59 |        0.00 |

### precompile-blake2f

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      1.77 |        1.77 |     1.77 |     1.77 |        0.00 |
| REVM        |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |      4.93 |        4.93 |     4.93 |     4.93 |        0.00 |
| evmone      |      2.11 |        2.11 |     2.11 |     2.11 |        0.00 |

### precompile-bn256add

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      3.11 |        3.11 |     3.11 |     3.11 |        0.00 |
| REVM        |      1.80 |        1.80 |     1.80 |     1.80 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |     10.29 |       10.29 |    10.29 |    10.29 |        0.00 |
| evmone      |      1.66 |        1.66 |     1.66 |     1.66 |        0.00 |

### precompile-bn256mul

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      2.19 |        2.19 |     2.19 |     2.19 |        0.00 |
| REVM        |      1.74 |        1.74 |     1.74 |     1.74 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |     55.03 |       55.03 |    55.03 |    55.03 |        0.00 |
| evmone      |      1.86 |        1.86 |     1.86 |     1.86 |        0.00 |

### precompile-bn256pairing

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      8.89 |        8.89 |     8.89 |     8.89 |        0.00 |
| REVM        |      1.60 |        1.60 |     1.60 |     1.60 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |     94.83 |       94.83 |    94.83 |    94.83 |        0.00 |
| evmone      |      1.53 |        1.53 |     1.53 |     1.53 |        0.00 |

### precompile-ecrecover

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      1.78 |        1.78 |     1.78 |     1.78 |        0.00 |
| REVM        |      2.06 |        2.06 |     2.06 |     2.06 |        0.00 |
| EthereumJS  |    182.10 |      182.10 |   182.10 |   182.10 |        0.00 |
| Geth        |      7.10 |        7.10 |     7.10 |     7.10 |        0.00 |
| evmone      |      1.73 |        1.73 |     1.73 |     1.73 |        0.00 |

### precompile-identity

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      5.58 |        5.58 |     5.58 |     5.58 |        0.00 |
| REVM        |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| EthereumJS  |      0.00 |        0.00 |     0.00 |     0.00 |        0.00 |
| Geth        |      6.09 |        6.09 |     6.09 |     6.09 |        0.00 |
| evmone      |      2.04 |        2.04 |     2.04 |     2.04 |        0.00 |

### precompile-modexp

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      1.67 |        1.67 |     1.67 |     1.67 |        0.00 |
| REVM        |      1.58 |        1.58 |     1.58 |     1.58 |        0.00 |
| EthereumJS  |    196.88 |      196.88 |   196.88 |   196.88 |        0.00 |
| Geth        |      4.39 |        4.39 |     4.39 |     4.39 |        0.00 |
| evmone      |      1.65 |        1.65 |     1.65 |     1.65 |        0.00 |

### precompile-ripemd160

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      1.55 |        1.55 |     1.55 |     1.55 |        0.00 |
| REVM        |      1.59 |        1.59 |     1.59 |     1.59 |        0.00 |
| EthereumJS  |    117.11 |      117.11 |   117.11 |   117.11 |        0.00 |
| Geth        |      3.94 |        3.94 |     3.94 |     3.94 |        0.00 |
| evmone      |      1.88 |        1.88 |     1.88 |     1.88 |        0.00 |

### precompile-sha256

| EVM | Mean (ms) | Median (ms) | Min (ms) | Max (ms) | Std Dev (ms) |
|-----|-----------|-------------|----------|----------|-------------|
| Guillotine  |      1.52 |        1.52 |     1.52 |     1.52 |        0.00 |
| REVM        |      2.15 |        2.15 |     2.15 |     2.15 |        0.00 |
| EthereumJS  |    116.33 |      116.33 |   116.33 |   116.33 |        0.00 |
| Geth        |      4.05 |        4.05 |     4.05 |     4.05 |        0.00 |
| evmone      |      1.80 |        1.80 |     1.80 |     1.80 |        0.00 |

## Overall Performance Summary

| Test Case | Guillotine (ms) | REVM (ms) | EthereumJS (ms) | Geth (ms) | evmone (ms) |
|-----------|-----------------|-----------|-----------|-----------|-------------|
| erc20-approval-transfer   |           60.70 |     54.82 |   3493.40 |    111.60 |        1.62 |
| erc20-mint                |           45.64 |     43.26 |   3710.54 |     98.91 |        1.60 |
| erc20-transfer            |           73.79 |     68.71 |   5133.61 |    148.67 |        1.62 |
| ten-thousand-hashes       |           28.80 |     18.86 |   2218.82 |     55.08 |        1.60 |
| snailtracer               |         2061.34 |    708.68 |   3707.36 |    818.76 |        1.74 |
| opcodes-arithmetic        |            1.44 |      1.53 |      0.00 |      0.00 |        1.60 |
| opcodes-arithmetic-advanced |            1.39 |      1.52 |      0.00 |      0.00 |        1.65 |
| opcodes-bitwise           |            1.37 |      1.54 |      0.00 |      0.00 |        1.58 |
| opcodes-block-1           |            2.06 |      0.00 |      0.00 |      7.25 |        2.24 |
| opcodes-block-2           |            1.99 |      0.00 |      0.00 |      6.88 |        2.15 |
| opcodes-comparison        |            1.48 |      1.53 |      0.00 |      0.00 |        1.59 |
| opcodes-control           |            2.24 |      0.00 |      0.00 |      8.66 |        2.58 |
| opcodes-crypto            |            1.96 |      2.09 |    138.66 |     10.10 |        1.82 |
| opcodes-data              |            1.79 |      1.91 |    131.41 |      6.54 |        1.91 |
| opcodes-dup               |            1.49 |      1.57 |      0.00 |      0.00 |        1.63 |
| opcodes-environmental-1   |            1.40 |      1.62 |      0.00 |      0.00 |        1.61 |
| opcodes-environmental-2   |            2.33 |      0.00 |      0.00 |      8.43 |        2.53 |
| opcodes-jump-basic        |            1.39 |      1.48 |    119.43 |      4.12 |        1.74 |
| opcodes-memory            |            1.38 |      1.50 |      0.00 |      0.00 |        1.59 |
| opcodes-push-pop          |            1.44 |      1.53 |      0.00 |      0.00 |        1.57 |
| opcodes-storage-cold      |            1.52 |      1.52 |      0.00 |      0.00 |        1.68 |
| opcodes-storage-warm      |            1.38 |      1.53 |      0.00 |      0.00 |        1.52 |
| opcodes-swap              |            1.46 |      1.54 |      0.00 |      0.00 |        1.59 |
| precompile-blake2f        |            1.77 |      0.00 |      0.00 |      4.93 |        2.11 |
| precompile-bn256add       |            3.11 |      1.80 |      0.00 |     10.29 |        1.66 |
| precompile-bn256mul       |            2.19 |      1.74 |      0.00 |     55.03 |        1.86 |
| precompile-bn256pairing   |            8.89 |      1.60 |      0.00 |     94.83 |        1.53 |
| precompile-ecrecover      |            1.78 |      2.06 |    182.10 |      7.10 |        1.73 |
| precompile-identity       |            5.58 |      0.00 |      0.00 |      6.09 |        2.04 |
| precompile-modexp         |            1.67 |      1.58 |    196.88 |      4.39 |        1.65 |
| precompile-ripemd160      |            1.55 |      1.59 |    117.11 |      3.94 |        1.88 |
| precompile-sha256         |            1.52 |      2.15 |    116.33 |      4.05 |        1.80 |

## Notes

- All implementations use optimized builds:
  - Zig: ReleaseFast
  - Rust (REVM): --release
  - JavaScript (EthereumJS): Bun runtime
  - Go (geth): -O3 optimizations
  - C++ (evmone): -O3 -march=native
- All times are in milliseconds (ms)
- Lower values indicate better performance
- These benchmarks measure the full execution time including contract deployment

---

*Generated by Guillotine Benchmark Orchestrator*
