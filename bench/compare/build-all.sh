#!/usr/bin/env bash
set -euo pipefail

# Builds all cross-EVM benchmark runners from pinned revisions in bench/compare/versions.json.
# Run from the repository root: ./bench/compare/build-all.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"
BIN_DIR="$ROOT/bin"
mkdir -p "$BIN_DIR" "$ROOT/.cache"

ZIG_BIN="${ZIG_BIN:-$(command -v zig)}"
if [ -x "$HOME/.zvm/0.17.1/zig" ]; then
  ZIG_BIN="$HOME/.zvm/0.17.1/zig"
fi

echo "==> [1/7] Fetching/normalizing canonical workloads"
node "$ROOT/fetch-workloads.mjs"

echo "==> [2/7] Building Guillotine (Zig ReleaseFast)"
(cd "$REPO_ROOT" && "$ZIG_BIN" build bench-compare-build)

echo "==> [3/7] Building alloy-rs/evm2 (+ LLVM 23 JIT if available)"
LLVM23_PREFIX="${LLVM_SYS_231_PREFIX:-/opt/homebrew/opt/llvm}"
if [ -d "$LLVM23_PREFIX" ]; then
  LLVM_SYS_231_PREFIX="$LLVM23_PREFIX" RUSTFLAGS="-C target-cpu=native" \
    cargo build --release --features jit --manifest-path "$ROOT/runners/rust-evm2/Cargo.toml"
else
  RUSTFLAGS="-C target-cpu=native" \
    cargo build --release --manifest-path "$ROOT/runners/rust-evm2/Cargo.toml"
fi
cp "$ROOT/runners/rust-evm2/target/release/compare-evm2" "$BIN_DIR/compare-evm2"
rm -rf "$ROOT/runners/rust-evm2/target"

echo "==> [4/7] Building bluealloy/revm"
RUSTFLAGS="-C target-cpu=native" \
  cargo build --release --manifest-path "$ROOT/runners/rust-revm/Cargo.toml"
cp "$ROOT/runners/rust-revm/target/release/compare-revm" "$BIN_DIR/compare-revm"
rm -rf "$ROOT/runners/rust-revm/target"

echo "==> [5/7] Building lambdaclass/ethrex (ethrex-levm)"
RUSTFLAGS="-C target-cpu=native" \
  cargo build --release --manifest-path "$ROOT/runners/rust-ethrex/Cargo.toml"
cp "$ROOT/runners/rust-ethrex/target/release/compare-ethrex" "$BIN_DIR/compare-ethrex"
rm -rf "$ROOT/runners/rust-ethrex/target"

echo "==> [6/7] Building ipsilon/evmone (Advanced + Baseline)"
if [ ! -f "$ROOT/.cache/evmone/CMakeLists.txt" ]; then
  mkdir -p "$ROOT/.cache/evmone"
  curl -fsSL "https://github.com/ipsilon/evmone/archive/ba22a659174e.tar.gz" \
    | tar -xz --strip-components=1 -C "$ROOT/.cache/evmone"
fi
cmake -S "$ROOT/.cache/evmone" -B "$ROOT/.cache/evmone/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DEVMONE_TOOLS=ON \
  -DEVMONE_TESTING=OFF \
  -DEVMONE_PRECOMPILES_LIBSECP256K1=ON \
  -DCMAKE_PROJECT_evmone_INCLUDE="$ROOT/runners/cpp-evmone/compare_target.cmake"
cmake --build "$ROOT/.cache/evmone/build" --target compare-evmone -j8
cp "$ROOT/.cache/evmone/build/compare-evmone" "$BIN_DIR/compare-evmone"
rm -rf "$ROOT/.cache/evmone/build"

echo "==> [7/7] Building Go runners (gevm + geth) and optional revmc (LLVM 22)"
(cd "$ROOT/runners/go-evms" && go build -o "$BIN_DIR/compare-gevm" ./cmd/gevm && go build -o "$BIN_DIR/compare-geth" ./cmd/geth)

LLVM22_PREFIX="${LLVM_SYS_221_PREFIX:-/opt/homebrew/opt/llvm@22}"
if [ -d "$LLVM22_PREFIX" ]; then
  PATH="$LLVM22_PREFIX/bin:$PATH" LLVM_SYS_221_PREFIX="$LLVM22_PREFIX" RUSTFLAGS="-C target-cpu=native" \
    cargo build --release --manifest-path "$ROOT/runners/rust-revmc/Cargo.toml"
  cp "$ROOT/runners/rust-revmc/target/release/compare-revmc" "$BIN_DIR/compare-revmc"
  rm -rf "$ROOT/runners/rust-revmc/target"
fi

echo "==> All benchmark binaries built in $BIN_DIR and zig-out/bin/guillotine-compare"
