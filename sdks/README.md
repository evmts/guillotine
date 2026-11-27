# Guillotine SDKs

Guillotine officially ships three integration surfaces:

| Surface | Source | Use |
| --- | --- | --- |
| Zig native bindings | Repository root, `src/root.zig` | Import the EVM and its types directly from Zig. |
| C FFI bindings | [`c/`](c/), `src/evm_c_api.zig` | Embed the native EVM or build a custom language SDK. |
| `@tevm/guillotine` TypeScript package | [`typescript/`](typescript/) | Call the native EVM from Bun through `bun:ffi`. |

The C and TypeScript APIs are in beta.

The TypeScript package is a Bun native FFI binding over `libguillotine_ffi`,
the shared library built from `src/evm_c_api.zig`. It loads the library from
`GUILLOTINE_LIB_PATH` or from the `prebuilds/<platform>-<arch>/` directory
packaged with it (`bun run build:native` fills that directory). It requires
Bun and does not run in Node.js or browsers.

Python, Go, Rust, Swift, Kotlin/JNI, and direct `bun:ffi` integrations are
custom SDKs built on the C ABI, not separately maintained packages in this
repository. Start with [Building custom SDKs](../docs/building-custom-sdks.md)
and the [SDK builder skill](../.agents/skills/guillotine-sdk-builder/SKILL.md)
(also at [`skills/guillotine-sdk-builder`](../skills/guillotine-sdk-builder/SKILL.md)).

## Build from the repository root

Use the Zig version pinned in `build.zig.zon`:

```sh
zig build shared
zig build static
```

Native artifacts are installed under `zig-out/lib/`:

- Shared: `libguillotine_ffi.dylib` on macOS, `libguillotine_ffi.so` on Linux.
- Static: `libguillotine_ffi_static.a`.

The [C header](c/include/guillotine.h) declares the ABI. The
[custom SDK guide](../docs/building-custom-sdks.md) covers exported symbols,
struct layouts, ownership, errors, threading, linking, and language templates.

## Tests

```sh
make -f sdks/c/Makefile test      # C header, integration, and safety tests
cd sdks/typescript && bun test    # TypeScript SDK (needs the shared library)
```
