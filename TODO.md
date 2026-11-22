# TODO: EVM Performance Optimization Refactoring

This document outlines the remaining work for the performance optimization refactoring.

## High-Level Goal

The primary goal is to refactor the performance-critical bytecode analysis and dispatch pipeline. A previous attempt introduced a complex, single-pass analyzer with opcode fusions that led to correctness issues and regressions.

This effort replaces that with a simpler, more robust two-pass analysis that prioritizes correctness and allows for safe, incremental performance enhancements.

## Current State (What's Done)

We have successfully completed the initial refactoring and cleanup phase. The codebase is now in a stable, correct, and non-optimized state.

1.  **Analyzed Previous Attempt**: Reviewed commits `32d6d03` through `285bd56` to understand the pitfalls of the complex single-pass approach.

2.  **Code Cleanup & Baseline Reset**:
    *   Removed the single-pass analyzer (`src/bytecode/bytecode_single_pass.zig`).
    *   Stripped all fusion logic from the bytecode iterator (`src/bytecode/bytecode.zig`) and the dispatch builder (`src/preprocessor/dispatch.zig`).
    *   Deleted obsolete fusion-related tests (`test/fusion/`) and fixed resulting compilation errors.

3.  **Established a Correct Two-Pass Analyzer**:
    *   **Pass 1 (Validation)**: The `buildBitmapsAndValidateWithLength` function in `bytecode.zig` now performs a clean pass to identify instruction boundaries, PUSH data, and `JUMPDEST` locations.
    *   **Pass 2 (Jump Validation)**: A second pass was added to the `bytecode.zig` `init` function to verify that all static jumps (i.e., `PUSH` followed by `JUMP` or `JUMPI`) target a valid `JUMPDEST`.

4.  **Verified Correctness**: All tests are now passing, confirming that the refactored, non-optimized baseline is functionally correct.

## Next Steps (To Finish This PR)

The following steps will incrementally re-introduce performance optimizations on top of the new, stable foundation.

### 1. Benchmark the Baseline

-   [ ] Create a comprehensive benchmark suite that executes a representative set of smart contracts.
-   [ ] Run the benchmarks on the current codebase to establish a clear performance baseline.
-   [ ] Document the baseline results to measure against future optimizations.

### 2. Implement Simple, High-Impact Fusions

For each fusion type, the process will be: implement, test for correctness, and benchmark for performance impact.

-   [ ] **Implement `PUSH` + `[OP]` Fusions:**
    -   [ ] Detect `PUSH1` + `ADD`/`SUB`/`MUL`/etc. patterns in `bytecode.zig`.
    -   [ ] Introduce synthetic opcodes and handlers for these patterns.
    -   [ ] Update `dispatch.zig` to create dispatch items for these fusions.
    -   [ ] Write targeted unit and integration tests.
    -   [ ] Benchmark the performance gain.

-   [ ] **Implement `DUPN` + `[OP]` Fusions:**
    -   [ ] Follow the same process as `PUSH` fusions for common `DUP` patterns.
    -   [ ] Benchmark the performance gain.

-   [ ] **Implement Multi-`POP` Fusions:**
    -   [ ] Implement fusions for sequences of `POP` opcodes (e.g., `POP` + `POP` -> `POP2`).
    -   [ ] Benchmark the performance gain.

### 3. Final Review and Documentation

-   [ ] Review all new code for clarity, correctness, and adherence to the project's style guide.
-   [ ] Ensure all new logic is covered by tests.
-   [ ] Update any relevant documentation to reflect the new architecture.
-   [ ] Consolidate benchmark results to demonstrate the overall performance improvement.
