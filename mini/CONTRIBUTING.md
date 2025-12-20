# Contributing to Guillotine Mini

Thanks for helping improve Guillotine Mini. This guide covers setup, workflows, and conventions so you can be productive quickly.

## Prerequisites

- Zig `0.15.1` or later
- Cargo (Rust build tool) - required for cryptographic dependencies
- Python `3.10+`
- uv (Python package manager): `brew install uv`
- Bun (TypeScript scripts/agents): `brew install bun`
- macOS or Linux (tested on macOS/arm64)

## One‑Time Setup

```bash
# Fetch execution-specs submodule for test generation
git submodule update --init execution-specs

# Ensure Python deps and virtualenv for execution-specs are created on first fill
uv --version  # should print a version

# Scripts/agents dependencies
cd scripts && bun install && cd -
```

## Build And Test

```bash
# Build library + modules
zig build

# Run all tests (unit + spec tests)
zig build test

# Run execution-spec tests (generation happens automatically)
zig build specs

# Interactive runner
zig build test-watch

# Build WASM + show size
zig build wasm
```

## Running Spec Subsets (fast iteration)

We provide granular targets to iterate quickly:

```bash
# Berlin
zig build specs-berlin-acl
zig build specs-berlin-intrinsic-gas-cost
zig build specs-berlin-intrinsic-type0
zig build specs-berlin-intrinsic-type1

# Frontier
zig build specs-frontier-precompiles
zig build specs-frontier-identity
zig build specs-frontier-create
zig build specs-frontier-call
zig build specs-frontier-calldata
zig build specs-frontier-dup
zig build specs-frontier-push
zig build specs-frontier-stack
zig build specs-frontier-opcodes

# Shanghai
zig build specs-shanghai-push0
zig build specs-shanghai-warmcoinbase
zig build specs-shanghai-initcode
zig build specs-shanghai-withdrawals

# Cancun
zig build specs-cancun-tstore-basic
zig build specs-cancun-tstore-reentrancy
zig build specs-cancun-tstore-contexts
zig build specs-cancun-mcopy
zig build specs-cancun-selfdestruct
zig build specs-cancun-blobbasefee
zig build specs-cancun-blob-precompile
zig build specs-cancun-blob-opcodes
zig build specs-cancun-blob-tx-small
zig build specs-cancun-blob-tx-subtraction
zig build specs-cancun-blob-tx-insufficient
zig build specs-cancun-blob-tx-sufficient
zig build specs-cancun-blob-tx-valid-combos

# Prague
zig build specs-prague-calldata-cost-type0
zig build specs-prague-calldata-cost-type1-2
zig build specs-prague-calldata-cost-type3
zig build specs-prague-calldata-cost-type4
zig build specs-prague-calldata-cost-refunds
zig build specs-prague-bls-g1
zig build specs-prague-bls-g2
zig build specs-prague-bls-pairing
zig build specs-prague-bls-map
zig build specs-prague-bls-misc
zig build specs-prague-setcode-calls
zig build specs-prague-setcode-gas
zig build specs-prague-setcode-txs
zig build specs-prague-setcode-advanced

# Osaka
zig build specs-osaka-modexp-variable-gas
zig build specs-osaka-modexp-vectors-eip
zig build specs-osaka-modexp-vectors-legacy
zig build specs-osaka-modexp-misc
zig build specs-osaka-other
```

You can also filter tests with an environment variable:

```bash
TEST_FILTER="transStorageReset" zig build specs
TEST_FILTER="vmIOandFlowOperations" zig build specs
```

## Diff + Trace (E2E)

On spec failures, the runner automatically:
- Captures an EIP‑3155 trace from our EVM
- Generates a reference trace using the Python `ethereum-spec-evm`
- Compares them and prints the divergence point

Capture an end‑to‑end divergence log to a file:

```bash
# Example: run a likely-failing VM test and tee output
TEST_SEQUENTIAL=1 TEST_FILTER="vmIOandFlowOperations" \
  zig build specs | tee reports/divergence_example.log

# Search the log for divergence prints
rg -n "Trace Divergence|Difference in|Our EVM|Reference" reports/divergence_example.log
```

You can also validate tracing independently:

```bash
zig build test-trace
cat trace_test.json | head -n 10
```

Tip: Generation prints are verbose. Using `TEST_FILTER` to reduce to a few tests keeps logs manageable.

## AI-Assisted Fixer (Optional)

```bash
cd scripts && bun install
export ANTHROPIC_API_KEY=sk-ant-…

# Run a single suite (recommended)
bun run ../scripts/fix-specs.ts suite shanghai-push0

# Or run all suites (long)
bun run ../scripts/fix-specs.ts
```

If `ANTHROPIC_API_KEY` is not set, the script still runs tests but skips auto‑fix attempts with a clear notice.

## Conventions

- Keep changes minimal and focused; avoid drive‑by refactors
- Preserve behavior across hardforks; gate with `hardfork.isAtLeast()`
- Prefer fixing root causes (gas constants, warm/cold access) over patching symptoms
- Use `scripts/test-subset.sh` while iterating; run full `zig build specs` before PRs
- Commit messages: conventional style (e.g., `fix: correct CALL memory expansion for Cancun`)

## Known Status

The EVM currently passes most tests. Some failure is expected in deep/future suites; that’s acceptable while we focus on runner stability, trace/diff quality, and developer ergonomics.

