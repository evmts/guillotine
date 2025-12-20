#!/bin/bash

# Automated Test Fix Pipeline
# This script coordinates the test fixing process

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "🎯 Automated Test Fix Pipeline"
echo "================================"
echo ""

# Check if failed_tests.txt exists
if [ ! -f "failed_tests.txt" ]; then
    echo "❌ failed_tests.txt not found"
    echo ""
    echo "To generate it, run:"
    echo "  zig build specs 2>&1 | tee test_results.log"
    echo "  grep 'FAIL.*›' test_results.log | sed -E 's/.*› //; s/\x1b\[[0-9;]*m//g' | sort -u > failed_tests.txt"
    echo ""
    exit 1
fi

# Count failed tests
FAILED_COUNT=$(wc -l < failed_tests.txt | tr -d ' ')
echo "📋 Found $FAILED_COUNT failed tests"
echo ""

# Ask for confirmation
read -p "Start fixing tests with 8 concurrent agents? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted"
    exit 0
fi

# Run the TypeScript pipeline
echo ""
echo "🚀 Starting test fix pipeline..."
echo ""

cd scripts
bun fix-tests.ts ../failed_tests.txt
