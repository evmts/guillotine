#!/bin/bash

zig build build-evm-runner -Doptimize=ReleaseFast \
  && zig build build-evm-runner-small -Doptimize=ReleaseSmall \
  && zig build build-orchestrator -Doptimize=ReleaseFast \
  && zig-out/bin/orchestrator \
    --compare \
    --export markdown \
    --num-runs 2 \
    --js-runs 1 \
    --internal-runs 20 \
    --js-internal-runs 1 \
    --snailtracer-internal-runs 2 \
    --js-snailtracer-internal-runs 1 \
    --next \
  && echo "Opening results in browser..." \
  && npx markserv bench/official/results.md
