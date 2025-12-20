#!/usr/bin/env bash
# Test Isolation Helper
# Usage: ./scripts/isolate-test.sh <test_name> [build_target]
#
# Runs a single test with maximum debugging output including:
# - Verbose tracing enabled
# - Trace divergence comparison
# - Full gas calculation details
# - Stack/memory/storage state
#
# Examples:
#   ./scripts/isolate-test.sh "transientStorageReset"
#   ./scripts/isolate-test.sh "push0" specs-shanghai-push0
#   ./scripts/isolate-test.sh "MCOPY" specs-cancun-mcopy

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
RESET='\033[0m'

# Function to print colored output
print_header() {
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${CYAN}${BOLD}$1${RESET}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

print_info() {
    echo -e "${BLUE}ℹ${RESET} $1"
}

print_success() {
    echo -e "${GREEN}✓${RESET} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${RESET} $1"
}

print_error() {
    echo -e "${RED}✗${RESET} $1"
}

print_section() {
    echo ""
    echo -e "${MAGENTA}${BOLD}▶ $1${RESET}"
    echo -e "${MAGENTA}$(printf '─%.0s' {1..80})${RESET}"
}

# Check arguments
if [ -z "$1" ]; then
    echo -e "${RED}${BOLD}Error: Test name required${RESET}"
    echo ""
    echo "Usage: $0 <test_name> [build_target]"
    echo ""
    echo "Examples:"
    echo "  $0 \"transientStorageReset\""
    echo "  $0 \"push0\" specs-shanghai-push0"
    echo "  $0 \"MCOPY\" specs-cancun-mcopy"
    echo ""
    echo "To find test names:"
    echo "  zig build specs 2>&1 | grep -i <keyword>"
    echo "  grep -r \"test_name\" ethereum-tests/GeneralStateTests/"
    exit 1
fi

TEST_NAME="$1"
BUILD_TARGET="${2:-specs}"  # Default to 'specs' if not specified

# Get script directory and repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

# Print banner
print_header "🔬 Test Isolation Helper"
echo ""
print_info "Test name: ${BOLD}${TEST_NAME}${RESET}"
print_info "Build target: ${BOLD}${BUILD_TARGET}${RESET}"
print_info "Repo root: ${BOLD}${REPO_ROOT}${RESET}"
echo ""

# Step 1: Show matching tests
print_section "Step 1: Finding matching tests"
echo ""
print_info "Searching for tests matching '${TEST_NAME}'..."
echo ""

# Search in ethereum-tests directory
if [ -d "ethereum-tests/GeneralStateTests" ]; then
    echo -e "${CYAN}Tests found in ethereum-tests:${RESET}"
    find ethereum-tests/GeneralStateTests -name "*.json" -exec grep -l "$TEST_NAME" {} \; 2>/dev/null | head -10 || true
    echo ""
fi

# Step 2: Run isolated test with verbose output
print_section "Step 2: Running isolated test with verbose tracing"
echo ""
print_info "Command: TEST_FILTER=\"${TEST_NAME}\" zig build ${BUILD_TARGET}"
echo ""

# Create a temporary file to capture output
TEMP_OUTPUT=$(mktemp)
trap "rm -f $TEMP_OUTPUT" EXIT

# Run the test with filter
set +e  # Don't exit on test failure
TEST_FILTER="$TEST_NAME" zig build "$BUILD_TARGET" 2>&1 | tee "$TEMP_OUTPUT"
EXIT_CODE=${PIPESTATUS[0]}
set -e

echo ""

# Step 3: Analyze results
print_section "Step 3: Test Results Analysis"
echo ""

if [ $EXIT_CODE -eq 0 ]; then
    print_success "Test passed! ✨"
    echo ""
    print_info "No issues detected. The test is passing."
else
    print_error "Test failed (exit code: $EXIT_CODE)"
    echo ""

    # Analyze failure type
    if grep -q "segmentation fault\|Segmentation fault" "$TEMP_OUTPUT"; then
        print_warning "Failure type: ${BOLD}CRASH (Segmentation Fault)${RESET}"
        echo ""
        echo "This is a crash, not a logic error. Recommended debugging approach:"
        echo "  1. Use binary search with @panic(\"CHECKPOINT\") to find crash location"
        echo "  2. Run with: TEST_FILTER=\"$TEST_NAME\" zig build $BUILD_TARGET"
        echo "  3. See crash debugging guide in CLAUDE.md or fix-specs.ts"

    elif grep -q "panic\|unreachable" "$TEMP_OUTPUT"; then
        print_warning "Failure type: ${BOLD}CRASH (Panic/Unreachable)${RESET}"
        echo ""
        # Extract panic message
        PANIC_MSG=$(grep -A 2 "panic:" "$TEMP_OUTPUT" | head -3 || echo "")
        if [ -n "$PANIC_MSG" ]; then
            echo -e "${YELLOW}Panic message:${RESET}"
            echo "$PANIC_MSG"
            echo ""
        fi

    elif grep -q "Trace divergence\|trace divergence" "$TEMP_OUTPUT"; then
        print_warning "Failure type: ${BOLD}BEHAVIOR DIVERGENCE${RESET}"
        echo ""
        echo "The test runner detected execution trace differences."
        echo ""

        # Extract divergence details
        echo -e "${YELLOW}Divergence details:${RESET}"
        grep -A 10 "Trace divergence\|divergence at\|Expected.*Got" "$TEMP_OUTPUT" | head -20 || true
        echo ""

    elif grep -q "gas.*mismatch\|gas.*error\|expected.*gas\|actual.*gas" "$TEMP_OUTPUT" -i; then
        print_warning "Failure type: ${BOLD}GAS CALCULATION ERROR${RESET}"
        echo ""
        echo "Gas metering differs from expected behavior."
        echo ""

        # Extract gas details
        echo -e "${YELLOW}Gas details:${RESET}"
        grep -i "gas" "$TEMP_OUTPUT" | grep -i "expected\|actual\|mismatch\|error" | head -10 || true
        echo ""

    elif grep -q "output mismatch\|return.*mismatch\|state.*mismatch" "$TEMP_OUTPUT" -i; then
        print_warning "Failure type: ${BOLD}OUTPUT/STATE MISMATCH${RESET}"
        echo ""
        echo "Execution completed but produced wrong output or state."
        echo ""

    else
        print_warning "Failure type: ${BOLD}UNKNOWN${RESET}"
        echo ""
        echo "Could not automatically determine failure type."
        echo "Review the output above for details."
        echo ""
    fi

    # Extract test file location if possible
    TEST_FILE=$(grep -o "ethereum-tests/[^:]*\.json" "$TEMP_OUTPUT" | head -1 || echo "")
    if [ -n "$TEST_FILE" ]; then
        echo -e "${CYAN}Test file location:${RESET}"
        echo "  $TEST_FILE"
        echo ""

        if [ -f "$TEST_FILE" ]; then
            print_info "To inspect test JSON:"
            echo "  cat $TEST_FILE | jq '.\"$TEST_NAME\"'"
            echo ""
        fi
    fi
fi

# Step 4: Next steps guidance
print_section "Step 4: Next Steps"
echo ""

if [ $EXIT_CODE -eq 0 ]; then
    echo "✨ Test is passing. No further action needed."
else
    echo "Recommended debugging workflow:"
    echo ""
    echo "  ${BOLD}1. Re-run this test:${RESET}"
    echo "     ./scripts/isolate-test.sh \"$TEST_NAME\" $BUILD_TARGET"
    echo ""
    echo "  ${BOLD}2. Review trace output above${RESET} to identify:"
    echo "     - Divergence point (PC, opcode)"
    echo "     - Expected vs actual values"
    echo "     - Stack/memory/storage differences"
    echo ""
    echo "  ${BOLD}3. Read Python reference implementation:${RESET}"
    echo "     # Identify hardfork from test name/path"
    echo "     cd execution-specs/src/ethereum/forks/<hardfork>/vm/instructions/"
    echo "     # Find the diverging opcode function"
    echo ""
    echo "  ${BOLD}4. Compare with Zig implementation:${RESET}"
    echo "     # For opcodes:"
    echo "     grep -A 20 \"<opcode_name>\" src/frame.zig"
    echo "     # For calls/creates:"
    echo "     grep -A 20 \"inner_call\|inner_create\" src/evm.zig"
    echo ""
    echo "  ${BOLD}5. Fix the discrepancy${RESET} to match Python reference exactly"
    echo ""
    echo "  ${BOLD}6. Verify the fix:${RESET}"
    echo "     ./scripts/isolate-test.sh \"$TEST_NAME\" $BUILD_TARGET"
    echo ""
fi

# Step 5: Quick reference
print_section "Quick Reference"
echo ""
echo "Useful commands for this test:"
echo ""
echo "  ${BOLD}# Run just this test${RESET}"
echo "  TEST_FILTER=\"$TEST_NAME\" zig build $BUILD_TARGET"
echo ""
echo "  ${BOLD}# Run with specific hardfork${RESET}"
echo "  TEST_FILTER=\"$TEST_NAME\" zig build specs-<hardfork>"
echo ""
echo "  ${BOLD}# Search for test definition${RESET}"
echo "  find ethereum-tests -name '*.json' -exec grep -l \"$TEST_NAME\" {} \\;"
echo ""
echo "  ${BOLD}# Find related tests${RESET}"
echo "  find ethereum-tests -name '*.json' -exec grep -l \"${TEST_NAME:0:10}\" {} \\;"
echo ""
echo "  ${BOLD}# Check current test status in full suite${RESET}"
echo "  zig build $BUILD_TARGET 2>&1 | grep -C 3 \"$TEST_NAME\""
echo ""

print_header "🔬 Test Isolation Complete"
echo ""

exit $EXIT_CODE
