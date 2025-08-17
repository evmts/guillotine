
#!/bin/bash

zig build build-evm-runner -Doptimize=ReleaseFast \
  && zig build build-evm-runner-small -Doptimize=ReleaseSmall \
  && zig build build-evm-runner-call2 -Doptimize=ReleaseFast \
  && zig build build-orchestrator -Doptimize=ReleaseFast \
  && ./zig-out/bin/orchestrator \
    --compare \
    --export markdown \
    --num-runs 20 \
    --js-runs 3 \
    --internal-runs 200 \
    --js-internal-runs 20 \
    --snailtracer-internal-runs 20 \
    --js-snailtracer-internal-runs 3\
  && echo "Opening results in browser..." \
  && npx markserv bench/official/results.md
