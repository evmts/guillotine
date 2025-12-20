#!/bin/bash
# Helper script to debug a specific test with trace output
# Usage: ./scripts/debug-test.sh <test_name>

set -e

TEST_NAME="${1:-}"

if [ -z "$TEST_NAME" ]; then
    echo "Usage: $0 <test_name>"
    echo ""
    echo "Examples:"
    echo "  $0 push0Gas           # Debug the push0Gas test"
    echo "  $0 transStorageOK     # Debug transStorageOK test"
    echo "  $0 'add'              # Debug the 'add' test"
    echo ""
    echo "This will:"
    echo "  1. Run only the specified test"
    echo "  2. Show trace divergence if test fails"
    echo "  3. Compare with reference implementation"
    exit 1
fi

echo "Debugging test: $TEST_NAME"
echo "========================================"
echo ""

# Run the specific test with full output
# Remove the log level override to see debug output
zig test test/specs/root.zig \
    --test-runner test_runner.zig \
    --deps evm,primitives \
    --mod "evm::src/evm.zig" \
    --mod "primitives::src/primitives.zig" \
    --test-filter "$TEST_NAME" \
    2>&1

echo ""
echo "========================================"
echo "Debug run complete for: $TEST_NAME"
