# Scripts

Build, development, and utility scripts for the Guillotine EVM project.

## Available Scripts

### Benchmarking & Performance

- **`perf-fast.sh`** - Fast benchmark runner with reduced iteration counts for quick feedback
  - Runs orchestrator with 2 outer runs, 20 internal runs
  - Opens results in browser via markserv
  - Usage: `./scripts/perf-fast.sh`

- **`perf-fastest.sh`** - Ultra-fast benchmark for immediate feedback
  - Single run per test case
  - Usage: `./scripts/perf-fastest.sh`

- **`perf-slow.sh`** - Comprehensive benchmarking with high iteration counts
  - 20 outer runs, 200 internal runs for statistical accuracy
  - Usage: `./scripts/perf-slow.sh`

- **`profile.sh`** - Performance profiling with flamegraph generation
  - Supports Linux (perf) and macOS profiling
  - Generates SVG flamegraphs for performance analysis
  - Usage: `./scripts/profile.sh [profile_name]`
  - Profiles: all, arithmetic_ops, memory_ops, storage_ops, stack_ops, control_flow, precompiles, contract_calls

- **`rust-benchmarks.sh`** - Run benchmarks using external Rust benchmark suite
  - Clones and builds evm-benchmarks repository
  - Usage: `./scripts/rust-benchmarks.sh [args]`

- **`cloud-bench-local.sh`** - Cloud benchmarking with AWS infrastructure
  - Builds AMIs with Packer and deploys with Terraform
  - Supports x86_64 and ARM64 architectures, spot/on-demand instances
  - Usage: `./scripts/cloud-bench-local.sh [x86|arm64|both] [spot|ondemand]`
  - Prerequisites: aws-cli, terraform, packer, jq

### Development & Debugging

- **`debug-zig-runner.sh`** - Debug mode runner with verbose output
  - Builds in Debug mode and runs all benchmark cases with detailed logging
  - Usage: `./scripts/debug-zig-runner.sh`

- **`diff-trace.sh`** - Differential trace analysis between Guillotine and REVM
  - Builds both implementations with tracing enabled
  - Compares execution traces to identify divergences
  - Usage: `./scripts/diff-trace.sh [test_case]` (default: ten-thousand-hashes)

- **`snailtracer.sh`** - Quick snailtracer test runner
  - Single test execution of the snailtracer benchmark
  - Usage: `./scripts/snailtracer.sh`

### Testing

- **`run-fuzz-tests.sh`** - Dockerized fuzz testing
  - Builds fuzz testing Docker container
  - Usage: `./scripts/run-fuzz-tests.sh`

### Analysis & Utilities

- **`analyze_bytecode.py`** - EVM bytecode block analysis for optimization
  - Analyzes opcode sequences, identifies fusion candidates
  - Focuses on real contracts (ERC20, snailtracer)
  - Usage: `python3 scripts/analyze_bytecode.py`

- **`count_jump_ops.py`** - Count jump-related opcodes in bytecode
  - Counts JUMP, JUMPI, and JUMPDEST instructions
  - Usage: `python3 scripts/count_jump_ops.py`

- **`count_pc.py`** - Count PC (program counter) opcodes across test cases
  - Analyzes PC opcode usage patterns
  - Usage: `python3 scripts/count_pc.py`

- **`fetch_contract_bytecode.sh`** - Download real contract bytecode from Ethereum
  - Uses Etherscan API to fetch contract bytecode
  - Usage: `./scripts/fetch_contract_bytecode.sh <contract_address> [api_key]`
  - Example: `./scripts/fetch_contract_bytecode.sh 0xA0b86a33E6Ba3b2a6b14b1a0b5b2c1234567890`

- **`wasm-analyze.py`** - WebAssembly bundle size analysis and optimization
  - Analyzes WASM build sizes, sections, and functions
  - Checks against size targets for CI/CD
  - Usage: 
    - `python3 scripts/wasm-analyze.py` (build and analyze)
    - `python3 scripts/wasm-analyze.py --no-build` (analyze existing)
    - `python3 scripts/wasm-analyze.py --update` (update benchmarks)
    - `python3 scripts/wasm-analyze.py --check` (CI size validation)

### macOS Distribution

- **`create-dmg.sh`** - Create basic macOS disk image installer
  - Simple DMG with drag-and-drop interface
  - Usage: `./scripts/create-dmg.sh`

- **`create-dmg-fancy.sh`** - Create styled macOS disk image installer
  - Custom window appearance and icon positioning
  - Usage: `./scripts/create-dmg-fancy.sh`

## Prerequisites

Different scripts have varying requirements:

- **Zig toolchain**: Required for all build scripts
- **Rust/Cargo**: Required for REVM comparison and external benchmarks  
- **Docker**: Required for fuzz testing
- **Python 3**: Required for analysis scripts
- **AWS CLI + Terraform + Packer**: Required for cloud benchmarking
- **macOS tools**: Required for DMG creation (hdiutil, osascript)
- **hyperfine**: Recommended for accurate benchmarking
- **Linux tools**: perf, flamegraph (for profiling on Linux)

## Common Workflows

### Quick Development Cycle
```bash
# Fast feedback loop
./scripts/perf-fastest.sh

# Quick debugging
./scripts/debug-zig-runner.sh
```

### Performance Analysis
```bash
# Comprehensive benchmarking
./scripts/perf-slow.sh

# Profile specific operations
./scripts/profile.sh arithmetic_ops
```

### Debugging Execution Differences
```bash
# Compare against REVM reference
./scripts/diff-trace.sh ten-thousand-hashes
```

### Bytecode Analysis & Optimization
```bash
# Analyze patterns for fusion opportunities  
python3 scripts/analyze_bytecode.py

# Check bundle size compliance
python3 scripts/wasm-analyze.py --check
```