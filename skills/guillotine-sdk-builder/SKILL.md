---
name: guillotine-sdk-builder
description: Build custom Guillotine language SDKs on its native C ABI or Zig API, including Python, Go, Rust, Swift, Kotlin/JNI, and Bun FFI. Use for new bindings, ABI synchronization, ownership, and linking; use the maintained TypeScript/WASM SDK for ordinary JS applications.
---

# Guillotine SDK builder

Guillotine officially ships Zig native bindings, C FFI bindings, and
`@tevm/guillotine` TypeScript/WASM. Build other bindings in the consumer's
project rather than reintroducing separately maintained SDK directories.

## Read the actual interface

Work from the repository root. Read `src/evm_c_api.zig`,
`sdks/c/include/guillotine.h`, and [Building custom SDKs](../../docs/building-custom-sdks.md) before
implementing a wrapper. Read only the guide's relevant language section after
the shared ABI/ownership sections. Use `src/root.zig` and
`src/modules.build.zig` for direct Zig integration. Respect the repository's
instructions and protected paths; use `jj --no-pager` for version control.

`zig build shared` builds `src/evm_c_api.zig` into
`zig-out/lib/libguillotine_ffi.{dylib,so}` on macOS/Linux.
`zig build static` builds `libguillotine_ffi_static.a` on Unix.
Link with `-Isdks/c/include -Lzig-out/lib -lguillotine_ffi` for shared builds.
Pin the header and library to one revision and arrange the runtime loader path.
Static consumers also need the target's native crypto/system dependencies.
Inspect actual exports with the target's symbol tool before generating bindings.

`src/root_c.zig` is a different frame/component API (`evm_frame_*`,
`evm_version`, `evm_build_info`, `evm_init`, `evm_cleanup`, `evm_test_*`).
It is not the shared/static build root. WASM uses `src/evm_c.zig` and a separate
32-bit pointer/layout contract; use the TypeScript loader for that interface.

## Preserve the ABI and ownership

- Mirror complete `extern struct` fields in declaration order with natural C
  alignment. Inline `[20]u8`/`[32]u8` arrays are not pointers. `usize` is
  `size_t`; scalar `u64` is `uint64_t`; `bool` is C bool. Configuration and
  fusion enum tags are uint8, not int-sized C enums. Verify sizeof/alignment
  and offsetof against Zig for the target; do not transplant WASM offsets.
- Encode u256 values, balances, storage keys/values and salts as 32-byte
  big-endian integers; raw addresses are 20 bytes. Scalars use native byte
  order. Validate ranges before FFI, including the current transaction context's
  narrowed chain ID. Supply a valid sentinel buffer for zero-length input.
- CALL=0, CALLCODE=1, DELEGATECALL=2, STATICCALL=3, CREATE=4, CREATE2=5.
  `guillotine_simulate` supports CALL only. Use mainnet handles by default;
  tracing calls/setters/destruction require matching `_tracing` operations.
  Mainnet operations cast to DefaultEvm; do not assume test/tracing handles
  are interchangeable. Do not invent missing exports such as a nonce getter.
- Initialize once, serialize native operations on a single dedicated OS thread,
  copy borrowed last-error strings immediately on failure, and close explicitly
  on that same thread. Thread-local allocators/errors coexist with global
  pools/maps; a mutex, actor or async executor alone is insufficient.
- Distinguish NULL/false FFI failure from a non-NULL result with success=false.
  Preserve revert output. Copy binary output, nested logs/topics, access lists,
  created address and length-delimited traces before freeing the result.
- Pair call/simulate with `guillotine_free_result`; get_code with
  `guillotine_free_code`; dump_state with `guillotine_free_state_dump`;
  bytecode_create with `evm_bytecode_destroy`; successful bytecode_analyze with
  `evm_bytecode_free_analysis`. The analysis struct itself is caller-owned.
  Never separately free a result's output or use host-language allocators to
  release native allocations. Length zero can mean a sentinel pointer.
- Release all result/buffer/dump/bytecode owners, destroy EVM handles, then
  cleanup once and unload. Copy error_message before other calls because it
  can alias the thread-local error buffer. Do not read last-error on success.

## Concrete language patterns

Use the full templates in the linked guide; the patterns below identify the
native boundary to retain when adapting them. Variables named `lib`, `raw`,
`result` or `handle` refer to the declarations/owners in those templates.

### Python ctypes / cffi

Set every ctypes signature, particularly pointer return types:

```python
lib.guillotine_evm_create.argtypes = [ctypes.POINTER(BlockInfoFFI)]
lib.guillotine_evm_create.restype = ctypes.c_void_p
lib.guillotine_free_result.argtypes = [ctypes.POINTER(EvmResult)]
lib.guillotine_free_result.restype = None
try:
    output = ctypes.string_at(result.contents.output, result.contents.output_len)
finally:
    lib.guillotine_free_result(result)
```

Define BlockInfoFFI and the complete EvmResult with ctypes.Structure,
c_uint8*N, c_uint64, c_bool, and c_size_t. Keep input objects alive across the
call. For cffi compile against `#include "guillotine.h"` using set_source with
include_dirs, library_dirs and libraries=["guillotine_ffi"]. cdef accepts C
declarations, not an unprocessed header. Copy using bytes(ffi.buffer(ptr, len))
and release using library destructors, not ffi.gc on a random finalizer thread.

### Go cgo

Import the header through cgo and pin the whole native scope:

```go
runtime.LockOSThread()
defer runtime.UnlockOSThread()
C.guillotine_init()
defer C.guillotine_cleanup()
handle := C.guillotine_evm_create(&block)
if handle == nil { return fmt.Errorf("create: %s", C.GoString(C.guillotine_get_last_error())) }
defer C.guillotine_evm_destroy(handle)
```

Use CGO_CFLAGS/CGO_LDFLAGS with absolute checkout include/library paths. Use
C-owned storage for pointer-containing parameter structs and input; pair
C.CBytes with C.free. Copy native results before freeing; validate size_t
before narrowing to the C.int expected by C.GoBytes. A dedicated worker
OS thread can serialize requests for a long-lived runtime.

### Rust bindgen / FFI

Generate target-specific repr(C) declarations from the header:

```sh
bindgen sdks/c/include/guillotine.h --output /tmp/guillotine_bindings.rs
```

Emit cargo:rustc-link-search=native=<absolute zig-out/lib> and
cargo:rustc-link-lib=dylib=guillotine_ffi in the consumer's build.rs. Wrap
NonNull handles/results in RAII guards with PhantomData<Rc<()>> to prevent
Send/Sync. Tie guards to the runtime lifetime and copy output with
slice::from_raw_parts(...).to_vec() only for nonzero lengths. Drop results
before handles/runtime. Never use Vec::from_raw_parts or Box::from_raw for
Guillotine-owned memory; use guillotine_free_result.

### Swift C interop

Use a SwiftPM system-library module map or bridging header, not manually
redeclared Swift structs:

```sh
swiftc -import-objc-header sdks/c/include/guillotine.h \
  -Lzig-out/lib -lguillotine_ffi custom_sdk.swift -o /tmp/custom_sdk_swift
```

Within a dedicated OS-thread scope, pair guillotine_init/cleanup and
create/destroy using defer. Use withUnsafeBytes for synchronous inputs and
copy native output into Data before freeing. C fixed arrays import as tuples;
prefer C helper setters when constructing complex structs. Actors/serial
queues do not guarantee OS-thread affinity; arbitrary deinit is insufficient.

### Kotlin / JNI

Use a C bridge and Kotlin external declarations, for example:

```kotlin
package example
class Guillotine {
    external fun readFreshBalance(address: ByteArray): ByteArray
    companion object { init { System.loadLibrary("custom_guillotine_jni") } }
}
```

Implement Java_example_Guillotine_readFreshBalance with JNIEnv*: validate
array length, GetByteArrayRegion into a 20-byte C buffer, create/use/close on
the calling OS thread, and NewByteArray/SetByteArrayRegion to return copied
32-byte words. Check JNI exceptions and free native owners on every path.
Use a serialized dedicated worker for a long-lived handle. Do not accept
unchecked Long values as pointers. The guide includes the complete C bridge.

### Bun FFI

Load native functions with bun:ffi, using typed pointer and bool returns:

```typescript
const lib = dlopen(path, {
  guillotine_init: { args: [], returns: FFIType.void },
  guillotine_evm_create: { args: [FFIType.ptr], returns: FFIType.ptr },
  guillotine_free_result: { args: [FFIType.ptr], returns: FFIType.void },
});
```

Use bigint for u64, usize for lengths, ptr(Uint8Array) for retained input
buffers, and target-verified C layout measurements (or a compiled C bridge)
for struct construction/access. Copy native memory before freeing. The old
Bun prototype's CALLCODE omission and stale layouts must not be reused.
Simulation and state-dump exports remain available for custom native bindings;
they are not a maintained alternative backend in the TypeScript/WASM package.

## Prove the wrapper

Start with create/destroy, then state round trips and a contract returning a
known 32-byte word. Test REVERT bytes, empty/nonempty binary buffers, u256
boundaries, invalid call tags, copied errors, and repeated cleanup cycles.
Exercise nested logs/dumps if exposed. Validate layouts and exported symbols
on the actual target. Keep scope explicit: compile-only checks cannot certify
native execution. Report missing crypto artifacts or build configuration
failures instead of substituting implementations.

For repository changes run `zig build` and `zig build test-opcodes` from the
root, plus `make -f sdks/c/Makefile test` for C integration. Preserve any
protected paths and report blockers with their exact cause.
