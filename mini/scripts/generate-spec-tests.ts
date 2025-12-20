#!/usr/bin/env bun
/**
 * Generate Spec Tests
 *
 * Scans execution-specs test fixtures and generates individual .test.ts files
 * for each test case. This allows Bun's test runner to execute tests in parallel
 * with proper reporting.
 *
 * Usage:
 *   bun scripts/generate-spec-tests.ts [state|blockchain]
 *
 * Port of scripts/generate_spec_tests.py
 */

import * as fs from 'fs';
import * as path from 'path';

const SPECS_DIR = 'execution-specs/tests/eest/static';
const OUTPUT_DIR = 'test/specs/generated';

/**
 * Get all JSON test files in a directory recursively
 */
function findTestFiles(dir: string): string[] {
  const files: string[] = [];

  try {
    const entries = fs.readdirSync(dir, { withFileTypes: true });

    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);

      if (entry.isDirectory()) {
        files.push(...findTestFiles(fullPath));
      } else if (entry.isFile() && entry.name.endsWith('.json')) {
        files.push(fullPath);
      }
    }
  } catch (error) {
    // Directory doesn't exist, skip
  }

  return files;
}

/**
 * Generate test file for a JSON fixture
 */
function generateTestFile(jsonPath: string, outputDir: string): void {
  // Read JSON file
  const jsonContent = fs.readFileSync(jsonPath, 'utf8');
  let fixture: any;

  try {
    fixture = JSON.parse(jsonContent);
  } catch (error) {
    console.warn(`Failed to parse ${jsonPath}: ${error}`);
    return;
  }

  // Get test names
  const testNames = Object.keys(fixture);
  if (testNames.length === 0) {
    return;
  }

  // Calculate relative paths
  const relativePath = path.relative(SPECS_DIR, jsonPath);
  const outputPath = path.join(outputDir, relativePath.replace('.json', '.test.ts'));

  // Ensure output directory exists
  const outputFileDir = path.dirname(outputPath);
  fs.mkdirSync(outputFileDir, { recursive: true });

  // Generate test file content
  const lines: string[] = [];

  lines.push(`/**`);
  lines.push(` * Generated test file for ${relativePath}`);
  lines.push(` * DO NOT EDIT - regenerate with: bun scripts/generate-spec-tests.ts`);
  lines.push(` */`);
  lines.push('');
  lines.push(`import { test } from 'bun:test';`);
  lines.push(`import { runJsonTest } from '../../../runner';`);
  lines.push('');

  // Generate test cases
  for (const testName of testNames) {
    // Skip internal metadata fields
    if (testName.startsWith('_')) {
      continue;
    }

    // Sanitize test name for TypeScript
    const safeName = testName.replace(/[^a-zA-Z0-9_]/g, '_');

    lines.push(`test('${testName}', async () => {`);
    lines.push(`  const fixture = await Bun.file('${jsonPath}').json();`);
    lines.push(`  await runJsonTest(fixture, '${testName}');`);
    lines.push(`});`);
    lines.push('');
  }

  // Write file
  fs.writeFileSync(outputPath, lines.join('\n'));
}

/**
 * Main entry point
 */
function main() {
  const args = process.argv.slice(2);
  const testType = args[0] || 'state';

  if (testType !== 'state' && testType !== 'blockchain') {
    console.error('Usage: bun scripts/generate-spec-tests.ts [state|blockchain]');
    process.exit(1);
  }

  console.log(`Generating ${testType} tests...`);

  // Find test files
  const testDir = path.join(SPECS_DIR, testType === 'state' ? 'state_tests' : 'blockchain_tests');
  const testFiles = findTestFiles(testDir);

  console.log(`Found ${testFiles.length} test files`);

  // Clear output directory
  const outputDir = path.join(OUTPUT_DIR, testType === 'state' ? 'state' : 'blockchain');
  if (fs.existsSync(outputDir)) {
    fs.rmSync(outputDir, { recursive: true });
  }
  fs.mkdirSync(outputDir, { recursive: true });

  // Generate test files
  let generated = 0;
  for (const testFile of testFiles) {
    generateTestFile(testFile, outputDir);
    generated++;

    if (generated % 100 === 0) {
      console.log(`Generated ${generated}/${testFiles.length} test files...`);
    }
  }

  console.log(`✓ Generated ${generated} test files in ${outputDir}`);
}

main();
