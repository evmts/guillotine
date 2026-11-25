---
name: guillotine-sdk-builder
description: Build a custom Guillotine language SDK (Python, Go, Rust, Swift, Kotlin/JNI, Bun, or any C FFI) on the native C ABI in src/evm_c_api.zig. Use for new bindings, ABI synchronization, ownership, threading, and linking. For TypeScript on Bun, use the maintained @tevm/guillotine package instead.
---

# Guillotine SDK builder

Guillotine has one native C ABI, `src/evm_c_api.zig`, declared in
`sdks/c/include/guillotine.h` and built as `libguillotine_ffi`. The
`@tevm/guillotine` TypeScript package (`sdks/typescript`) is a Bun native FFI
(`bun:ffi`) binding over the same library. Build other language bindings in
the consumer's project on this ABI.

All paths below are relative to the repository root.

## 1. Read the sources

- [ ] `sdks/c/include/guillotine.h`: the top comment states the lifecycle,
      handle, error, memory, threading, and pointer rules.
- [ ] `src/evm_c_api.zig`: the implementation. `grep -n "export fn"` lists
      every exported symbol; bind nothing else.
- [ ] `docs/building-custom-sdks.md`: function inventory, 64-bit layouts,
      ownership table, and language templates. Read the shared sections, then
      only your language's template.
- [ ] `sdks/c/tests/safety_test.c`: the conformance checks your binding must
      reproduce.

`src/root_c.zig` only re-exports `src/evm_c_api.zig`. There is no WASM build
of this ABI and no other C entry point.

## 2. Build and link

- [ ] `zig build shared` produces `zig-out/lib/libguillotine_ffi.dylib`
      (macOS) or `libguillotine_ffi.so` (Linux). `zig build static` produces
      `libguillotine_ffi_static.a`. Prefer the shared library.
- [ ] Compile with `-Isdks/c/include`, link with
      `-Lzig-out/lib -lguillotine_ffi`, and set a runtime search path.
- [ ] Pin the header and library to one revision. Check the exports with
      `nm` on the target before generating bindings.

## 3. Mirror the ABI

- [ ] Declare every struct field in header order with natural C alignment.
      `[20]u8` and `[32]u8` are inline arrays. `size_t` is pointer-sized.
      `bool` is 1 byte. `EvmConfiguration` and `CFusionType` are `uint8_t`.
- [ ] Assert 64-bit layouts: `BlockInfoFFI` 104, `CallParams` 136
      (`salt` at 97), `EvmResult` 144 (`trace_json` at 128),
      `AccountStateFFI` 104. Re-measure on any other target.
- [ ] Encode addresses as 20 bytes and u256 values (balance, value, salt,
      storage keys and values, log topics) as 32-byte big-endian arrays.
      Scalars use host byte order.
- [ ] `call_type`: 0 CALL, 1 CALLCODE, 2 DELEGATECALL, 3 STATICCALL,
      4 CREATE, 5 CREATE2. `guillotine_simulate` accepts CALL only and does
      not commit state. Both `guillotine_call` and `guillotine_simulate` set
      ORIGIN to `caller`.
- [ ] Pass `chain_id` as the full u64. Creation returns NULL with
      `exceeds the supported maximum` when the value does not fit the EVM's
      CHAINID type; surface that error instead of hard-coding a cap.
- [ ] There is no nonce getter. Read nonces through `guillotine_dump_state`.

## 4. Handles

- [ ] Call `guillotine_init()` once before creating handles.
- [ ] Each `guillotine_evm_create*` call allocates a fresh EVM and state
      database. Handles never share state.
- [ ] `config` is 0 (mainnet), 1 (mainnet with tracer), or 2 (test mode);
      other bytes return NULL. Only config 1 fills `trace_json`.
- [ ] Any handle works with every function. The `*_tracing` and `*_test`
      functions are aliases; bind the unsuffixed names.
- [ ] The live-handle registry rejects NULL, foreign, destroyed, and
      cleaned-up handles with an error. It cannot detect a stale handle whose
      address was reused, so clear references after `guillotine_evm_destroy`.
- [ ] `guillotine_cleanup()` destroys every live handle. Call it only at
      shutdown, when no thread is inside a library call.
- [ ] `BytecodeHandle` is not registry-checked. Destroy it exactly once.

## 5. Ownership

- [ ] `EvmResult*` from call or simulate: copy what you need, then call
      `guillotine_free_result` once. It frees every nested array and
      `error_message`.
- [ ] `guillotine_get_code` buffers: `guillotine_free_code(code, len)`.
- [ ] `StateDumpFFI*`: `guillotine_free_state_dump`.
- [ ] `BytecodeHandle*`: `evm_bytecode_destroy`. Successful
      `evm_bytecode_analyze`: `evm_bytecode_free_analysis`; the struct itself
      is caller-owned.
- [ ] Never free library memory with the host allocator. Never free
      `guillotine_get_last_error`, `evm_bytecode_opcode_name`, or
      `evm_bytecode_error_string` strings.
- [ ] Zero-length arrays use non-NULL placeholder pointers. Trust the length.
- [ ] Input buffers are borrowed for the call only. NULL with length 0 is
      empty; NULL with a non-zero length is rejected.
- [ ] Library memory comes from the C allocator, so free functions may run on
      any thread, including GC finalizer threads.

## 6. Errors

- [ ] NULL or false return: read `guillotine_get_last_error()` immediately on
      the same OS thread and copy it. It is thread-local, at most 256 bytes,
      and overwritten by the next failure on that thread. Never read it after
      a success.
- [ ] Non-NULL `EvmResult` with `success == false`: an execution failure.
      Keep `output` (revert data), `gas_left`, and `error_message` (an owned
      copy, `""` when empty, valid until `guillotine_free_result`).
- [ ] `evm_bytecode_analyze` returns `EVM_BYTECODE_*` codes; translate them
      with `evm_bytecode_error_string`.

## 7. Threading

- [ ] Different handles may run on different threads concurrently.
- [ ] One handle must never be used by two threads at once. Model it as
      movable but not shareable (Rust `Send` but not `Sync`), or guard it with
      a mutex.
- [ ] Runtimes that migrate tasks between OS threads (Go goroutines, async
      executors, Swift actors) must keep the failing call and the last-error
      read on one OS thread, for example with `runtime.LockOSThread`.

## 8. Prove the binding

- [ ] Port every check in `sdks/c/tests/safety_test.c`: invalid handles,
      invalid config, double destroy, cleanup with live handles, isolated
      state per handle, ORIGIN parity between call and simulate, test-mode and
      tracing handles through unsuffixed functions, no memory growth over
      repeated calls and invalid bytecode, and chain ids 1, 8453, 84532, and
      11155111.
- [ ] Add a contract that returns a known 32-byte word, a REVERT with data,
      empty and non-empty buffers, u256 boundaries, and an invalid call type.
- [ ] Deploy test code at a non-precompile address (for example
      `0x...c3`); low addresses are precompiles.
- [ ] Run `make -f sdks/c/Makefile test` (simple, basic, and safety targets).
      For repository changes, also run `zig build && zig build test-opcodes`.
- [ ] Report missing native artifacts or build failures with their exact
      cause. Do not substitute stub implementations.
