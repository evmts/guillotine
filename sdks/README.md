# Guillotine SDKs

Guillotine officially ships three integration surfaces:

| Surface | Source | Use |
| --- | --- | --- |
| Zig native bindings | Repository root, `src/root.zig` | Import the EVM and its types directly from Zig. |
| C FFI bindings | [`c/`](c/), `src/evm_c_api.zig` | Embed the native EVM or build a custom language SDK. |
| `@tevm/guillotine` TypeScript npm package | [`typescript/`](typescript/) | Call the native library from Bun through Bun FFI (Bun ≥ 1.1; Node.js and browsers are not supported). |

The C and TypeScript APIs are experimental and may change. The TypeScript
package source is `sdks/typescript`. `sdks/wasm/build.zig` is not called by the
root build and the TypeScript package does not use it.

Python, Go, Rust, Swift, and Kotlin/JNI integrations are custom
SDKs built on the C/Zig FFI, rather than separately maintained language SDKs in
this repository. Start with [Building custom SDKs](../docs/building-custom-sdks.md)
and the [SDK builder skill](../.agents/skills/guillotine-sdk-builder/SKILL.md)
(also available at [`skills/guillotine-sdk-builder`](../skills/guillotine-sdk-builder/SKILL.md)).

## Build from the repository root

Use the Zig version required by `build.zig.zon` and the repository's native
crypto toolchain. The root build resolves the module and native dependencies:

```sh
zig build
zig build shared
zig build static
```

Native artifacts are installed under `zig-out/lib/`:

- Shared: `libguillotine_ffi.dylib` on macOS, `libguillotine_ffi.so` on Linux
  (Windows uses a DLL).
- Static: `libguillotine_ffi_static.a` on Unix targets.

The [C header](c/include/guillotine.h) describes the native library. The
[custom SDK guide](../docs/building-custom-sdks.md) covers ownership, layouts,
exported symbols, linking, and language templates.

## Bun

Bun applications use `@tevm/guillotine`, which loads `libguillotine_ffi`
through `bun:ffi`. Build the native library for it with `bun run build:native`
in `sdks/typescript` (it runs `zig build shared -Doptimize=ReleaseFast` from
the repository root). See [the package README](typescript/README.md).
