## Guillotine EVM Implementation Review

### Executive summary

Guillotine’s EVM exhibits a strong, data‑oriented design with a pre‑decoded instruction stream, cache‑aligned struct‑of‑arrays jump table, and hot‑opcode inlining. This architecture is aligned with best‑in‑class interpreters and should deliver predictable branches and strong cache locality. The most impactful next steps are: fully implementing SSTORE gas/refund semantics (EIP‑2200/3529), pushing more analysis to decode time (esp. memory sizing and copy ops), and ensuring all hot paths are free of logging and unnecessary branches in release builds. With these, Guillotine should compete with evmone advanced and revm on throughput.

### Strengths

- Data‑oriented dispatch
  - Centralized, compile‑time `OpcodeMetadata` (formerly JumpTable) with 64‑byte alignment; O(1) metadata access for execute func, gas, min/max stack, memory size and dynamic gas pointers. Metadata is now validated at compile time via the new comptime config layer.
  - BEGINBLOCK basic‑block validation in the interpreter frontloads gas and stack checks, reducing per‑instruction overhead and improving branch predictability.
- Instruction stream and control flow
  - Pre‑decoded `Instruction` union carries block info, push immediates, dynamic gas metadata, and jump targets. Dynamic JUMP/JUMPI resolved via `pc_to_block_start` and precomputed validity.
  - PUSH and some hot ops inlined in the interpreter; clear fast paths for common sequences.
- Stack and memory
  - Stack uses pointer arithmetic and aligns data; safe/unsafe split lets opcodes use unsafe variants after validation.
  - Memory has shared‑buffer contexts with checkpoints and a cached memory expansion cost (including a small LUT for ≤4KB) – excellent for copy/expansion heavy code.
- Gas accounting
  - EIP‑150 gas forwarding, value stipend rules, EIP‑2929 warm/cold account accesses implemented and tested for CALL family.
- Testing
  - Broad coverage across opcodes, system calls, memory expansion, nested calls, warm/cold paths, journaling and revert semantics. Property‑style fuzz tests for state and memory.

### Opportunities and gaps

1) Implement complete SSTORE semantics
- Status: TODO placeholder for dynamic gas/refund logic.
- Impact: High (correctness + perf). Implement EIP‑2200/3529: warm/cold cost, net‑new, reset to zero, original vs current value comparisons, refund accounting (even if tracked externally).

2) Push more work to analysis/translation time
- Precompute, per instruction:
  - Memory word counts for MCOPY/CALLDATACOPY/RETURNDATACOPY paths; avoid repeated divisions and alignment logic at runtime.
  - Cold/warm account flags when statically known (e.g. EXTCODESIZE self).
  - For common blocks (PUSH/PUSH/ALU/MSTORE), generate fused micro‑ops to reduce dispatch overhead.

3) Hot‑path hygiene
- Remove/guard all logs in release from the interpreter hot loop and memory/stack fast paths.
- Prefer predictable branches: consolidate error paths with `@branchHint(.unlikely)`, and ensure likely paths have minimal conditionals.

4) Micro‑optimizations
- Stack: inline `swap_unsafe` manually instead of `std.mem.swap`; add `peek2_unsafe()` and `peek3_unsafe()` to avoid temporary structs; annotate hottest tiny helpers with always_inline where helpful.
- Memory: further streamline `get_expansion_cost()` by caching last word count as well as size; ensure all expansions align requested size to 32 bytes consistently.
- Instruction stream: store compact indices (u16/u32) for `pc_to_block_start` and co‑locate with instructions in the same slab to improve locality.

5) Observability
6) Comptime configuration system
- Adopt and standardize on the new centralized `EvmConfig`/`ComptimeConfig` + `EipFlags` system for all feature gating and constants. Ensure all opcode implementations source their gas/stack metadata from `OpcodeMetadata.init_from_hardfork()` using the selected config. Add compile‑time validation hooks for trait consistency. See PR notes [feat: implement centralized comptime EVM configuration system][pr488].

### Migration notes (comptimeconfigs branch)

- JumpTable → OpcodeMetadata rename: update all reviews and internal references to use `OpcodeMetadata` and the new `init_from_hardfork` API. The table copy helpers were simplified (dropped stale `dynamic_gas`/`memory_size` in copy), and GasConstants shadowing was removed at the metadata layer. Use `EvmConfig` presets (DEFAULT/DEBUG/PERFORMANCE/TESTING/MINIMAL, plus L2 configs) for consistent builds. [pr488]

- Replace per‑opcode debug logging with a build‑time trace mode that writes to a ring buffer; keep interpreter loop free of logging in release.

### Correctness and safety review (selected highlights)

- Static context write protection: enforced for SSTORE/LOG/CREATE/SELFDESTRUCT and covered by tests.
- Memory offset/size bounds: copy/memory ops return `OutOfOffset`/`InvalidOffset`; ensure consistent error selection across modules.
- Depth limits and gas forwarding: CALL/CREATE family validated, with tests covering nested calls and stipend math.
- Journaling: snapshot/revert logic is comprehensive; entries cover storage, balance, nonce, code, logs, and selfdestruct markings; revert walks entries in reverse.

### Performance profile and hotspots

- Dispatch and decode: excellent structure; consider extending hot inline set (e.g., DUP2/SWAP1 sequences) and add peephole fusion within blocks.
- Copy and memory expansion: likely the second largest CPU consumer; decoding per‑op memory word counts will reduce divisions and alignment work.
- CALL family: gas math is correct; memory pre‑sizing of return areas can reduce allocator work; prefer direct slice copies when bounds are pre‑validated.

### Testing and benchmarking

- Unit and integration tests are broad and valuable. Recommended additions:
  - Microbench tests comparing function‑pointer dispatch vs inlined hot ops per opcode.
  - Trace‑based benches (ERC20 transfer/mint, DeFi hotspots, MCOPY‑heavy loops) to gauge instruction‑mix performance.
  - SSTORE semantics tests once implemented, including refund behavior and warm/cold transitions.

### Prioritized recommendations (90‑day plan)

1) Complete SSTORE dynamic gas/refund implementation and tests (EIP‑2200/3529).  
2) Extend translation: precompute memory word counts; emit fused micro‑ops for PUSH/PUSH/ALU/MSTORE and common DUP/SWAP patterns.  
3) Strip hot‑path logging in release; add optional trace ring buffer.  
4) Stack and memory micro‑opts: specialized peeks, manual swap, predictable overlap copy; align all expansions.  
5) Add targeted microbenches and trace benches; validate gains vs baselines.
6) Migrate to `OpcodeMetadata` + comptime config across code and tests; enable compile‑time validation in CI. [pr488]

### Quality gates and KPIs

- Correctness: All tests pass; add SSTORE suite parity with official test vectors.  
- Throughput: Target ≥ evmone advanced on ADD/MLOAD/MSTORE loops and within ±5% on CALL‑heavy traces; within ±5–10% of revm on mixed workloads.  
- Variance: Keep p95 latency within +5% of mean for uniform instruction streams (branch predictability proxy).  
- Memory: Zero regressions in allocations per executed instruction after decode‑time precomputation.

### Conclusion

Guillotine’s core is architecturally sound and positioned for top‑tier performance. The remaining work centers on SSTORE semantics, pushing analysis forward to eliminate runtime branches and divisions, and ensuring the hot loop remains surgically minimal. With these addressed, Guillotine should meet “best‑in‑class” goals against evmone advanced and revm.

\

[pr488]: https://github.com/evmts/guillotine/pull/488


