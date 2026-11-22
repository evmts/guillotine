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
| `build` | Prepare Voltaire crypto, then `zig build` |
| `test-unit` | `zig build test-unit` |
| `test-opcodes` | `zig build test-opcodes` |
| `test-modexp` | `zig build test-modexp --build-file .smithers/build.zig` |
| `test-fusions` | `zig build test-fusions` |
| `test-specs` | `zig build state-tests` (the root build also exposes `specs`) |
| `bench-build` | Build the MODEXP benchmark with ReleaseFast; cache its binary |
| `bench` | Run that binary with a fresh timing measurement |
| `test-foundry-link` | Verify the real Foundry configuration and Linux archive flattening/linking |
| `factory-check` | Validate factory/home projections against their declarations and discovered flows |
| `factory-write` | Regenerate factory/home projections through the target verb with `--write` |

For example, the build plan is selected with `smthrs build //.smithers:build
--plan`; the complete test plan is selected with `smthrs test //...
--plan`. Each EVM suite depends on the build rather than other suites. Use one
job when compiling the full suite on a memory-constrained host.

All commands run from the repository root. The toolchain is Zig 0.15.1 and
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

The root build lacks a MODEXP step and benchmark runners. The supplemental
build runs all existing MODEXP arithmetic/gas tests, including known failures;
it never filters or downgrades them. The benchmark measures the in-repository
MODEXP implementation with opaque runtime inputs, a bounded iteration count,
an expected-result check and JSON timing output. It measures that workload
only, and is not evidence for EVM dispatch/fusion performance. Timing runs are
uncached even when compilation is replayed.

Voltaire's Cargo crate is nested inside the root Cargo workspace without being
a member or exclusion. `build-crypto.mjs` stages its unchanged Rust sources in
a standalone workspace under `.smithers/cache`, builds with its lockfile, then
copies only the required ignored static archive to the path its Zig module
expects. This avoids changing manifests or the dependency checkout's tracked
Cargo metadata. Foundry's legacy `rust_build.zig` points at `src/compilers` and
is not used by the root build; the active integration is `lib/foundry.zig`.

Factory flows cover consensus, memory ownership, state compliance, differential
evidence and benchmark regressions. PR triage consumes supplied diffs without
executing PR code. There are no scheduled or automatic publishing triggers.
GitHub main remains maintainer-controlled; flows do not grant merge permission.
