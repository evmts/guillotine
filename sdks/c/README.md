# Guillotine C FFI

The native C ABI is implemented in `src/evm_c_api.zig` and declared in
[`include/guillotine.h`](include/guillotine.h). It is the foundation for custom
language bindings. The API is experimental; pin the header and library to the
same revision.

Run commands from the repository root, with the Zig version required by
`build.zig.zon` and the native crypto dependencies available:

```sh
zig build shared
zig build static
make -f sdks/c/Makefile simple
make -f sdks/c/Makefile test
```

`simple` checks header compilation only. `test` also builds the shared library
and runs the native integration tests. The Makefile sets an absolute runtime
search path to this checkout's `zig-out/lib/` for local testing.

The shared library is `zig-out/lib/libguillotine_ffi.dylib` on macOS or
`zig-out/lib/libguillotine_ffi.so` on Linux. The static library is
`zig-out/lib/libguillotine_ffi_static.a`; link it with the native crypto and
platform dependencies required by the selected target.

Include `guillotine.h` using `-Isdks/c/include` and link the shared library with
`-Lzig-out/lib -lguillotine_ffi`. Arrange a runtime loader path or install the
library alongside your application.

Read [Building custom SDKs](../../docs/building-custom-sdks.md) for exact struct
layouts, the exported function inventory, ownership, errors, threading,
tracing restrictions, and templates for Python, Go, Rust, Swift, Kotlin/JNI,
and Bun. `src/root_c.zig` is a separate component API and is not the entry
point of the shared/static libraries above. WASM uses a different ABI.
