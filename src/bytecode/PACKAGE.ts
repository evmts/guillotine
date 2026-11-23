import { Smithers as S } from "@smthrs/targets"
import { zigMicroBench } from "../../bench/package-helpers.ts"
import { Package as shared } from "../../bench/shared/PACKAGE.ts"

const sources = S.Filegroup({
  srcs: [S.glob("**/*.zig", { exclude: ["**/*_bench*.zig"] })]
})

const { benchBuild, bench } = zigMicroBench({
  name: "bytecode",
  needsNativeTools: false,
  data: [
    sources,
    shared["micro-harness"],
    shared["opcodes-sources"],
    S.file("//bench/suites/bytecode_bench.zig")
  ]
})

export const Package = S.Package({
  targets: {
    sources,
    "bench-build": benchBuild,
    bench
  }
})
