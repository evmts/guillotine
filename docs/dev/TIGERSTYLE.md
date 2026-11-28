# TigerStyle in Guillotine

Guillotine is mission-critical financial infrastructure written in Zig, so it borrows heavily from TigerBeetle's [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md) engineering discipline—while making explicit, documented trade-offs where an embeddable Ethereum Virtual Machine differs from a standalone database.

This document records **exact boundaries**: where Guillotine follows TigerStyle, where it intentionally diverges for EVM performance or embeddability, and how consumers should build and deploy Guillotine to get TigerStyle guarantees.

---

## 1. You Are Only TigerStyle in `ReleaseSafe`

**Guillotine is NOT TigerStyle-compliant in `ReleaseFast` or `ReleaseSmall`.** If you want TigerStyle safety guarantees in production, build with **`-Doptimize=ReleaseSafe`**.

| Mechanism | `Debug` / `ReleaseSafe` (TigerStyle mode) | `ReleaseFast` / `ReleaseSmall` (Max-throughput mode) |
|---|---|---|
| Zig runtime safety checks (overflow, bounds, null) | **Enabled** | Disabled |
| `Dispatch.Item` schedule representation | **Tagged 16-byte union** (`item_tagged = true`), validated item by item | **Untagged 8-byte extern union** (comptime-pinned `@sizeOf == 8`) |
| `preserve_none` opcode inner loop hooks | `handler_abi.hooksEnabled` **enabled** | Compiled out (zero overhead) |
| `Stack` `_unsafe` bounds assertions | **Active** (`std.debug.assert` / safety-checked) | Compiled out (relies on basic-block pre-validation) |
| `SafetyCounter` (`EvmConfig.loop_quota`) | **Enabled** (`1_000_000` default) | Disabled (`null` default; gas bounds execution) |
| Embedded C-ABI (`libguillotine_ffi`) assertions | Never aborts host process; logs & counts in `Tracer.failed_checks` | Logged/counted only when tracer is enabled |

### Untrusted Input vs. Internal Invariants

Guillotine strictly separates two failure classes across **all** build modes:

1. **Untrusted EVM inputs** (bytecode, calldata, invalid jumps, gas exhaustion, malformed precompile inputs, oversized initcode): **always validated and returned as typed errors** in every build mode (`Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`). Untrusted transaction inputs must never crash the process.
2. **Internal programmer invariants** (dispatch schedule layout, stack pointer within `[buf_ptr, buf_ptr + capacity]`, snapshot/journal consistency): checked in `Debug` and `ReleaseSafe`. Official EEST state tests (`66,652 / 66,652`, fusion on and off), fuzz campaigns, and Lean differential fuzzing all run in **`ReleaseSafe`**.

---

## 2. Memory Allocation & EVM Pooling

### No Eager Upfront Static Allocation Inside `Evm.init`

Unlike TigerBeetle, **Guillotine does not eagerly pre-allocate worst-case static memory inside `Evm.init` unless the consumer supplies a static/bounded allocator**.

EVM worst-case limits are large (e.g., `arena_capacity_limit = 64 MiB`, `memory_limit = 16 MiB` per call depth up to 1,024). Eagerly committing that memory inside `Evm.init` would make lightweight or multi-instance hosts pay tens of megabytes per idle EVM handle. Instead, Guillotine starts small (`initial_call_arena_capacity = 64 KiB`) and stabilizes resident memory through reusable pools:

- **`FrameMemoryPool`** (`src/memory/frame_memory_pool.zig`): reserves virtual address space lazily committed by the OS (zero copy on EVM memory expansion), retains up to `max_retained_buffers = 8`, and trims oversized buffers via `madvise(MADV_DONTNEED)` at transaction end.
- **`FrameStackPool`** (`src/evm.zig`): pools 64-byte-aligned 32 KiB stacks across nested frames (retaining up to 16).
- **`GrowingArenaAllocator`** (`src/evm_arena_allocator.zig`): grows on demand, retains up to `arena_capacity_limit` across transactions, and trims an arena that one call grew past that limit back to its initial size. The hard per-call limit is `MAX_ABSOLUTE_CAPACITY`.
- **`DispatchCache`** (`src/evm.zig`): caches preprocessed bytecode schedules by code hash.

### Expected Production Pattern: Use a Pool of `Evm` Instances

Do **not** create and destroy an `Evm` per transaction, and do **not** run all concurrent work through one monolithic `Evm`. The expected architecture is a **fixed pool of reusable `Evm` instances—typically one `Evm` per worker thread / CPU core**:

```zig
// Recommended production pattern: one reusable Evm per worker thread.
// Each Evm warms up its FrameMemoryPool, FrameStackPool, GrowingArenaAllocator,
// and DispatchCache, then reuses them across transactions with zero churn.
const WorkerEvm = evm.Evm(.{});

// On worker startup:
var vm = try WorkerEvm.init(worker_allocator, &db, block_info, tx_ctx, gas_price, origin);
defer vm.deinit();

// Per transaction:
const result = vm.call(params);
defer result.deinit(worker_allocator);
vm.resetTouched(); // Prevents cumulative touched_addresses / touched_storage growth.
```

### Consumer-Driven Upfront Static Allocation

If your deployment requires **strict TigerStyle upfront static memory bounds** (zero OS heap allocations after startup), supply a consumer-owned fixed buffer or capped allocator **per pooled `Evm` instance**:

```zig
// Consumer-owned static memory budget per pooled worker EVM:
const worker_budget = try page_allocator.alloc(u8, 128 * 1024 * 1024);
defer page_allocator.free(worker_budget);

var fba = std.heap.FixedBufferAllocator.init(worker_budget);
var vm = try WorkerEvm.init(fba.allocator(), &db, block_info, tx_ctx, gas_price, origin);
defer vm.deinit();
```

If a host allocator does fail mid-execution, `Evm` records `host_failure` (`error.OutOfMemory` / `error.AllocationError`) and rolls back the transaction rather than turning host exhaustion into a consensus-diverging EVM halt.

---

## 3. `SafetyCounter` (`loop_quota`)

`SafetyCounter` (`src/internal/safety_counter.zig`) provides explicit, non-panicking iteration limits (`tick()` returns `error.SafetyLimitExceeded`, `inc()` saturates and logs).

It follows the **same build-mode and pooling model** as memory allocation:

- **Default in `Debug` & `ReleaseSafe`**: `EvmConfig.loop_quota = 1_000_000` (enabled).
- **Default in `ReleaseFast` & `ReleaseSmall`**: `EvmConfig.loop_quota = null` (disabled, zero overhead in the gas-metered opcode loop).
- **Explicit consumer override**: If you want hard instruction caps even in `ReleaseFast` (for example, on a dedicated RPC `eth_call` simulation pool handling untrusted calls with generous gas limits), configure `.loop_quota` on that pool's `EvmConfig`:

```zig
const SimulationEvm = evm.Evm(.{
    .loop_quota = 10_000_000,
});
```

---

## 4. Native Recursion for Nested EVM Calls

TigerStyle forbids recursion. **Guillotine intentionally uses native OS call-stack recursion** for nested EVM calls (`CALL`, `CALLCODE`, `DELEGATECALL`, `STATICCALL`, `CREATE`, `CREATE2`):

```
callImpl -> inner_call -> executeCall/executeCreate -> execute_frame
         -> Frame.interpret -> SystemHandlers.callFamily -> inner_call (depth <= 1024)
```

### Why We Keep Native Recursion

Guillotine's opcode handlers run on a `preserve_none` + `.always_tail` register-pinned calling convention (`src/preprocessor/handler_abi.zig`). Keeping sub-calls as native recursive calls avoids suspending/restoring handler state into a heap-allocated state machine on every `CALL` boundary and keeps the interpreter simpler and faster on common shallow call depths.

### How Deep Call Stacks Stay Safe

- EVM call depth is strictly capped at `EvmConfig.max_call_depth` (`u11`, default `1024`).
- `src/native_stack.zig` probes the calling thread's native stack bounds (`lowAddress()` via Darwin pthreads or Linux `getauxval(AT_EXECFN)` / `pthread_getattr_np`).
- When `@frameAddress() < self.native_stack_limit`, `inner_call` transparently trampolines the remaining call subtree onto a persistent, reusable `large_stack_worker` thread (created lazily once per `Evm` and reused across calls).
- Note: **The Merkle Patricia Trie (`src/trie/`) does NOT use recursion**—its lookup, deletion, proof collection, and proof verification traversals are iterative with fixed-size nibble/cursor stacks and `[32]u8` hash keys.

---

## 5. 70-Line Functions & 100-Column Lines Without Hurting Performance

Guillotine adopts TigerStyle's **≤70-line function limit** and **≤100-column line limit** for new and refactored code because they can be achieved with **zero performance regression** (and often better L1 instruction-cache locality):

- **Hot-path helpers**: Mark small extracted helpers called from opcode handlers `inline` so LLVM produces identical register-allocated machine code.
- **Cold / error paths**: Extract slow validation, logging, and error-formatting paths out of hot functions and annotate branches with `@branchHint(.cold)` or `@branchHint(.unlikely)`. Keeping cold code out-of-line shrinks the hot function's instruction footprint.
- **Formatting**: All files in `src/` must pass `zig fmt --check`, enforced in CI.

---

## 6. Dependencies

TigerStyle promotes zero external dependencies. Guillotine keeps its core EVM dependency-free beyond Zig `0.17.1`, **except for audited consensus cryptography** and optional test/CLI tooling:

| Dependency | Location | Language | Purpose | Why Not Pure Zig From Scratch? |
|---|---|---|---|---|
| **Zig Standard Library** | Zig `0.17.1` toolchain | Zig | Core runtime, allocators, hashing, build system | Core toolchain |
| **`voltaire` (vendored)** | `lib/voltaire` | Zig + Rust | EVM primitives (`Address`, `U256`, RLP, gas constants) and Rust crypto wrappers (`keccak-asm`, `secp256k1`, pairing glue) | Shared Tevm primitives + assembly-accelerated Keccak & secp256k1 |
| **`ark` (`ark-bn254`, `ark-bls12-381`, `ark-ec`, `ark-ff`, `ark-serialize`)** | `lib/ark`, `Cargo.toml` | Rust | Elliptic-curve arithmetic & pairing precompiles (`0x06–0x08`, `0x0B–0x11`) | Audited constant-time / assembly-backed pairing cryptography |
| **`blst` & `c-kzg`** | `lib/blst.zig`, `lib/c-kzg.zig` (via `lib/voltaire`) | C / Asm | EIP-4844 KZG point evaluation (`0x0A`) and BLS12-381 | Ethereum consensus-standard reference libraries |
| **`foundry-compilers`** | `lib/foundry-compilers` | Rust | Compiling Solidity contracts in test suites (`lib/foundry.zig`) | Test/benchmark fixture compilation only; not linked into production EVM binaries |
| **`zbench`, `clap`** | `build.zig.zon` (`.lazy = true`) | Zig | Optional CLI/benchmark helpers | Lazy dependencies—never fetched by library consumers |

For consensus-critical elliptic-curve pairings and KZG verification, relying on battle-tested, audited implementations (`blst`, `c-kzg`, `arkworks`) is an intentional security and performance decision over maintaining bespoke pairing assembly in Zig.

---

## 7. Zero-Cost & Performance-Improving TigerStyle Rules We Enforce

Every TigerStyle rule that has **zero runtime cost** or **improves performance** is actively enforced:

- **Comptime struct layout pins**: Hot structs (`Dispatch.Item`, `Stack`, `Frame`, `Memory`, `Account`, `CallStackEntry`) verify their exact `@sizeOf` / `@alignOf` / cache-line invariants at `comptime`.
- **16-byte `Stack` with active `Debug`/`ReleaseSafe` assertions**: `Stack` contains only `buf_ptr` + `stack_ptr` (16 bytes, keeping `Frame` hot fields inside Cache Line 1) while checking bounds via `std.debug.assert` in `Debug`/`ReleaseSafe` (and zero instructions in `ReleaseFast`).
- **Fixed-width integer types in structs**: Use explicit `u32` / `u64` / `u11` / `u12` instead of architecture-dependent `usize` in internal structs (outside C ABI `size_t` boundaries in `src/evm_c_api.zig`).
- **Options structs for multi-same-type parameters**: Functions accepting multiple positional arguments of the same primitive type (e.g., `sstoreCost`, `copyPadded`) take named option structs to prevent silent argument swaps at zero runtime cost.
- **Iterative `[32]u8`-keyed Merkle Patricia Trie**: `src/trie/` avoids both recursion and per-hop hex-string heap allocations.
- **Strict host-failure propagation**: Mid-frame `error.AllocationError` and host/database failures always set `Evm.host_failure` and abort the transaction result instead of silently halting with gas consumed.
- **No swallowed errors or debug prints**: Zero `catch {}` and zero `std.debug.print` in production `src/`.
- **Continuous verification in `ReleaseSafe`**: 66,652 official EEST state tests (fusion on and off), coverage-guided `--fuzz`, multi-threaded `fuzz-campaign`, SMT proofs, LLVM IR checks, and Lean 4 differential fuzzing.
