#!/bin/bash
# Helper script to run filtered subsets of execution-spec tests
# Usage: ./scripts/run-filtered-tests.sh <filter_pattern>

set -e

FILTER="${1:-}"

if [ -z "$FILTER" ]; then
    echo "Usage: $0 <filter_pattern>"
    echo ""
    echo "Examples:"
    echo "  $0 push0              # Run all push0 tests"
    echo "  $0 transientStorage   # Run transient storage tests"
    echo "  $0 Cancun             # Run all Cancun tests"
    echo "  $0 Shanghai           # Run all Shanghai tests"
    echo "  $0 MCOPY              # Run MCOPY tests"
    echo "  $0 'add'              # Run specific test like 'add'"
    exit 1
fi

echo "Running tests matching: $FILTER"
echo "========================================"

# Use Zig's test filter to run only matching tests
# The --summary all flag gives detailed output
zig build specs -- --test-filter "$FILTER" --summary all

echo ""
echo "========================================"
echo "Test run complete for filter: $FILTER"
