# Guillotine C FFI

The native C ABI is implemented in `src/evm_c_api.zig` and declared in
[`include/guillotine.h`](include/guillotine.h). The header's top comment
states the lifecycle, handle, error, memory, threading, and pointer rules.
Every language binding, including the Bun-based `@tevm/guillotine` package,
uses this ABI. The API is experimental; pin the header and library to the
same revision.

Run commands from the repository root with the Zig version pinned in
`build.zig.zon`:

```sh
zig build shared
zig build static
make -f sdks/c/Makefile test
```

| Make target | Program | Needs the native library |
| --- | --- | --- |
| `simple` | `tests/simple_test.c`: header compiles; 64-bit struct sizes and offsets | No |
| `basic` | `tests/basic_test.c`: state, execution, CREATE, tracing, revert | Yes |
| `safety` | `tests/safety_test.c`: handle validation, isolation, ORIGIN parity, memory growth, chain ids, cleanup | Yes |
| `test` | `simple`, `basic`, and `safety` | Yes |

`basic` and `safety` run `zig build shared` first. The Makefile sets an
absolute runtime search path to this checkout's `zig-out/lib/`.

The shared library is `zig-out/lib/libguillotine_ffi.dylib` on macOS or
`zig-out/lib/libguillotine_ffi.so` on Linux. The static library is
`zig-out/lib/libguillotine_ffi_static.a`; a static link must also supply libc,
libunwind on Linux, and the native crypto archives the build links in.

Compile with `-Isdks/c/include` and link with
`-Lzig-out/lib -lguillotine_ffi`. Set a runtime loader path or install the
library beside your application.

`src/root_c.zig` only re-exports `src/evm_c_api.zig`; it is not a separate
API. Read [Building custom SDKs](../../docs/building-custom-sdks.md) for the
exported function inventory, struct layouts, ownership, errors, threading,
chain id limits, and templates for Python, Go, Rust, Swift, Kotlin/JNI, and
Bun.
