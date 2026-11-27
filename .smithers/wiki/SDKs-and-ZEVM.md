---
title: SDKs and Tevm / ZEVM Ecosystem
tags: [sdks, ffi, zevm, voltaire]
---

# SDKs and Tevm / ZEVM Ecosystem

Guillotine is designed to be embedded cleanly from Zig, C, TypeScript, and any language with a C FFI, while dogfooding Smithers Cloud across the Tevm ecosystem.

## Three Supported Surfaces

1. **Zig package (`build.zig`, `build.zig.zon`)**: Exports `evm`, `voltaire`, and `layer2` via `b.addModule`. Consumers install with `zig fetch --save=guillotine https://github.com/evmts/guillotine/archive/refs/tags/v0.1.0.tar.gz`.
2. **C ABI (`src/evm_c_api.zig`, `sdks/c/include/guillotine.h`)**: Builds `libguillotine_ffi.dylib` (macOS arm64) and `libguillotine_ffi.so` (Linux x86_64, `glibc >= 2.28`). Runs in embedded mode (`guillotine_embedded = true`), guaranteeing monotonic handles and zero host aborts.
3. **TypeScript Bun FFI SDK (`@tevm/guillotine`, `sdks/typescript/`)**: Ships both native prebuilds with zero-overhead Bun FFI bindings, strict TypeScript types, and `340 / 340` passing E2E and fuzz tests.

For Python, Go, Rust, Swift, or Kotlin bindings, use the Custom SDK Builder skill (`.agents/skills/guillotine-sdk-builder/SKILL.md` and `docs/building-custom-sdks.md`).

## Dogfooding Across Tevm Repositories

- **`evmts/voltaire`** (`https://smithers.sh/evmts/voltaire`): Supplies core Ethereum primitives and native cryptography (`blst`, `c-kzg-4844`, `libcrypto_wrappers.a`) vendored into `lib/voltaire/`.
- **`evmts/zevm`** (`https://smithers.sh/evmts/zevm`): Embeddable Zig Ethereum node with JSON-RPC, beacon light client, and N-API bindings sharing the same `smthrs` incremental graph and `build.smithers.sh` cloud object store.
- **`evmts/guillotine-mini`**: Standalone readable reference EVM for spec clarity and cross-checking.

All agents operating across these repositories connect to their respective `https://smithers.sh/evmts/<repo>/mcp` endpoints using one-time PKCE auth (`scripts/smithers-auth.mjs`) to create issues, draft TODOs, inspect PRs, and land stacked changesets cleanly (`[[Trust-Model-and-Factory]]`).

## Related Pages

- [[Overview]]
- [[Trust-Model-and-Factory]]
- [[TigerStyle-and-Safety]]
- [[Mythical-History]]
