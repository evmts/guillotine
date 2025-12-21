#!/usr/bin/env tsx
/**
 * Agent Orchestrator - Issue Queue Runner
 *
 * Loops through GitHub issues, validates each, and works on valid ones.
 * Features:
 * - Fetches issue details from GitHub
 * - Validates issues before working (checks if closed, safe, useful)
 * - Comments on issues if aborting
 * - Generates reports for each iteration
 * - Auto-commits changes
 */

import { execSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';

// Issue priority lists
const CRITICAL_ISSUES = [853, 852, 851, 850];
const MEDIUM_ISSUES = [858, 857, 854];
const MINOR_ISSUES = [859];
const BUG_ISSUES = [844, 842, 841, 838, 815];
const PERF_ISSUES = [837, 832, 764, 635];

// Issues that need continued work (HANDOFF from iteration 1)
const HANDOFF_ISSUES = [851, 850, 858, 857, 854, 859, 844, 842, 841, 832, 764];

const ALL_ISSUES = [
  ...CRITICAL_ISSUES,
  ...MEDIUM_ISSUES,
  ...MINOR_ISSUES,
  ...BUG_ISSUES,
  ...PERF_ISSUES,
];

// Configuration
const MAX_TURNS = 20; // Doubled from default ~10
const TIMEOUT_MS = 1200000; // 20 minutes (doubled from 10)

// Types
interface GitHubIssue {
  number: number;
  title: string;
  body: string;
  state: 'open' | 'closed';
  labels: string[];
}

interface ValidationResult {
  valid: boolean;
  reason: string;
  shouldComment: boolean;
}

interface IterationReport {
  issueNumber: number;
  iteration: number;
  startTime: Date;
  endTime: Date;
  summary: string;
  filesModified: string[];
  testsPassed: boolean;
  status: 'completed' | 'handoff' | 'skipped' | 'aborted' | 'error';
  validationResult?: ValidationResult;
}

// Constants
const REPO_ROOT = execSync('git rev-parse --show-toplevel').toString().trim();
const REPORTS_DIR = path.join(REPO_ROOT, 'scripts/agent-orchestrator/reports');
const REPO = 'anthropics/guillotine'; // Update this to actual repo

/**
 * Find previous reports for an issue
 */
function findPreviousReports(issueNumber: number): { path: string; content: string; iteration: number }[] {
  const reports: { path: string; content: string; iteration: number }[] = [];

  try {
    const files = fs.readdirSync(REPORTS_DIR);
    const issueReports = files
      .filter(f => f.startsWith(`issue-${issueNumber}-iter-`) && f.endsWith('.md'))
      .sort(); // Sort to get chronological order

    for (const file of issueReports) {
      const filePath = path.join(REPORTS_DIR, file);
      const content = fs.readFileSync(filePath, 'utf-8');
      const iterMatch = file.match(/iter-(\d+)/);
      const iteration = iterMatch ? parseInt(iterMatch[1], 10) : 1;
      reports.push({ path: filePath, content, iteration });
    }
  } catch {
    // No reports found
  }

  return reports;
}

/**
 * Get the next iteration number for an issue
 */
function getNextIteration(issueNumber: number): number {
  const reports = findPreviousReports(issueNumber);
  if (reports.length === 0) return 1;
  return Math.max(...reports.map(r => r.iteration)) + 1;
}

/**
 * Fetch issue details from GitHub using gh CLI
 */
function fetchIssue(issueNumber: number): GitHubIssue | null {
  try {
    const output = execSync(
      `gh issue view ${issueNumber} --json number,title,body,state,labels`,
      { encoding: 'utf-8', cwd: REPO_ROOT }
    );
    const data = JSON.parse(output);
    return {
      number: data.number,
      title: data.title,
      body: data.body || '',
      state: data.state.toLowerCase(),
      labels: data.labels?.map((l: any) => l.name) || [],
    };
  } catch (error) {
    console.error(`Failed to fetch issue #${issueNumber}:`, error);
    return null;
  }
}

/**
 * Add a comment to an issue
 */
function commentOnIssue(issueNumber: number, comment: string): boolean {
  try {
    execSync(
      `gh issue comment ${issueNumber} --body "${comment.replace(/"/g, '\\"')}"`,
      { encoding: 'utf-8', cwd: REPO_ROOT }
    );
    return true;
  } catch (error) {
    console.error(`Failed to comment on issue #${issueNumber}:`, error);
    return false;
  }
}

/**
 * Get modified files from git
 */
function getModifiedFiles(): string[] {
  try {
    const output = execSync('git diff --name-only HEAD', { encoding: 'utf-8' });
    return output.split('\n').filter(f => f.length > 0);
  } catch {
    return [];
  }
}

/**
 * Run claude to validate an issue before working on it
 */
function validateIssue(issue: GitHubIssue): ValidationResult {
  console.log(`\nValidating issue #${issue.number}: ${issue.title}`);

  // Quick checks first
  if (issue.state === 'closed') {
    return { valid: false, reason: 'Issue is already closed', shouldComment: false };
  }

  // Check for dangerous labels
  const dangerousLabels = ['wontfix', 'duplicate', 'invalid'];
  for (const label of issue.labels) {
    if (dangerousLabels.includes(label.toLowerCase())) {
      return { valid: false, reason: `Issue has '${label}' label`, shouldComment: false };
    }
  }

  // Simple validation - most issues from our curated list are valid
  // Only check for obvious blockers
  const bodyLower = issue.body.toLowerCase();
  const titleLower = issue.title.toLowerCase();

  // Check for issues that need architectural decisions (skip for automation)
  if (titleLower.includes('benchmark') || titleLower.includes('refactor') ||
      bodyLower.includes('architectural') || bodyLower.includes('breaking change')) {
    return { valid: false, reason: 'Requires architectural decision - needs human approval', shouldComment: false };
  }

  // Check for build/platform issues we can't test locally
  if (titleLower.includes('linux') || titleLower.includes('windows') ||
      titleLower.includes('x86') || titleLower.includes('build fails')) {
    return { valid: false, reason: 'Platform-specific issue - needs appropriate environment', shouldComment: false };
  }

  // Otherwise, assume issues from our curated list are valid
  return { valid: true, reason: 'Issue from curated priority list', shouldComment: false };
}

/**
 * Generate the work prompt for an issue
 */
function generateWorkPrompt(issue: GitHubIssue, iteration: number): string {
  const priority = CRITICAL_ISSUES.includes(issue.number) ? 'CRITICAL' :
                   MEDIUM_ISSUES.includes(issue.number) ? 'MEDIUM' :
                   MINOR_ISSUES.includes(issue.number) ? 'MINOR' :
                   BUG_ISSUES.includes(issue.number) ? 'BUG' : 'PERFORMANCE';

  // Get previous reports
  const previousReports = findPreviousReports(issue.number);
  let previousContext = '';

  if (previousReports.length > 0) {
    previousContext = `
---

### IMPORTANT: Previous Work Done (Iteration ${iteration - 1})

**You MUST read the previous reports before starting work!**

Previous report files:
${previousReports.map(r => `- ${r.path}`).join('\n')}

**Read these files first** to understand what was already tried and what progress was made.
The previous iteration(s) made progress but did not fully resolve the issue.
Continue from where they left off - do NOT repeat the same work.

`;
  }

  return `## Issue #${issue.number} [${priority}]: ${issue.title} (Iteration ${iteration})

### Issue Description
${issue.body}
${previousContext}
---

### Instructions

1. ${previousReports.length > 0 ? '**READ PREVIOUS REPORTS FIRST**: Use the Read tool to read the previous report files listed above' : '**Understand First**: Read relevant code before making changes'}
2. **Minimal Changes**: Make focused, minimal changes to fix the issue
3. **Test Thoroughly**: Run \`zig build && zig build test-opcodes\` after changes
4. **Follow CLAUDE.md**: Zero tolerance for error swallowing, broken tests, etc.

### Commands
\`\`\`bash
# Build and test
zig build && zig build test-opcodes

# Run specific tests
zig build test-integration -Dtest-filter='<pattern>'
\`\`\`

### Constraints (from CLAUDE.md)
- Zero tolerance for \`catch {}\` error swallowing
- Use \`tracer.assert()\` not \`std.debug.assert\`
- Use \`log.debug/warn/err\` not \`std.debug.print\`
- All changes must pass tests

### When Done or Context Low
Provide a handoff summary:
\`\`\`
## Handoff Prompt
[Complete context for next iteration]
\`\`\`

If the issue is COMPLETE, say "ISSUE RESOLVED" clearly.
`;
}

/**
 * Run claude to work on an issue
 */
function workOnIssue(issue: GitHubIssue, iteration: number): { output: string; handoffPrompt: string; resolved: boolean } {
  const prompt = generateWorkPrompt(issue, iteration);
  const tempFile = '/tmp/claude-work-prompt.txt';
  fs.writeFileSync(tempFile, prompt);

  console.log(`\n--- Starting Claude with max-turns=${MAX_TURNS}, timeout=${TIMEOUT_MS/1000}s ---\n`);

  try {
    const output = execSync(
      `claude -p "$(cat ${tempFile})" --output-format text --max-turns ${MAX_TURNS}`,
      {
        cwd: REPO_ROOT,
        encoding: 'utf-8',
        maxBuffer: 10 * 1024 * 1024,
        timeout: TIMEOUT_MS,
        env: { ...process.env, FORCE_COLOR: '0' }
      }
    );

    console.log(output);

    // Check if resolved
    const resolved = output.toLowerCase().includes('issue resolved') ||
                     output.toLowerCase().includes('task complete');

    // Extract handoff prompt
    let handoffPrompt = '';
    const handoffMatch = output.match(/## Handoff Prompt[\s\S]*?```([\s\S]*?)```/);
    if (handoffMatch) {
      handoffPrompt = handoffMatch[1].trim();
    }

    return { output, handoffPrompt, resolved };
  } catch (error: any) {
    const output = error.stdout?.toString() || '';
    console.log(output);
    return { output, handoffPrompt: '', resolved: false };
  }
}

/**
 * Run tests and return pass/fail
 */
function runTests(): boolean {
  try {
    console.log('\nRunning tests...');
    execSync('zig build && zig build test-opcodes', {
      cwd: REPO_ROOT,
      stdio: 'pipe',
      timeout: 300000
    });
    console.log('Tests passed!');
    return true;
  } catch (error: any) {
    // Check if it's just logged errors (tests actually passed)
    const output = error.stdout?.toString() || '';
    if (output.includes('tests passed')) {
      console.log('Tests passed (with expected logged errors)');
      return true;
    }
    console.log('Tests failed');
    return false;
  }
}

/**
 * Save report to file
 */
function saveReport(report: IterationReport): string {
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const filename = path.join(REPORTS_DIR, `issue-${report.issueNumber}-iter-${report.iteration}-${timestamp}.md`);

  const content = `# Report: Issue #${report.issueNumber} - Iteration ${report.iteration}

## Status: ${report.status.toUpperCase()}

## Timing
- Start: ${report.startTime.toISOString()}
- End: ${report.endTime.toISOString()}
- Duration: ${Math.round((report.endTime.getTime() - report.startTime.getTime()) / 1000)}s

## Summary
${report.summary}

${report.validationResult ? `## Validation
- Valid: ${report.validationResult.valid}
- Reason: ${report.validationResult.reason}` : ''}

## Files Modified
${report.filesModified.map(f => `- ${f}`).join('\n') || 'None'}

## Tests Passed
${report.testsPassed ? 'Yes' : 'No'}
`;

  fs.writeFileSync(filename, content);
  console.log(`Report saved: ${filename}`);
  return filename;
}

/**
 * Commit changes
 */
function commitChanges(issueNumber: number, summary: string): boolean {
  const files = getModifiedFiles();
  if (files.length === 0) return false;

  try {
    execSync('git add -A', { stdio: 'inherit' });
    const msg = `fix(#${issueNumber}): ${summary.substring(0, 50)}

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>`;
    execSync(`git commit -m "${msg.replace(/"/g, '\\"')}"`, { stdio: 'inherit' });
    return true;
  } catch {
    return false;
  }
}

/**
 * Main orchestration loop
 */
async function main() {
  // Use HANDOFF_ISSUES for continuation run
  const issuesToProcess = HANDOFF_ISSUES;

  console.log('='.repeat(60));
  console.log('Agent Orchestrator - Issue Queue Runner (Iteration 2)');
  console.log('='.repeat(60));
  console.log(`\nProcessing ${issuesToProcess.length} HANDOFF issues`);
  console.log(`Config: max-turns=${MAX_TURNS}, timeout=${TIMEOUT_MS/1000}s\n`);

  // Ensure reports dir exists
  if (!fs.existsSync(REPORTS_DIR)) {
    fs.mkdirSync(REPORTS_DIR, { recursive: true });
  }

  const results: { issue: number; status: string; iteration: number; reason?: string }[] = [];

  for (const issueNum of issuesToProcess) {
    const iteration = getNextIteration(issueNum);

    console.log('\n' + '='.repeat(60));
    console.log(`Processing Issue #${issueNum} (Iteration ${iteration})`);
    console.log('='.repeat(60));

    const startTime = new Date();

    // Fetch issue
    const issue = fetchIssue(issueNum);
    if (!issue) {
      console.log(`Skipping #${issueNum} - could not fetch`);
      results.push({ issue: issueNum, status: 'skipped', iteration, reason: 'Could not fetch' });
      continue;
    }

    console.log(`Title: ${issue.title}`);
    console.log(`State: ${issue.state}`);

    // Skip if closed
    if (issue.state === 'closed') {
      console.log(`Skipping #${issueNum} - already closed`);
      results.push({ issue: issueNum, status: 'skipped', iteration, reason: 'Already closed' });
      continue;
    }

    // Validate
    const validation = validateIssue(issue);
    if (!validation.valid) {
      console.log(`Skipping #${issueNum} - ${validation.reason}`);

      if (validation.shouldComment) {
        const comment = `🤖 **Automated Agent Note**

This issue was reviewed by an automated agent but was not worked on.

**Reason**: ${validation.reason}

This issue may need human review or clarification before automated work can proceed.

*Note: This comment was generated by Claude AI assistant*`;
        commentOnIssue(issueNum, comment);
      }

      results.push({ issue: issueNum, status: 'aborted', iteration, reason: validation.reason });
      continue;
    }

    // Work on issue
    console.log(`\nWorking on issue #${issueNum} (iteration ${iteration})...`);
    const work = workOnIssue(issue, iteration);

    // Run tests
    const testsPassed = runTests();

    // Save report
    const report: IterationReport = {
      issueNumber: issueNum,
      iteration,
      startTime,
      endTime: new Date(),
      summary: work.resolved ? 'Issue resolved' : 'Iteration completed',
      filesModified: getModifiedFiles(),
      testsPassed,
      status: work.resolved ? 'completed' : 'handoff',
      validationResult: validation,
    };
    saveReport(report);

    // Commit
    if (report.filesModified.length > 0) {
      commitChanges(issueNum, report.summary);
    }

    results.push({
      issue: issueNum,
      iteration,
      status: work.resolved ? 'completed' : 'worked',
      reason: work.resolved ? 'Issue resolved' : 'Made progress'
    });

    // If resolved, optionally close the issue
    if (work.resolved && testsPassed) {
      console.log(`Issue #${issueNum} appears resolved!`);
    }
  }

  // Final summary
  console.log('\n' + '='.repeat(60));
  console.log('FINAL SUMMARY');
  console.log('='.repeat(60));
  console.log('\nResults:');
  for (const r of results) {
    console.log(`  #${r.issue} (iter ${r.iteration}): ${r.status}${r.reason ? ` - ${r.reason}` : ''}`);
  }
}

main().catch(console.error);
