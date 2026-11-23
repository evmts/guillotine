import { Smithers as S } from "@smthrs/targets"
import { zigMicroBench } from "../../bench/package-helpers.ts"
import { Package as shared } from "../../bench/shared/PACKAGE.ts"

const ringBufferSources = S.Filegroup({
  srcs: [S.file("ring_buffer.zig")]
})

const sources = S.Filegroup({
  srcs: [S.glob("**/*.zig")]
})

const ringBufferBench = zigMicroBench({
  name: "tracer",
  needsNativeTools: false,
  data: [
    ringBufferSources,
    shared["micro-harness"],
    S.file("//bench/suites/tracer_bench.zig")
  ]
})

const minimalEvmBench = zigMicroBench({
  name: "minimal-evm",
  iterations: 25,
  warmup: 5,
  data: [
    sources,
    shared["micro-harness"],
    shared["evm-root-sources"],
    S.file("//bench/suites/minimal_evm_bench.zig")
  ]
})

export const Package = S.Package({
  targets: {
    sources,
    "bench-build": ringBufferBench.benchBuild,
    bench: ringBufferBench.bench,
    "bench-minimal-evm-build": minimalEvmBench.benchBuild,
    "bench-minimal-evm": minimalEvmBench.bench
  }
})
