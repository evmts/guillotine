# Performance Optimization Workflow for Guillotine EVM - Single Issue

<system_context>
You are an AI assistant helping to optimize the performance of Guillotine, a Zig-based Ethereum Virtual Machine implementation. Your goal is to implement a specific performance improvement using Test-Driven Development (TDD) and validate performance gains relative to REVM (the reference Rust implementation).
</system_context>

<workflow>
## Performance Optimization Process

### 1. Issue Analysis
<step>
- Read the issue description carefully to understand the performance bottleneck
- Review the proposed solution and expected benefits
- Identify all related code locations mentioned in the issue
- Understand both the current implementation and the optimized approach
</step>

### 2. Test-Driven Development Implementation
<step>
- Write tests FIRST that validate the optimization maintains correctness
- Tests should cover all edge cases mentioned in the issue
- Ensure tests pass with the current implementation before optimizing
- Use inline tests within the same file (following project convention)
- Tests should be comprehensive and self-contained (no abstractions)
</step>

### 3. Implementation and Validation
<step>
- Implement the performance optimization exactly as described in the issue
- Run `zig build test` to ensure all tests pass
- Debug any failing tests until the implementation is correct
- NEVER run just `zig build` - always use `zig build test`
- If tests fail, use logging to understand the issue - never speculate
</step>

### 4. Performance Benchmarking
<step>
- Run `scripts/perf-slow.sh` to regenerate benchmark results
- This command runs: 
  ```bash
  zig build build-evm-runner -Doptimize=ReleaseFast && 
  zig build build-orchestrator -Doptimize=ReleaseFast && 
  ./zig-out/bin/orchestrator --compare --export markdown --num-runs 5 --js-runs 1 --internal-runs 10 --js-internal-runs 1
  ```
- Results will be written to `bench/official/results.md`
</step>

### 5. Performance Analysis
<step>
- Compare new results with baseline in `bench/official/results.md`
- Focus on RELATIVE performance vs REVM, not absolute numbers
- Calculate the performance ratio: (Guillotine time / REVM time)
- A lower ratio means better relative performance
- Example: If Guillotine was 2x slower and is now 1.5x slower, that's a 25% improvement
</step>

### 6. Pull Request Creation
<step>
If performance IMPROVED relative to REVM:
- Commit with message: `⚡ perf: <description of optimization>`
- Use `gh pr create` with title and body describing the performance gain
- Include before/after performance ratios in the PR description

If performance DID NOT improve:
- Still create PR with "DO NOT MERGE" in title
- Use `gh pr create --title "DO NOT MERGE: perf: <description>" --body "Performance results: <details>"`
- Comment on PR explaining why the optimization didn't work
- This helps document what approaches have been tried
</step>
</workflow>

<benchmark_interpretation>
## Understanding Benchmark Results

### Key Metrics to Compare

1. **Relative Performance Ratio**
   ```
   Ratio = Guillotine_time / REVM_time
   Lower is better (1.0 = equal performance)
   ```

2. **Benchmark Cases**
   - `snailtracer`: CPU-intensive computation (baseline: 2.1x slower than REVM)
   - `ten-thousand-hashes`: Crypto operations (baseline: 1.94x slower)
   - `erc20-*`: Realistic contract operations (baseline: 1.05-1.11x slower)
   - `opcodes-push-pop`: Stack operations (baseline: 1.39x slower)

3. **What Constitutes Success**
   - Any reduction in the ratio is a win
   - Even 0.01 improvement in ratio on snailtracer is significant
   - Focus on benchmarks most relevant to your optimization
</benchmark_interpretation>

<important_notes>
## Critical Reminders

1. **ALWAYS run `zig build test`, NEVER just `zig build`**
2. **Write tests BEFORE implementing the optimization**
3. **Relative performance matters, not absolute times**
4. **Create PRs even for failed optimizations (with DO NOT MERGE)**
5. **Use TDD - comprehensive tests ensure correctness**
6. **When debugging, use logging - never speculate about issues**
7. **Small improvements in hot functions yield big gains**
</important_notes>

<debugging_approach>
## Debugging Failed Tests

When tests fail after your optimization:
1. **Add logging** to trace execution and understand what's happening
2. **Never guess** - use concrete evidence from logs
3. **Check assumptions** - verify each step with logging
4. **Compare behavior** - log both old and new code paths
5. **Fix incrementally** - make small changes and test each one
</debugging_approach>