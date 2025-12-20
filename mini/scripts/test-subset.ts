#!/usr/bin/env bun
/**
 * Test Subset Runner - Run filtered execution-spec tests
 *
 * Usage:
 *   bun scripts/test-subset.ts [FILTER]
 *   TEST_FILTER=<pattern> bun scripts/test-subset.ts
 *   bun scripts/test-subset.ts --list
 *
 * Examples:
 *   bun scripts/test-subset.ts push0
 *   bun scripts/test-subset.ts transientStorage
 *   bun scripts/test-subset.ts Cancun
 *   TEST_FILTER=Shanghai bun scripts/test-subset.ts
 */

import { $ } from "bun";
import { existsSync } from "fs";
import { readFile } from "fs/promises";

const colors = {
  GREEN: '\x1b[0;32m',
  RED: '\x1b[0;31m',
  BLUE: '\x1b[0;34m',
  YELLOW: '\x1b[1;33m',
  RESET: '\x1b[0m',
};

function showHelp() {
  console.log(`Test Subset Runner - Run filtered execution-spec tests

USAGE:
    bun scripts/test-subset.ts [FILTER]
    TEST_FILTER=<pattern> bun scripts/test-subset.ts

EXAMPLES:
    # Run by argument
    bun scripts/test-subset.ts push0
    bun scripts/test-subset.ts transientStorage
    bun scripts/test-subset.ts Cancun

    # Run by environment variable
    TEST_FILTER=Shanghai bun scripts/test-subset.ts
    TEST_FILTER=MCOPY bun scripts/test-subset.ts

    # List available test categories
    bun scripts/test-subset.ts --list

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
`);
}

async function listTests() {
  console.log('Available test categories (from test/specs/root.zig):\n');
  console.log('HARDFORKS:');
  console.log('  - Cancun');
  console.log('  - Shanghai\n');

  if (existsSync('test/specs/root.zig')) {
    try {
      const content = await readFile('test/specs/root.zig', 'utf-8');

      // Extract GeneralStateTests paths
      const stateTests = [...content.matchAll(/GeneralStateTests\/([^\/]+)\/([^\/]+)\//g)]
        .map(m => `${m[1]}/${m[2]}`)
        .filter((v, i, a) => a.indexOf(v) === i)
        .sort();

      if (stateTests.length > 0) {
        console.log('TEST SUITES:');
        stateTests.forEach(test => console.log(`  - ${test}`));
        console.log();
      }

      // Extract VMTests paths
      const vmTests = [...content.matchAll(/VMTests\/([^\/]+)\//g)]
        .map(m => m[1])
        .filter((v, i, a) => a.indexOf(v) === i)
        .sort();

      if (vmTests.length > 0) {
        console.log('VM TESTS:');
        vmTests.forEach(test => console.log(`  - ${test}`));
      }
    } catch (e) {
      console.error('Error reading test/specs/root.zig:', e);
    }
  }
}

// Get filter from argument or environment
const args = process.argv.slice(2);
const filter = args[0] || process.env.TEST_FILTER || '';

if (filter === '--help' || filter === '-h') {
  showHelp();
  process.exit(0);
}

if (filter === '--list' || filter === '-l') {
  await listTests();
  process.exit(0);
}

if (!filter) {
  console.log(`${colors.RED}Error: No filter specified${colors.RESET}\n`);
  showHelp();
  process.exit(1);
}

console.log('━'.repeat(60));
console.log(`Running tests matching: '${colors.BLUE}${filter}${colors.RESET}'`);
console.log('━'.repeat(60));
console.log();

// Run tests with filter
try {
  const proc = Bun.spawn(['zig', 'build', 'specs', '--', '--test-filter', filter], {
    stdout: 'inherit',
    stderr: 'inherit',
  });

  const exitCode = await proc.exited;

  console.log();
  console.log('━'.repeat(60));
  if (exitCode === 0) {
    console.log(`${colors.GREEN}✅ All tests passed for filter: '${filter}'${colors.RESET}`);
  } else {
    console.log(`${colors.RED}❌ Some tests failed for filter: '${filter}'${colors.RESET}`);
    console.log();
    console.log(`${colors.YELLOW}TIP: Check trace divergence output above for debugging details${colors.RESET}`);
    console.log(`${colors.YELLOW}TIP: Use 'bun scripts/isolate-test.ts "<test_name>"' for detailed analysis${colors.RESET}`);
  }
  console.log('━'.repeat(60));

  process.exit(exitCode);
} catch (e) {
  console.error(`${colors.RED}Error running tests:${colors.RESET}`, e);
  process.exit(1);
}
