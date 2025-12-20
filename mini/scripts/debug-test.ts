#!/usr/bin/env bun
/**
 * Debug Test Script
 * Debug a specific test with trace output
 *
 * Usage: bun scripts/debug-test.ts [options] <test_name_or_pattern>
 *
 * Options:
 *   --suite <suite_name>   Run test within a specific test suite (e.g., cancun-tstore-contexts-execution)
 *   --list                 List all available test suites
 *   --help                 Show this help message
 *
 * Examples:
 *   # Run a single test by exact name
 *   bun scripts/debug-test.ts "test_transient_storage_unset_values_000"
 *
 *   # Run a single test within a specific suite
 *   bun scripts/debug-test.ts --suite cancun-tstore-contexts-execution "test_transient_storage_unset_values"
 *
 *   # Run all tests matching a pattern
 *   bun scripts/debug-test.ts "transient_storage"
 *
 *   # List all available test suites
 *   bun scripts/debug-test.ts --list
 *
 * Test Name Format:
 *   Test names follow the pattern: tests_eest_<hardfork>_<eip>_<test_category>__<test_name>_fork_<Fork>_...
 *   Example: tests_eest_cancun_eip1153_tstore_test_tstorage_py__test_transient_storage_unset_values_fork_Cancun_blockchain_test_engine_from_state_test_
 *
 * Finding Test Names:
 *   You can find test names by:
 *   1. Looking at test failure output (shows the full test name)
 *   2. Searching generated test files: grep "^test \"" test/specs/generated -r
 *   3. Using isolate-test.ts which will show you the exact test name
 *
 * Using with isolate-test.ts:
 *   For detailed analysis with trace divergence, use isolate-test.ts instead:
 *   bun scripts/isolate-test.ts "test_name"
 */

const args = process.argv.slice(2);

// Parse arguments
let testName: string | undefined;
let suite: string | undefined;
let showList = false;
let showHelp = false;

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--suite' && i + 1 < args.length) {
    suite = args[++i];
  } else if (args[i] === '--list') {
    showList = true;
  } else if (args[i] === '--help') {
    showHelp = true;
  } else if (!testName) {
    testName = args[i];
  }
}

// Show help
if (showHelp || (!testName && !showList)) {
  console.log('Usage: bun scripts/debug-test.ts [options] <test_name_or_pattern>\n');
  console.log('Options:');
  console.log('  --suite <suite_name>   Run test within a specific test suite');
  console.log('  --list                 List all available test suites');
  console.log('  --help                 Show this help message\n');
  console.log('Examples:');
  console.log('  bun scripts/debug-test.ts "test_transient_storage_unset_values_000"');
  console.log('  bun scripts/debug-test.ts --suite cancun-tstore-contexts-execution "test_transient_storage_unset_values"');
  console.log('  bun scripts/debug-test.ts "transient_storage"');
  console.log('  bun scripts/debug-test.ts --list\n');
  console.log('For detailed trace analysis, use: bun scripts/isolate-test.ts "test_name"');
  process.exit(showHelp ? 0 : 1);
}

// List available suites
if (showList) {
  console.log('Available test suites (use with --suite flag):\n');
  console.log('Berlin:');
  console.log('  - berlin-acl, berlin-intrinsic-gas-cost, berlin-intrinsic-type0, berlin-intrinsic-type1\n');
  console.log('Frontier:');
  console.log('  - frontier-precompiles, frontier-identity, frontier-create, frontier-call');
  console.log('  - frontier-calldata, frontier-dup, frontier-push, frontier-stack, frontier-opcodes\n');
  console.log('Cancun (Transient Storage):');
  console.log('  - cancun-tstore-basic, cancun-tstore-reentrancy');
  console.log('  - cancun-tstore-contexts-execution (60 tests)');
  console.log('  - cancun-tstore-contexts-tload-reentrancy (48 tests)');
  console.log('  - cancun-tstore-contexts-reentrancy (20 tests)');
  console.log('  - cancun-tstore-contexts-create (20 tests)');
  console.log('  - cancun-tstore-contexts-selfdestruct (12 tests)');
  console.log('  - cancun-tstore-contexts-clear (4 tests)\n');
  console.log('Cancun (SELFDESTRUCT):');
  console.log('  - cancun-selfdestruct-basic (306 tests)');
  console.log('  - cancun-selfdestruct-collision (52 tests)');
  console.log('  - cancun-selfdestruct-reentrancy (36 tests)');
  console.log('  - cancun-selfdestruct-revert (12 tests)\n');
  console.log('Cancun (Blobs):');
  console.log('  - cancun-blob-precompile-basic (310 tests), cancun-blob-precompile-gas (48 tests)');
  console.log('  - cancun-blob-opcodes-basic (75 tests), cancun-blob-opcodes-contexts (23 tests)');
  console.log('  - cancun-blob-tx-small, cancun-blob-tx-subtraction, cancun-blob-tx-insufficient');
  console.log('  - cancun-blob-tx-sufficient, cancun-blob-tx-valid-combos\n');
  console.log('Cancun (Other):');
  console.log('  - cancun-mcopy, cancun-blobbasefee\n');
  console.log('Shanghai:');
  console.log('  - shanghai-push0, shanghai-warmcoinbase, shanghai-withdrawals');
  console.log('  - shanghai-initcode-basic (162 tests), shanghai-initcode-eof (24 tests)\n');
  console.log('Byzantium:');
  console.log('  - byzantium-modexp (352 tests)\n');
  console.log('Constantinople:');
  console.log('  - constantinople-bitshift (~250 tests), constantinople-create2 (~250 tests)\n');
  console.log('Istanbul:');
  console.log('  - istanbul-blake2, istanbul-chainid\n');
  console.log('Prague & Osaka: See zig build --help for full list');
  process.exit(0);
}

console.log(`Debugging test: ${testName}`);
if (suite) {
  console.log(`Using test suite: specs-${suite}`);
}
console.log('='.repeat(60));
console.log();

// Run the specific test with full output
const command = suite
  ? ['zig', 'build', `specs-${suite}`]
  : ['zig', 'build', 'specs'];

const proc = Bun.spawn(command, {
  stdout: 'inherit',
  stderr: 'inherit',
  env: {
    ...process.env,
    TEST_FILTER: testName,
  },
});

const exitCode = await proc.exited;

console.log();
console.log('='.repeat(60));
console.log(`Debug run complete for: ${testName}`);
if (exitCode !== 0) {
  console.log('\n💡 Tip: For detailed trace analysis, use:');
  console.log(`   bun scripts/isolate-test.ts "${testName}"`);
}

process.exit(exitCode);
