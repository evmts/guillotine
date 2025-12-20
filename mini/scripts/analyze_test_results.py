#!/usr/bin/env python3
"""
Analyze Ethereum spec test results to identify patterns in failures.
"""

import re
import sys
from collections import defaultdict
from pathlib import Path

def analyze_test_results(log_file):
    """Parse test results and categorize failures."""

    with open(log_file, 'r') as f:
        content = f.read()

    # Extract test results
    # Zig test output format: "test.test_name...OK" or "test.test_name...FAIL"

    passed = []
    failed = []

    # Pattern for test results
    # Looking for lines like: "test.ethereum_tests.stExample.test_name...OK"
    test_pattern = r'test\.([^\s]+)\.\.\.(?:OK|FAIL)'

    for match in re.finditer(test_pattern, content):
        test_name = match.group(1)
        status = match.group(0).split('...')[-1]

        if status == 'OK':
            passed.append(test_name)
        else:
            failed.append(test_name)

    # Categorize by test type
    categories = defaultdict(lambda: {'passed': 0, 'failed': 0})

    for test in passed:
        category = extract_category(test)
        categories[category]['passed'] += 1

    for test in failed:
        category = extract_category(test)
        categories[category]['failed'] += 1

    # Print summary
    print("=" * 80)
    print("ETHEREUM SPEC TEST RESULTS SUMMARY")
    print("=" * 80)
    print()

    total_passed = len(passed)
    total_failed = len(failed)
    total_tests = total_passed + total_failed

    print(f"Total Tests: {total_tests}")
    print(f"Passed: {total_passed} ({100 * total_passed / total_tests if total_tests > 0 else 0:.1f}%)")
    print(f"Failed: {total_failed} ({100 * total_failed / total_tests if total_tests > 0 else 0:.1f}%)")
    print()

    print("=" * 80)
    print("BREAKDOWN BY CATEGORY")
    print("=" * 80)
    print()

    # Sort by total tests
    sorted_categories = sorted(
        categories.items(),
        key=lambda x: x[1]['passed'] + x[1]['failed'],
        reverse=True
    )

    for category, counts in sorted_categories:
        total = counts['passed'] + counts['failed']
        pass_rate = 100 * counts['passed'] / total if total > 0 else 0

        print(f"{category:40} {counts['passed']:4}/{total:4} ({pass_rate:5.1f}%)")

    print()
    print("=" * 80)
    print("TOP FAILING CATEGORIES (by count)")
    print("=" * 80)
    print()

    sorted_by_failures = sorted(
        categories.items(),
        key=lambda x: x[1]['failed'],
        reverse=True
    )

    for category, counts in sorted_by_failures[:20]:
        if counts['failed'] > 0:
            print(f"{category:40} {counts['failed']:4} failures")

    return {
        'total': total_tests,
        'passed': total_passed,
        'failed': total_failed,
        'categories': dict(categories)
    }

def extract_category(test_name):
    """Extract category from test name."""

    # test_name format examples:
    # - "ethereum_tests.stExample.test_add"
    # - "execution-specs.arithmetic.test_mul"

    parts = test_name.split('.')

    if len(parts) >= 2:
        # Use second part as category (e.g., "stExample" or "arithmetic")
        return parts[1]

    return 'unknown'

if __name__ == '__main__':
    if len(sys.argv) > 1:
        log_file = sys.argv[1]
    else:
        log_file = 'test_results.log'

    if not Path(log_file).exists():
        print(f"Error: Log file not found: {log_file}")
        sys.exit(1)

    analyze_test_results(log_file)
