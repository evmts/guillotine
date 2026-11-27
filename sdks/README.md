# Guillotine SDKs

Guillotine officially ships four integration surfaces:

| Surface | Source | Use |
| --- | --- | --- |
| Zig native bindings | Repository root, `src/root.zig` | Import `evm`, `voltaire`, `crypto`, `precompiles`, and `layer2` directly from Zig. |
| EVMC ABI v12 | [`c/include/evmc_guillotine.h`](c/include/evmc_guillotine.h), `src/evmc_c_api.zig` | Drop-in EVMC v12 VM (`evmc_create_guillotine`) for Ethereum clients. |
| C ABI v2 | [`c/`](c/), `src/evm_c_api.zig` | Embed the native EVM with external state callbacks or build custom language SDKs. |
| `@tevm/guillotine` TypeScript package | [`typescript/`](typescript/) | Call the native EVM from **Node.js ≥ 20** (Node-API `guillotine.node`) or **Bun ≥ 1.1** (Node-API or `bun:ffi`). |

The C, EVMC, and TypeScript APIs are in beta.

The TypeScript package loads the zero-`node-gyp` Node-API addon `guillotine.node`
on Node.js (and optionally Bun), or `libguillotine_ffi` through `bun:ffi` on Bun.
It checks `GUILLOTINE_NAPI_PATH`, `GUILLOTINE_LIB_PATH`, and
`prebuilds/<platform>-<arch>/` (`bun run build:native` populates that directory).
Browsers are not supported here; use `evmts/guillotine-mini` for WASM.

Python, Go, Rust, Swift, Kotlin/JNI, and direct `bun:ffi` integrations are
custom SDKs built on the C ABI, not separately maintained packages in this
repository. Start with [Building custom SDKs](../docs/building-custom-sdks.md)
and the [SDK builder skill](../.agents/skills/guillotine-sdk-builder/SKILL.md)
(also at [`skills/guillotine-sdk-builder`](../skills/guillotine-sdk-builder/SKILL.md)).

## Build from the repository root

Use Zig `0.17.1` (pinned in `build.zig.zon`):

```sh
zig build shared -Doptimize=ReleaseFast -Dstrip=true
zig build napi   -Doptimize=ReleaseFast -Dstrip=true
zig build evmc   -Doptimize=ReleaseFast -Dstrip=true
zig build static
```

Native artifacts are installed under `zig-out/lib/`:

- C ABI v2 shared: `libguillotine_ffi.dylib` on macOS, `libguillotine_ffi.so` on Linux.
- Node-API addon: `guillotine.node`.
- EVMC v12 shared: `libguillotine_evmc.dylib` on macOS, `libguillotine_evmc.so` on Linux.
- Static: `libguillotine_ffi_static.a`.

The [C header](c/include/guillotine.h) and [EVMC header](c/include/evmc_guillotine.h)
declare the native ABIs. The [custom SDK guide](../docs/building-custom-sdks.md)
covers exported symbols, struct layouts, ownership, errors, threading, linking,
and language templates.

## Tests

```sh
zig build test-evmc                    # EVMC ABI v12 integration tests
make -f sdks/c/Makefile test           # C ABI v1 + v2, layout, and safety tests
cd sdks/typescript && bun test         # Bun FFI & Node-API TypeScript tests (341 tests)
cd sdks/typescript && npm run test:node # Node.js native Node-API E2E tests
```
