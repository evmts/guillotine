#!/bin/bash
# Simple script to build and run Guillotine with Tracy profiling enabled

echo "Building Guillotine with Tracy enabled..."
zig build -Dtracy=true -Doptimize=ReleaseFast build-evm-runner

echo ""
echo "Build complete! You can now run benchmarks with Tracy profiling."
echo ""
echo "Example benchmark commands:"
echo "  ./zig-out/bin/evm-runner --contract-code-path bench/official/cases/erc20-transfer/bytecode.txt --calldata 0xa9059cbb000000000000000000000000000000000000000000000000000000000000dead0000000000000000000000000000000000000000000000000000000000000064"
echo ""
echo "  ./zig-out/bin/evm-runner --contract-code-path bench/official/cases/ten-thousand-hashes/bytecode.txt --calldata 0x30627b7c"
echo ""
echo "Make sure Tracy profiler is running before executing these commands!"