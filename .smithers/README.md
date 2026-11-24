# Guillotine factory

The current `smthrs` CLI discovers `.smithers/WORKSPACE.ts` and
`.smithers/PACKAGE.ts`. `WORKSPACE.smithers` re-exports them for tooling using
the needlefish convention; the CLI does not discover that extension.

Targets use the `//.smithers:<name>` labels. Both build and test verbs require
an explicit label or pattern; bare `build --plan` and `test --plan` are invalid.

| Target | Command / behavior |
| --- | --- |
| `build-crypto` | Run `build-crypto.mjs`: prebuild Voltaire's `libcrypto_wrappers.a` |
| `build` | Prepare Voltaire crypto, then `zig build` |
| `test-unit` | `zig build test-unit` |
| `test-opcodes` | `zig build test-opcodes` |
| `test-modexp` | `zig build test-modexp --build-file .smithers/build.zig` |
| `test-fusions` | `zig build test-fusions` |
| `test-specs` | `zig build state-tests` (the root build also exposes `specs`) |
| `bench-build` | Build the MODEXP benchmark (`.smithers/bench.zig`) with ReleaseFast; cache its binary |
| `bench` | Run that binary with a fresh timing measurement (manual target) |
| `test-foundry-link` | Verify the real Foundry configuration and Linux archive flattening/linking |
| `factory-check` | Validate factory/home projections against their declarations and discovered flows |
| `factory-write` | Regenerate factory/home projections through the target verb with `--write` |

For example, the build plan is selected with `smthrs build //.smithers:build
--plan`; the complete test plan is selected with `smthrs test //...
--plan`. Each EVM suite depends on the build rather than other suites. Use one
job when compiling the full suite on a memory-constrained host.

All commands run from the repository root. The toolchain is Zig 0.15.2 (the
version CI installs; `build.zig.zon` requires at least 0.15.1) and Cargo/Rust;
the CI matrix covers macOS and x86_64 Linux. Host tool identities,
source files, fixtures, manifests, lockfiles and dependency edges contribute to
target keys. A root-anchored Filegroup plus a separate factory Filegroup are required
because globs remain package-scoped even with a `//` prefix. These source
closures conservatively invalidate checks on source changes, while unchanged checks replay from the result cache. Zig global/local
caches and Voltaire Cargo intermediates live under `.smithers/cache`; the root
Cargo build requires `target/`, matching the existing Foundry artifact lookup.
Build output, engine state and report directories are excluded from source keys.
Cache paths use absolute URLs derived from PACKAGE.ts because the installed CLI
does not expand the older `{smthrs:cache-directory}` environment token.

The root build now has its own `test-modexp` (Voltaire's `crypto` module tests
plus `lib/voltaire/src/precompiles/modexp.zig`) and `bench*` steps. The
supplemental `.smithers/build.zig` predates them and is narrower: it runs only
the `lib/voltaire/src/crypto/modexp.zig` arithmetic/gas tests, including known
failures (it never filters or downgrades them), and builds the MODEXP
benchmark. CI and the `test-modexp` target still use it. The benchmark measures the in-repository
MODEXP implementation with opaque runtime inputs, a bounded iteration count,
an expected-result check and JSON timing output. It measures that workload
only, and is not evidence for EVM dispatch/fusion performance. Timing runs are
uncached even when compilation is replayed.

Voltaire's Cargo crate is its own workspace, excluded from the root one, and
`zig build` runs its Cargo step before linking `libcrypto_wrappers.a`
(`tests/voltaire-archive.test.mjs`, #862/#863). `build-crypto.mjs` is an
optional cached prebuild: it builds the same sources with the lockfile under
`.smithers/cache` and copies the archive to the path the Zig module links.
Foundry's legacy `rust_build.zig` points at `src/compilers` and is not used by
the root build; the active integration is `lib/foundry.zig`.

Factory flows cover consensus, memory ownership, state compliance, differential
evidence and benchmark regressions. PR triage consumes supplied diffs without
executing PR code. There are no scheduled or automatic publishing triggers.
GitHub main remains maintainer-controlled; flows do not grant merge permission.
