import { Smithers as S } from "@smthrs/targets"
import { fileURLToPath } from "node:url"

// Full source closure, including submodules, fixtures and lockfiles. Tool output
// and factory reports cannot invalidate targets or become cached source inputs.
const repository = S.Filegroup({ cwd: "//", srcs: [S.glob("//**", { exclude: [
  "//.git/**", "//.jj/**", "//.flows/**", "//.smithers/cache/**", "//.smithers/reports/**",
  "//.zig-cache/**", "//zig-out/**", "//target/**", "//node_modules/**",
  "//**/.git/**", "//**/.zig-cache/**", "//**/zig-out/**", "//**/target/**"
] })] })
// Globs are package scoped even with a // prefix. Anchor the repository group
// at // explicitly, then add this package's files across that boundary.
const source = S.Filegroup({ srcs: [repository, S.glob("**", { exclude: ["cache/**", "reports/**"] })] })
const env = {
  ZIG_GLOBAL_CACHE_DIR: fileURLToPath(new URL("./cache/tools/zig/global", import.meta.url)),
  ZIG_LOCAL_CACHE_DIR: fileURLToPath(new URL("./cache/tools/zig/local", import.meta.url)),
  // lib/foundry.zig resolves Cargo artifacts under this workspace-relative path.
  CARGO_TARGET_DIR: "target"
}
const tools = [S.Host.bin("cargo"), S.Host.bin("rustc"), S.Host.bin("cc")]
const common = { bin: S.Host.bin("zig"), tools, env, sandbox: "none" as const, timeout: "6h" as const }

const crypto = S.Shell.Build({
  bin: S.Host.bin("node"), tools,
  args: [".smithers/build-crypto.mjs"],
  sandbox: "none", timeout: "1h", data: [source],
  outFiles: ["//lib/voltaire/target/release/libcrypto_wrappers.a"]
})
const build = S.Shell.Build({ ...common, args: ["build"], data: [source, crypto], outDirs: ["//zig-out"] })
const unit = S.Shell.Test({ ...common, args: ["build", "test-unit"], data: [source, build] })
const opcodes = S.Shell.Test({ ...common, args: ["build", "test-opcodes"], data: [source, build] })
const modexp = S.Shell.Test({
  ...common, args: ["build", "test-modexp", "--build-file", ".smithers/build.zig"], data: [source, build]
})
const fusions = S.Shell.Test({ ...common, args: ["build", "test-fusions"], data: [source, build] })
const specs = S.Shell.Test({ ...common, args: ["build", "state-tests"], data: [source, build] })
const bench = S.Shell.Build({
  ...common, args: ["build", "--build-file", ".smithers/build.zig", "-Doptimize=ReleaseFast",
    "--prefix", "zig-out/smithers"],
  data: [source], outDirs: ["//zig-out/smithers"]
})

export const Package = S.Package({ targets: {
  "repository-sources": repository,
  sources: source,
  "factory-write": S.FactoryProjection({ mode: "write" }),
  "factory-check": S.FactoryProjection({ mode: "check" }),
  "build-crypto": crypto,
  build,
  "test-unit": unit,
  "test-opcodes": opcodes,
  "test-modexp": modexp,
  "test-fusions": fusions,
  "test-specs": specs,
  "bench-build": bench,
  // Timing observations must be fresh; compilation is cached by bench-build.
  bench: S.Shell.Run({
    shell: "zig-out/smithers/bin/guillotine-modexp-bench", sandbox: "none", timeout: "5m", data: [bench], manual: true
  }),
  "test-foundry-link": S.Shell.Test({
    bin: S.Host.bin("node"), args: ["--test", ".smithers/tests/foundry-link.test.mjs"],
    tools: [S.Host.bin("zig")], env, sandbox: "none", timeout: "10m", data: [source]
  })
} })
