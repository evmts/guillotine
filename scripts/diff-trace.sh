#!/bin/bash

set -Eeuo pipefail

if [[ "${TRACE:-}" == "1" ]]; then
  set -x
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
LOG_DIR="${ROOT_DIR}/bench/official"
LOG_FILE="${LOG_DIR}/diff-trace.log"
DIFF_OUTPUT_DIR="${LOG_DIR}/diff_output"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(timestamp)] $*" | tee -a "${LOG_FILE}"; }

trap 'log "ERROR: Command failed (exit=$?) at line ${LINENO}: ${BASH_COMMAND}"' ERR

mkdir -p "${LOG_DIR}"
echo > "${LOG_FILE}"

log "Starting diff-trace.sh"
log "ROOT_DIR=${ROOT_DIR}"
log "DIFF_OUTPUT_DIR=${DIFF_OUTPUT_DIR}"

# Environment diagnostics
log "System: $(uname -a)"
if command -v zig >/dev/null 2>&1; then log "zig: $(zig version)"; else log "zig: NOT FOUND"; fi
if command -v rustc >/dev/null 2>&1; then log "rustc: $(rustc --version)"; else log "rustc: NOT FOUND"; fi
if command -v cargo >/dev/null 2>&1; then log "cargo: $(cargo --version)"; else log "cargo: NOT FOUND"; fi

# Git diagnostics (best-effort)
if command -v git >/dev/null 2>&1 && git -C "${ROOT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_BRANCH=$(git -C "${ROOT_DIR}" rev-parse --abbrev-ref HEAD || echo "unknown")
  GIT_COMMIT=$(git -C "${ROOT_DIR}" rev-parse --short HEAD || echo "unknown")
  GIT_STATUS=$(git -C "${ROOT_DIR}" status --porcelain || true)
  log "git: branch=${GIT_BRANCH} commit=${GIT_COMMIT} dirty=$([[ -n "${GIT_STATUS}" ]] && echo yes || echo no)"
fi

# Parse command line arguments
TEST_CASE="${1:-ten-thousand-hashes}"
log "Test case: ${TEST_CASE}"

# Build REVM runner in release mode (it doesn't need tracing flag)
log "Building REVM runner (release mode)"
(cd "${ROOT_DIR}/bench/official/evms/revm" && cargo build --release) 2>&1 | tee -a "${LOG_FILE}"

REVM_RUNNER="${ROOT_DIR}/bench/official/evms/revm/target/release/revm-runner"
if [[ ! -x "${REVM_RUNNER}" ]]; then
  log "ERROR: REVM runner not found: ${REVM_RUNNER}"
  exit 1
fi

# Build Zig runner in debug mode with tracing enabled
log "Building Zig runner (Debug mode with tracing enabled)"
time zig build build-evm-runner -Doptimize=Debug -Denable-tracing=true 2>&1 | tee -a "${LOG_FILE}"

ZIG_RUNNER="${ROOT_DIR}/zig-out/bin/evm-runner"
if [[ ! -x "${ZIG_RUNNER}" ]]; then
  log "ERROR: Zig runner not found: ${ZIG_RUNNER}"
  exit 1
fi

# Build orchestrator in debug mode
log "Building orchestrator (Debug mode)"
time zig build build-orchestrator -Doptimize=Debug 2>&1 | tee -a "${LOG_FILE}"

ORCH_BIN="${ROOT_DIR}/zig-out/bin/orchestrator"
if [[ ! -x "${ORCH_BIN}" ]]; then
  log "ERROR: Orchestrator binary not found: ${ORCH_BIN}"
  exit 1
fi

# Clean previous diff output
if [[ -d "${DIFF_OUTPUT_DIR}" ]]; then
  log "Cleaning previous diff output directory"
  rm -rf "${DIFF_OUTPUT_DIR}"
fi
mkdir -p "${DIFF_OUTPUT_DIR}"

# Run differential trace
log "Running differential trace for test case: ${TEST_CASE}"
log "Command: ${ORCH_BIN} --diff ${TEST_CASE} --diff-output ${DIFF_OUTPUT_DIR}"
time "${ORCH_BIN}" \
  --diff "${TEST_CASE}" \
  --diff-output "${DIFF_OUTPUT_DIR}" \
  2>&1 | tee -a "${LOG_FILE}"

# Check results
DIVERGENCE_FILE="${DIFF_OUTPUT_DIR}/${TEST_CASE}_divergence.txt"
REVM_TRACE="${DIFF_OUTPUT_DIR}/${TEST_CASE}_revm_trace.json"
ZIG_TRACE="${DIFF_OUTPUT_DIR}/${TEST_CASE}_zig_trace.json"

if [[ -f "${DIVERGENCE_FILE}" ]]; then
  log "Divergence analysis written to: ${DIVERGENCE_FILE}"
  echo ""
  echo "=== DIVERGENCE SUMMARY ==="
  cat "${DIVERGENCE_FILE}"
  echo "=========================="
else
  log "WARNING: Divergence file not found: ${DIVERGENCE_FILE}"
fi

# Report trace file sizes
if [[ -f "${REVM_TRACE}" ]]; then
  REVM_SIZE=$(stat -f%z "${REVM_TRACE}" 2>/dev/null || stat -c%s "${REVM_TRACE}" 2>/dev/null || echo "unknown")
  log "REVM trace size: ${REVM_SIZE} bytes"
else
  log "WARNING: REVM trace not found: ${REVM_TRACE}"
fi

if [[ -f "${ZIG_TRACE}" ]]; then
  ZIG_SIZE=$(stat -f%z "${ZIG_TRACE}" 2>/dev/null || stat -c%s "${ZIG_TRACE}" 2>/dev/null || echo "unknown")
  log "Zig trace size: ${ZIG_SIZE} bytes"
else
  log "WARNING: Zig trace not found: ${ZIG_TRACE}"
fi

log "Differential trace complete"
log "Full log available at: ${LOG_FILE}"