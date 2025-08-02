#!/bin/bash

# Build and run snailtracer benchmark with Tracy profiling enabled
# This script provides a quick way to profile the EVM with Tracy

set -e

echo "🔨 Building EVM runner with Tracy profiling enabled..."
zig build build-evm-runner -Dtracy=true -Doptimize=ReleaseFast

echo "🚀 Running snailtracer benchmark with Tracy..."
echo "⚡ Make sure Tracy profiler is running to capture the data!"
echo ""

./zig-out/bin/evm-runner \
  --contract-code-path bench/official/cases/snailtracer/bytecode.txt \
  --calldata 0x30627b7c

echo ""
echo "✅ Done! Check Tracy profiler for performance data."
echo ""
echo "💡 Tip: Download Tracy from https://github.com/wolfpld/tracy/releases"
echo "   and run it before executing this script to capture profiling data."