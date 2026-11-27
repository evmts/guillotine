// Engineering Wiki and Mythical History validation and feed build workflow.
import { Flow } from "@smthrs/flow"
import { Node } from "@smthrs/plan"
import { CiJob } from "@smthrs/sandbox"
import { Schema } from "effect"

const wiki = CiJob.make("wiki", {
  steps: [
    { name: "wiki-check", run: "node .smithers/wiki/build-feed.mjs --check" },
    { name: "wiki-build", run: "node .smithers/wiki/build-feed.mjs --write" }
  ]
})

export default Flow.make("wiki", {
  description: "Validate and build Guillotine's Obsidian-compatible Engineering Wiki and Mythical History feed payload.",
  modelInvocable: true,
  payload: {
    run: Schema.String,
    repo: Schema.String,
    sha: Schema.String,
    ref: Schema.String,
    event: Schema.String
  },
  success: Schema.Struct({
    wiki: CiJob.Result
  }),
  body: (run) =>
    Node.all({
      wiki: wiki.call(run)
    })
})
