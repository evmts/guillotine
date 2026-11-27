import { Flow } from "@smthrs/flow"
import { Node } from "@smthrs/plan"
import { CiJob } from "@smthrs/sandbox"
import { Schema } from "effect"

const uphill = CiJob.make("uphill", {
  steps: [
    { name: "uphill", run: "uphill --compact" },
  ],
})

export default Flow.make("uphill", {
  payload: {
    run: Schema.String,
    repo: Schema.String,
    sha: Schema.String,
    ref: Schema.String,
    event: Schema.String,
  },
  success: Schema.Struct({ uphill: CiJob.Result }),
  body: (run) => Node.all({ uphill: uphill.call(run) }),
})
