#!/bin/bash
# Generate all test fixtures and Zig test wrappers
# This script runs the full test generation pipeline:
# 1. Fill JSON fixtures from Python tests (~40k tests, takes 2-4 hours)
# 2. Generate Zig test wrappers for each JSON
# 3. Update test/specs/root.zig with imports

set -e  # Exit on error

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "==================================="
echo "Ethereum Execution Specs Test Generation"
echo "==================================="
echo ""

# Step 1: Fill JSON test fixtures
echo "[1/3] Generating JSON test fixtures from Python tests..."
echo "This will generate ~40,000 test fixtures and may take 2-4 hours."
echo "You can monitor progress in execution-specs/logs/"
echo ""
cd execution-specs
uv run --extra fill --extra test fill tests/eest --output tests/eest/static/state_tests --clean
cd "$REPO_ROOT"

# Count generated fixtures
FIXTURE_COUNT=$(find execution-specs/tests/eest/static/state_tests -name "*.json" -type f | wc -l | tr -d ' ')
echo "Generated $FIXTURE_COUNT JSON test fixtures"
echo ""

# Step 2: Generate Zig test wrappers
echo "[2/3] Generating Zig test wrappers..."
python3 scripts/generate_spec_tests.py

# Count generated Zig files
ZIG_COUNT=$(find test/specs/generated -name "*.zig" -type f | wc -l | tr -d ' ')
echo "Generated $ZIG_COUNT Zig test files"
echo ""

# Step 3: Update root.zig
echo "[3/3] Updating test/specs/root.zig..."
python3 scripts/update_spec_root.py
echo ""

echo "==================================="
echo "Test generation complete!"
echo "Generated $FIXTURE_COUNT JSON fixtures and $ZIG_COUNT Zig test files"
echo ""
echo "You can now run:"
echo "  zig build test       - Run all tests"
echo "  zig build specs      - Run spec tests only"
echo "  zig build test-watch - Interactive test runner"
echo "==================================="
