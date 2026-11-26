# Guillotine factory

The current `smthrs` CLI discovers `.smithers/WORKSPACE.ts` and
`.smithers/PACKAGE.ts`. `WORKSPACE.smithers` re-exports them for tooling using
the needlefish convention; the CLI does not discover that extension. The
requested `~/voltaire-factory/.smithers` reference was absent when this factory
was authored, so its formats were verified against the local Smithers source.

Targets use the `//.smithers:<name>` labels. Both build and test verbs require
an explicit label or pattern; bare `build --plan` and `test --plan` are invalid.

| Target | Command / behavior |
| --- | --- |
| `build` | `zig build` (also compiles Voltaire's Rust crypto archive) |
| `test-unit` | `zig build test-unit` |
| `test-opcodes` | `zig build test-opcodes` |
| `test-modexp` | `zig build test-modexp` |
| `test-fusions` | `zig build test-fusions` |
| `test-layer2` | `zig build test-layer2` |
| `test-bench` | `zig build test-bench` |
| `state-tests` | `zig build state-tests` (official EEST state fixtures) |
| `test-lean-diff` | `zig build test-lean-diff` (manual; needs the Lean 4 toolchain) |
| `bench-build` | `zig build bench-build --prefix zig-out/smithers`; caches the binary |
| `bench` | Run `zig-out/smithers/bin/guillotine-bench` with a fresh timing measurement |
| `test-foundry-link` | Verify the real Foundry configuration and Linux archive flattening/linking |
| `factory-check` | Validate factory/home projections against their declarations and discovered flows |
| `factory-write` | Regenerate factory/home projections through the target verb with `--write` |

Every Zig target runs a step of the root `build.zig`; there is no
supplemental build file.

For example, the build plan is selected with `smthrs build //.smithers:build
--plan`; the complete test plan is selected with `smthrs test //...
--plan`. Each EVM suite depends on the build rather than other suites. Use one
job when compiling the full suite on a memory-constrained host.

All commands run from the repository root. The toolchain is Zig 0.17.1 and
Cargo/Rust; the CI matrix covers macOS and x86_64 Linux. Host tool identities,
source files, fixtures, manifests, lockfiles and dependency edges contribute to
target keys. A root-anchored Filegroup plus a separate factory Filegroup are required
because globs remain package-scoped even with a `//` prefix. These source
closures conservatively invalidate checks on source changes, while unchanged checks replay from the result cache. Zig global/local
caches and Voltaire Cargo intermediates live under `.smithers/cache`; the root
Cargo build requires `target/`, matching the existing Foundry artifact lookup.
Build output, engine state and report directories are excluded from source keys.
Cache paths use absolute URLs derived from PACKAGE.ts because the installed CLI
does not expand the older `{smthrs:cache-directory}` environment token.

`lib/voltaire/Cargo.toml` declares its own `[workspace]`. `lib/voltaire/build.zig`
runs `cargo build --release --locked` for it with `--target-dir` set to a Zig
cache output directory and links the resulting `libcrypto_wrappers.a`, so no
separate crypto step exists. Foundry's legacy
`rust_build.zig` points at `src/compilers` and is not used by the root build;
the active integration is `lib/foundry.zig`.

Factory flows cover consensus, memory ownership, state compliance, differential
evidence and benchmark regressions. PR triage consumes supplied diffs without
executing PR code. There are no scheduled or automatic publishing triggers.
GitHub main remains maintainer-controlled; flows do not grant merge permission.
