// Uphill Lighthouse backpressure audit workflow for Smithers Cloud.
import { Flow } from "@smthrs/flow"
import { Node } from "@smthrs/plan"
import { CiJob } from "@smthrs/sandbox"
import { Schema } from "effect"

const uphill = CiJob.make("uphill", {
  steps: [
    { name: "install-uphill", run: "command -v uphill >/dev/null 2>&1 || curl -fsSL https://wevm.sh/uphill | sh" },
    { name: "uphill-check", run: "PATH=\"$HOME/.uphill/bin:$HOME/.bun/bin:$PATH\" uphill check" },
    { name: "uphill-compact", run: "PATH=\"$HOME/.uphill/bin:$HOME/.bun/bin:$PATH\" uphill --compact" },
    { name: "lighthouse-audit", run: "node .smithers/reports/audit.mjs --write && node .smithers/reports/audit.mjs --check", timeoutSeconds: 300 }
  ]
})

export default Flow.make("uphill", {
  description: "Score Guillotine safety, TigerStyle, modularity, formal verification, documentation, and factory health into a Lighthouse audit report.",
  modelInvocable: true,
  payload: {
    run: Schema.String,
    repo: Schema.String,
    sha: Schema.String,
    ref: Schema.String,
    event: Schema.String
  },
  success: Schema.Struct({
    uphill: CiJob.Result
  }),
  body: (run) =>
    Node.all({
      uphill: uphill.call(run)
    })
})
