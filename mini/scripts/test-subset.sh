#!/bin/bash
# Comprehensive test subset runner with environment variable support
# Usage:
#   TEST_FILTER=push0 ./scripts/test-subset.sh
#   ./scripts/test-subset.sh push0
#   ./scripts/test-subset.sh --list

set -e

# Get filter from argument or environment
FILTER="${1:-${TEST_FILTER:-}}"

show_help() {
    cat <<EOF
Test Subset Runner - Run filtered execution-spec tests

USAGE:
    $0 [FILTER]
    TEST_FILTER=<pattern> $0

EXAMPLES:
    # Run by argument
    $0 push0
    $0 transientStorage
    $0 Cancun

    # Run by environment variable
    TEST_FILTER=Shanghai $0
    TEST_FILTER=MCOPY $0

    # List available test categories
    $0 --list

COMMON FILTERS:
    Cancun              - All Cancun hardfork tests
    Shanghai            - All Shanghai hardfork tests
    transientStorage    - EIP-1153 transient storage tests
    push0               - EIP-3855 PUSH0 tests
    MCOPY               - EIP-5656 MCOPY tests
    vmArithmetic        - Arithmetic operation tests
    add, sub, mul       - Specific opcodes

DEBUGGING:
    For detailed trace output on failures, the test runner automatically
    generates trace comparisons with the reference implementation.

EOF
}

list_tests() {
    echo "Available test categories (from test/specs/root.zig):"
    echo ""
    echo "HARDFORKS:"
    echo "  - Cancun"
    echo "  - Shanghai"
    echo ""
    echo "TEST SUITES:"
    grep -o 'GeneralStateTests/[^/]*/[^/]*/' test/specs/root.zig | sort -u | sed 's/GeneralStateTests\//  - /' | sed 's/\/$//'
    echo ""
    echo "VM TESTS:"
    grep -o 'VMTests/[^/]*/' test/specs/root.zig | sort -u | sed 's/VMTests\//  - /'
}

if [ "$FILTER" = "--help" ] || [ "$FILTER" = "-h" ]; then
    show_help
    exit 0
fi

if [ "$FILTER" = "--list" ] || [ "$FILTER" = "-l" ]; then
    list_tests
    exit 0
fi

if [ -z "$FILTER" ]; then
    echo "Error: No filter specified"
    echo ""
    show_help
    exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Running tests matching: '$FILTER'"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Run tests with filter and capture output
zig build specs -- --test-filter "$FILTER"

EXIT_CODE=$?

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ All tests passed for filter: '$FILTER'"
else
    echo "❌ Some tests failed for filter: '$FILTER'"
    echo ""
    echo "TIP: Check trace divergence output above for debugging details"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $EXIT_CODE
