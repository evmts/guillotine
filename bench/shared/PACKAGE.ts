import { Smithers as S } from "@smthrs/targets"

const buildScripts = S.Filegroup({
  cwd: "//",
  srcs: [
    S.file("//build.zig"),
    S.file("//build.zig.zon"),
    S.file("//src/modules.build.zig"),
    S.file("//src/build.zig"),
    S.file("//src/pure_exports.zig"),
    S.file("//src/voltaire_exports.zig"),
    S.file("//lib/build.zig"),
    S.file("//lib/foundry.zig"),
    S.file("//lib/bn254.zig"),
    S.file("//bench/bench_step.zig"),
    S.file("//bench/suites_build.zig")
  ]
})

const microHarness = S.Filegroup({
  cwd: "//",
  srcs: [buildScripts, S.file("//bench/micro.zig")]
})

const evmBenchHarness = S.Filegroup({
  cwd: "//",
  srcs: [
    buildScripts,
    S.file("//bench/main.zig"),
    S.file("//bench/cli.zig"),
    S.file("//bench/engine.zig"),
    S.file("//bench/report.zig"),
    S.file("//bench/stats.zig"),
    S.file("//bench/workloads.zig"),
    S.file("//bench/tests.zig"),
    S.glob("//bench/native/**")
  ]
})

const voltaireSources = S.Filegroup({
  cwd: "//",
  srcs: [
    S.glob("//lib/voltaire/src/**"),
    S.file("//lib/voltaire/build.zig"),
    S.file("//lib/voltaire/build.zig.zon"),
    S.glob("//bench/native/**")
  ]
})

const opcodesSources = S.Filegroup({
  cwd: "//",
  srcs: [
    S.glob("//src/opcodes/**/*.zig"),
    S.glob("//src/internal/**/*.zig"),
    S.file("//src/log.zig")
  ]
})

const fixturesSources = S.Filegroup({
  cwd: "//",
  srcs: [S.glob("//fixtures/**")]
})

const evmRootSources = S.Filegroup({
  cwd: "//",
  srcs: [
    voltaireSources,
    opcodesSources,
    S.file("//src/root.zig"),
    S.file("//src/evm.zig"),
    S.file("//src/evm_config.zig"),
    S.file("//src/evm_arena_allocator.zig"),
    S.file("//src/evm_storage_integration.zig"),
    S.glob("//src/block/**/*.zig"),
    S.glob("//src/frame/**/*.zig"),
    S.glob("//src/instructions/**/*.zig"),
    S.glob("//src/stack/**/*.zig"),
    S.glob("//src/memory/**/*.zig"),
    S.glob("//src/bytecode/**/*.zig"),
    S.glob("//src/preprocessor/**/*.zig"),
    S.glob("//src/storage/**/*.zig"),
    S.glob("//src/eips_and_hardforks/**/*.zig"),
    S.glob("//src/provider/**/*.zig"),
    S.glob("//src/tracer/**/*.zig")
  ]
})

export const Package = S.Package({
  targets: {
    "build-scripts": buildScripts,
    "micro-harness": microHarness,
    "evm-bench-harness": evmBenchHarness,
    "voltaire-sources": voltaireSources,
    "opcodes-sources": opcodesSources,
    "fixtures-sources": fixturesSources,
    "evm-root-sources": evmRootSources
  }
})
