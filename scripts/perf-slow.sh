
#!/bin/bash

zig build build-evm-runner -Doptimize=ReleaseFast \
  && zig build build-orchestrator -Doptimize=ReleaseFast \
  && ./zig-out/bin/orchestrator \
    --compare \
    --export markdown \
    --num-runs 10 \
    --js-runs 2 \
    --internal-runs 100 \
    --js-internal-runs 10 \
    --snailtracer-internal-runs 10 \
    --js-snailtracer-internal-runs 1\
  && echo "Opening results in browser..." \
  && npx markserv bench/official/results.md
