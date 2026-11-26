# Building custom Guillotine SDKs

Guillotine exposes one native C ABI: `src/evm_c_api.zig`, declared in
[`sdks/c/include/guillotine.h`](../sdks/c/include/guillotine.h). Every language
binding, including the `@tevm/guillotine` TypeScript package, loads the same
library, `libguillotine_ffi`. This guide covers the build artifacts, every
exported function, struct layouts, ownership, errors, threading, and binding
templates for Python, Go, Rust, Swift, Kotlin/JNI, and Bun.

The conformance reference is
[`sdks/c/tests/safety_test.c`](../sdks/c/tests/safety_test.c). Port its checks
to your language before you ship a binding.

## Interfaces

| Interface | Source of truth | Use |
| --- | --- | --- |
| Zig | `src/root.zig`, `src/evm.zig` | Import the EVM directly and configure it at compile time. |
| C ABI | `src/evm_c_api.zig`, `sdks/c/include/guillotine.h` | Embed the EVM from any language with a C FFI. |
| TypeScript | `sdks/typescript` (`@tevm/guillotine`) | Bun native FFI (`bun:ffi`) binding over `libguillotine_ffi`. |

`src/root_c.zig` only re-exports `src/evm_c_api.zig`; it is not a separate API.
`src/bytecode/bytecode_c.zig` implements the `evm_bytecode_*` functions that
`src/evm_c_api.zig` exports. There is no WASM build of this ABI.

## Build artifacts

Run from the repository root with the Zig version pinned in `build.zig.zon`:

```sh
zig build shared -Doptimize=ReleaseFast   # shared library
zig build static -Doptimize=ReleaseFast   # static archive
```

| Artifact | macOS | Linux |
| --- | --- | --- |
| Shared | `zig-out/lib/libguillotine_ffi.dylib` | `zig-out/lib/libguillotine_ffi.so` |
| Static | `zig-out/lib/libguillotine_ffi_static.a` | `zig-out/lib/libguillotine_ffi_static.a` |

Windows is not built or tested by the repository.

Compile against the header with `-Isdks/c/include` and link the shared library
with `-Lzig-out/lib -lguillotine_ffi`. Set a runtime search path (`-Wl,-rpath`,
`LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`) or ship the library beside your binary.
The shared library is the supported artifact. A static link must also supply
libc, libunwind on Linux, and any native crypto archives the build links in.

Pin the header and the library to the same revision. Confirm the exports on
your target before generating bindings:

```sh
nm -gU zig-out/lib/libguillotine_ffi.dylib | grep -E ' _(guillotine|evm)_'   # macOS
nm -D --defined-only zig-out/lib/libguillotine_ffi.so | grep -E ' (guillotine|evm)_'  # Linux
```

## Exported functions

This is the complete list of `export fn` declarations in `src/evm_c_api.zig`.
No other symbols are part of the ABI. There is no nonce getter; read nonces
through `guillotine_dump_state`.

### Lifecycle and handles

| Function | Returns | Notes |
| --- | --- | --- |
| `guillotine_init(void)` | `void` | Enables handle creation. Idempotent. Call once before creating handles. |
| `guillotine_cleanup(void)` | `void` | Destroys every live handle and disables creation until the next `guillotine_init`. |
| `guillotine_evm_create_with_config(const BlockInfoFFI*, uint8_t config)` | `EvmHandle*` or NULL | `config` is 0 (mainnet), 1 (mainnet with tracer), or 2 (test mode). Any other byte returns NULL. |
| `guillotine_evm_create(const BlockInfoFFI*)` | `EvmHandle*` or NULL | Config 0. |
| `guillotine_evm_create_mainnet(const BlockInfoFFI*)` | `EvmHandle*` or NULL | Config 0. |
| `guillotine_evm_create_tracing(const BlockInfoFFI*)` | `EvmHandle*` or NULL | Config 1. Results carry `trace_json`. |
| `guillotine_evm_create_test(const BlockInfoFFI*)` | `EvmHandle*` or NULL | Config 2. |
| `guillotine_evm_destroy(EvmHandle*)` | `void` | NULL is a no-op. A destroyed or unknown handle records an error and is ignored. |
| `guillotine_evm_destroy_tracing(EvmHandle*)` | `void` | Alias of `guillotine_evm_destroy`. |

### State

| Function | Returns | Notes |
| --- | --- | --- |
| `guillotine_set_balance(h, const uint8_t addr[20], const uint8_t bal[32])` | `bool` | Balance is a big-endian u256. |
| `guillotine_set_nonce(h, const uint8_t addr[20], uint64_t nonce)` | `bool` | |
| `guillotine_set_code(h, const uint8_t addr[20], const uint8_t *code, size_t len)` | `bool` | `code` may be NULL only when `len` is 0. |
| `guillotine_set_storage(h, addr[20], const uint8_t key[32], const uint8_t value[32])` | `bool` | Big-endian words. |
| `guillotine_get_balance(h, addr[20], uint8_t out[32])` | `bool` | Writes a big-endian u256. |
| `guillotine_get_storage(h, addr[20], key[32], uint8_t out[32])` | `bool` | Writes a big-endian word. |
| `guillotine_get_code(h, addr[20], uint8_t **code_out, size_t *len_out)` | `bool` | Writes an owned copy. Missing accounts have empty code. Free with `guillotine_free_code`. |
| `guillotine_free_code(uint8_t *code, size_t len)` | `void` | No-op for NULL or `len` 0. |
| `guillotine_set_balance_tracing`, `guillotine_set_nonce_tracing`, `guillotine_set_code_tracing` | `bool` | Aliases of the functions without the suffix. |

### Execution

| Function | Returns | Notes |
| --- | --- | --- |
| `guillotine_call(h, const CallParams*)` | `EvmResult*` or NULL | Executes and commits state. ORIGIN is `params->caller`. |
| `guillotine_call_tracing(h, const CallParams*)` | `EvmResult*` or NULL | Alias of `guillotine_call`. |
| `guillotine_simulate(h, const CallParams*)` | `EvmResult*` or NULL | Executes without committing database changes. Supports `call_type` 0 (CALL) only; other types return NULL. ORIGIN is `params->caller`. |
| `guillotine_free_result(EvmResult*)` | `void` | Frees the result and every array it owns. NULL is a no-op. |
| `guillotine_free_output(uint8_t *buf, size_t len)` | `void` | Frees a library-allocated byte buffer; same behavior as `guillotine_free_code`. Never call it on `EvmResult.output`. |
| `guillotine_get_last_error(void)` | `const char*` | Thread-local message; never NULL; `""` when none was recorded on this thread. |

`call_type` values: 0 CALL, 1 CALLCODE, 2 DELEGATECALL, 3 STATICCALL, 4 CREATE,
5 CREATE2. Any other value returns NULL with `Invalid call type`. CREATE and
CREATE2 use `input` as init code; CREATE2 reads `salt`; `to` is ignored for
both, and DELEGATECALL and STATICCALL ignore `value`.

### State dump

| Function | Returns | Notes |
| --- | --- | --- |
| `guillotine_dump_state(h)` | `StateDumpFFI*` or NULL | Every non-empty account touched through this handle, by setters or execution. |
| `guillotine_dump_state_test(h)` | `StateDumpFFI*` or NULL | Alias of `guillotine_dump_state`. |
| `guillotine_free_state_dump(StateDumpFFI*)` | `void` | Frees the dump and all nested arrays. NULL is a no-op. |

### Bytecode utilities

These functions do not take an `EvmHandle` and do not need `guillotine_init`.

| Function | Returns | Notes |
| --- | --- | --- |
| `evm_bytecode_create(const uint8_t *data, size_t len)` | `BytecodeHandle*` or NULL | Copies and validates `data`. Invalid bytecode returns NULL and sets the last error. |
| `evm_bytecode_destroy(BytecodeHandle*)` | `void` | NULL is a no-op. Bytecode handles are not registry-checked: destroy each exactly once. |
| `evm_bytecode_get_length(const BytecodeHandle*)` | `size_t` | 0 for NULL. |
| `evm_bytecode_get_runtime_data(h, uint8_t *buf, size_t len)` | `size_t` | Copies up to `len` bytes; returns bytes copied. 0 for NULL handle, NULL buffer, or `len` 0. |
| `evm_bytecode_get_opcode_at(h, size_t pos)` | `uint8_t` | `0xFF` for NULL or out of range. `0xFF` is also SELFDESTRUCT, so bounds-check with `evm_bytecode_get_length` first. |
| `evm_bytecode_analyze(h, CBytecodeAnalysis *out)` | `int` | `EVM_BYTECODE_SUCCESS` (0) or a negative `EVM_BYTECODE_ERROR_*` code. The caller owns `*out`; the library owns its arrays. |
| `evm_bytecode_free_analysis(CBytecodeAnalysis*)` | `void` | Frees the arrays and zeroes the struct. Call after every successful analyze. |
| `evm_bytecode_opcode_name(uint8_t)` | `const char*` | Static string; `"INVALID"` for undefined opcodes. Never free. |
| `evm_bytecode_opcode_info(uint8_t)` | `COpcodeInfo` | Returned by value. |
| `evm_bytecode_is_valid_opcode(uint8_t)` | `int` | 1 or 0. |
| `evm_bytecode_error_string(int)` | `const char*` | Static string for an `EVM_BYTECODE_*` code. Never free. |
| `evm_bytecode_pretty_print(data, len, buf, buf_len)` | `size_t` | Writes NUL-terminated text, truncated to fit. Returns bytes written including the NUL, the required size when `buf_len` is 0, or 0 on invalid input. |
| `evm_dispatch_pretty_print(data, len, buf, buf_len)` | `size_t` | Same size contract. On failure the buffer receives an `Error: ...` line. |

## Struct layouts

All structs use natural C alignment in declaration order. `[20]u8` and
`[32]u8` fields are inline arrays, not pointers. `usize` is `size_t`, `bool`
is C `bool` (1 byte), and `EvmConfiguration` and `CFusionType` are `uint8_t`,
not `int`-sized enums.

Sizes and offsets below are for 64-bit targets (LP64). `sdks/c/tests/simple_test.c`
asserts the sizes of `BlockInfoFFI`, `CallParams`, `EvmResult`, and
`AccountStateFFI` plus two offsets. Re-measure on any other target.

`BlockInfoFFI` (104 bytes, align 8)

| Offset | Field | Type |
| ---: | --- | --- |
| 0 | `number` | `uint64_t` |
| 8 | `timestamp` | `uint64_t` |
| 16 | `gas_limit` | `uint64_t` |
| 24 | `coinbase` | `uint8_t[20]` |
| 48 | `base_fee` | `uint64_t` |
| 56 | `chain_id` | `uint64_t` |
| 64 | `difficulty` | `uint64_t` |
| 72 | `prev_randao` | `uint8_t[32]` |

`CallParams` (136 bytes, align 8)

| Offset | Field | Type |
| ---: | --- | --- |
| 0 | `caller` | `uint8_t[20]` |
| 20 | `to` | `uint8_t[20]` |
| 40 | `value` | `uint8_t[32]`, big-endian u256 |
| 72 | `input` | `const uint8_t*` |
| 80 | `input_len` | `size_t` |
| 88 | `gas` | `uint64_t` |
| 96 | `call_type` | `uint8_t` |
| 97 | `salt` | `uint8_t[32]`, big-endian u256 |

`EvmResult` (144 bytes, align 8)

| Offset | Field | Type |
| ---: | --- | --- |
| 0 | `success` | `bool` |
| 8 | `gas_left` | `uint64_t` |
| 16 | `output` | `const uint8_t*` |
| 24 | `output_len` | `size_t` |
| 32 | `error_message` | `const char*`, NUL-terminated |
| 40 | `logs` | `const LogEntry*` |
| 48 | `logs_len` | `size_t` |
| 56 | `selfdestructs` | `const SelfDestructRecord*` |
| 64 | `selfdestructs_len` | `size_t` |
| 72 | `accessed_addresses` | `const uint8_t (*)[20]` |
| 80 | `accessed_addresses_len` | `size_t` |
| 88 | `accessed_storage` | `const StorageAccessRecord*` |
| 96 | `accessed_storage_len` | `size_t` |
| 104 | `created_address` | `uint8_t[20]` |
| 124 | `has_created_address` | `bool` |
| 128 | `trace_json` | `const uint8_t*`, not NUL-terminated |
| 136 | `trace_json_len` | `size_t` |

`LogEntry` (56 bytes, align 8): `address` `uint8_t[20]` at 0, `topics`
`const uint8_t (*)[32]` at 24, `topics_len` at 32, `data` at 40, `data_len` at
48. Topics are big-endian words.

`SelfDestructRecord` (40 bytes, align 1): `contract[20]`, `beneficiary[20]`.

`StorageAccessRecord` (52 bytes, align 1): `address[20]`, `slot[32]`
(big-endian).

`AccountStateFFI` (104 bytes, align 8)

| Offset | Field | Type |
| ---: | --- | --- |
| 0 | `address` | `uint8_t[20]` |
| 20 | `balance` | `uint8_t[32]`, big-endian u256 |
| 56 | `nonce` | `uint64_t` |
| 64 | `code` | `const uint8_t*` |
| 72 | `code_len` | `size_t` |
| 80 | `storage_keys` | `const uint8_t (*)[32]` |
| 88 | `storage_values` | `const uint8_t (*)[32]` |
| 96 | `storage_count` | `size_t` |

`StateDumpFFI` (16 bytes): `accounts` pointer at 0, `accounts_count` at 8.

Bytecode structs: `CBytecodeAnalysis` is 80 bytes, `CFusionInfo` 48,
`CAdvancedFusion` 56, `COpcodeInfo` 4 (align 2). Take field order from the
header.

## Encoding

- Addresses are 20 raw bytes.
- u256 values (balances, `value`, `salt`, storage keys and values, log topics)
  are 32-byte big-endian arrays.
- Scalars (`uint64_t`, `size_t`) use the host byte order.
- `trace_json` holds `{"structLogs":[...]}`. Each step has `pc`, `op`, `gas`,
  `gasCost`, `depth`, `stack` (hex strings), and `memSize`. It is filled only
  for handles created with config 1 and is empty otherwise.

## Handle lifecycle

```text
guillotine_init()
  h = guillotine_evm_create*(&block)      fresh EVM + fresh state database
  guillotine_set_* / get_* / call / simulate / dump_state
  guillotine_evm_destroy(h)
guillotine_cleanup()                      optional; destroys handles still alive
```

- Each `guillotine_evm_create*` call allocates a new EVM and a new state
  database. Nothing is pooled or shared, so no state crosses handles.
- Creation fails before `guillotine_init` and after `guillotine_cleanup`.
- The library keeps a registry of live handles. Every function looks the
  handle up before using it and never dereferences an unknown pointer, so NULL,
  foreign, destroyed, and cleaned-up handles return NULL or false with an
  error.
- A handle is a registry token, not an address. Tokens start at 1, only grow,
  and are never reissued, even across `guillotine_cleanup` and
  `guillotine_init`, so a destroyed handle never aliases a newer one and every
  later call with it fails. Destroy only handles you own.
- Any handle works with every function. The `*_tracing` and `*_test` functions
  are aliases kept for existing callers; the handle's configuration decides
  tracing, not the function name.
- `guillotine_cleanup` is a process-shutdown step. Do not call it while
  another thread is inside a library call.

## Ownership

Every buffer the library returns comes from the C allocator (`malloc` family)
and must go back through the matching library function. Never free library
memory with your language's allocator, and never free nested arrays yourself.

| Owner | Release with |
| --- | --- |
| `EvmHandle*` | `guillotine_evm_destroy` (or `guillotine_cleanup`) |
| `EvmResult*` from call or simulate | `guillotine_free_result` once; frees output, error message, logs, topics, data, access lists, and trace |
| `*code_out` from `guillotine_get_code` | `guillotine_free_code(code, len)` |
| `StateDumpFFI*` | `guillotine_free_state_dump` |
| `BytecodeHandle*` | `evm_bytecode_destroy` |
| Arrays inside a successful `CBytecodeAnalysis` | `evm_bytecode_free_analysis` |
| `guillotine_get_last_error`, `evm_bytecode_opcode_name`, `evm_bytecode_error_string` | Never freed |

Rules:

- Copy everything you need out of a result before freeing it.
- Zero-length arrays use non-NULL placeholder pointers. Treat the length as
  authoritative and never free a placeholder. The free functions ignore
  length 0.
- Free functions are thread-safe and may run on any thread, including a
  garbage-collector finalizer thread.
- Input buffers (`code`, `input`, `data`) are borrowed only for the duration
  of the call. The library copies what it keeps.
- A NULL input pointer with a non-zero length is rejected. NULL with length 0
  means empty.

## Error model

Two failure levels exist. Handle both.

1. **ABI failure.** The function returns NULL or false. Causes include a bad
   handle, a NULL required pointer, an invalid config or call type,
   `guillotine_simulate` with a non-CALL type, an out-of-range chain id, and
   allocation failure. Read `guillotine_get_last_error()` on the same thread
   immediately and copy the string. The buffer is thread-local, holds at most
   256 bytes (longer messages end in `...`), and is overwritten by the next
   failing call on that thread. Successful calls do not clear it, so never
   read it after a success.
2. **Execution failure.** The call returns a non-NULL `EvmResult` with
   `success == false`. `output` holds revert data, `gas_left` is valid, and
   `error_message` holds the reason. `error_message` is an owned copy, `""`
   when there is none, and lives until `guillotine_free_result`.

`evm_bytecode_analyze` reports failure through its return code, not the last
error. `evm_bytecode_create` sets the last error on failure, and
`evm_dispatch_pretty_print` sets it when building the dispatch schedule fails.

## Threading

- Different handles may run on different threads at the same time.
- A single handle must not be used by two threads at the same time. Serialize
  access with a mutex or confine the handle to one thread.
- Read the last error on the thread whose call failed, before that thread
  makes another call. Runtimes that migrate tasks between OS threads (Go
  goroutines, async executors) must pin the thread across the failing call
  and the read.
- Results, code buffers, and dumps may be freed on any thread.

## Chain id

`BlockInfoFFI.chain_id` is a `uint64_t`, and the EVM's CHAINID type
(`TransactionContext.chain_id` in `src/block/transaction_context.zig`) is also
`u64`, so every value is accepted and CHAINID returns it unchanged. Pass the
full 64-bit value through your binding; do not hard-code a cap. A build that
narrows `TransactionContext.chain_id` rejects wider values instead of
truncating them: creation returns NULL and the last error reads
`chain_id <n> exceeds the supported maximum <max>`. `safety_test.c` requires
an exact CHAINID round-trip for 1, 8453, 84532, 11155111, and `UINT64_MAX`.

## Binding templates

Each template creates a handle, deploys code, calls it, copies the output, and
frees everything. Error paths read the last error immediately. Adapt the
structs from the layout tables; sizes must match the 64-bit values above.

### Python (ctypes)

```python
import ctypes, os

lib = ctypes.CDLL(os.environ["GUILLOTINE_LIB_PATH"])
U8, U64, SZ = ctypes.c_uint8, ctypes.c_uint64, ctypes.c_size_t

class BlockInfoFFI(ctypes.Structure):
    _fields_ = [("number", U64), ("timestamp", U64), ("gas_limit", U64),
                ("coinbase", U8 * 20), ("base_fee", U64), ("chain_id", U64),
                ("difficulty", U64), ("prev_randao", U8 * 32)]

class CallParams(ctypes.Structure):
    _fields_ = [("caller", U8 * 20), ("to", U8 * 20), ("value", U8 * 32),
                ("input", ctypes.POINTER(U8)), ("input_len", SZ), ("gas", U64),
                ("call_type", U8), ("salt", U8 * 32)]

class EvmResult(ctypes.Structure):
    _fields_ = [("success", ctypes.c_bool), ("gas_left", U64),
                ("output", ctypes.POINTER(U8)), ("output_len", SZ),
                ("error_message", ctypes.c_char_p),
                ("logs", ctypes.c_void_p), ("logs_len", SZ),
                ("selfdestructs", ctypes.c_void_p), ("selfdestructs_len", SZ),
                ("accessed_addresses", ctypes.c_void_p), ("accessed_addresses_len", SZ),
                ("accessed_storage", ctypes.c_void_p), ("accessed_storage_len", SZ),
                ("created_address", U8 * 20), ("has_created_address", ctypes.c_bool),
                ("trace_json", ctypes.POINTER(U8)), ("trace_json_len", SZ)]

assert ctypes.sizeof(BlockInfoFFI) == 104
assert ctypes.sizeof(CallParams) == 136 and CallParams.salt.offset == 97
assert ctypes.sizeof(EvmResult) == 144 and EvmResult.trace_json.offset == 128

lib.guillotine_init.argtypes, lib.guillotine_init.restype = [], None
lib.guillotine_get_last_error.argtypes, lib.guillotine_get_last_error.restype = [], ctypes.c_char_p
lib.guillotine_evm_create.argtypes = [ctypes.POINTER(BlockInfoFFI)]
lib.guillotine_evm_create.restype = ctypes.c_void_p
lib.guillotine_evm_destroy.argtypes, lib.guillotine_evm_destroy.restype = [ctypes.c_void_p], None
lib.guillotine_set_code.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, SZ]
lib.guillotine_set_code.restype = ctypes.c_bool
lib.guillotine_call.argtypes = [ctypes.c_void_p, ctypes.POINTER(CallParams)]
lib.guillotine_call.restype = ctypes.POINTER(EvmResult)
lib.guillotine_free_result.argtypes = [ctypes.POINTER(EvmResult)]
lib.guillotine_free_result.restype = None

def last_error() -> str:
    return lib.guillotine_get_last_error().decode("utf-8", "replace")

lib.guillotine_init()
block = BlockInfoFFI(number=1, timestamp=1, gas_limit=30_000_000, chain_id=1)
handle = lib.guillotine_evm_create(ctypes.byref(block))
if not handle:
    raise RuntimeError(last_error())
try:
    target = bytes(19) + b"\xc3"  # not a precompile address
    code = bytes.fromhex("602a60005260206000f3")  # return 42 as a 32-byte word
    if not lib.guillotine_set_code(handle, target, code, len(code)):
        raise RuntimeError(last_error())
    params = CallParams(gas=100_000, call_type=0)
    params.caller[19] = 0xAA
    ctypes.memmove(params.to, target, 20)
    result = lib.guillotine_call(handle, ctypes.byref(params))
    if not result:
        raise RuntimeError(last_error())
    try:
        r = result.contents
        output = ctypes.string_at(r.output, r.output_len)
        if not r.success:
            raise RuntimeError(r.error_message.decode("utf-8", "replace"), output)
    finally:
        lib.guillotine_free_result(result)
finally:
    lib.guillotine_evm_destroy(handle)
```

Python threads are OS threads, so reading the last error right after the
failing call on the same thread is sufficient. For non-empty input, keep a
`(U8 * n).from_buffer_copy(data)` object alive across the call and assign
`ctypes.cast(buf, ctypes.POINTER(U8))` to `params.input`.

### Go (cgo)

```go
package guillotine

/*
#cgo CFLAGS: -I/abs/path/guillotine/sdks/c/include
#cgo LDFLAGS: -L/abs/path/guillotine/zig-out/lib -lguillotine_ffi -Wl,-rpath,/abs/path/guillotine/zig-out/lib
#include <stdlib.h>
#include "guillotine.h"
*/
import "C"

import (
	"errors"
	"runtime"
	"unsafe"
)

func init() { C.guillotine_init() }

// lastError must run on the OS thread that saw the failure.
func lastError() error { return errors.New(C.GoString(C.guillotine_get_last_error())) }

type EVM struct{ h *C.EvmHandle }

func New(chainID uint64) (*EVM, error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	block := C.BlockInfoFFI{gas_limit: 30_000_000, chain_id: C.uint64_t(chainID)}
	h := C.guillotine_evm_create(&block)
	if h == nil {
		return nil, lastError()
	}
	return &EVM{h: h}, nil
}

func (e *EVM) Close() { C.guillotine_evm_destroy(e.h); e.h = nil }

func (e *EVM) Call(caller, to [20]byte, input []byte, gas uint64) ([]byte, bool, error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	var p C.CallParams
	for i := 0; i < 20; i++ {
		p.caller[i] = C.uint8_t(caller[i])
		p.to[i] = C.uint8_t(to[i])
	}
	if len(input) > 0 {
		// CallParams is passed by pointer, so input must be C memory (cgo pointer rules).
		buf := C.CBytes(input)
		defer C.free(buf)
		p.input = (*C.uint8_t)(buf)
		p.input_len = C.size_t(len(input))
	}
	p.gas = C.uint64_t(gas)
	p.call_type = C.GUILLOTINE_CALL
	r := C.guillotine_call(e.h, &p)
	if r == nil {
		return nil, false, lastError()
	}
	defer C.guillotine_free_result(r)
	out := C.GoBytes(unsafe.Pointer(r.output), C.int(r.output_len)) // check output_len <= MaxInt32 first
	return out, bool(r.success), nil
}
```

`runtime.LockOSThread` keeps the goroutine on one OS thread between the
failing call and `guillotine_get_last_error`. Guard each `*EVM` with a mutex
if goroutines share it.

### Rust

Generate declarations with bindgen and wrap owners in RAII types:

```sh
bindgen sdks/c/include/guillotine.h -o src/sys.rs
```

```rust
// build.rs
fn main() {
    println!("cargo:rustc-link-search=native=/abs/path/guillotine/zig-out/lib");
    println!("cargo:rustc-link-lib=dylib=guillotine_ffi");
}
```

```rust
use std::{ffi::CStr, ptr::NonNull, sync::Once};
mod sys { include!("sys.rs"); }

static INIT: Once = Once::new();

fn last_error() -> String {
    unsafe { CStr::from_ptr(sys::guillotine_get_last_error()) }.to_string_lossy().into_owned()
}

pub struct Evm(NonNull<sys::EvmHandle>);
// A handle may move between threads but must not be shared concurrently.
unsafe impl Send for Evm {}

impl Evm {
    pub fn new(chain_id: u64) -> Result<Self, String> {
        INIT.call_once(|| unsafe { sys::guillotine_init() });
        let block = sys::BlockInfoFFI { gas_limit: 30_000_000, chain_id, ..unsafe { std::mem::zeroed() } };
        NonNull::new(unsafe { sys::guillotine_evm_create(&block) }).map(Evm).ok_or_else(last_error)
    }

    pub fn call(&mut self, mut params: sys::CallParams, input: &[u8]) -> Result<(bool, Vec<u8>), String> {
        params.input = if input.is_empty() { std::ptr::null() } else { input.as_ptr() };
        params.input_len = input.len();
        let r = unsafe { sys::guillotine_call(self.0.as_ptr(), &params) };
        let r = NonNull::new(r).ok_or_else(last_error)?;
        let res = unsafe { r.as_ref() };
        let out = if res.output_len == 0 {
            Vec::new()
        } else {
            unsafe { std::slice::from_raw_parts(res.output, res.output_len) }.to_vec()
        };
        let ok = res.success;
        unsafe { sys::guillotine_free_result(r.as_ptr()) };
        Ok((ok, out))
    }
}

impl Drop for Evm {
    fn drop(&mut self) { unsafe { sys::guillotine_evm_destroy(self.0.as_ptr()) } }
}
```

`Evm` is `Send` but not `Sync`, which matches the one-thread-per-handle rule.
`&mut self` on `call` prevents concurrent use. Never pass library memory to
`Vec::from_raw_parts` or `Box::from_raw`.

### Swift

Expose the header through a SwiftPM system library target:

```text
// Sources/CGuillotine/module.modulemap
module CGuillotine [system] {
    header "guillotine.h"
    link "guillotine_ffi"
    export *
}
```

Copy `sdks/c/include/guillotine.h` next to the module map and pass
`-Xlinker -L/abs/path/guillotine/zig-out/lib` to `swift build`.

```swift
import CGuillotine
import Foundation

guillotine_init()
var block = BlockInfoFFI()
block.gas_limit = 30_000_000
block.chain_id = 1
guard let evm = guillotine_evm_create(&block) else {
    fatalError(String(cString: guillotine_get_last_error()))
}
defer { guillotine_evm_destroy(evm) }

var params = CallParams()
params.gas = 100_000
params.call_type = UInt8(GUILLOTINE_CALL)
withUnsafeMutableBytes(of: &params.to) { $0[19] = 0xc3 }
let input: [UInt8] = []
let output: Data = input.withUnsafeBufferPointer { buf in
    params.input = buf.baseAddress
    params.input_len = buf.count
    guard let r = guillotine_call(evm, &params) else {
        fatalError(String(cString: guillotine_get_last_error()))
    }
    defer { guillotine_free_result(r) }
    return r.pointee.output_len == 0 ? Data() : Data(bytes: r.pointee.output, count: r.pointee.output_len)
}
```

`EvmHandle` imports as `OpaquePointer` and fixed C arrays import as tuples;
use `withUnsafeMutableBytes(of:)` to fill them. Swift actors and serial
queues do not pin an OS thread, so read the last error in the same
synchronous block as the failing call, as above.

### Kotlin / JNI

Write a small C bridge and declare it from Kotlin:

```kotlin
package example

class Guillotine private constructor(private var handle: Long) : AutoCloseable {
    companion object {
        init { System.loadLibrary("guillotine_jni") }
        @JvmStatic external fun create(chainId: Long): Long
        @JvmStatic external fun destroy(handle: Long)
        @JvmStatic external fun balance(handle: Long, address: ByteArray): ByteArray
        fun open(chainId: Long) = Guillotine(create(chainId))
    }
    fun balance(address: ByteArray) = balance(handle, address)
    override fun close() { destroy(handle); handle = 0 }
}
```

```c
#include <jni.h>
#include <stdint.h>
#include "guillotine.h"

static void throw_last_error(JNIEnv *env) {
    (*env)->ThrowNew(env, (*env)->FindClass(env, "java/lang/IllegalStateException"),
                     guillotine_get_last_error());
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)vm; (void)reserved;
    guillotine_init();
    return JNI_VERSION_1_8;
}

JNIEXPORT jlong JNICALL Java_example_Guillotine_create(JNIEnv *env, jclass cls, jlong chain_id) {
    (void)cls;
    BlockInfoFFI info = {0};
    info.gas_limit = 30000000;
    info.chain_id = (uint64_t)chain_id;
    EvmHandle *h = guillotine_evm_create(&info);
    if (h == NULL) throw_last_error(env);
    return (jlong)(intptr_t)h;
}

JNIEXPORT void JNICALL Java_example_Guillotine_destroy(JNIEnv *env, jclass cls, jlong h) {
    (void)env; (void)cls;
    guillotine_evm_destroy((EvmHandle *)(intptr_t)h);
}

JNIEXPORT jbyteArray JNICALL Java_example_Guillotine_balance(JNIEnv *env, jclass cls, jlong h, jbyteArray address) {
    (void)cls;
    if ((*env)->GetArrayLength(env, address) != 20) {
        (*env)->ThrowNew(env, (*env)->FindClass(env, "java/lang/IllegalArgumentException"), "address must be 20 bytes");
        return NULL;
    }
    uint8_t addr[20], out[32];
    (*env)->GetByteArrayRegion(env, address, 0, 20, (jbyte *)addr);
    if (!guillotine_get_balance((EvmHandle *)(intptr_t)h, addr, out)) {
        throw_last_error(env);
        return NULL;
    }
    jbyteArray result = (*env)->NewByteArray(env, 32);
    if (result != NULL) (*env)->SetByteArrayRegion(env, result, 0, 32, (const jbyte *)out);
    return result;
}
```

Build the bridge against `sdks/c/include` and link `-lguillotine_ffi`. The
registry rejects a forged or stale `Long` without dereferencing it, but
Kotlin code must still not share one handle across concurrent threads.

### Bun (`bun:ffi`)

Prefer the maintained `@tevm/guillotine` package (`sdks/typescript`), which
already binds this ABI. For a direct binding:

```typescript
import { CString, dlopen, FFIType, type Pointer, read, suffix, toArrayBuffer } from 'bun:ffi'

const path = process.env.GUILLOTINE_LIB_PATH ?? `zig-out/lib/libguillotine_ffi.${suffix}`
const { symbols: g } = dlopen(path, {
  guillotine_init: { args: [], returns: FFIType.void },
  guillotine_get_last_error: { args: [], returns: FFIType.ptr },
  guillotine_evm_create: { args: [FFIType.ptr], returns: FFIType.ptr },
  guillotine_evm_destroy: { args: [FFIType.ptr], returns: FFIType.void },
  guillotine_set_code: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.u64], returns: FFIType.bool },
  guillotine_call: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
  guillotine_free_result: { args: [FFIType.ptr], returns: FFIType.void },
})
const lastError = () => new CString(g.guillotine_get_last_error()!).toString()

g.guillotine_init()
const block = new Uint8Array(104)
const bv = new DataView(block.buffer)
bv.setBigUint64(16, 30_000_000n, true) // gas_limit
bv.setBigUint64(56, 1n, true) // chain_id
const evm = g.guillotine_evm_create(block)
if (!evm) throw new Error(lastError())
try {
  const target = new Uint8Array(20); target[19] = 0xc3 // low addresses are precompiles
  const code = Uint8Array.from([0x60, 0x2a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3])
  if (!g.guillotine_set_code(evm, target, code, BigInt(code.length))) throw new Error(lastError())

  const params = new Uint8Array(136)
  const pv = new DataView(params.buffer)
  params.set(target, 20) // to; input stays NULL with input_len 0
  pv.setBigUint64(88, 100_000n, true) // gas
  params[96] = 0 // CALL
  const r = g.guillotine_call(evm, params)
  if (!r) throw new Error(lastError())
  try {
    const success = read.u8(r, 0) !== 0
    const len = Number(read.u64(r, 24))
    const output = len === 0 ? new Uint8Array(0) : new Uint8Array(toArrayBuffer(read.ptr(r, 16) as Pointer, 0, len)).slice()
    console.log(success, output)
  } finally {
    g.guillotine_free_result(r)
  }
} finally {
  g.guillotine_evm_destroy(evm)
}
```

The `DataView` writes use little-endian scalars, so this template runs only
on little-endian hosts. `.slice()` copies native memory before the result is
freed. For non-empty input, write `BigInt(ptr(input))` (import `ptr`) at offset 72 and the
length at 80, and keep `input` referenced until the call returns.

## Verify a binding

Port these checks from `sdks/c/tests/safety_test.c`:

- NULL, forged, destroyed, and cleaned-up handles return NULL or false with an
  error and do not crash.
- Configuration bytes other than 0, 1, and 2 are rejected.
- Two handles never see each other's state.
- ORIGIN equals `caller` for both `guillotine_call` and `guillotine_simulate`.
- Test-mode and tracing handles work through the unsuffixed functions, and
  only tracing handles return `trace_json`.
- Repeated large calls and invalid bytecode do not grow memory.
- Chain ids 1, 8453, 84532, and 11155111 either round-trip through CHAINID or
  fail with `exceeds the supported maximum`.
- Double destroy is reported, not a crash.

Also test revert output, empty and non-empty buffers, u256 boundaries, and
invalid call types. Run the C suites from the repository root:

```sh
make -f sdks/c/Makefile test     # simple + basic + safety
```

For repository changes also run `zig build && zig build test-opcodes`.
