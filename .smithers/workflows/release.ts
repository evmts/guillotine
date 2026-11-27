// Release readiness and docs verification workflow for Smithers Cloud.
import { Flow } from "@smthrs/flow"
import { Node } from "@smthrs/plan"
import { CiJob } from "@smthrs/sandbox"
import { Schema } from "effect"

const readiness = CiJob.make("readiness", {
  steps: [
    {
      name: "version-lockstep",
      run: "node -e 'const fs=require(\"fs\"); const zon=fs.readFileSync(\"build.zig.zon\",\"utf8\").match(/\\.version\\s*=\\s*\"([^\"]+)\"/)?.[1]; const pkg=JSON.parse(fs.readFileSync(\"sdks/typescript/package.json\",\"utf8\")).version; const ch=fs.readFileSync(\"CHANGELOG.md\",\"utf8\"); if(!zon||zon!==pkg||!ch.includes(\"## [\"+zon+\"]\")){console.error({zon,pkg}); process.exit(1)} console.log(\"version lockstep ok:\", zon)'"
    },
    { name: "wiki-and-audit", run: "node .smithers/wiki/build-feed.mjs --check && node .smithers/reports/audit.mjs --check" },
    { name: "docs-build", run: "cd docs && bun install --frozen-lockfile && bun run build", timeoutSeconds: 300 }
  ]
})

const packageCheck = CiJob.make("package-check", {
  needs: ["readiness"],
  steps: [
    { name: "ffi-release", run: "zig build shared -Doptimize=ReleaseFast -Dstrip=true", timeoutSeconds: 600 },
    { name: "c-sdk", run: "make -f sdks/c/Makefile -o build-core test", timeoutSeconds: 300 },
    { name: "ts-pack-dry-run", run: "cd sdks/typescript && bun install --frozen-lockfile && bun scripts/copy-native.ts && bun run build && bun run typecheck && bun test && bun run lint:package && npm pack --dry-run --ignore-scripts", timeoutSeconds: 300 }
  ]
})

export default Flow.make("release", {
  description: "Verify Guillotine release lockstep, Vocs documentation build, FFI artifacts, and @tevm/guillotine npm dry-run packaging.",
  modelInvocable: false,
  payload: {
    run: Schema.String,
    repo: Schema.String,
    sha: Schema.String,
    ref: Schema.String,
    event: Schema.String
  },
  success: Schema.Struct({
    readiness: CiJob.Result,
    packageCheck: CiJob.Result
  }),
  body: (run) =>
    Node.all({
      readiness: readiness.call(run),
      packageCheck: packageCheck.call(run)
    })
})
