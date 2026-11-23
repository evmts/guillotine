import { Smithers as S } from "@smthrs/targets"
import { zigMicroBench } from "../../bench/package-helpers.ts"
import { Package as shared } from "../../bench/shared/PACKAGE.ts"

const sources = S.Filegroup({
  srcs: [S.glob("**/*.zig")]
})

const { benchBuild, bench } = zigMicroBench({
  name: "layer2",
  data: [
    sources,
    shared["micro-harness"],
    shared["voltaire-sources"],
    S.file("//bench/suites/layer2_bench.zig")
  ]
})

export const Package = S.Package({
  targets: {
    sources,
    "bench-build": benchBuild,
    bench
  }
})
