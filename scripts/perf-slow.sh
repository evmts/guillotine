#!/bin/bash

# Performance benchmarking script for Guillotine EVM
# Runs official benchmarks with optimization and compares against REVM

set -e

echo "Building EVM runner with ReleaseFast optimization..."
zig build build-evm-runner -Doptimize=ReleaseFast

echo "Building orchestrator with ReleaseFast optimization..."
zig build build-orchestrator -Doptimize=ReleaseFast

echo "Running benchmarks..."
./zig-out/bin/orchestrator --compare --export markdown --num-runs 5 --js-runs 1 --internal-runs 10 --js-internal-runs 1

echo "Results written to bench/official/results.md"