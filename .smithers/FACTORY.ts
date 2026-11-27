/**
 * The Smithers Cloud coding factory that develops evmts/guillotine
 * (https://smithers.sh/evmts/guillotine): featured flows, Dispatcher rules,
 * Cloud CI trigger bindings, saved issue views, GitHub mirroring and trust
 * policy, and personalized home views for maintainers, contributors, and viewers.
 *
 * Projected into .smithers/factory.json and .smithers/home.json by
 * `scripts/smthrs target //.smithers:factory-write --write` and drift-checked by
 * `scripts/smthrs target //.smithers:factory-check`. Edit this file, never the JSON.
 */
import { Smithers as S } from "@smthrs/targets"

export const review = S.Flow({
  flow: "checks/review",
  featured: true,
  summary: "Review consensus, Zig ownership, state compliance, and benchmark regressions."
})

export const issueRepro = S.Flow({
  flow: "issue/repro",
  featured: true,
  summary: "Reproduce an EVM issue with repository fixtures before planning a fix."
})

export const issuePoc = S.Flow({
  flow: "issue/poc",
  featured: true,
  summary: "Prove a fix with a failing regression first and incremental smthrs checks."
})

export const prTriage = S.Flow({
  flow: "pr-triage",
  featured: true,
  summary: "Assess pull request readiness from its diff without executing untrusted code."
})

export const uphill = S.Flow({
  flow: "uphill",
  featured: true,
  summary: "Score safety, TigerStyle, verification, docs, and factory health in a Lighthouse audit report."
})

export const wikiRefresh = S.Flow({
  flow: "wiki-refresh",
  featured: true,
  summary: "Refresh the Engineering Wiki and Mythical History from committed repository truth."
})

export const releaseCheck = S.Flow({
  flow: "release-check",
  featured: false,
  summary: "Audit version lockstep, FFI artifacts, docs build, and npm dry-run packaging."
})

export const playground = S.Flow({
  flow: "playground/exec",
  featured: true,
  summary: "Inspect Guillotine bytecode dispatch fusions or run bounded native EVM calls."
})

export const factory = S.Factory({
  summary: "Guillotine EVM: register-passing Zig 0.17.1 EVM, formal proofs, Lighthouse backpressure, and Smithers Cloud CI.",
  flows: [review, issueRepro, issuePoc, prTriage, uphill, wikiRefresh, releaseCheck, playground],
  on: {
    "issue.labeled:todo": {
      flow: "issue/poc",
      description: "Build a failing regression and bounded PoC for every maintainer-accepted TODO"
    },
    "change.opened": {
      flow: "checks/review",
      description: "Review every Change across consensus, memory safety, compliance, and performance lenses"
    },
    "change.updated": {
      flow: "checks/review",
      description: "Re-review every updated Change before maintainer merge"
    },
    "change.landed": {
      flow: "wiki-refresh",
      description: "Refresh the Engineering Wiki and Mythical History after a Change lands"
    },
    "github.push:main": {
      flow: "wiki-refresh",
      description: "Refresh the Engineering Wiki and audit report after main advances"
    },
    "schedule:0 4 * * *": {
      flow: "uphill",
      description: "Run the nightly Uphill Lighthouse backpressure audit on main"
    },
    "schedule:0 10 * * 1": {
      flow: "release-check",
      description: "Weekly Monday release lockstep, SDK packaging, and docs audit"
    }
  },
  triggers: {
    "ci-push": {
      _tag: "TriggerBinding",
      flow: "ci",
      title: "CI on main and gate branches",
      on: { _tag: "Push", branches: ["main", "gate/**"] }
    },
    "ci-pull-request": {
      _tag: "TriggerBinding",
      flow: "ci",
      title: "CI on pull requests",
      on: { _tag: "PullRequest" }
    },
    "ci-manual": {
      _tag: "TriggerBinding",
      flow: "ci",
      title: "Run Guillotine CI",
      on: { _tag: "Manual" }
    },
    "uphill-pull-request": {
      _tag: "TriggerBinding",
      flow: "uphill",
      title: "Uphill Lighthouse audit on pull requests",
      on: { _tag: "PullRequest" }
    },
    "uphill-nightly": {
      _tag: "TriggerBinding",
      flow: "uphill",
      title: "Nightly Uphill Lighthouse audit",
      on: { _tag: "Cron", cron: "0 4 * * *", timezone: "UTC", overlap: "skip" }
    },
    "uphill-manual": {
      _tag: "TriggerBinding",
      flow: "uphill",
      title: "Run Lighthouse Backpressure Audit",
      on: { _tag: "Manual" }
    },
    "wiki-main": {
      _tag: "TriggerBinding",
      flow: "wiki",
      title: "Refresh Engineering Wiki on main",
      on: { _tag: "Push", branches: ["main"] }
    },
    "wiki-manual": {
      _tag: "TriggerBinding",
      flow: "wiki",
      title: "Rebuild Engineering Wiki and Mythical History",
      on: { _tag: "Manual" }
    },
    "release-manual": {
      _tag: "TriggerBinding",
      flow: "release",
      title: "Verify release readiness and docs build",
      on: { _tag: "Manual" }
    }
  },
  machine: {
    vcpus: 4,
    memoryMiB: 8192,
    tools: ["zig", "cargo", "rustc", "cc", "bun", "node"]
  },
  issueViews: [
    { id: "todos", title: "Accepted TODOs", state: "open", labels: ["todo"] },
    { id: "consensus", title: "Consensus and EVM", state: "open", labels: ["consensus"] },
    { id: "verification", title: "Formal verification", state: "open", labels: ["verification"] },
    { id: "performance", title: "Performance and JIT", state: "open", labels: ["performance"] },
    { id: "sdks", title: "C and TypeScript SDKs", state: "open", labels: ["sdk"] },
    { id: "needs-repro", title: "Needs reproduction", state: "open", labels: ["needs-repro"] }
  ],
  issueTransitions: [
    { id: "request-repro", title: "Request minimal reproduction", to: "needs-repro", actor: "anyone" },
    { id: "accept", title: "Accept issue for implementation", from: "needs-repro", to: "accepted", actor: "person" },
    { id: "promote-todo", title: "Promote to factory TODO", from: "accepted", to: "todo", actor: "person" }
  ],
  github: S.Github.Policy({
    mirror: "pull",
    issues: "two-way",
    changes: "send-upstream",
    maintainers: ["roninjin10", "fucory"],
    protectedPaths: [
      "src/evm.zig",
      "src/eips_and_hardforks",
      "src/frame",
      "src/core/verified_ops.zig",
      "build.zig",
      "build.zig.zon",
      ".github/workflows",
      ".smithers/FACTORY.ts",
      ".smithers/WORKSPACE.ts",
      ".smithers/PACKAGE.ts",
      ".agents/uphill"
    ],
    dailyTokens: 1_000_000_000
  }),
  policy: {
    lifecycle: {
      docs: "evergreen",
      tests: "evergreen"
    },
    approvals: {
      approve: "person",
      merge: "person"
    }
  }
})

export const home = S.Factory.Home({
  docs: "https://guillotine.tevm.sh/llms.txt",
  contributors: "role",
  sections: [
    {
      title: "Maintainer Control Room",
      audience: "maintainer",
      blocks: [
        {
          type: "action",
          flow: "branch.new",
          title: "New branch",
          key: "b"
        },
        {
          type: "issues",
          title: "Triage and open pull requests"
        },
        {
          type: "stack",
          title: "TODO and changeset stack"
        },
        {
          type: "runs",
          title: "Recent factory runs"
        },
        {
          type: "links",
          title: "Operations and trust gates",
          links: [
            { label: "Factory dashboard", url: "https://smithers.sh/evmts/guillotine/-/factory" },
            { label: "Engineering Wiki", url: "https://smithers.sh/evmts/guillotine/-/wiki" },
            { label: "Lighthouse Audit Report", url: "https://guillotine.tevm.sh/audit.html" },
            { label: "Mythical History", url: "https://guillotine.tevm.sh/wiki.html#Mythical-History.md" },
            { label: "GitHub Releases", url: "https://github.com/evmts/guillotine/releases" }
          ]
        }
      ]
    },
    {
      title: "Contributor Workbench",
      audience: "contributor",
      blocks: [
        {
          type: "code",
          title: "Verify locally with shared read-only cloud cache",
          language: "sh",
          code: "zig build && zig build test-opcodes\nscripts/smthrs test //.smithers:test-factory\nuphill --compact\nnode scripts/smithers-auth.mjs verify"
        },
        {
          type: "cards",
          title: "How a change lands",
          cards: [
            {
              label: "Step 1",
              title: "Reproduce first",
              text: "Include a minimal failing Zig, C, or TypeScript test with hardfork, bytecode, and expected gas or output."
            },
            {
              label: "Step 2",
              title: "Run untrusted freely",
              text: "Run builds, tests, and Uphill locally or in PR CI using read-only cache hits from build.smithers.sh. Untrusted runs never write to the cache or skip gates."
            },
            {
              label: "Step 3",
              title: "Clear Lighthouse backpressure",
              text: "Keep safety, TigerStyle, verification, docs, and factory scores green. Every crash must become a graceful error."
            },
            {
              label: "Step 4",
              title: "Connect your agent via MCP",
              text: "Point Claude Code, Codex, Cursor, or Antigravity at https://smithers.sh/evmts/guillotine/mcp with one-time PKCE auth. Maintainers approve and merge."
            }
          ]
        },
        {
          type: "stack",
          title: "Public TODO stack"
        },
        {
          type: "flows",
          title: "Factory flows"
        },
        {
          type: "links",
          title: "Contributor resources",
          links: [
            { label: "Issues", url: "https://smithers.sh/evmts/guillotine/issues" },
            { label: "Pull requests", url: "https://smithers.sh/evmts/guillotine/pulls" },
            { label: "Engineering Wiki", url: "https://smithers.sh/evmts/guillotine/-/wiki" },
            { label: "Lighthouse Backpressure Audit", url: "https://guillotine.tevm.sh/audit.html" },
            { label: "Contributing guide", url: "https://guillotine.tevm.sh/contributing" }
          ]
        },
        {
          type: "prompt",
          title: "Ask about Guillotine",
          placeholder: "Ask about dispatch schedules, formal proofs, gas rules, or SDKs…"
        }
      ]
    },
    {
      audience: "everyone",
      blocks: [
        {
          type: "hero",
          title: "Guillotine",
          tagline: "An ultra-fast, formally verified Ethereum Virtual Machine written in Zig 0.17.1 with register-passing tailcall dispatch.",
          text: "Passes 66,652 / 66,652 official Ethereum Execution Spec Tests (Frontier through Osaka), 55 Zean Lean 4 proofs, 32 SMT theorems, and ships native Zig, C ABI, and Bun FFI TypeScript surfaces.",
          install: "zig fetch --save=guillotine https://github.com/evmts/guillotine/archive/refs/tags/v0.1.0.tar.gz",
          actions: [
            { label: "Read Docs", url: "https://guillotine.tevm.sh" },
            { label: "Audit Report", url: "https://guillotine.tevm.sh/audit.html" },
            { label: "Wiki and History", url: "https://guillotine.tevm.sh/wiki.html" }
          ],
          announcement: {
            label: "v0.1.0 Beta · 100% EEST + Zean direct Zig AIR to Lean 4.35 proofs",
            url: "https://github.com/evmts/guillotine/releases/tag/v0.1.0"
          }
        },
        {
          type: "code",
          file: "execute.zig",
          language: "zig",
          code: "const std = @import(\"std\");\nconst evm = @import(\"evm\");\nconst primitives = @import(\"voltaire\");\n\npub fn main() !void {\n    var gpa = std.heap.GeneralPurposeAllocator(.{}){};\n    defer _ = gpa.deinit();\n    const allocator = gpa.allocator();\n\n    var db = evm.Database.init(allocator);\n    defer db.deinit();\n\n    const code = [_]u8{ 0x60, 0x2a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };\n    const target = try primitives.Address.fromHex(\n        \"0x2000000000000000000000000000000000000002\",\n    );\n    try db.set_code(target.bytes, &code);\n\n    var instance = try evm.MainnetEvm.init(allocator, &db, .{}, .{}, 0, null);\n    defer instance.deinit();\n    const res = instance.call(.{ .call = .{\n        .caller = @splat(0),\n        .to = target.bytes,\n        .value = 0,\n        .input = &.{},\n        .gas = 100_000,\n    } });\n    std.debug.print(\"success={} output={x}\\n\", .{ res.success, res.output });\n}"
        },
        {
          type: "stats",
          stats: [
            { value: "66,652 / 66,652", label: "Official EEST (Frontier to Osaka)" },
            { value: "1.43x vs revm", label: "Classic interpreter suite (M3 Max)" },
            { value: "183 Lean + 42 SMT", label: "Machine-checked formal proofs" },
            { value: "116,384 / 116,384", label: "Zig to Lean 4 differential vectors" },
            { value: "Zig · C · Bun TS", label: "Native package and C ABI surfaces" },
            { value: "MIT", label: "Open source license" }
          ]
        },
        {
          type: "cards",
          title: "Why Guillotine",
          cards: [
            {
              label: "Dispatch",
              title: "Register-passing tailcall engine",
              text: "Preprocesses bytecode into 8-byte dispatch schedules with basic-block gas batching, synthetic opcode fusions, and stock Zig 0.17.1 preserve_none tailcalls.",
              url: "https://guillotine.tevm.sh/concepts/dispatch"
            },
            {
              label: "Verification",
              title: "Dual Zean and Lean 4 formal stack",
              text: "Direct Zig 0.17.1 AIR to Lean 4.35.0 proofs via Zean, hand-authored Lean specs, Bitwuzla and Z3 SMT bitvector proofs, and LLVM IR equivalence checks.",
              url: "https://guillotine.tevm.sh/guides/testing-and-verification"
            },
            {
              label: "Mainnet + L2",
              title: "Frontier through Osaka and Base L2",
              text: "Complete mainnet hardfork coverage plus Base and OP Stack Bedrock through Jovian with EIP-7702 authorizations, L1 data fees, and deposits.",
              url: "https://guillotine.tevm.sh/reference/hardforks"
            },
            {
              label: "Safety",
              title: "TigerStyle zero-crash posture",
              text: "Every runtime error returns gracefully, O(1) undo-log snapshots protect state atomicity, and Uphill Lighthouse audits enforce continuous backpressure.",
              url: "https://guillotine.tevm.sh/guides/tigerstyle"
            },
            {
              label: "Crypto",
              title: "Fast native precompiles",
              text: "Pure-Zig secp256k1 ECRECOVER at 0.171 ms, adaptive Montgomery MODEXP, BN254 GLV, BLS12-381 via blst, KZG 4844, and SIMD calldata counting.",
              url: "https://guillotine.tevm.sh/guides/benchmarks-and-jit"
            },
            {
              label: "Factory",
              title: "Built in public on Smithers Cloud",
              text: "Public MCP server, shared build.smithers.sh object store with untrusted-read isolation, Engineering Wiki, Mythical History, and automated releases.",
              url: "https://guillotine.tevm.sh/audit.html"
            }
          ]
        },
        {
          type: "cards",
          title: "Surfaces and Tevm Ecosystem",
          cards: [
            {
              label: "Zig",
              title: "dep.module(\"evm\")",
              text: "Embed the dispatch EVM, Layer 2 module, and Voltaire primitives directly in Zig 0.17.1 projects.",
              url: "https://guillotine.tevm.sh/installation"
            },
            {
              label: "C ABI",
              title: "libguillotine_ffi",
              text: "Prebuilt macOS arm64 and Linux x86_64 shared libraries with guillotine.h and Custom SDK Builder recipes.",
              url: "https://guillotine.tevm.sh/guides/bindings"
            },
            {
              label: "TypeScript",
              title: "@tevm/guillotine",
              text: "Zero-overhead Bun FFI SDK shipping both prebuilds with 340 passing E2E and fuzz tests.",
              url: "https://www.npmjs.com/package/@tevm/guillotine"
            },
            {
              label: "Node",
              title: "ZEVM",
              text: "Embeddable Zig Ethereum node with JSON-RPC and beacon light client built in the Tevm ecosystem.",
              url: "https://smithers.sh/evmts/zevm"
            },
            {
              label: "Primitives",
              title: "Voltaire",
              text: "High-performance Zig and TypeScript Ethereum primitives and cryptography powering Guillotine.",
              url: "https://smithers.sh/evmts/voltaire"
            },
            {
              label: "Reference",
              title: "Guillotine Mini",
              text: "Standalone readable reference EVM for differential testing and educational clarity.",
              url: "https://github.com/evmts/guillotine-mini"
            }
          ]
        },
        {
          type: "releases",
          title: "Releases",
          releases: [
            {
              name: "v0.1.0",
              url: "https://github.com/evmts/guillotine/releases/tag/v0.1.0",
              date: "2026-11-25",
              summary: "First beta release: Zig 0.17.1 preserve_none dispatch, 66,652/66,652 EEST, Lean 4 and SMT formal verification, Base L2, C FFI, and @tevm/guillotine."
            }
          ],
          more: {
            label: "All releases",
            url: "https://github.com/evmts/guillotine/releases"
          }
        },
        {
          type: "links",
          title: "Smithers Cloud, Wiki, and Community",
          links: [
            { label: "Public MCP Endpoint", url: "https://smithers.sh/evmts/guillotine/mcp" },
            { label: "Engineering Wiki", url: "https://smithers.sh/evmts/guillotine/-/wiki" },
            { label: "Mythical History", url: "https://guillotine.tevm.sh/wiki.html#Mythical-History.md" },
            { label: "Lighthouse Audit Report", url: "https://guillotine.tevm.sh/audit.html" },
            { label: "Documentation", url: "https://guillotine.tevm.sh" },
            { label: "Telegram", url: "https://t.me/+ANThR9bHDLAwMjUx" },
            { label: "Twitter / X", url: "https://x.com/tevmtools" }
          ]
        },
        {
          type: "prompt",
          title: "Questions about Guillotine?",
          placeholder: "Ask Smithers about Guillotine EVM…"
        }
      ]
    }
  ]
})
