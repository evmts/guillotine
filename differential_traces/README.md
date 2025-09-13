# Differential Testing Traces

This directory contains execution traces generated during differential testing between Guillotine EVM and revm. These traces are used to debug execution differences and validate EVM correctness.

## Overview

Differential testing is a critical component of Guillotine's testing strategy. It involves running the same EVM execution on both Guillotine and revm (the reference Rust implementation), then comparing their:

- **Execution success/failure status**
- **Gas consumption** 
- **Output data**
- **Step-by-step execution traces** (when enabled)

When differences are detected, detailed traces are written to this directory for analysis and debugging.

## Trace Files

### Format

Execution traces are stored as JSON files containing a sequence of execution steps. Each step represents one opcode execution with the following structure:

```json
{
  "pc": 0,                    // Program counter
  "op": 96,                   // Opcode number (0x60 = PUSH1)
  "gas": "0x3b9a77b8",        // Gas remaining (hex string)
  "gasCost": "0x3",           // Gas cost of this operation
  "stack": ["0x80"],          // Stack contents (top to bottom)
  "depth": 1,                 // Call depth
  "returnData": "0x",         // Return data buffer
  "refund": "0x0",            // Gas refund counter
  "memSize": "0",             // Memory size in bytes
  "opName": "PUSH1"           // Human-readable opcode name
}
```

### Naming Convention

Trace files follow the pattern:
- `{test_case}_revm_trace.json` - Trace from revm execution
- `{test_case}_guillotine_trace.json` - Trace from Guillotine execution  
- `{test_case}_divergence.txt` - Analysis of where execution diverged

### Example Files

- `snailtracer_revm_trace.json` - Large trace (208K+ steps, ~200MB) from the snailtracer contract test

## Generating Traces

### Automatic Generation

Traces are automatically generated when differential tests detect execution differences. This happens during:

1. **Test suite execution** - `zig build test-opcodes`
2. **Specific differential tests** - `zig build test test/differential/`
3. **Manual trace generation** - Using the `diff-trace.sh` script

### Manual Trace Generation

Use the provided script to generate traces for specific test cases:

```bash
# Generate traces for the ten-thousand-hashes test case
./scripts/diff-trace.sh ten-thousand-hashes

# Results will be in bench/official/diff_output/
```

### Enabling Trace Output

Traces are controlled by the `DifferentialConfig` in test code:

```zig
const config = evm.differential_tracer.DifferentialConfig{
    .write_trace_files = true,  // Enable trace file generation
    .context_before = 10,       // Steps to show before divergence  
    .context_after = 10,        // Steps to show after divergence
    .max_differences = 5,       // Max differences before stopping
};
```

## Using Traces for Debugging

### 1. Identify Divergence Points

When tests fail with `ExecutionDivergence`, look for:

- **Gas differences** - May indicate missing opcode implementations
- **Stack mismatches** - Incorrect stack manipulation
- **Output differences** - Wrong execution results
- **Success/failure mismatches** - Incorrect revert conditions

### 2. Trace Analysis

Compare trace files step by step to find where execution first differs:

```bash
# Large traces should be analyzed with tools
head -100 snailtracer_revm_trace.json
head -100 snailtracer_guillotine_trace.json

# Look for the first step where PC, stack, or gas differs
```

### 3. Common Debug Patterns

- **PC mismatch early** - Usually indicates wrong jump/branch logic
- **Stack depth differences** - Missing pop/push operations  
- **Gas consumption differences** - Incorrect gas calculations
- **Memory size differences** - Wrong memory expansion logic

### 4. Debugging Tools

The differential tracer provides built-in debugging:

```bash
# Enable verbose differential output
TRACE=1 zig build test-opcodes

# The tracer will show:
# - First few execution steps
# - Divergence points with context
# - Final execution state comparison
```

## Trace File Management

### Storage Considerations

Traces can be extremely large:
- Simple operations: ~1KB - 10KB
- Complex contracts: 1MB - 10MB  
- Long-running contracts: 100MB+ (like snailtracer)

### Cleanup

Trace files are not automatically cleaned up. Remove old traces periodically:

```bash
# Clean all traces older than 7 days
find differential_traces/ -name "*.json" -mtime +7 -delete
find differential_traces/ -name "*_divergence.txt" -mtime +7 -delete
```

### Selective Generation

For large contracts, consider disabling traces unless actively debugging:

```zig
const config = evm.differential_tracer.DifferentialConfig{
    .write_trace_files = false, // Disable for performance
    // Traces will still be compared in memory for small contracts
};
```

## Integration with Testing

### Test-Driven Debugging

1. **Write a failing test** that demonstrates the bug
2. **Enable trace generation** in the test configuration
3. **Run the test** to generate trace files
4. **Analyze traces** to identify the root cause
5. **Fix the implementation**
6. **Re-run test** to verify the fix

### Continuous Integration

In CI environments:
- Traces are generated only for failed tests
- Large trace files are compressed before upload
- Trace analysis is automated where possible

### Performance Impact

Tracing has significant performance overhead:
- **Memory**: Each step allocates trace data
- **I/O**: Writing large JSON files to disk
- **CPU**: JSON serialization and string formatting

Only enable tracing when actively debugging execution differences.

## Reference Implementation

The differential tracer (`src/_test_utils/differential_tracer.zig`) handles:

- **EVM synchronization** - Keeping both EVMs in sync
- **Trace collection** - Gathering execution data from both EVMs
- **Result comparison** - Detecting and reporting differences  
- **File output** - Writing traces and analysis to disk

See `test/evm/snailtracer_test.zig` for an example of trace-enabled testing.

## Related Documentation

- [Differential Testing Overview](../test/differential/README.md)
- [Popular Contracts Testing](../test/differential/POPULAR_CONTRACTS_README.md)
- [Testing Architecture](../docs/pages/advanced/testing/unit.mdx)
- [Build System](../CLAUDE.md#commands)