#!/usr/bin/env bun
/**
 * Test Isolation Helper
 *
 * Runs a single test with maximum debugging output including:
 * - Verbose tracing enabled
 * - Trace divergence comparison
 * - Full gas calculation details
 * - Stack/memory/storage state
 *
 * Usage:
 *   bun scripts/isolate-test.ts <test_name> [build_target]
 *
 * Examples:
 *   bun scripts/isolate-test.ts "transientStorageReset"
 *   bun scripts/isolate-test.ts "push0" specs-shanghai-push0
 *   bun scripts/isolate-test.ts "MCOPY" specs-cancun-mcopy
 */

import { $, file } from "bun";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { existsSync } from "fs";
import { readdir } from "fs/promises";

// Color codes
const colors = {
  RED: '\x1b[0;31m',
  GREEN: '\x1b[0;32m',
  YELLOW: '\x1b[1;33m',
  BLUE: '\x1b[0;34m',
  CYAN: '\x1b[0;36m',
  MAGENTA: '\x1b[0;35m',
  BOLD: '\x1b[1m',
  RESET: '\x1b[0m',
};

// Helper functions for colored output
function printHeader(text: string) {
  console.log(`${colors.CYAN}${colors.BOLD}${'━'.repeat(80)}${colors.RESET}`);
  console.log(`${colors.CYAN}${colors.BOLD}${text}${colors.RESET}`);
  console.log(`${colors.CYAN}${colors.BOLD}${'━'.repeat(80)}${colors.RESET}`);
}

function printInfo(text: string) {
  console.log(`${colors.BLUE}ℹ${colors.RESET} ${text}`);
}

function printSuccess(text: string) {
  console.log(`${colors.GREEN}✓${colors.RESET} ${text}`);
}

function printWarning(text: string) {
  console.log(`${colors.YELLOW}⚠${colors.RESET} ${text}`);
}

function printError(text: string) {
  console.log(`${colors.RED}✗${colors.RESET} ${text}`);
}

function printSection(text: string) {
  console.log();
  console.log(`${colors.MAGENTA}${colors.BOLD}▶ ${text}${colors.RESET}`);
  console.log(`${colors.MAGENTA}${'─'.repeat(80)}${colors.RESET}`);
}

// Get arguments
const args = process.argv.slice(2);

if (args.length === 0 || args[0] === '--help' || args[0] === '-h') {
  console.log(`${colors.RED}${colors.BOLD}Error: Test name required${colors.RESET}\n`);
  console.log('Usage: bun scripts/isolate-test.ts <test_name> [build_target]\n');
  console.log('Examples:');
  console.log('  bun scripts/isolate-test.ts "transientStorageReset"');
  console.log('  bun scripts/isolate-test.ts "push0" specs-shanghai-push0');
  console.log('  bun scripts/isolate-test.ts "MCOPY" specs-cancun-mcopy\n');
  console.log('To find test names:');
  console.log('  zig build specs 2>&1 | grep -i <keyword>');
  console.log('  grep -r "test_name" ethereum-tests/GeneralStateTests/');
  process.exit(1);
}

const testName = args[0];
const buildTarget = args[1] || 'specs';

// Get repo root
const scriptDir = dirname(new URL(import.meta.url).pathname);
const repoRoot = join(scriptDir, '..');

// Change to repo root
process.chdir(repoRoot);

// Print banner
printHeader('🔬 Test Isolation Helper');
console.log();
printInfo(`Test name: ${colors.BOLD}${testName}${colors.RESET}`);
printInfo(`Build target: ${colors.BOLD}${buildTarget}${colors.RESET}`);
printInfo(`Repo root: ${colors.BOLD}${repoRoot}${colors.RESET}`);
console.log();

// Step 1: Find matching tests
printSection('Step 1: Finding matching tests');
console.log();
printInfo(`Searching for tests matching '${testName}'...`);
console.log();

if (existsSync('ethereum-tests/GeneralStateTests')) {
  console.log(`${colors.CYAN}Tests found in ethereum-tests:${colors.RESET}`);
  try {
    const result = await $`find ethereum-tests/GeneralStateTests -name "*.json" -exec grep -l ${testName} {} \\;`.quiet();
    const files = result.text().trim().split('\n').filter(Boolean).slice(0, 10);
    files.forEach(f => console.log(f));
  } catch (e) {
    // No matches or error - that's okay
  }
  console.log();
}

// Step 2: Run isolated test
printSection('Step 2: Running isolated test with verbose tracing');
console.log();
printInfo(`Command: TEST_FILTER="${testName}" zig build ${buildTarget}`);
console.log();

// Run the test and capture output
let exitCode = 0;
let output = '';

try {
  const proc = Bun.spawn(['zig', 'build', buildTarget], {
    env: { ...process.env, TEST_FILTER: testName },
    stdout: 'pipe',
    stderr: 'pipe',
  });

  const decoder = new TextDecoder();

  // Stream output in real-time
  for await (const chunk of proc.stdout) {
    const text = decoder.decode(chunk);
    process.stdout.write(text);
    output += text;
  }

  for await (const chunk of proc.stderr) {
    const text = decoder.decode(chunk);
    process.stderr.write(text);
    output += text;
  }

  exitCode = await proc.exited;
} catch (e) {
  exitCode = 1;
  output += String(e);
}

console.log();

// Step 3: Analyze results
printSection('Step 3: Test Results Analysis');
console.log();

if (exitCode === 0) {
  printSuccess('Test passed! ✨');
  console.log();
  printInfo('No issues detected. The test is passing.');
} else {
  printError(`Test failed (exit code: ${exitCode})`);
  console.log();

  // Analyze failure type
  if (output.includes('segmentation fault') || output.includes('Segmentation fault')) {
    printWarning(`Failure type: ${colors.BOLD}CRASH (Segmentation Fault)${colors.RESET}`);
    console.log();
    console.log('This is a crash, not a logic error. Recommended debugging approach:');
    console.log('  1. Use binary search with @panic("CHECKPOINT") to find crash location');
    console.log(`  2. Run with: TEST_FILTER="${testName}" zig build ${buildTarget}`);
    console.log('  3. See crash debugging guide in CLAUDE.md or fix-specs.ts');

  } else if (output.match(/panic|unreachable/i)) {
    printWarning(`Failure type: ${colors.BOLD}CRASH (Panic/Unreachable)${colors.RESET}`);
    console.log();

    const panicMatch = output.match(/panic:.+/);
    if (panicMatch) {
      console.log(`${colors.YELLOW}Panic message:${colors.RESET}`);
      console.log(panicMatch[0]);
      console.log();
    }

  } else if (output.match(/Trace divergence|trace divergence/i)) {
    printWarning(`Failure type: ${colors.BOLD}BEHAVIOR DIVERGENCE${colors.RESET}`);
    console.log();
    console.log('The test runner detected execution trace differences.');
    console.log();

    console.log(`${colors.YELLOW}Divergence details:${colors.RESET}`);
    const lines = output.split('\n');
    const divergenceStart = lines.findIndex(l => l.match(/Trace divergence|divergence at/i));
    if (divergenceStart >= 0) {
      lines.slice(divergenceStart, divergenceStart + 20).forEach(l => console.log(l));
    }
    console.log();

  } else if (output.match(/gas.*mismatch|gas.*error|expected.*gas|actual.*gas/i)) {
    printWarning(`Failure type: ${colors.BOLD}GAS CALCULATION ERROR${colors.RESET}`);
    console.log();
    console.log('Gas metering differs from expected behavior.');
    console.log();

    console.log(`${colors.YELLOW}Gas details:${colors.RESET}`);
    const gasLines = output.split('\n').filter(l =>
      l.match(/gas/i) && l.match(/expected|actual|mismatch|error/i)
    ).slice(0, 10);
    gasLines.forEach(l => console.log(l));
    console.log();

  } else if (output.match(/output mismatch|return.*mismatch|state.*mismatch/i)) {
    printWarning(`Failure type: ${colors.BOLD}OUTPUT/STATE MISMATCH${colors.RESET}`);
    console.log();
    console.log('Execution completed but produced wrong output or state.');
    console.log();

  } else {
    printWarning(`Failure type: ${colors.BOLD}UNKNOWN${colors.RESET}`);
    console.log();
    console.log('Could not automatically determine failure type.');
    console.log('Review the output above for details.');
    console.log();
  }

  // Extract test file location
  const testFileMatch = output.match(/ethereum-tests\/[^:\s]+\.json/);
  if (testFileMatch) {
    const testFile = testFileMatch[0];
    console.log(`${colors.CYAN}Test file location:${colors.RESET}`);
    console.log(`  ${testFile}`);
    console.log();

    if (existsSync(testFile)) {
      printInfo('To inspect test JSON:');
      console.log(`  cat ${testFile} | jq '."${testName}"'`);
      console.log();
    }
  }
}

// Step 4: Next steps
printSection('Step 4: Next Steps');
console.log();

if (exitCode === 0) {
  console.log('✨ Test is passing. No further action needed.');
} else {
  console.log('Recommended debugging workflow:');
  console.log();
  console.log(`  ${colors.BOLD}1. Re-run this test:${colors.RESET}`);
  console.log(`     bun scripts/isolate-test.ts "${testName}" ${buildTarget}`);
  console.log();
  console.log(`  ${colors.BOLD}2. Review trace output above${colors.RESET} to identify:`);
  console.log('     - Divergence point (PC, opcode)');
  console.log('     - Expected vs actual values');
  console.log('     - Stack/memory/storage differences');
  console.log();
  console.log(`  ${colors.BOLD}3. Read Python reference implementation:${colors.RESET}`);
  console.log('     # Identify hardfork from test name/path');
  console.log('     cd execution-specs/src/ethereum/forks/<hardfork>/vm/instructions/');
  console.log('     # Find the diverging opcode function');
  console.log();
  console.log(`  ${colors.BOLD}4. Compare with Zig implementation:${colors.RESET}`);
  console.log('     # For opcodes:');
  console.log('     grep -A 20 "<opcode_name>" src/frame.zig');
  console.log('     # For calls/creates:');
  console.log('     grep -A 20 "inner_call|inner_create" src/evm.zig');
  console.log();
  console.log(`  ${colors.BOLD}5. Fix the discrepancy${colors.RESET} to match Python reference exactly`);
  console.log();
  console.log(`  ${colors.BOLD}6. Verify the fix:${colors.RESET}`);
  console.log(`     bun scripts/isolate-test.ts "${testName}" ${buildTarget}`);
  console.log();
}

// Step 5: Quick reference
printSection('Quick Reference');
console.log();
console.log('Useful commands for this test:');
console.log();
console.log(`  ${colors.BOLD}# Run just this test${colors.RESET}`);
console.log(`  TEST_FILTER="${testName}" zig build ${buildTarget}`);
console.log();
console.log(`  ${colors.BOLD}# Run with specific hardfork${colors.RESET}`);
console.log(`  TEST_FILTER="${testName}" zig build specs-<hardfork>`);
console.log();
console.log(`  ${colors.BOLD}# Search for test definition${colors.RESET}`);
console.log(`  find ethereum-tests -name '*.json' -exec grep -l "${testName}" {} \\;`);
console.log();
console.log(`  ${colors.BOLD}# Find related tests${colors.RESET}`);
console.log(`  find ethereum-tests -name '*.json' -exec grep -l "${testName.slice(0, 10)}" {} \\;`);
console.log();
console.log(`  ${colors.BOLD}# Check current test status in full suite${colors.RESET}`);
console.log(`  zig build ${buildTarget} 2>&1 | grep -C 3 "${testName}"`);
console.log();

printHeader('🔬 Test Isolation Complete');
console.log();

process.exit(exitCode);
