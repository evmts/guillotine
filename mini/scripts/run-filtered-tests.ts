#!/usr/bin/env bun
/**
 * Simple filtered test runner
 * Usage: bun scripts/run-filtered-tests.ts <filter_pattern>
 *
 * Examples:
 *   bun scripts/run-filtered-tests.ts push0
 *   bun scripts/run-filtered-tests.ts transientStorage
 *   bun scripts/run-filtered-tests.ts Cancun
 */

const args = process.argv.slice(2);
const filter = args[0];

if (!filter) {
  console.log('Usage: bun scripts/run-filtered-tests.ts <filter_pattern>\n');
  console.log('Examples:');
  console.log('  bun scripts/run-filtered-tests.ts push0              # Run all push0 tests');
  console.log('  bun scripts/run-filtered-tests.ts transientStorage   # Run transient storage tests');
  console.log('  bun scripts/run-filtered-tests.ts Cancun             # Run all Cancun tests');
  console.log('  bun scripts/run-filtered-tests.ts Shanghai           # Run all Shanghai tests');
  console.log('  bun scripts/run-filtered-tests.ts MCOPY              # Run MCOPY tests');
  console.log('  bun scripts/run-filtered-tests.ts "add"              # Run specific test like "add"');
  process.exit(1);
}

console.log(`Running tests matching: ${filter}`);
console.log('='.repeat(60));

// Run tests with Zig's test filter
const proc = Bun.spawn(['zig', 'build', 'specs', '--', '--test-filter', filter, '--summary', 'all'], {
  stdout: 'inherit',
  stderr: 'inherit',
});

const exitCode = await proc.exited;

console.log();
console.log('='.repeat(60));
console.log(`Test run complete for filter: ${filter}`);

process.exit(exitCode);
