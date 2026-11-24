# Building custom Guillotine SDKs

Guillotine ships Zig native bindings, C FFI bindings, and the
`@tevm/guillotine` TypeScript/WASM package. Build other language integrations
on the native C ABI, or use Zig directly when you need compile-time EVM
configuration. Python, Go, Rust, Swift, Kotlin/JNI, and native Bun examples
below are patterns for custom bindings, not separately shipped SDKs.

## Choose the correct interface

| Interface | Source of truth | Role |
| --- | --- | --- |
| Zig native | `src/root.zig`, `src/evm.zig`, `src/evm_config.zig` | EVM types, allocator ownership, compile-time configuration. Follow the repository module graph. |
| Native C ABI | `src/evm_c_api.zig`, [guillotine.h](../sdks/c/include/guillotine.h) | Stateful EVM calls, account state, results, traces, bytecode analysis. Built by `shared` and `static`. |
| Component C API | `src/root_c.zig` | Separate frame/component entry point; not the root of `shared` or `static`, and no root `zig build` step compiles it. |
| TypeScript/WASM | `sdks/typescript`, `sdks/wasm`, `src/evm_c.zig` | Browser/runtime loader and WASM memory ABI. Native pointer offsets do not apply. |

`src/root_c.zig` explicitly re-exports `evm_frame_create`,
`evm_frame_destroy`, `evm_frame_reset`, and `evm_frame_execute`. It also defines
`evm_version`, `evm_build_info`, `evm_init`, `evm_cleanup`,
`evm_test_simple_execution`, `evm_test_stack_operations`, and
`evm_test_integration`. Its imported component modules have their own APIs;
imports alone are not a promise that every function is exported. In particular,
`evm_init` is not `guillotine_init`, and `evm_frame_create` is not a stateful
`guillotine_evm_create`. Do not bind component functions against a library built
from `src/evm_c_api.zig` without checking its symbol table. Its test block
also references `src/precompiles/precompiles_c.zig`, which does not exist in
this revision.

## Build and link from the repository root

Use Zig 0.15.x (CI uses 0.15.2; `build.zig.zon` sets 0.15.1 as the minimum;
Zig 0.16 and later are not supported), Cargo, and the native C/crypto
dependencies used by the root build.

```sh
zig build shared
zig build static
```

| Build step | Artifact under `zig-out/lib/` |
| --- | --- |
| `shared` on macOS | `libguillotine_ffi.dylib` |
| `shared` on Linux | `libguillotine_ffi.so` |
| `shared` on Windows | Target DLL/import-library naming; inspect installed output. |
| `static` on Unix | `libguillotine_ffi_static.a` |

The header lives at `sdks/c/include/guillotine.h`; the build does not install it
automatically. Bundle it with the library from the same revision. Link shared
consumers with `-Isdks/c/include -Lzig-out/lib -lguillotine_ffi`. Use
`-lguillotine_ffi_static` for static linking, together with the target's native
crypto archives and system libraries; the static archive is not a promise of a
self-contained link. Inspect `build.zig`, `src/modules.build.zig`, and the
Voltaire dependency when resolving link dependencies.

For Unix-like systems, inspect exports using `nm -g` on the installed library
(or `nm -D --defined-only` on Linux). macOS symbol listings can have a leading
underscore. Use `dumpbin /exports` for Windows DLLs. Export checks must match
the target library, not just a copied header.

If the root build reports missing
`lib/voltaire/target/release/libcrypto_wrappers.a`, the vendored native crypto
artifact has not been prepared by the dependency build. Resolve that prerequisite
using the dependency's declared build/toolchain; do not replace crypto symbols
with stubs or claim that a wrapper's compilation proves the EVM library works.

For Zig-only consumers, use `src/root.zig` through the repository module graph
(`src/modules.build.zig`); a standalone `zig build-lib src/root_c.zig` omits
required module imports. Native Zig integration owns its allocator/database
lifetimes directly; C integration must use the exported destructors below.

## Native ABI layouts

The complete C declarations are in [guillotine.h](../sdks/c/include/guillotine.h).
Its structs mirror Zig `extern struct` declarations with natural C alignment.
Do not use packed structs, replace inline byte arrays with pointers, or assume
that all integers are 32-bit. `usize` maps to `size_t`, `u64` to `uint64_t`, and
Zig `bool` to C `bool`. `EvmConfiguration` and `CFusionType` are **uint8_t**,
not ordinary C enums. Scalars use the target's native byte order. Addresses
are 20 raw bytes; balances, values, storage keys/values, and CREATE2 salts are
32-byte **big-endian** unsigned integers.

The following sizes/offsets describe a 64-bit ABI with 8-byte pointer, size_t,
and uint64_t alignment. Measure `sizeof`, `_Alignof`, and `offsetof` on every
target, especially 32-bit platforms; these are not WASM layouts.

| Struct | Size | Fields in declaration order (`field: type @ offset`) |
| --- | ---: | --- |
| `BlockInfoFFI` | 104 | number: u64 @0; timestamp: u64 @8; gas_limit: u64 @16; coinbase: u8[20] @24; base_fee: u64 @48; chain_id: u64 @56; difficulty: u64 @64; prev_randao: u8[32] @72 |
| `CallParams` | 136 | caller: u8[20] @0; to: u8[20] @20; value: u8[32] @40; input: const u8* @72; input_len: size_t @80; gas: u64 @88; call_type: u8 @96; salt: u8[32] @97 |
| `LogEntry` | 56 | address: u8[20] @0; topics: const u8(*)[32] @24; topics_len: size_t @32; data: const u8* @40; data_len: size_t @48 |
| `SelfDestructRecord` | 40 | contract: u8[20] @0; beneficiary: u8[20] @20 |
| `StorageAccessRecord` | 52 | address: u8[20] @0; slot: u8[32] @20 |
| `EvmResult` | 144 | success: bool @0; gas_left: u64 @8; output: const u8* @16; output_len: size_t @24; error_message: const char* @32; logs: const LogEntry* @40; logs_len: size_t @48; selfdestructs: const SelfDestructRecord* @56; selfdestructs_len: size_t @64; accessed_addresses: const u8(*)[20] @72; accessed_addresses_len: size_t @80; accessed_storage: const StorageAccessRecord* @88; accessed_storage_len: size_t @96; created_address: u8[20] @104; has_created_address: bool @124; trace_json: const u8* @128; trace_json_len: size_t @136 |
| `AccountStateFFI` | 104 | address: u8[20] @0; balance: u8[32] @20; nonce: u64 @56; code: const u8* @64; code_len: size_t @72; storage_keys: const u8(*)[32] @80; storage_values: const u8(*)[32] @88; storage_count: size_t @96 |
| `StateDumpFFI` | 16 | accounts: const AccountStateFFI* @0; accounts_count: size_t @8 |
| `CBasicBlock` | 8 | start: u32 @0; end: u32 @4 |
| `CFusionInfo` | 48 | fusion_type: u8 @0; original_length: u32 @4; folded_value_low: u64 @8; folded_value_high: u64 @16; folded_value_extra_high: u64 @24; folded_value_top: u64 @32; count: u8 @40 |
| `CJumpFusion` | 8 | source_pc: u32 @0; target_pc: u32 @4 |
| `CAdvancedFusion` | 56 | pc: u32 @0; info: CFusionInfo @8 |
| `CBytecodeAnalysis` | 80 | push_pcs: u32* @0; push_pcs_count: u32 @8; jumpdests: u32* @16; jumpdests_count: u32 @24; basic_blocks: CBasicBlock* @32; basic_blocks_count: u32 @40; jump_fusions: CJumpFusion* @48; jump_fusions_count: u32 @56; advanced_fusions: CAdvancedFusion* @64; advanced_fusions_count: u32 @72 |
| `COpcodeInfo` | 4 | gas_cost: u16 @0; stack_inputs: u8 @2; stack_outputs: u8 @3 |

`CFusionType` values are constant_fold=0, multi_push=1, multi_pop=2,
iszero_jumpi=3, dup2_mstore_push=4. Folded words contain four numeric 64-bit
limbs from least to most significant; they are not a big-endian byte buffer.

Call types are CALL=0, CALLCODE=1, DELEGATECALL=2, STATICCALL=3, CREATE=4,
CREATE2=5. `input` holds calldata for calls and init code for deployment.
`guillotine_simulate` currently supports **CALL only**. Configuration values
are mainnet=0, mainnet_with_tracer=1, test_mode=2.

## Exported native symbols

These are the 42 functions explicitly exported by `src/evm_c_api.zig` in this
revision. The header contains exact prototypes; helper `pub fn` declarations
in other Zig modules are not automatically this library's exports.

| Category | Symbols |
| --- | --- |
| Library lifecycle | `guillotine_init`, `guillotine_cleanup`, `guillotine_get_last_error` |
| EVM lifecycle | `guillotine_evm_create`, `guillotine_evm_create_mainnet`, `guillotine_evm_create_with_config`, `guillotine_evm_create_tracing`, `guillotine_evm_create_test`, `guillotine_evm_destroy`, `guillotine_evm_destroy_tracing` |
| State setters | `guillotine_set_balance`, `guillotine_set_nonce`, `guillotine_set_code`, `guillotine_set_storage` |
| Tracing setters | `guillotine_set_balance_tracing`, `guillotine_set_nonce_tracing`, `guillotine_set_code_tracing` |
| State reads/buffers | `guillotine_get_balance`, `guillotine_get_code`, `guillotine_get_storage`, `guillotine_free_code` |
| Execution/results | `guillotine_call`, `guillotine_call_tracing`, `guillotine_simulate`, `guillotine_free_result`, `guillotine_free_output` |
| State dumps | `guillotine_dump_state`, `guillotine_dump_state_test`, `guillotine_free_state_dump` |
| Bytecode lifecycle/inspection | `evm_bytecode_create`, `evm_bytecode_destroy`, `evm_bytecode_get_length`, `evm_bytecode_get_runtime_data`, `evm_bytecode_get_opcode_at` |
| Bytecode analysis | `evm_bytecode_analyze`, `evm_bytecode_free_analysis`, `evm_bytecode_opcode_name`, `evm_bytecode_opcode_info`, `evm_bytecode_is_valid_opcode`, `evm_bytecode_error_string` |
| Formatting | `evm_bytecode_pretty_print`, `evm_dispatch_pretty_print` |

For example, `evm_bytecode_get_data`, `evm_bytecode_get_full_length`,
`evm_bytecode_find_jump_dests`, and `evm_bytecode_is_jump_dest` exist as
component helpers but are not explicitly exported by `src/evm_c_api.zig`.
Do not invent `guillotine_get_nonce` or a tracing storage getter/setter.

## Ownership, errors, and execution constraints

1. Call `guillotine_init()` before EVM operations. The allocator and error
   buffer are thread-local, but pools/maps are global. Serialize **all** native
   operations on one dedicated OS thread, including creation, getters/setters,
   destructors and cleanup. A mutex or async executor alone does not provide
   thread affinity. Do not create independently cleaned-up runtimes in multiple
   wrappers within the same process.
2. Create a mainnet handle with `guillotine_evm_create` (alias of
   `guillotine_evm_create_mainnet`). NULL indicates an FFI failure. Block data is
   copied; caller-owned argument structs/buffers need to remain valid only for
   the synchronous call. Reject invalid lengths, integers outside their declared
   unsigned range, and unsupported call/config tags before entering native code.
   The current transaction-context conversion narrows `chain_id` to `u16`; validate it
   against 0–65535 in this revision. Non-optional Zig pointer parameters require
   valid storage even when the corresponding byte count is zero; use a sentinel
   byte for empty input/code. Never pass arbitrary or already-closed handles.
3. Check every boolean setter/getter and nullable result. On failure, immediately
   copy `guillotine_get_last_error()` on that same thread. It is borrowed,
   NUL-terminated storage that subsequent calls may overwrite; it is not a
   nullable error object or a reliable success indicator. `init`/`cleanup` have
   no return status. The buffer is not guaranteed initialized before an error;
   do not read it speculatively after a successful operation.
4. A non-NULL `EvmResult` can have `success=false`: EVM failure/revert is distinct
   from an FFI failure. Preserve output/revert bytes and `gas_left` in either
   case. Gas used is requested gas minus gas left, rather than a native result
   field. Copy `error_message` immediately: it can alias the last-error buffer,
   and failure text may be stale when no detailed error was produced.
5. Copy output, nested log topics/data, access records, created address, and
   trace JSON into language-owned memory before `guillotine_free_result(result)`.
   That destructor owns every nested allocation and the result. Never free a
   result's output separately with `guillotine_free_output`: that would double
   free it. The latter is a low-level raw-buffer deallocator, not the normal
   result cleanup path. Empty arrays can contain sentinel pointers: use lengths,
   and never read/free them independently. Trace JSON is length-delimited bytes,
   not a guaranteed C string. Check `has_created_address` before using its bytes.
6. `guillotine_get_code` writes an allocated buffer and length through out
   parameters on success. Copy it, then call `guillotine_free_code(ptr, len)`
   (empty length is handled by that function). Never free this pointer through
   Python/Rust/Go/system allocators. Account code is copied by `set_code`.
7. `guillotine_dump_state` / `_test` return a dump owning account code and both
   storage arrays. Copy everything, then call `guillotine_free_state_dump` once.
   Storage keys/values are parallel arrays of `storage_count` 32-byte words.
8. Use `evm_bytecode_destroy` for bytecode handles. Allocate a zeroed
   `CBytecodeAnalysis` in caller storage, check `evm_bytecode_analyze`'s integer
   status (0 success), and call `evm_bytecode_free_analysis` after success to
   release nested arrays, not the caller-owned struct. Opcode names/error
   strings are borrowed static strings. Bytecode status codes are 0 and -1
   through -6 as declared in the header. Inspection functions also have sentinel
   returns (length 0, opcode 0xff); consult their implementation before treating
   a value as an error.
9. Mainnet destruction returns an instance to a pool; it is still invalid to
   reuse that handle. Tracing handles need `_tracing` setters/call/destructor.
   There are no tracing counterparts for general state reads, simulation, or
   storage setters. Test handles have their own type and `_test` dump function;
   generic mainnet setters/calls cast to `DefaultEvm` and must not be assumed
   compatible. A custom wrapper should default to mainnet and expose other
   configurations only with a verified set of compatible operations.
10. Release results, code buffers, dumps and bytecode handles, destroy all EVMs,
    then call `guillotine_cleanup()` once. Unload a dynamic library only after
    those operations complete. Do not rely on GC/finalizers on arbitrary threads
    for cleanup; expose explicit close/context-manager/RAII scopes that dispatch
    to the owning thread.

## A native C call

Save this as `custom_sdk.c` in a consumer project. Run compiler commands from
the repository root with paths adjusted to that consumer file. The contract
returns a 32-byte word ending in 42. Inputs use stack storage; the result is
copied before it is freed.

```c
#include "guillotine.h"
#include <stdio.h>
#include <string.h>

int main(void) {
    int status = 1;
    guillotine_init();
    BlockInfoFFI block = {0};
    block.gas_limit = 30000000;
    block.chain_id = 1;
    EvmHandle *evm = guillotine_evm_create(&block);
    if (!evm) {
        fprintf(stderr, "%s\n", guillotine_get_last_error());
        guillotine_cleanup();
        return status;
    }
    uint8_t address[20] = {0};
    address[19] = 0x42;
    const uint8_t code[] = {0x60,0x2a,0x60,0,0x52,0x60,0x20,0x60,0,0xf3};
    if (!guillotine_set_code(evm, address, code, sizeof code)) {
        fprintf(stderr, "%s\n", guillotine_get_last_error());
        goto done;
    }
    const uint8_t empty = 0;
    CallParams params = {0};
    memcpy(params.to, address, sizeof address);
    params.caller[19] = 0x43;
    params.gas = 100000;
    params.call_type = GUILLOTINE_CALL;
    params.input = &empty;
    EvmResult *result = guillotine_call(evm, &params);
    if (!result) {
        fprintf(stderr, "%s\n", guillotine_get_last_error());
        goto done;
    }
    uint8_t output[32] = {0};
    if (result->success && result->output_len == sizeof output) {
        memcpy(output, result->output, sizeof output);
        status = output[31] == 42 ? 0 : 1;
    } else {
        fprintf(stderr, "EVM execution failed or returned an unexpected length\n");
    }
    guillotine_free_result(result);
done:
    guillotine_evm_destroy(evm);
    guillotine_cleanup();
    return status;
}
```

```sh
cc -std=c99 -Isdks/c/include custom_sdk.c -Lzig-out/lib \
  -lguillotine_ffi -Wl,-rpath,"$PWD/zig-out/lib" -o /tmp/custom_sdk
/tmp/custom_sdk
```

## Python ctypes and cffi

For ctypes, declare **every** function's `argtypes` and `restype`: pointer
returns must not use ctypes' default integer return type. Use native alignment
and `c_size_t`, with inline `c_uint8 * N` fields. This complete mainnet lifecycle
example is the starting point; add all result fields from the header before
reading execution results.

```python
import ctypes as C
import os

class Block(C.Structure):
    _fields_ = [
        ("number", C.c_uint64), ("timestamp", C.c_uint64),
        ("gas_limit", C.c_uint64), ("coinbase", C.c_uint8 * 20),
        ("base_fee", C.c_uint64), ("chain_id", C.c_uint64),
        ("difficulty", C.c_uint64), ("prev_randao", C.c_uint8 * 32),
    ]

lib = C.CDLL(os.environ["GUILLOTINE_LIBRARY"])
lib.guillotine_init.argtypes, lib.guillotine_init.restype = [], None
lib.guillotine_cleanup.argtypes, lib.guillotine_cleanup.restype = [], None
lib.guillotine_evm_create.argtypes = [C.POINTER(Block)]
lib.guillotine_evm_create.restype = C.c_void_p
lib.guillotine_evm_destroy.argtypes = [C.c_void_p]
lib.guillotine_evm_destroy.restype = None
lib.guillotine_get_last_error.argtypes = []
lib.guillotine_get_last_error.restype = C.c_char_p

lib.guillotine_init()
try:
    block = Block(gas_limit=30_000_000, chain_id=1)
    handle = lib.guillotine_evm_create(C.byref(block))
    if not handle:
        raise RuntimeError(lib.guillotine_get_last_error().decode())
    try:
        print("Created mainnet EVM")
    finally:
        lib.guillotine_evm_destroy(handle)
finally:
    lib.guillotine_cleanup()
```

Use `value.to_bytes(32, "big", signed=False)` after validating a u256 range.
For an execution result pointer `result`, copy `C.string_at(result.contents.output,
result.contents.output_len)` when length is nonzero inside a `try/finally` that
calls `guillotine_free_result(result)`. Do not use `c_char_p` for binary outputs
or for a buffer pointer that must later be freed by address.

With [cffi](https://cffi.readthedocs.io/en/stable/cdef.html), compile against the
real header so C handles padding and bools. Save this generator as
`custom_cffi_build.py`, then run it from the root:

```python
from cffi import FFI
from pathlib import Path
ffi = FFI()
ffi.cdef("""
    typedef struct EvmHandle EvmHandle;
    typedef struct BlockInfoFFI {
        uint64_t number, timestamp, gas_limit;
        uint8_t coinbase[20];
        uint64_t base_fee, chain_id, difficulty;
        uint8_t prev_randao[32];
    } BlockInfoFFI;
    void guillotine_init(void);
    void guillotine_cleanup(void);
    EvmHandle *guillotine_evm_create(const BlockInfoFFI *);
    void guillotine_evm_destroy(EvmHandle *);
    const char *guillotine_get_last_error(void);
""")
ffi.set_source("_custom_guillotine", '#include "guillotine.h"',
    include_dirs=[str(Path("sdks/c/include").resolve())],
    library_dirs=[str(Path("zig-out/lib").resolve())],
    libraries=["guillotine_ffi"])
ffi.compile(tmpdir="/tmp/custom-guillotine-cffi", verbose=True)
```

Import the built module's `ffi, lib`; use `ffi.new("BlockInfoFFI *")` and
check pointers against `ffi.NULL`. Copy binary data with
`bytes(ffi.buffer(ptr, length))`, strings with `ffi.string`, and use the same
explicit destructor scopes as ctypes. Configure the runtime library search
path for the extension. `ffi.cdef` consumes C declarations, not an unprocessed
header containing include guards, `#include`, or `extern "C"` directives.

## Go cgo

[Go's cgo documentation](https://pkg.go.dev/cmd/cgo) defines pointer-lifetime
rules. Pin execution to an OS thread for the whole native lifecycle. The
following file belongs in the consumer Go module; `CGO_CFLAGS` and
`CGO_LDFLAGS` supply this checkout's absolute paths without changing cwd:

```go
package main

/*
#include "guillotine.h"
*/
import "C"
import (
    "fmt"
    "runtime"
)

func run() error {
    runtime.LockOSThread()
    defer runtime.UnlockOSThread()
    C.guillotine_init()
    defer C.guillotine_cleanup()
    var block C.BlockInfoFFI
    block.gas_limit = 30000000
    block.chain_id = 1
    handle := C.guillotine_evm_create(&block)
    if handle == nil {
        return fmt.Errorf("create: %s", C.GoString(C.guillotine_get_last_error()))
    }
    defer C.guillotine_evm_destroy(handle)
    return nil
}

func main() {
    if err := run(); err != nil { panic(err) }
}
```

```sh
CGO_CFLAGS="-I$PWD/sdks/c/include" \
CGO_LDFLAGS="-L$PWD/zig-out/lib -lguillotine_ffi -Wl,-rpath,$PWD/zig-out/lib" \
  go run /absolute/path/to/consumer/main.go
```

For structs containing an input pointer, prefer C-allocated input memory and
C-allocated parameter storage. Pair `C.CBytes` with `C.free` (include
`<stdlib.h>`), and set an explicit non-NULL sentinel for empty input. Do not
let C retain Go pointers. Copy results before `guillotine_free_result` using
`C.GoBytes` after checking that `size_t` fits its signed C-int length, or use a
bounded `unsafe.Slice` and copy for larger buffers. Keep every operation on
the same locked thread; a real service should queue work to one owning worker.

## Rust bindgen / FFI

Generate bindings from the header, keeping [bindgen's C layouts](https://rust-lang.github.io/rust-bindgen/introduction.html):

```sh
bindgen sdks/c/include/guillotine.h \
  --allowlist-function 'guillotine_.*|evm_bytecode_.*|evm_dispatch_pretty_print' \
  --allowlist-type 'Evm.*|CallParams|BlockInfoFFI|LogEntry|SelfDestructRecord|StorageAccessRecord|AccountStateFFI|StateDumpFFI|BytecodeHandle|C.*' \
  --allowlist-var 'GUILLOTINE_.*|EVM_BYTECODE_.*' \
  --output /tmp/guillotine_bindings.rs
```

In the consumer's `build.rs`, emit `cargo:rustc-link-search=native=...` for the
absolute `zig-out/lib` path and `cargo:rustc-link-lib=dylib=guillotine_ffi`.
Keep the generated bindings in the consumer crate and wrap the raw interface.
A result guard can own native results without owning the runtime:

```rust
use std::{marker::PhantomData, ptr::NonNull, rc::Rc};
mod raw { include!("/tmp/guillotine_bindings.rs"); }

// The caller retains the initialized runtime and its owning OS thread.
struct ResultGuard {
    ptr: NonNull<raw::EvmResult>,
    thread: PhantomData<Rc<()>>, // neither Send nor Sync
}
impl Drop for ResultGuard {
    fn drop(&mut self) {
        unsafe { raw::guillotine_free_result(self.ptr.as_ptr()) }
    }
}
impl ResultGuard {
    fn output(&self) -> Vec<u8> {
        let result = unsafe { self.ptr.as_ref() };
        if result.output_len == 0 { return Vec::new(); }
        unsafe { std::slice::from_raw_parts(result.output, result.output_len).to_vec() }
    }
}
```

Construct the guard only after checking the call result for NULL. Copy the
error string before other native calls; use `CStr` only for NUL-terminated
strings. Validate lengths against Rust's slice constraints. Give EVM/runtime
owners the same `!Send`/`!Sync` property, and tie result guards to the runtime
lifetime in the safe wrapper. Cleanup must run after all guards and handles
have been dropped. Do not use `Box::from_raw` or `Vec::from_raw_parts` for
native allocations. Use `#[repr(C)]` if manually declaring structs; never
use default Rust layout across FFI.

## Swift C interop

Import the header through a SwiftPM system-library module or an Xcode
bridging header. [Swift imports C structs directly](https://developer.apple.com/documentation/swift/using-imported-c-structs-and-unions-in-swift).
For example, a consumer module map can contain:

```text
module CGuillotine [system] {
    header "guillotine.h"
    link "guillotine_ffi"
    export *
}
```

Put that module map next to a copy of the matching header. Or compile a
standalone `custom_sdk.swift` using the header directly:

```sh
swiftc -import-objc-header sdks/c/include/guillotine.h \
  -Lzig-out/lib -lguillotine_ffi \
  -Xlinker -rpath -Xlinker "$PWD/zig-out/lib" \
  custom_sdk.swift -o /tmp/custom_sdk_swift
```

```swift
import Foundation

func createAndClose() throws {
    guillotine_init()
    defer { guillotine_cleanup() }
    var block = BlockInfoFFI()
    block.gas_limit = 30_000_000
    block.chain_id = 1
    guard let handle = guillotine_evm_create(&block) else {
        throw NSError(domain: "Guillotine", code: 1,
            userInfo: [NSLocalizedDescriptionKey: String(cString: guillotine_get_last_error())])
    }
    defer { guillotine_evm_destroy(handle) }
    print("Created mainnet EVM")
}
try createAndClose()
```

Run this scope on a dedicated OS thread. An actor or serial Dispatch queue may
move work between OS threads. Use `withUnsafeBytes` only while making a
synchronous call and copy native output into `Data` before freeing its result.
C fixed arrays import as tuples; use compiler-imported types or small C helper
setters rather than assuming a Swift tuple's address is a serialized struct.
Do not depend on `deinit` executing on the native owner thread.

## Kotlin / JNI

Use a C/C++ JNI bridge compiled for each target architecture and link it to
`guillotine_ffi`. Pass addresses/words as `ByteArray` of exactly 20/32 bytes.
Use opaque managed IDs for long-lived handles, or keep the complete native
lifecycle within one synchronous JNI call. Do not accept unchecked `Long`
values as native addresses.

This one-call bridge gives a concrete zero-state balance read pattern while
keeping initialization and cleanup on the calling OS thread. Serialize all
calls globally; use a dedicated Java/Kotlin worker for a long-lived EVM.

```kotlin
package example
class Guillotine {
    external fun readFreshBalance(address: ByteArray): ByteArray
    companion object { init { System.loadLibrary("custom_guillotine_jni") } }
}
```

```c
#include <jni.h>
#include "guillotine.h"

JNIEXPORT jbyteArray JNICALL
Java_example_Guillotine_readFreshBalance(JNIEnv *env, jobject self, jbyteArray address) {
    (void)self;
    if (!address || (*env)->GetArrayLength(env, address) != 20) {
        jclass cls = (*env)->FindClass(env, "java/lang/IllegalArgumentException");
        if (cls) (*env)->ThrowNew(env, cls, "address must have 20 bytes");
        return NULL;
    }
    uint8_t bytes[20], balance[32];
    (*env)->GetByteArrayRegion(env, address, 0, 20, (jbyte *)bytes);
    if ((*env)->ExceptionCheck(env)) return NULL;
    guillotine_init();
    BlockInfoFFI block = {0};
    block.gas_limit = 30000000;
    block.chain_id = 1;
    EvmHandle *handle = guillotine_evm_create(&block);
    jbyteArray output = NULL;
    if (!handle || !guillotine_get_balance(handle, bytes, balance)) {
        jclass cls = (*env)->FindClass(env, "java/lang/IllegalStateException");
        if (cls) (*env)->ThrowNew(env, cls, "native EVM operation failed");
    } else {
        output = (*env)->NewByteArray(env, 32);
        if (output) (*env)->SetByteArrayRegion(env, output, 0, 32, (const jbyte *)balance);
    }
    if (handle) guillotine_evm_destroy(handle);
    guillotine_cleanup();
    return output;
}
```

Compile with `-Isdks/c/include`, the JDK's `include` and target-specific JNI
include directory (or Android NDK sysroot), `-Lzig-out/lib -lguillotine_ffi`,
and your platform's shared-library flags. Arrange loading of the dependent
Guillotine library too. For execution buffers, check that native lengths fit
`jsize` before allocating/copying and free native results even when JNI raises
an exception. JNI region-copy functions avoid holding a JVM array pin while
the EVM runs. See the [JNI function specification](https://docs.oracle.com/en/java/javase/25/docs/specs/jni/functions.html).

## Bun FFI

Use the official TypeScript/WASM package for the maintained JavaScript SDK.
For a custom native backend, [Bun FFI](https://bun.sh/docs/runtime/ffi) can load
the shared C ABI. A minimal lifecycle template on native 64-bit little-endian
Bun targets is:

```typescript
import { dlopen, FFIType, ptr, CString } from "bun:ffi";
const path = process.env.GUILLOTINE_LIBRARY;
if (!path) throw new Error("Set GUILLOTINE_LIBRARY to the shared library path");
if (!["arm64", "x64"].includes(process.arch)) {
  throw new Error("This layout example requires a native 64-bit target");
}
const lib = dlopen(path, {
  guillotine_init: { args: [], returns: FFIType.void },
  guillotine_cleanup: { args: [], returns: FFIType.void },
  guillotine_evm_create: { args: [FFIType.ptr], returns: FFIType.ptr },
  guillotine_evm_destroy: { args: [FFIType.ptr], returns: FFIType.void },
  guillotine_get_last_error: { args: [], returns: FFIType.ptr },
});
lib.symbols.guillotine_init();
try {
  // Verify these sizeof/offsetof values against a C probe on the target.
  const block = new Uint8Array(104);
  const view = new DataView(block.buffer);
  view.setBigUint64(16, 30_000_000n, true); // gas_limit
  view.setBigUint64(56, 1n, true); // chain_id
  const handle = lib.symbols.guillotine_evm_create(ptr(block));
  if (!handle) {
    throw new Error(new CString(lib.symbols.guillotine_get_last_error()).toString());
  }
  try { console.log("Created mainnet EVM"); }
  finally { lib.symbols.guillotine_evm_destroy(handle); }
} finally {
  lib.symbols.guillotine_cleanup();
  lib.close();
}
```

Use `FFIType.u64`/`bigint` for gas and nonce, and `FFIType.usize` for native
lengths. For CALL/CREATE buffers, derive all offsets from a compiled C probe or
use a C bridge that constructs structs and exposes result accessors. Keep
`Uint8Array` input buffers strongly referenced through the synchronous call.
`ptr(buffer)` is an address, not a copy. Copy result buffers before freeing;
Bun views over native memory cannot outlive their native owner. Serialize this
backend on one runtime/OS thread and provide explicit close behavior.

The old Bun prototype's useful native features were `guillotine_simulate`
(CALL only) and `guillotine_dump_state`, plus state setters and native calls.
The native ABI still offers them, but its old enum and handwritten result/state
layouts were stale. They are not part of the TypeScript/WASM package backend.

## Verify a custom SDK

Compile the wrapper against the matching header and inspect the library's
exports. Compare `sizeof`/alignment/offsets against the actual Zig extern types
on every target. Check empty/nonempty binary buffers, u256 byte order and range
errors, maximum supported chain ID, and the CALL/CALLCODE distinction.

Run a mainnet create/destroy scope, balance/storage/code round trips, a contract
returning known bytes (the C example returns 42), a REVERT preserving its output,
and an invalid call type producing NULL with a copied error. Repeat creation,
execution, copying, and destruction to expose ownership bugs; include nested
logs and state dumps when the wrapper supports them. Do not claim success from
header-only compilation or mocked native execution.

For repository changes run, from the root:

```sh
zig build
zig build test-opcodes
make -f sdks/c/Makefile test
```

Report missing dependency or protected build configuration failures precisely.
Keep custom wrapper code in its consumer project; do not restore separate
language SDK directories merely to use these patterns.
