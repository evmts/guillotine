#!/bin/bash

set -Eeuo pipefail

if [[ "${TRACE:-}" == "1" ]]; then
  set -x
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
LOG_DIR="${ROOT_DIR}/bench/official"
LOG_FILE="${LOG_DIR}/last-run.log"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(timestamp)] $*" | tee -a "${LOG_FILE}"; }

trap 'log "ERROR: Command failed (exit=$?) at line ${LINENO}: ${BASH_COMMAND}"' ERR

mkdir -p "${LOG_DIR}"
echo > "${LOG_FILE}"

log "Starting perf-fastest.sh"
log "ROOT_DIR=${ROOT_DIR}"

# Environment diagnostics
log "System: $(uname -a)"
if command -v zig >/dev/null 2>&1; then log "zig: $(zig version)"; else log "zig: NOT FOUND"; fi
if command -v rustc >/dev/null 2>&1; then log "rustc: $(rustc --version)"; else log "rustc: NOT FOUND"; fi
if command -v cargo >/dev/null 2>&1; then log "cargo: $(cargo --version)"; else log "cargo: NOT FOUND"; fi
if command -v bun >/dev/null 2>&1; then log "bun: $(bun --version)"; else log "bun: NOT FOUND (ethereumjs runner will fail)"; fi
if command -v hyperfine >/dev/null 2>&1; then log "hyperfine: $(hyperfine --version)"; else log "hyperfine: NOT FOUND (benchmarks will not run)"; fi

# Git diagnostics (best-effort)
if command -v git >/dev/null 2>&1 && git -C "${ROOT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_BRANCH=$(git -C "${ROOT_DIR}" rev-parse --abbrev-ref HEAD || echo "unknown")
  GIT_COMMIT=$(git -C "${ROOT_DIR}" rev-parse --short HEAD || echo "unknown")
  GIT_STATUS=$(git -C "${ROOT_DIR}" status --porcelain || true)
  log "git: branch=${GIT_BRANCH} commit=${GIT_COMMIT} dirty=$([[ -n "${GIT_STATUS}" ]] && echo yes || echo no)"
fi

# Preflight: check known runner locations used by orchestrator (relative to repo root)
REVM_RUNNER="${ROOT_DIR}/bench/official/evms/revm/target/release/revm-runner"
GETH_RUNNER="${ROOT_DIR}/bench/official/evms/geth/runner"
EVMONE_RUNNER="${ROOT_DIR}/bench/official/evms/evmone/build/evmone-runner"
ETHJS_RUNNER="${ROOT_DIR}/bench/official/evms/ethereumjs/runner.js"
ZIG_RUNNER="${ROOT_DIR}/zig-out/bin/evm-runner"
ZIG_RUNNER_SMALL="${ROOT_DIR}/zig-out/bin/evm-runner-small"
for path in \
  "${REVM_RUNNER}" \
  "${GETH_RUNNER}" \
  "${EVMONE_RUNNER}" \
  "${ETHJS_RUNNER}" \
  "${ZIG_RUNNER}" \
  "${ZIG_RUNNER_SMALL}"; do
  if [[ ! -e "${path}" ]]; then
    log "NOTE: Runner missing: ${path}"
  else
    log "Found runner: ${path}"
  fi
done

log "Building Zig runners (ReleaseFast and ReleaseSmall)"
time zig build build-evm-runner -Doptimize=ReleaseFast 2>&1 | tee -a "${LOG_FILE}"
time zig build build-evm-runner-small -Doptimize=ReleaseSmall 2>&1 | tee -a "${LOG_FILE}"

log "Building orchestrator (ReleaseFast)"
time zig build build-orchestrator -Doptimize=ReleaseFast 2>&1 | tee -a "${LOG_FILE}"

ORCH_BIN="${ROOT_DIR}/zig-out/bin/orchestrator"
if [[ ! -x "${ORCH_BIN}" ]]; then
  log "ERROR: Orchestrator binary not found: ${ORCH_BIN}"
  exit 1
fi

log "Running orchestrator with compare mode (single run per case)"
log "Command: ${ORCH_BIN} --compare --export markdown --num-runs 1 --js-runs 1 --internal-runs 1 --js-internal-runs 1 --snailtracer-internal-runs 1 --js-snailtracer-internal-runs 1"
time "${ORCH_BIN}" \
  --compare \
  --export markdown \
  --num-runs 1 \
  --js-runs 1 \
  --internal-runs 1 \
  --js-internal-runs 1 \
  --snailtracer-internal-runs 1 \
  --js-snailtracer-internal-runs 1 \
  2>&1 | tee -a "${LOG_FILE}"

RESULTS_MD="${ROOT_DIR}/bench/official/results.md"
if [[ -f "${RESULTS_MD}" ]]; then
  log "Benchmark results written to: ${RESULTS_MD}"
else
  log "WARNING: Results file not found at expected location: ${RESULTS_MD}"
fi

log "Opening results in browser..."
npx -y markserv "./bench/official/results.md"

