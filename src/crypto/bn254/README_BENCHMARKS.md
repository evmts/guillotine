# BN254 Comprehensive Pairing Library Benchmarks

This directory contains a comprehensive, high-quality benchmark suite for the BN254 pairing library implementation in Zig. The benchmarks are designed for performance analysis, optimization tracking, and comparison with other cryptographic libraries.

## Features

### 🔥 High-Quality Benchmarking
- **Cryptographically secure random input generation** using ChaCha20 PRNG
- **Statistical analysis** with confidence intervals, percentiles, and standard deviations
- **Comprehensive coverage** of all major operations in the BN254 elliptic curve pairing library
- **Performance tracking** suitable for detecting regressions and improvements
- **Multiple benchmark implementations** for different use cases

### 📊 Statistical Rigor
- 95% confidence intervals for all measurements
- P95, P99, and P999 percentile reporting
- Standard deviation and coefficient of variation analysis
- Automatic outlier detection and handling
- Warmup phase to eliminate cold-start effects

### 🚀 Comprehensive Operation Coverage

#### Field Operations
- **Base Field (Fp)**: Addition, subtraction, multiplication, squaring, inversion
- **Quadratic Extension (Fp2)**: All arithmetic operations with complex number semantics
- **Sextic Extension (Fp6)**: Tower field operations for pairing intermediate calculations
- **Dodecic Extension (Fp12)**: Full target group operations for pairing results
- **Scalar Field (Fr)**: Operations on curve scalar multipliers

#### Elliptic Curve Operations
- **G1 Group** (Base curve over Fp):
  - Point addition and doubling
  - Scalar multiplication (most performance-critical operation)
  - Point negation and affine conversion
  - Curve validation and membership testing

- **G2 Group** (Twisted curve over Fp2):
  - All G1 operations extended to the quadratic extension
  - Frobenius map operations
  - Compressed/uncompressed point handling

#### Pairing Operations
- **Complete pairing computation** (e: G1 × G2 → Fp12)
- **Miller loop** (core pairing algorithm)
- **Final exponentiation** (both easy and hard parts)
- **Multi-pairing optimizations** for batch verification

## Benchmark Implementations

### 1. `comprehensive_benchmarks.zig` - Standalone Suite
**Recommended for most users**

- **No external dependencies** - works out of the box
- **Statistical analysis** with comprehensive reporting
- **Beautiful console output** with formatted tables and progress indicators
- **Configurable iteration counts** for different precision vs speed tradeoffs

```bash
# Quick performance check (10 iterations per operation)
zig test src/crypto/bn254/comprehensive_benchmarks.zig --test-filter "BN254 Quick Performance Check"

# Full comprehensive benchmarks (thousands of iterations)
zig test src/crypto/bn254/comprehensive_benchmarks.zig --test-filter "BN254 Comprehensive Performance Benchmarks"
```

**Example Output:**
```
╔══════════════════════════════════════════════════════════════════════════════╗
║   BN254 Comprehensive Pairing Library Performance Benchmarks               ║
╚══════════════════════════════════════════════════════════════════════════════╝

┌──────────────────────────────┬────────────┬────────────┬───────────────┬───────┐
│ Operation                    │ Mean (±σ)  │ Std Dev    │ Ops/Second    │ n     │
├──────────────────────────────┼────────────┼────────────┼───────────────┼───────┤
│ Fp Addition                  │    45.2 ns │    12.1 ns │ 22,123,504    │ 10000 │
│ Fp Multiplication            │   157.8 ns │    23.4 ns │  6,336,785    │ 10000 │
│ G1 Scalar Multiplication     │   245.6 μs │    15.2 μs │      4,072    │   100 │
│ Full Pairing                 │    8.2 ms  │   0.4 ms   │        122    │    20 │
```

### 2. `zbench_benchmarks.zig` - zbench Integration
**For advanced users with zbench configured**

- **Professional zbench integration** with full statistical framework
- **Advanced configuration options** for specialized benchmarking scenarios
- **Memory allocation tracking** and performance profiling
- **Cross-library comparison support**

**Setup Required:**
```zig
// In your build.zig
const zbench = b.dependency("zbench", .{});
bn254_module.addImport("zbench", zbench.module("zbench"));
```

### 3. Legacy `benchmarks.zig` - Simple Timing
**Basic timing measurements for quick checks**

- Simple nano-timestamp based timing
- Minimal dependencies and setup
- Compatible with existing benchmark infrastructure

## Performance Baselines

### Expected Performance Ranges
These are approximate ranges for modern x86_64 processors (Intel Core i7/i9, AMD Ryzen):

| Operation | Typical Range | Best Case | Notes |
|-----------|---------------|-----------|-------|
| **Fp Addition** | 30-80 ns | ~25 ns | Memory bandwidth limited |
| **Fp Multiplication** | 100-300 ns | ~80 ns | Montgomery form optimized |
| **Fp Inversion** | 8-15 μs | ~6 μs | Extended Euclidean algorithm |
| **Fp2 Multiplication** | 300-600 ns | ~200 ns | 3 base field mults + adds |
| **Fp12 Multiplication** | 2-8 μs | ~1.5 μs | Tower field optimizations |
| **G1 Addition** | 200-800 ns | ~150 ns | Jacobian coordinates |
| **G1 Scalar Mult** | 150-600 μs | ~100 μs | Windowed NAF method |
| **G2 Addition** | 800-2000 ns | ~600 ns | Fp2 coefficient overhead |
| **G2 Scalar Mult** | 600-2000 μs | ~400 μs | Extension field complexity |
| **Miller Loop** | 2-8 ms | ~1.5 ms | Core pairing computation |
| **Final Exponentiation** | 1-4 ms | ~800 μs | Hard part dominates |
| **Complete Pairing** | 4-15 ms | ~3 ms | Miller + final exp |

### Factors Affecting Performance

1. **CPU Architecture**: Modern processors with advanced vector units perform better
2. **Compiler Optimizations**: `-O ReleaseFast` vs `-O Debug` can show 5-10x differences
3. **Memory Patterns**: Random vs sequential access patterns affect cache performance
4. **Input Distribution**: Some inputs trigger worst-case behavior in algorithms
5. **System Load**: Other processes can affect timing measurements

## Usage Guide

### Quick Start
```bash
# Run a quick performance check (recommended for CI/CD)
zig test src/crypto/bn254/comprehensive_benchmarks.zig --test-filter "Quick"

# Full benchmark suite (for detailed analysis)
zig test src/crypto/bn254/comprehensive_benchmarks.zig --test-filter "Comprehensive"
```

### Integration in Your Code
```zig
const bn254_bench = @import("path/to/comprehensive_benchmarks.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    
    try bn254_bench.runComprehensiveBenchmarks(gpa.allocator());
}
```

### Custom Benchmarking
```zig
const bn254_bench = @import("comprehensive_benchmarks.zig");

// Benchmark a specific operation
var rng = bn254_bench.SecureRandomGenerator.init();
const stats = try bn254_bench.benchmark(allocator, "Custom Op", customBenchmarkFn, 1000);
try stats.format(std.io.getStdOut().writer());
```

## Interpreting Results

### Key Metrics
- **Mean (±σ)**: Average execution time with one standard deviation
- **P95/P99/P999**: 95th/99th/99.9th percentile latencies (important for worst-case analysis)  
- **Ops/Second**: Throughput metric for comparison
- **Confidence Interval**: Statistical certainty range for the mean

### Performance Analysis
1. **Look for outliers**: High P99 compared to mean indicates inconsistent performance
2. **Compare with baselines**: Significant deviations may indicate regressions or improvements
3. **Consider standard deviation**: High σ suggests unstable performance
4. **Evaluate in context**: Different operations have vastly different expected ranges

### Regression Detection
- **>10% change in mean**: Likely significant performance change
- **>20% change in P95**: Possible algorithmic regression
- **Confidence intervals not overlapping**: Strong evidence of performance change

## Best Practices

### For Accurate Measurements
1. **Run on dedicated hardware** when possible
2. **Disable CPU frequency scaling** for consistent results  
3. **Close unnecessary applications** to reduce system noise
4. **Use release builds** (`-O ReleaseFast`) for meaningful performance data
5. **Run multiple times** and look for consistency across runs

### For Comparison Studies
1. **Use identical hardware** across different implementations
2. **Measure warm-up behavior** separately from steady-state performance
3. **Consider memory allocation patterns** - some libraries use different strategies
4. **Account for input distribution effects** - random inputs may not represent real workloads

### For Performance Optimization
1. **Profile before optimizing** - identify actual bottlenecks
2. **Measure small changes carefully** - noise can mask real improvements
3. **Test across different input patterns** - optimizations may be input-dependent
4. **Validate correctness** - ensure optimizations don't break functionality

## Technical Implementation Details

### Random Input Generation
The benchmark suite uses cryptographically secure random number generation to ensure:
- **Uniform distribution** across the field/group elements
- **No predictable patterns** that might trigger algorithmic shortcuts
- **Reproducible results** with optional seeding for deterministic testing
- **Proper edge case coverage** including near-zero and near-modulus values

### Statistical Methods
- **Central Limit Theorem application** for confidence interval calculation
- **Percentile estimation** using linear interpolation for non-integer indices  
- **Outlier detection** using interquartile range (IQR) method
- **Sample size determination** based on desired statistical power

### Memory Management
- **Zero allocation** in timing critical paths
- **Pre-allocated input arrays** to eliminate allocation noise
- **Careful use of `doNotOptimizeAway`** to prevent compiler elimination
- **Stack-based storage** for intermediate results when possible

## Troubleshooting

### Common Issues
1. **Inconsistent results**: System load, thermal throttling, or power management
2. **Unexpectedly slow**: Debug builds, insufficient warmup, or memory pressure  
3. **Compilation errors**: Missing dependencies, incorrect Zig version
4. **Statistical anomalies**: Insufficient sample size or systematic measurement bias

### Debugging Performance Issues
1. **Check CPU frequency scaling**: `cat /proc/cpuinfo | grep MHz`
2. **Monitor system resources**: `htop`, `iostat`, `vmstat`
3. **Profile memory allocation**: Enable zbench allocation tracking
4. **Compare with known baselines**: Sanity check against expected ranges

## Contributing

When adding new benchmarks:
1. **Follow existing patterns** for consistency
2. **Include comprehensive documentation** explaining the operation
3. **Add expected performance ranges** based on testing
4. **Ensure statistical validity** with adequate sample sizes
5. **Test on multiple architectures** when possible

### Code Style Guidelines
- Use descriptive benchmark names (e.g., "G1 Scalar Multiplication", not "G1 Mul")
- Include input parameter descriptions in comments
- Follow the secure random input generation patterns
- Add appropriate `doNotOptimizeAway` calls to prevent elimination

## References

- [BN254 Curve Specification](https://eips.ethereum.org/eip-196)
- [Pairing-Based Cryptography Implementation Guide](https://eprint.iacr.org/2019/077.pdf)
- [Statistical Methods for Performance Analysis](https://www.cse.wustl.edu/~jain/papers/ftp/perfmeas.pdf)
- [zbench Documentation](https://github.com/hendriknielaender/zBench)

---

This benchmark suite represents a professional-grade performance analysis toolkit for the BN254 pairing library. It provides the statistical rigor and comprehensive coverage needed for serious cryptographic performance analysis and optimization work.