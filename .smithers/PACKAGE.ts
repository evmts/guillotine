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

// `zig build` compiles Voltaire's Rust archive itself (lib/voltaire/build.zig
// runs `cargo build --release --locked` into a Zig cache output directory).
const build = S.Shell.Build({ ...common, args: ["build"], data: [source], outDirs: ["//zig-out"] })
// Every target runs a step of the root build.zig (Zig 0.17.1).
const step = (name: string, manual = false) =>
  S.Shell.Test({ ...common, args: ["build", name], data: [source, build], manual })
const bench = S.Shell.Build({
  ...common, args: ["build", "bench-build", "--prefix", "zig-out/smithers"],
  data: [source], outDirs: ["//zig-out/smithers"]
})

export const Package = S.Package({ targets: {
  "repository-sources": repository,
  sources: source,
  "factory-write": S.FactoryProjection({ mode: "write" }),
  "factory-check": S.FactoryProjection({ mode: "check" }),
  build,
  "test-unit": step("test-unit"),
  "test-opcodes": step("test-opcodes"),
  "test-modexp": step("test-modexp"),
  "test-fusions": step("test-fusions"),
  "test-layer2": step("test-layer2"),
  "test-bench": step("test-bench"),
  "state-tests": step("state-tests"),
  // Needs the Lean 4 toolchain (elan) on the host; builds the reference itself.
  "test-lean-diff": step("test-lean-diff", true),
  "bench-build": bench,
  // Timing observations must be fresh; compilation is cached by bench-build.
  bench: S.Shell.Run({
    shell: "zig-out/smithers/bin/guillotine-bench", sandbox: "none", timeout: "30m", data: [bench], manual: true
  }),
  "test-foundry-link": S.Shell.Test({
    bin: S.Host.bin("node"), args: ["--test", ".smithers/tests/foundry-link.test.mjs"],
    tools: [S.Host.bin("zig")], env, sandbox: "none", timeout: "10m", data: [source]
  })
} })
