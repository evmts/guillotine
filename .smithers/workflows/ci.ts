// Guillotine primary CI workflow for Smithers Cloud.
// Evaluated in the Worker QuickJS realm (only @smthrs/flow, @smthrs/plan,
// @smthrs/sandbox, and effect are imported). Runs untrusted PRs with zero
// secrets and read-only cloud cache; main/maintainer runs populate the shared
// object store and enforce all merge gates.
import { Flow } from "@smthrs/flow"
import { Node } from "@smthrs/plan"
import { CiJob } from "@smthrs/sandbox"
import { Schema } from "effect"

const hygiene = CiJob.make("hygiene", {
  steps: [
    { name: "factory-json-valid", run: "node -e 'for (const f of [\".smithers/factory.json\", \".smithers/home.json\"]) JSON.parse(require(\"fs\").readFileSync(f, \"utf8\"))'" },
    { name: "wiki-check", run: "node .smithers/wiki/build-feed.mjs --check" },
    { name: "factory-tests", run: "node --test .smithers/tests/*.test.mjs", timeoutSeconds: 300 }
  ]
})

const backpressure = CiJob.make("backpressure", {
  steps: [
    { name: "install-uphill", run: "command -v uphill >/dev/null 2>&1 || curl -fsSL https://wevm.sh/uphill | sh" },
    { name: "uphill-check", run: "PATH=\"$HOME/.uphill/bin:$HOME/.bun/bin:$PATH\" uphill check" },
    { name: "uphill-audit", run: "PATH=\"$HOME/.uphill/bin:$HOME/.bun/bin:$PATH\" uphill --compact && node .smithers/reports/audit.mjs --check", timeoutSeconds: 300 }
  ]
})

const core = CiJob.make("core", {
  needs: ["hygiene"],
  steps: [
    { name: "zig-fmt", run: "zig fmt --check src/" },
    { name: "zig-build", run: "zig build", timeoutSeconds: 600 },
    { name: "zig-unit-opcodes", run: "zig build test-unit && zig build test-opcodes", timeoutSeconds: 600 },
    { name: "zig-suites", run: "zig build test-modexp && zig build test-precompiles && zig build test-fusions && zig build test-layer2 && zig build test-bench", timeoutSeconds: 600 }
  ]
})

const sdks = CiJob.make("sdks", {
  needs: ["core"],
  steps: [
    { name: "ffi-shared", run: "zig build shared -Doptimize=ReleaseFast", timeoutSeconds: 600 },
    { name: "c-sdk", run: "make -f sdks/c/Makefile -o build-core test", timeoutSeconds: 300 },
    { name: "ts-sdk", run: "cd sdks/typescript && bun install --frozen-lockfile && bun test", timeoutSeconds: 300 }
  ]
})

export default Flow.make("ci", {
  description: "Run Guillotine hygiene, Uphill Lighthouse backpressure audit, Zig EVM suites, and C/TypeScript SDK verification.",
  modelInvocable: false,
  payload: {
    run: Schema.String,
    repo: Schema.String,
    sha: Schema.String,
    ref: Schema.String,
    event: Schema.String
  },
  success: Schema.Struct({
    hygiene: CiJob.Result,
    backpressure: CiJob.Result,
    core: CiJob.Result,
    sdks: CiJob.Result
  }),
  body: (run) =>
    Node.all({
      hygiene: hygiene.call(run),
      backpressure: backpressure.call(run),
      core: core.call(run),
      sdks: sdks.call(run)
    })
})
