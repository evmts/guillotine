#!/bin/bash
# Quick test script - runs a very small subset of tests for rapid iteration
# Usage: ./scripts/quick-test.sh

set -e

echo "Running quick smoke tests..."
echo ""

# Run just a few representative tests from different categories
TESTS=(
    "add"
    "push0"
    "transStorageOK"
)

PASSED=0
FAILED=0

for test in "${TESTS[@]}"; do
    echo "Testing: $test"
    if zig build specs -- --test-filter "$test" 2>&1 | grep -q "All 1 tests passed"; then
        echo "  ✓ Passed"
        ((PASSED++))
    else
        echo "  ✗ Failed"
        ((FAILED++))
    fi
    echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Quick test summary: $PASSED passed, $FAILED failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ $FAILED -gt 0 ]; then
    exit 1
fi
