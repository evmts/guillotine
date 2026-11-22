# Guillotine SDKs

Guillotine officially ships three integration surfaces:

| Surface | Source | Use |
| --- | --- | --- |
| Zig native bindings | Repository root, `src/root.zig` | Import the EVM and its types directly from Zig. |
| C FFI bindings | [`c/`](c/), `src/evm_c_api.zig` | Embed the native EVM or build a custom language SDK. |
| `@tevm/guillotine` TypeScript npm package | [`typescript/`](typescript/), [`wasm/`](wasm/) | Use the WebAssembly SDK from JavaScript/TypeScript, including Bun. |

The C and TypeScript APIs are experimental and may change. The TypeScript
package source is `sdks/typescript`; the WASM build support is `sdks/wasm`.

Python, Go, Rust, Swift, Kotlin/JNI, and native Bun FFI integrations are custom
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
exported symbols, linking, and language templates. WASM has a separate ABI;
use the TypeScript SDK's loader for it.

## Bun

Bun applications can use `@tevm/guillotine` through the TypeScript/WASM SDK.
For direct native calls through `bun:ffi`, see the
[TypeScript Bun notes](typescript/README.md#bun-native-ffi) and the custom SDK
guide. There is no separate Bun package in this repository.
