#!/bin/bash
# Script to run EVM benchmarks with Tracy profiling enabled

set -e

echo "Building with Tracy profiler support..."
zig build -Dtracy=true -Doptimize=ReleaseFast build-evm-runner

echo ""
echo "IMPORTANT: Make sure Tracy profiler is running before executing the benchmark!"
echo "Download Tracy from: https://github.com/wolfpld/tracy/releases"
echo ""
echo "Press Enter when Tracy is running..."
read -r

echo "Running snailtracer benchmark with Tracy..."
./zig-out/bin/evm-runner \
    --contract-code-path bench/official/cases/snailtracer/bytecode.txt \
    --calldata 0x30627b7c \
    --num-runs 1

echo ""
echo "Benchmark complete! Check Tracy profiler for the captured data."
echo ""
echo "To generate a flame graph from Tracy:"
echo "1. Save the capture in Tracy"
echo "2. Use File -> Export -> Chrome Tracing to export as JSON"
echo "3. Use a tool like speedscope.app to view the flame graph"