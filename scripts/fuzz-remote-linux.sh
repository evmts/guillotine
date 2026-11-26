#!/usr/bin/env bash
# Run Guillotine's coverage-guided Zig `--fuzz` suite, multi-threaded fuzz campaign,
# Rust BN254/BLS12-381 fuzz tests, and TypeScript SDK fuzz suite on an Ubuntu/Linux
# bare-metal Latitude host (default: `nyc-01`, 48 cores / 251 GiB RAM).
#
# Why Linux? Zig 0.15.x native `--fuzz` (LLVM coverage-guided in-process fuzzing)
# requires ELF debug info and runs natively on Linux (fails with InvalidElfMagic on macOS).
#
# Usage:
#   ./scripts/fuzz-remote-linux.sh                    # default: nyc-01, 60s campaign + --fuzz smoke
#   ./scripts/fuzz-remote-linux.sh --host=nyc-01 --seconds=300 --threads=32 --mode=all
#   ./scripts/fuzz-remote-linux.sh --mode=zig-fuzz --filter="fuzz differential" --seconds=120
#   ./scripts/fuzz-remote-linux.sh --mode=campaign --seconds=600 --threads=40

set -euo pipefail

HOST="${FUZZ_HOST:-nyc-01}"
REMOTE_DIR="${FUZZ_REMOTE_DIR:-~/guillotine-fuzz}"
SECONDS_BUDGET="${FUZZ_SECONDS:-60}"
THREADS="${FUZZ_THREADS:-16}"
MODE="${FUZZ_MODE:-all}"
FILTER="${FUZZ_FILTER:-}"
ZIG_VERSION="${ZIG_VERSION:-0.15.2}"

for arg in "$@"; do
  case "$arg" in
    --host=*) HOST="${arg#--host=}" ;;
    --remote-dir=*) REMOTE_DIR="${arg#--remote-dir=}" ;;
    --seconds=*) SECONDS_BUDGET="${arg#--seconds=}" ;;
    --threads=*) THREADS="${arg#--threads=}" ;;
    --mode=*) MODE="${arg#--mode=}" ;;
    --filter=*) FILTER="${arg#--filter=}" ;;
    --zig-version=*) ZIG_VERSION="${arg#--zig-version=}" ;;
    --help|-h)
      echo "Usage: $0 [--host=nyc-01] [--seconds=60] [--threads=16] [--mode=all|zig-fuzz|campaign|rust|ts] [--filter=PATTERN]"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

echo "[fuzz-remote] host=${HOST} remote_dir=${REMOTE_DIR} mode=${MODE} seconds=${SECONDS_BUDGET} threads=${THREADS}"

# 1. Sync repository to remote Linux host (excluding heavy local build caches)
rsync -az --delete \
  --exclude '.git/' \
  --exclude '.jj/' \
  --exclude '.zig-cache/' \
  --exclude '.zig-cache-verify/' \
  --exclude '.fuzz-crashes/' \
  --exclude 'zig-out/' \
  --exclude 'target/' \
  --exclude 'node_modules/' \
  --exclude 'sdks/typescript/node_modules/' \
  --exclude 'sdks/typescript/prebuilds/' \
  --exclude 'lib/voltaire/target/' \
  --exclude 'lib/voltaire/.zig-cache/' \
  --exclude 'bench/.zig-cache/' \
  --exclude 'specs/execution-specs/' \
  ./ "${HOST}:${REMOTE_DIR}/"

# 2. Ensure Zig 0.15.2 is installed in isolated ~/.local/opt/zig-${ZIG_VERSION} without touching host default zig
ssh "${HOST}" bash -s -- "${REMOTE_DIR}" "${ZIG_VERSION}" "${MODE}" "${SECONDS_BUDGET}" "${THREADS}" "${FILTER}" <<'REMOTE_EOF'
set -euo pipefail
REMOTE_DIR="$1"
ZIG_VERSION="$2"
MODE="$3"
SECONDS_BUDGET="$4"
THREADS="$5"
FILTER="$6"

export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.bun/bin:/usr/local/bin:$PATH"

ZIG_OPT="$HOME/.local/opt/zig-x86_64-linux-${ZIG_VERSION}"
ZIG_BIN="${ZIG_OPT}/zig"
if [ ! -x "${ZIG_BIN}" ]; then
  echo "[remote] installing Zig ${ZIG_VERSION} into ${ZIG_OPT}..."
  mkdir -p "$HOME/.local/opt"
  TARBALL="zig-x86_64-linux-${ZIG_VERSION}.tar.xz"
  curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/${TARBALL}" -o "/tmp/${TARBALL}"
  tar -xf "/tmp/${TARBALL}" -C "$HOME/.local/opt/"
  rm -f "/tmp/${TARBALL}"
fi

echo "[remote] zig: $(${ZIG_BIN} version) | cpus: $(nproc) | host: $(hostname)"
cd "${REMOTE_DIR}"

ensure_crypto_wrappers() {
  if [ ! -f "lib/voltaire/target/release/libcrypto_wrappers.a" ]; then
    echo "[remote] building Voltaire Rust crypto wrappers (libcrypto_wrappers.a)..."
    cargo build --manifest-path lib/voltaire/Cargo.toml --release
  fi
}

run_zig_corpus() {
  ensure_crypto_wrappers
  echo "[remote] === 1. Zig std.testing.fuzz corpus + leak check ==="
  if [ -n "${FILTER}" ]; then
    "${ZIG_BIN}" build test-fuzz -Dtest-filter="${FILTER}"
  else
    "${ZIG_BIN}" build test-fuzz
    echo "[remote] === 1b. guillotine-mini fuzz corpus ==="
    "${ZIG_BIN}" build test-mini-fuzz
  fi
}

run_zig_coverage_fuzz() {
  ensure_crypto_wrappers
  echo "[remote] === 2. Zig LLVM coverage-guided --fuzz (${SECONDS_BUDGET}s) ==="
  # Zig 0.15.2 --fuzz runs continuously until interrupted; bound cleanly with timeout (exit 124 = clean timeout, no crash!)
  local filter_args=()
  if [ -n "${FILTER}" ]; then
    filter_args=(-Dtest-filter="${FILTER}")
  else
    # Default to the differential EVM crown jewel if no filter specified
    filter_args=(-Dtest-filter="fuzz differential EVM execution")
  fi
  set +e
  timeout --signal=INT "${SECONDS_BUDGET}" "${ZIG_BIN}" build test-fuzz --fuzz "${filter_args[@]}"
  local rc=$?
  set -e
  if [ "${rc}" -ne 0 ] && [ "${rc}" -ne 124 ] && [ "${rc}" -ne 130 ]; then
    echo "[remote] ERROR: Zig --fuzz found a failure (exit=${rc})!" >&2
    exit "${rc}"
  fi
  echo "[remote] Zig --fuzz completed cleanly (no crashes or invariant violations in ${SECONDS_BUDGET}s)."
}

run_campaign() {
  ensure_crypto_wrappers
  echo "[remote] === 3. Multi-threaded structured fuzz campaign (${SECONDS_BUDGET}s, ${THREADS} threads) ==="
  local target_args=()
  if [ -n "${FILTER}" ]; then
    target_args=("--target=${FILTER}")
  fi
  "${ZIG_BIN}" build fuzz-campaign -- "--seconds=${SECONDS_BUDGET}" "--threads=${THREADS}" "${target_args[@]}"
}

run_rust() {
  echo "[remote] === 4. Rust BN254/BLS12-381 FFI fuzz & property tests ==="
  cargo test -p bn254_wrapper -- --nocapture
}

run_ts() {
  ensure_crypto_wrappers
  echo "[remote] === 5. TypeScript SDK live Bun FFI fuzz suite ==="
  "${ZIG_BIN}" build shared -Doptimize=ReleaseFast
  (cd sdks/typescript && GUILLOTINE_FUZZ_EXECS=1000 bun test test/fuzz/)
}

case "${MODE}" in
  all)
    run_zig_corpus
    run_campaign
    run_zig_coverage_fuzz
    run_rust
    run_ts
    ;;
  zig-fuzz)
    run_zig_coverage_fuzz
    ;;
  campaign)
    run_campaign
    ;;
  rust)
    run_rust
    ;;
  ts)
    run_ts
    ;;
  *)
    echo "Unknown mode: ${MODE}" >&2
    exit 1
    ;;
esac
REMOTE_EOF
