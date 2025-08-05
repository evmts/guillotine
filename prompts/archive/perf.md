# Performance Optimization Workflow for Guillotine EVM

<system_context>
You are an AI assistant helping to optimize the performance of Guillotine, a Zig-based Ethereum Virtual Machine implementation. Your goal is to systematically work through performance issues, implementing improvements using Test-Driven Development (TDD), and validating performance gains relative to REVM (the reference Rust implementation).
</system_context>

<workflow>
## Performance Optimization Process

### 1. Issue Selection and Analysis
<step>
- Use `gh issue view <number>` to examine the performance issue in detail
- Understand the current implementation and its performance bottlenecks
- Review the proposed solution and expected benefits
- Identify related code locations mentioned in the issue
</step>

### 2. Test-Driven Development Implementation
<step>
- Write tests FIRST that validate the optimization maintains correctness
- Tests should cover edge cases mentioned in the issue
- Ensure tests pass with current implementation before optimizing
- Use inline tests within the same file (following project convention)
</step>

### 3. Implementation and Validation
<step>
- Implement the performance optimization as described in the issue
- Run `zig build test` to ensure all tests pass
- Debug any failing tests until the implementation is correct
- NEVER run just `zig build` - always use `zig build test`
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
- Create a new branch: `git checkout -b perf/<issue-number>-<short-description>`
- Commit with message: `⚡ perf: <description of optimization>`
- Use `gh pr create` with title and body describing the performance gain
- Branch from previous performance branch if stacking PRs

If performance DID NOT improve:
- Still create PR with "DO NOT MERGE" in title
- Use `gh pr create --title "DO NOT MERGE: perf: <description>" --body "Performance results: <details>"`
- Comment on PR explaining the performance regression
- Create new branch from main or last successful perf branch for next issue
</step>

### 7. Next Issue Selection
<step>
- Move to the next performance issue in the prioritized list
- Repeat the process
- Stack successful optimizations, isolate unsuccessful ones
</step>
</workflow>

<performance_issues_priority>
## Prioritized Performance Issues (Easiest to Hardest)

### 🟢 Easy - High Impact, Simple Implementation

1. **Issue #338/337: Optimize memory expansion with inline wrapper**
   - Simple refactoring: Add inline wrapper for hot path
   - 4.6M function calls can skip full function overhead
   - Expected: Significant improvement with minimal risk

2. **Issue #339: Micro-optimize stack operations**
   - Add `@setRuntimeSafety(false)` to hottest functions
   - 18M+ calls benefit from saved instructions
   - Expected: Small but measurable improvement

3. **Issue #335: Use single big-endian loads for PUSH**
   - Replace loops with `std.mem.readInt`
   - Direct memory loads instead of byte-by-byte
   - Expected: 10-20% faster PUSH operations

### 🟡 Medium - Moderate Complexity

4. **Issue #334: Direct memory access optimization**
   - Combine gas check + memory expansion
   - Remove intermediate API layers
   - Expected: 5-10% improvement on memory ops

5. **Issue #333: Simplify precompile dispatch**
   - Replace hashmap with direct indexing
   - Inline common precompiles
   - Expected: Faster precompile calls

6. **Issue #332: Remove intermediate buffers in hash precompiles**
   - Stream data directly to hash functions
   - Eliminate temporary allocations
   - Expected: Reduced allocation overhead

### 🔴 Complex - Major Refactoring

7. **Issue #342: Smart pre-allocation for memory/stack**
   - Add contract profiling system
   - Predict memory usage patterns
   - Expected: 50% reduction in allocations

8. **Issue #341: Mandatory extended entries**
   - Always pre-compute analysis data
   - Direct array indexing without conditionals
   - Expected: 1-2% overall improvement

9. **Issue #340: True block-level fast path**
   - Eliminate per-instruction validation
   - Inline hot opcodes in fast path
   - Expected: 40%+ improvement (biggest potential gain)
</performance_issues_priority>

<benchmark_interpretation>
## Understanding Benchmark Results

### Key Metrics to Compare

1. **Relative Performance Ratio**
   ```
   Ratio = Guillotine_time / REVM_time
   Lower is better (1.0 = equal performance)
   ```

2. **Benchmark Cases**
   - `snailtracer`: CPU-intensive computation (currently 2.1x slower than REVM)
   - `ten-thousand-hashes`: Crypto operations (currently 1.94x slower)
   - `erc20-*`: Realistic contract operations (1.05-1.11x slower)
   - `opcodes-push-pop`: Stack operations (1.39x slower)

3. **What Constitutes Success**
   - Any reduction in the ratio is a win
   - Even 0.01 improvement in ratio on snailtracer is significant
   - Small improvements compound across multiple optimizations
</benchmark_interpretation>

<important_notes>
## Critical Reminders

1. **ALWAYS run `zig build test`, NEVER just `zig build`**
2. **Relative performance matters, not absolute times**
3. **Create PRs even for failed optimizations (with DO NOT MERGE)**
4. **Stack successful changes, isolate failures**
5. **Use TDD - write tests before optimizing**
6. **Focus on the hottest code paths first**
7. **Small improvements in hot functions yield big gains**
</important_notes>

<example_workflow>
## Example Workflow Execution

```bash
# 1. View issue
gh issue view 338

# 2. Create feature branch
git checkout -b perf/338-memory-inline-wrapper

# 3. Implement with TDD
# - Write tests for memory ensure_capacity behavior
# - Implement inline wrapper optimization
# - Run: zig build test

# 4. Benchmark
./scripts/perf-slow.sh

# 5. Check results
cat bench/official/results.md
# Compare Guillotine/REVM ratios before and after

# 6. Create PR (if improved)
gh pr create --title "⚡ perf: Add inline wrapper for memory expansion hot path" \
  --body "Optimized memory_ensure_capacity by adding inline wrapper for the common case where no expansion is needed.

## Performance Results
- ten-thousand-hashes: 1.94x → 1.85x (5% improvement)
- snailtracer: 2.10x → 2.05x (2.5% improvement)

Closes #338"

# 7. Move to next issue
git checkout -b perf/339-stack-micro-opt --track origin/perf/338-memory-inline-wrapper
```
</example_workflow>