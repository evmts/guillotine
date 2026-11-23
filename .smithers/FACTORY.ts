import { Smithers as S } from "@smthrs/targets"

export const factory = S.Factory({
  summary: "Guillotine EVM: incremental Zig/Rust checks, consensus safety, state compliance and measured performance.",
  flows: [
    S.Flow({ flow: "checks/review", featured: true, summary: "Review consensus, ownership, compliance and performance." }),
    S.Flow({ flow: "issue/repro", featured: true, summary: "Reproduce an EVM issue before planning a fix." }),
    S.Flow({ flow: "issue/poc", featured: true, summary: "Prove a fix with focused regressions and consensus checks." }),
    S.Flow({ flow: "pr-triage", featured: true, summary: "Assess PR readiness from its diff and supplied CI evidence." })
  ],
  on: {},
  github: S.Github.Policy({ mirror: "pull", issues: "read", changes: "send-upstream",
    maintainers: ["roninjin10", "fucory"],
    protectedPaths: ["src/evm.zig", "src/eips_and_hardforks", "src/frame", "build.zig.zon"]
  })
})

export const home = S.Factory.Home({ blocks: [
  { type: "text", title: "Guillotine EVM factory", text: "Consensus correctness and graceful errors are release gates. Incremental Zig and Cargo caches accelerate checks; benchmark timings are always fresh." },
  { type: "prompt", title: "Ask about Guillotine", placeholder: "Describe an EVM issue or change…" },
  { type: "flows", title: "Review and reproduce" },
  { type: "links", links: [
    { label: "Repository", url: "https://github.com/evmts/guillotine" },
    { label: "CI", url: "https://github.com/evmts/guillotine/actions/workflows/ci.yml" },
    { label: "Architecture", url: "https://github.com/evmts/guillotine/blob/main/docs/dev/ARCHITECTURE.md" }
  ] }
] })
