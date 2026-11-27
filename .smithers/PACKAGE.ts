import { Smithers as S } from "@smthrs/targets"
import { fileURLToPath } from "node:url"

// Guillotine's incremental Smithers build graph.
// Each target keys on its tightest real source closure so docs, wiki, uphill,
// and factory edits never invalidate Zig/Rust compilation or EVM test suites.
// Globs are package-scoped even with //, so root closures set cwd: "//".

const generated = [
  "**/.git/**",
  "**/.jj/**",
  "**/.flows/**",
  "**/.zig-cache/**",
  "**/zig-out/**",
  "**/zig-pkg/**",
  "**/target/**",
  "**/node_modules/**",
  "**/.lake/**"
]

// Core Zig + vendored Voltaire + Rust FFI crates compiled by `zig build`.
const zigCoreSources = S.Filegroup({
  cwd: "//",
  srcs: [
    S.file("//build.zig"),
    S.file("//build.zig.zon"),
    S.file("//Cargo.toml"),
    S.file("//Cargo.lock"),
    S.glob("//src/**", { exclude: generated }),
    S.glob("//lib/**", { exclude: generated })
  ]
})

// Full Zig test closure including differential tests, spec runner, and fixtures.
const zigTestSources = S.Filegroup({
  cwd: "//",
  srcs: [
    zigCoreSources,
    S.glob("//test/**", { exclude: generated }),
    S.glob("//specs/**", { exclude: generated }),
    S.glob("//fixtures/**", { exclude: generated })
  ]
})

// Benchmark harness and workloads (excluding external engine checkouts).
const benchSources = S.Filegroup({
  cwd: "//",
  srcs: [
    zigCoreSources,
    S.glob("//bench/**", {
      exclude: [...generated, "//bench/compare/engines/**", "//bench/blocks/runners/revm/target/**"]
    })
  ]
})

// C and TypeScript SDK closures.
const cSdkSources = S.Filegroup({
  cwd: "//",
  srcs: [S.glob("//sdks/c/**", { exclude: [...generated, "//sdks/c/build/**"] })]
})

const tsSdkSources = S.Filegroup({
  cwd: "//",
  srcs: [
    S.glob("//sdks/typescript/**", {
      exclude: [...generated, "//sdks/typescript/dist/**", "//sdks/typescript/prebuilds/**"]
    })
  ]
})

// Formal verification closure (SMT-LIB2, LLVM IR, Lean 4, Zean).
const verifySources = S.Filegroup({
  cwd: "//",
  srcs: [
    zigCoreSources,
    S.file("//zean.json"),
    S.file("//zean.outputs.json"),
    S.glob("//verify/**", { exclude: generated })
  ]
})

// Public documentation site and top-level markdown docs.
const docsSources = S.Filegroup({
  cwd: "//",
  srcs: [
    S.file("//README.md"),
    S.file("//CHANGELOG.md"),
    S.file("//CONTRIBUTING.md"),
    S.file("//CLAUDE.md"),
    S.glob("//docs/**", { exclude: [...generated, "//docs/dist/**", "//docs/.vocs/**"] })
  ]
})

// Wiki + mythical history sources.
const wikiSources = S.Filegroup({
  srcs: [S.glob("wiki/**")]
})

// Uphill Lighthouse backpressure metrics and baselines.
const uphillSources = S.Filegroup({
  cwd: "//",
  srcs: [
    S.file("//build.zig.zon"),
    S.file("//sdks/typescript/package.json"),
    S.glob("//.agents/uphill/**"),
    S.glob("//src/**", { exclude: generated }),
    S.glob("//lib/ark/src/**", { exclude: generated }),
    S.glob("//lib/foundry-compilers/src/**", { exclude: generated }),
    S.glob("//verify/lean/**/*.lean", { exclude: generated }),
    S.glob("//verify/smt/**/*.smt2", { exclude: generated }),
    docsSources,
    wikiSources
  ]
})

// Factory declarations, flows, workflows, playground, and tests (excluding caches/reports).
const factorySources = S.Filegroup({
  srcs: [S.glob("**", { exclude: ["cache/**", "reports/**", "node_modules/**"] })]
})

const env = {
  ZIG_GLOBAL_CACHE_DIR: fileURLToPath(new URL("./cache/tools/zig/global", import.meta.url)),
  ZIG_LOCAL_CACHE_DIR: fileURLToPath(new URL("./cache/tools/zig/local", import.meta.url)),
  // lib/foundry.zig resolves Cargo artifacts under this workspace-relative path.
  CARGO_TARGET_DIR: "target"
}

const zigTools = [S.Host.bin("cargo"), S.Host.bin("rustc"), S.Host.bin("cc")]
const zigCommon = {
  bin: S.Host.bin("zig"),
  tools: zigTools,
  env,
  sandbox: "none" as const,
  timeout: "6h" as const
}

// `zig build` also compiles Voltaire's Rust crypto archive via lib/voltaire/build.zig.
const build = S.Shell.Build({
  ...zigCommon,
  args: ["build"],
  data: [zigCoreSources],
  outDirs: ["//zig-out"]
})

// ReleaseFast FFI shared library for C and TypeScript SDKs.
const ffiShared = S.Shell.Build({
  ...zigCommon,
  args: ["build", "shared", "-Doptimize=ReleaseFast"],
  data: [zigCoreSources, build],
  outDirs: ["//zig-out"]
})

const step = (name: string, sources = zigTestSources, exclusive = false) =>
  S.Shell.Test({
    ...zigCommon,
    args: ["build", name],
    data: [sources, build],
    ...(exclusive ? { exclusive: true } : {})
  })

const benchBuild = S.Shell.Build({
  ...zigCommon,
  args: ["build", "bench-build", "--prefix", "zig-out/smithers"],
  data: [benchSources],
  outDirs: ["//zig-out/smithers"]
})

export const Package = S.Package({
  targets: {
    "zig-core-sources": zigCoreSources,
    "zig-test-sources": zigTestSources,
    "bench-sources": benchSources,
    "c-sdk-sources": cSdkSources,
    "ts-sdk-sources": tsSdkSources,
    "verify-sources": verifySources,
    "docs-sources": docsSources,
    "wiki-sources": wikiSources,
    "uphill-sources": uphillSources,
    "factory-sources": factorySources,

    // Factory projection checks
    "factory-write": S.FactoryProjection({ mode: "write" }),
    "factory-check": S.FactoryProjection({ mode: "check" }),

    // Fast static hygiene checks
    "zig-fmt": S.Shell.Test({
      bin: S.Host.bin("zig"),
      args: ["fmt", "--check", "src/"],
      env,
      sandbox: "none",
      timeout: "5m",
      data: [zigCoreSources]
    }),
    "zig-ast-check": S.Shell.Test({
      bin: S.Host.bin("sh"),
      args: [
        "-eu",
        "-c",
        "find src test -name '*.zig' -print0 | xargs -0 -n 1 zig ast-check"
      ],
      tools: [S.Host.bin("zig")],
      env,
      sandbox: "none",
      timeout: "10m",
      data: [zigTestSources]
    }),
    "tigerstyle-check": S.Shell.Test({
      bin: S.Host.bin("python3"),
      args: [
        "-c",
        [
          "import pathlib, re, sys",
          "bad = []",
          "for p in sorted(pathlib.Path('src').rglob('*.zig')):",
          "    if p.name.endswith(('_test.zig', '_tests.zig', '_bench.zig')) or '/_test_utils/' in str(p): continue",
          "    for idx, line in enumerate(p.read_text(errors='replace').splitlines(), 1):",
          "        if re.match(r'^test\\s*(?:\"[^\"]*\")?\\s*\\{', line): break",
          "        code = line.split('//', 1)[0]",
          "        if 'std.debug.print(' in code: bad.append(f'{p}:{idx}: forbidden std.debug.print')",
          "        if re.search(r'\\bcatch\\s*\\{\\s*\\}', code): bad.append(f'{p}:{idx}: forbidden empty catch {{}}')",
          "if bad: print('\\n'.join(bad), file=sys.stderr); sys.exit(1)"
        ].join("\n")
      ],
      sandbox: "none",
      timeout: "5m",
      data: [zigCoreSources]
    }),

    // Core build and FFI artifacts
    build,
    "ffi-shared": ffiShared,

    // Rust workspace tests
    "cargo-test": S.Shell.Test({
      bin: S.Host.bin("cargo"),
      args: ["test", "--locked"],
      tools: [S.Host.bin("rustc"), S.Host.bin("cc")],
      env,
      sandbox: "none",
      timeout: "30m",
      data: [zigCoreSources]
    }),

    // Self-contained Zig EVM suites
    "test-unit": step("test-unit"),
    "test-opcodes": step("test-opcodes"),
    "test-modexp": step("test-modexp"),
    "test-precompiles": step("test-precompiles"),
    "test-fusions": step("test-fusions"),
    "test-layer2": step("test-layer2"),
    "test-bench": step("test-bench", benchSources),
    "test-integration": step("test-integration"),
    "test-fuzz": step("test-fuzz"),
    "test-jit": step("test-jit", zigCoreSources, true),

    // SDK and FFI link tests
    "test-foundry-link": S.Shell.Test({
      bin: S.Host.bin("node"),
      args: ["--test", ".smithers/tests/foundry-link.test.mjs"],
      tools: [S.Host.bin("zig")],
      env,
      sandbox: "none",
      timeout: "10m",
      data: [zigCoreSources, factorySources]
    }),
    "test-c-sdk": S.Shell.Test({
      bin: S.Host.bin("make"),
      args: ["-f", "sdks/c/Makefile", "-o", "build-core", "test"],
      tools: [S.Host.bin("cc")],
      env,
      sandbox: "none",
      timeout: "10m",
      data: [cSdkSources, ffiShared]
    }),
    "test-ts-sdk": S.Shell.Test({
      bin: S.Host.bin("sh"),
      args: ["-eu", "-c", "cd sdks/typescript && bun test"],
      tools: [S.Host.bin("bun")],
      env,
      sandbox: "none",
      timeout: "15m",
      data: [tsSdkSources, ffiShared]
    }),

    // Official EEST state fixtures (exclusive: requires fetched fixtures)
    "state-tests": step("state-tests", zigTestSources, true),
    "state-tests-no-fusion": S.Shell.Test({
      ...zigCommon,
      args: ["build", "state-tests", "-Devm-enable-fusion=false"],
      data: [zigTestSources, build],
      exclusive: true
    }),

    // Formal verification targets (exclusive: requires external provers/elan)
    "verify-smt": step("verify-smt", verifySources, true),
    "verify-ir": step("verify-ir", verifySources, true),
    "verify-lean": step("verify-lean", verifySources, true),
    "verify-zean": step("verify-zean", verifySources, true),
    "test-lean-diff": step("test-lean-diff", verifySources, true),

    // Factory, wiki, auth, playground, and Lighthouse audit checks
    "test-factory": S.Shell.Test({
      bin: S.Host.bin("sh"),
      args: ["-eu", "-c", "node --test .smithers/tests/*.test.mjs"],
      tools: [S.Host.bin("node"), S.Host.bin("bun"), S.Host.bin("zig")],
      env,
      sandbox: "none",
      timeout: "10m",
      data: [factorySources, wikiSources, docsSources, uphillSources]
    }),
    "wiki-check": S.Shell.Test({
      bin: S.Host.bin("node"),
      args: [".smithers/wiki/build-feed.mjs", "--check"],
      sandbox: "none",
      timeout: "5m",
      data: [wikiSources, factorySources]
    }),
    "uphill-check": S.Shell.Test({
      bin: S.Host.bin("sh"),
      args: ["-eu", "-c", "PATH=\"$HOME/.uphill/bin:$HOME/.bun/bin:$PATH\" uphill check && PATH=\"$HOME/.uphill/bin:$HOME/.bun/bin:$PATH\" uphill --compact"],
      tools: [S.Host.bin("bun"), S.Host.bin("zig")],
      env,
      sandbox: "none",
      timeout: "10m",
      data: [uphillSources, factorySources]
    }),
    "audit-report": S.Shell.Test({
      bin: S.Host.bin("node"),
      args: [".smithers/reports/audit.mjs", "--check"],
      tools: [S.Host.bin("bun"), S.Host.bin("zig")],
      env,
      sandbox: "none",
      timeout: "10m",
      data: [uphillSources, wikiSources, factorySources]
    }),

    // Docs site build check (exclusive: runs Vocs)
    "docs-build": S.Shell.Test({
      bin: S.Host.bin("sh"),
      args: ["-eu", "-c", "npm --prefix docs run build && test -f docs/dist/public/llms.txt && test -f docs/dist/public/audit.html && test -f docs/dist/public/wiki.html"],
      tools: [S.Host.bin("node")],
      sandbox: "none",
      timeout: "15m",
      data: [docsSources],
      exclusive: true
    }),

    // Benchmarks: compile is cached; timing measurement is always fresh (manual).
    "bench-build": benchBuild,
    bench: S.Shell.Run({
      shell: "zig-out/smithers/bin/guillotine-bench",
      sandbox: "none",
      timeout: "30m",
      data: [benchBuild],
      manual: true
    })
  }
})
