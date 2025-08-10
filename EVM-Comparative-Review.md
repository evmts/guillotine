## Comparative Review: Guillotine vs evmone (advanced) vs revm

This review contrasts Guillotine’s EVM with evmone’s advanced interpreter (C++) and revm (Rust). The focus is performance‑critical design choices, branch predictability, cache locality, and correctness/robustness trade‑offs.

### High‑level architecture (with comptimeconfigs)

- Guillotine
  - Pre‑decoded instruction stream with BEGINBLOCK basic‑block metadata.
  - Centralized, compile‑time `OpcodeMetadata` (SoA, cache‑aligned) generated from `EvmConfig`/`EipFlags`; dynamic gas/memory traits separated from hot arrays; compile‑time validation of metadata consistency. [pr488]
  - Inline hot opcodes (PUSH1/DUP/ADD/MLOAD/MSTORE/POP) to bypass function pointers.
  - Pluggable state DB + journal for revert; shared‑buffer memory with checkpoints.

- evmone (advanced)
  - Decodes bytecode to instruction stream with compact instruction traits (stack in/out, gas, memory size); block‑based validation and gas frontloading.
  - Highly tuned C++ implementation with micro‑fusion and careful code layout to aid I‑cache and branch prediction.
  - Emphasis on decode‑time work to remove runtime checks; frequent use of constexpr‑like tables.

- revm
  - High‑performance Rust interpreter; strong journaling and precise gas semantics (SSTORE et al.); careful inlining and memory safety.
  - Focus on zero‑cost abstractions and borrowing; state layer is well‑structured for correctness and speed.

### Dispatch and branch prediction

- Guillotine and evmone advanced both avoid a 256‑way switch at runtime. Guillotine’s SoA table is cache‑friendly; evmone relies on compact instruction descriptors and fused paths.
- Revm achieves similar effect via Rust inlining/monomorphization and careful dispatcher code.

Expected performance ranking for dispatch alone: evmone ≈ Guillotine ≥ revm (differences likely within noise if instruction mixes align). The new comptime `OpcodeMetadata` layer should further reduce runtime errors and branchy validation by failing metadata mismatches at compile time. [pr488]

### Decode‑time analysis vs runtime checks

- evmone does more analysis up front (e.g., memory sizes, copy lengths) to eliminate divisions and alignment work in the hot path.
- Guillotine already pushes gas/stack checks to block level and inlines hot ops; pushing memory sizing and copy counts to decode time will close most remaining gaps.
- revm strikes a balance but benefits from Rust’s inlining; correctness around SSTORE semantics is a standout.

### Memory and copy operations

- evmone: copy/memory ops are heavily optimized; overlap and bounds resolved with minimal branching; word counts largely known at decode time.
- Guillotine: MCOPY handles overlaps correctly; memory expansion costs cached; opportunity to precompute word counts and bounds during analysis.
- revm: optimized copy paths with clear semantics; benefits from borrow‑checked slices and low‑level ops.

### SSTORE and state semantics

- evmone and revm: comprehensive SSTORE semantics (EIP‑2200/3529), warm/cold costs, refunds, net‑new and clear‑to‑zero behaviors, with thorough tests.
- Guillotine: SSTORE dynamic gas/refund is TODO; this is the main correctness/performance delta.

### Journaling and revert

- All three implement journaling/snapshot/revert.  
  - evmone: tight integration with state, minimal entry footprints.  
  - revm: robust and precise refund handling with clear revert semantics.  
  - Guillotine: comprehensive entry types and reverse replay; ensure large code blobs are not copied into entries.

### Logging and observability

- evmone/revm: hot paths are free of logs; profiling uses counters or external tooling.
- Guillotine: some `Log.debug` present in constructors/interpreter; must be stripped/guarded in release to match rivals.

### Build and codegen considerations

- evmone benefits from aggressive inlining, LTO, and compiler‑friendly small traits.
- revm leverages Rust’s monomorphization and inlining; zero‑cost abstractions.
- Guillotine (Zig): ensure ReleaseFast, inlining thresholds favorable for tiny helpers, and that hot code is in a single TU where beneficial.

### Comparative recommendations for Guillotine

1) Implement full SSTORE gas/refund semantics; add parity tests vs official vectors.
2) Extend decode‑time analysis to include memory word counts, copy sizes, and simple micro‑fusion for common sequences.
3) Strip logs from hot loop; gate traceability behind a dedicated feature.
4) Add microbench/tracebench parity harnesses mirroring evmone/revm public scenarios (e.g., ERC20 transfer/mint, keccak loops, CALL‑heavy code).
5) Validate inlining and code layout (align instruction array, co‑locate `pc_to_block_start`); consider per‑block trailers for precomputed aggregates.
6) Leverage `EvmConfig` presets (DEFAULT/DEBUG/PERFORMANCE/TESTING/MINIMAL, L2 variants) to benchmark and select optimal defaults; wire compile‑time validation into CI. [pr488]

### Where Guillotine is already on par

- Data‑oriented dispatch and block validation (≈ evmone advanced).
- Hot‑opcode inlining for common ops.
- Memory expansion caching and small LUT; shared buffer contexts.
- CALL gas math with stipend and warm/cold access (solid tests).

### Where evmone/revm still lead today

- Complete SSTORE semantics and refunds (both).  
- Wider decode‑time precomputation (evmone).  
- Extensive public benchmarks and long‑tail scenario tuning (both).

### Expected impact of proposed changes

- Closing SSTORE gap: correctness and real‑world throughput on storage‑heavy contracts.  
- Decode‑time memory sizing: reduces divisions/branches per instruction; measurable gains on copy/memory traces.  
- Micro‑fusion: reduces dispatch overhead in common sequences; small but consistent gains.  
- Hot‑path hygiene: improves inlining and branch prediction stability; lowers variance.

### Bottom line

Guillotine’s architecture places it squarely in the same performance class as evmone’s advanced interpreter and revm. With the new centralized, compile‑time configuration (`OpcodeMetadata` + `EvmConfig`) and validation from [pr488], plus SSTORE and decode‑time enrichments, Guillotine should meet or exceed both on targeted workloads while maintaining strong robustness and clean engineering ergonomics.

\

[pr488]: https://github.com/evmts/guillotine/pull/488


