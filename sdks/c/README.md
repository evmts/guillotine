# Guillotine C FFI & EVMC v12

The native C ABI v2 is implemented in `src/evm_c_api.zig` and declared in
[`include/guillotine.h`](include/guillotine.h). The standard EVMC ABI v12 shared
library (`evmc_create_guillotine`) is implemented in `src/evmc_c_api.zig` and
declared in [`include/evmc_guillotine.h`](include/evmc_guillotine.h).

Every language binding, including the universal Node.js + Bun `@tevm/guillotine`
package (`guillotine.node` via Node-API and `libguillotine_ffi` via Bun FFI),
uses `guillotine.h`. Pin the header and library to the same revision.

Run commands from the repository root with Zig `0.17.1` (pinned in `build.zig.zon`):

```sh
zig build shared -Doptimize=ReleaseFast -Dstrip=true
zig build evmc   -Doptimize=ReleaseFast -Dstrip=true
zig build napi   -Doptimize=ReleaseFast -Dstrip=true
zig build test-evmc
make -f sdks/c/Makefile test
```

| Make target | Program | Needs the native library |
| --- | --- | --- |
| `simple` | `tests/simple_test.c`: header compiles; 64-bit struct sizes and offsets | No |
| `basic` | `tests/basic_test.c`: state, execution, CREATE, tracing, revert | Yes |
| `safety` | `tests/safety_test.c`: handle validation, isolation, ORIGIN parity, memory growth, chain ids, cleanup | Yes |
| `v2` | `tests/v2_test.c`: `set_block_info`, `create_with_fork`, `call_tracer`, `GuillotineHostVTable`, `execute_tx`, `get_nonce` | Yes |
| `test` | `simple`, `basic`, `safety`, and `v2` | Yes |

The shared libraries are `zig-out/lib/libguillotine_ffi.{dylib,so}`,
`zig-out/lib/libguillotine_evmc.{dylib,so}`, and `zig-out/lib/guillotine.node`.

Compile with `-Isdks/c/include` and link with `-Lzig-out/lib -lguillotine_ffi`.
Read [Building custom SDKs](../../docs/building-custom-sdks.md) for the exported
function inventory, struct layouts, ownership, errors, threading, and templates
for Python, Go, Rust, Swift, Kotlin/JNI, Node.js, and Bun.
