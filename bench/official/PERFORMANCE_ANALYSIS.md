# Detailed Performance Analysis for Zig EVM

This document describes the enhanced performance analysis capabilities added to the Guillotine EVM benchmarking system.

## Overview

The benchmarking system now supports detailed performance analysis with advanced metrics including:
- Cache miss statistics
- Branch prediction accuracy
- Instruction counts
- Memory access patterns
- Platform-specific performance counters

## Usage

### CLI Integration

The orchestrator now supports detailed performance analysis directly:

```bash
# Run detailed analysis with default settings
./zig-out/bin/orchestrator --detailed

# Specify custom output directory
./zig-out/bin/orchestrator --detailed --perf-output results

# Export detailed results
./zig-out/bin/orchestrator --export detailed

# Combine with other options
./zig-out/bin/orchestrator --detailed -n 50 --internal-runs 100
```

### Standalone Script

Use the `perf-detailed.sh` script for comprehensive analysis:

```bash
# Run detailed analysis for all test cases
./bench/official/perf-detailed.sh

# Compare with other EVMs
./bench/official/perf-detailed.sh --compare
```

## Output Structure

Detailed analysis creates timestamped directories containing:

```
perf-reports/
└── zig_<timestamp>/
    ├── detailed_report.md      # Summary report
    ├── <test>.json             # Hyperfine JSON output
    ├── <test>.csv              # CSV timing data
    ├── <test>_cache.txt        # Cache statistics (Linux)
    ├── <test>_branches.txt     # Branch prediction (Linux)
    ├── <test>_instructions.txt # Instruction counts (Linux)
    └── <test>_profile.trace    # Instruments trace (macOS)
```

## Platform-Specific Features

### Linux

On Linux systems with `perf` installed, additional metrics are collected:

- **Cache Statistics**: L1/L2 cache hits/misses, cache references
- **Branch Prediction**: Branch instructions, misprediction rates
- **Instruction Analysis**: Total instructions, cycles, IPC
- **Memory Patterns**: Page faults, TLB misses

### macOS

On macOS with Xcode tools installed:

- **Instruments Profiling**: Time profiler traces
- **System Trace**: System call analysis (optional)
- **Sample-based Profiling**: CPU sampling data

## Metrics Explained

### Cache Misses
- **L1-dcache-load-misses**: First-level data cache misses
- **L1-icache-load-misses**: Instruction cache misses
- **cache-references**: Total cache accesses
- **cache-misses**: Total cache misses across all levels

### Branch Prediction
- **branches**: Total branch instructions
- **branch-misses**: Mispredicted branches
- **branch-loads**: Branch load operations
- **branch-load-misses**: Branch load misses

### Instructions
- **instructions**: Total CPU instructions executed
- **cycles**: CPU cycles consumed
- **task-clock**: Time spent on CPU
- **IPC**: Instructions per cycle (higher is better)

## Interpreting Results

### Performance Indicators

**Good Performance**:
- High IPC (>1.0)
- Low cache miss rate (<5%)
- Low branch misprediction rate (<2%)
- Consistent timing (low std dev)

**Performance Issues**:
- Low IPC (<0.5) - CPU stalls
- High cache misses (>10%) - Poor memory locality
- High branch misprediction (>5%) - Unpredictable control flow
- High variance - System interference or unstable performance

### Optimization Opportunities

Based on metrics, consider:

1. **High Cache Misses**: Improve data locality, optimize memory access patterns
2. **Branch Misprediction**: Simplify control flow, use branchless algorithms
3. **Low IPC**: Reduce data dependencies, improve instruction-level parallelism
4. **Memory Bottlenecks**: Reduce allocations, improve memory layout

## Advanced Analysis

### Flamegraphs (Linux)

Generate CPU flamegraphs for visual profiling:

```bash
# Record performance data
sudo perf record -F 99 -g ./zig-out/bin/evm-runner \
    --contract-code-path bench/official/cases/snailtracer/bytecode.txt \
    --calldata 0x30627b7c --num-runs 1

# Generate flamegraph
sudo perf script | flamegraph > flamegraph.svg
```

### Differential Analysis

Compare performance between implementations:

```bash
# Run comparative analysis
./zig-out/bin/orchestrator --compare --export detailed

# Generate differential report
diff -u perf-reports/zig_*/detailed_report.md perf-reports/revm_*/detailed_report.md
```

## Troubleshooting

### Common Issues

1. **"perf not found" on Linux**
   ```bash
   sudo apt-get install linux-tools-common linux-tools-generic
   ```

2. **"instruments not found" on macOS**
   - Install Xcode Command Line Tools
   - Run with reduced security: `instruments -t "Time Profiler" ...`

3. **Permission denied for perf**
   ```bash
   # Allow unprivileged perf access
   sudo sysctl kernel.perf_event_paranoid=-1
   ```

## Integration with CI/CD

For automated performance regression detection:

```yaml
# Example GitHub Actions workflow
- name: Run Performance Analysis
  run: |
    ./zig-out/bin/orchestrator --detailed --perf-output ${{ github.sha }}
    
- name: Compare with Baseline
  run: |
    # Compare against main branch metrics
    ./scripts/compare_performance.sh ${{ github.sha }} main
```

## Future Enhancements

Planned improvements:
- [ ] Valgrind integration for memory profiling
- [ ] VTune support for Intel processors
- [ ] AMD uProf integration
- [ ] Automated regression detection
- [ ] Performance dashboard generation
- [ ] Historical trend analysis

## Contributing

To add new performance metrics:

1. Extend `runDetailedBenchmark` in `Orchestrator.zig`
2. Add platform-specific collection in `runPerfStat` or `runMacOSPerformanceAnalysis`
3. Update report generation in `generateDetailedReport`
4. Document new metrics in this file

## References

- [Hyperfine Documentation](https://github.com/sharkdp/hyperfine)
- [Linux Perf Wiki](https://perf.wiki.kernel.org/)
- [Instruments User Guide](https://help.apple.com/instruments/)
- [Brendan Gregg's Performance Resources](http://www.brendangregg.com/perf.html)