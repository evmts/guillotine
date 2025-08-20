#!/bin/bash

echo "🔐 Building crypto benchmark runners..."

# Build Zig crypto benchmark
echo "Building Zig crypto benchmark..."
cd bench/official/src/crypto/zig
zig build -Doptimize=ReleaseFast
if [ $? -ne 0 ]; then
    echo "❌ Failed to build Zig crypto benchmark"
    exit 1
fi
cd - > /dev/null

# Build Rust crypto benchmark
echo "Building Rust crypto benchmark..."
cd bench/official/src/crypto/rust
cargo build --release
if [ $? -ne 0 ]; then
    echo "❌ Failed to build Rust crypto benchmark"
    exit 1
fi
cd - > /dev/null

# Build orchestrator
echo "Building orchestrator..."
zig build build-orchestrator -Doptimize=ReleaseFast
if [ $? -ne 0 ]; then
    echo "❌ Failed to build orchestrator"
    exit 1
fi

echo ""
echo "🚀 Running crypto benchmarks..."
echo ""

# Run crypto benchmarks
./zig-out/bin/orchestrator --crypto --internal-runs 1000

echo ""
echo "✅ Crypto benchmarks completed!"