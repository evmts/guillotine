#!/usr/bin/env bun
/**
 * Quick Test Script
 * Runs a small subset of tests for rapid iteration
 *
 * Usage: bun scripts/quick-test.ts
 */

import { $ } from "bun";

const colors = {
  GREEN: '\x1b[0;32m',
  RED: '\x1b[0;31m',
  RESET: '\x1b[0m',
};

console.log('Running quick smoke tests...\n');

// Representative tests from different categories
const tests = [
  'add',
  'push0',
  'transStorageOK',
];

let passed = 0;
let failed = 0;

for (const test of tests) {
  console.log(`Testing: ${test}`);

  try {
    const result = await $`zig build specs -- --test-filter ${test}`.quiet();
    const output = result.text();

    if (output.includes('All 1 tests passed') || output.includes('tests passed')) {
      console.log(`  ${colors.GREEN}✓ Passed${colors.RESET}`);
      passed++;
    } else {
      console.log(`  ${colors.RED}✗ Failed${colors.RESET}`);
      failed++;
    }
  } catch (e) {
    console.log(`  ${colors.RED}✗ Failed${colors.RESET}`);
    failed++;
  }

  console.log();
}

console.log('━'.repeat(60));
console.log(`Quick test summary: ${passed} passed, ${failed} failed`);
console.log('━'.repeat(60));

process.exit(failed > 0 ? 1 : 0);
