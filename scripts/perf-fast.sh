#!/bin/bash

 zig build build-evm-runner -Doptimize=ReleaseFast \
  && zig build build-orchestrator -Doptimize=ReleaseFast \
  && ./zig-out/bin/orchestrator --compare --export markdown --num-runs 1 --js-runs 1 --internal-runs 10 --js-internal-runs 1 \
  && echo "Opening results in browser..." \
  && npx markserv bench/official/results.md