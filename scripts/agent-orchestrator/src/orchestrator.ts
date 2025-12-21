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

const ALL_ISSUES = [
  ...CRITICAL_ISSUES,
  ...MEDIUM_ISSUES,
  ...MINOR_ISSUES,
  ...BUG_ISSUES,
  ...PERF_ISSUES,
];

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

  // Use claude to do deeper validation
  const validationPrompt = `You are validating GitHub issue #${issue.number} before an automated agent works on it.

## Issue Title
${issue.title}

## Issue Body
${issue.body}

## Task
Analyze this issue and determine if it's:
1. VALID - A real bug/feature that can be safely worked on
2. INVALID - Should not be worked on (unclear, dangerous, out of scope)
3. NEEDS_CLARIFICATION - Requires human input before proceeding

Consider:
- Is the issue clear and actionable?
- Could fixing this introduce security vulnerabilities?
- Is this within scope of the Guillotine EVM project?
- Does this require architectural decisions that need human approval?
- Could this break existing functionality?

Respond with EXACTLY one of these formats:
VALID: <brief reason>
INVALID: <reason>
NEEDS_CLARIFICATION: <what needs clarification>`;

  try {
    const tempFile = '/tmp/claude-validation-prompt.txt';
    fs.writeFileSync(tempFile, validationPrompt);

    const output = execSync(
      `claude -p "$(cat ${tempFile})" --output-format text --max-turns 3`,
      {
        cwd: REPO_ROOT,
        encoding: 'utf-8',
        timeout: 120000,  // 2 min for validation
        env: { ...process.env, FORCE_COLOR: '0' }
      }
    );

    const response = output.trim();
    console.log(`Validation response: ${response.substring(0, 200)}...`);

    // Search for keywords anywhere in the response (claude may include reasoning before the verdict)
    const validMatch = response.match(/VALID:\s*(.+?)(?:\n|$)/);
    const invalidMatch = response.match(/INVALID:\s*(.+?)(?:\n|$)/);
    const clarifyMatch = response.match(/NEEDS_CLARIFICATION:\s*(.+?)(?:\n|$)/);

    if (validMatch && !invalidMatch && !clarifyMatch) {
      return { valid: true, reason: validMatch[1].trim(), shouldComment: false };
    } else if (invalidMatch) {
      return { valid: false, reason: invalidMatch[1].trim(), shouldComment: true };
    } else if (clarifyMatch) {
      return { valid: false, reason: clarifyMatch[1].trim(), shouldComment: true };
    } else if (response.toLowerCase().includes('valid') && !response.toLowerCase().includes('invalid')) {
      // Fallback: if it says "valid" but not in exact format, assume valid
      return { valid: true, reason: 'Issue appears valid based on analysis', shouldComment: false };
    } else {
      // Default to skipping but not commenting
      return { valid: false, reason: 'Validation response unclear - needs human review', shouldComment: false };
    }
  } catch (error: any) {
    console.error('Validation failed:', error.message);
    // If validation fails, skip but don't comment
    return { valid: false, reason: 'Validation process failed', shouldComment: false };
  }
}

/**
 * Generate the work prompt for an issue
 */
function generateWorkPrompt(issue: GitHubIssue): string {
  const priority = CRITICAL_ISSUES.includes(issue.number) ? 'CRITICAL' :
                   MEDIUM_ISSUES.includes(issue.number) ? 'MEDIUM' :
                   MINOR_ISSUES.includes(issue.number) ? 'MINOR' :
                   BUG_ISSUES.includes(issue.number) ? 'BUG' : 'PERFORMANCE';

  return `## Issue #${issue.number} [${priority}]: ${issue.title}

### Issue Description
${issue.body}

---

### Instructions

1. **Understand First**: Read relevant code before making changes
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
function workOnIssue(issue: GitHubIssue): { output: string; handoffPrompt: string; resolved: boolean } {
  const prompt = generateWorkPrompt(issue);
  const tempFile = '/tmp/claude-work-prompt.txt';
  fs.writeFileSync(tempFile, prompt);

  try {
    const output = execSync(
      `claude -p "$(cat ${tempFile})" --output-format text`,
      {
        cwd: REPO_ROOT,
        encoding: 'utf-8',
        maxBuffer: 10 * 1024 * 1024,
        timeout: 600000, // 10 min
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
  console.log('=' .repeat(60));
  console.log('Agent Orchestrator - Issue Queue Runner');
  console.log('='.repeat(60));
  console.log(`\nProcessing ${ALL_ISSUES.length} issues\n`);

  // Ensure reports dir exists
  if (!fs.existsSync(REPORTS_DIR)) {
    fs.mkdirSync(REPORTS_DIR, { recursive: true });
  }

  const results: { issue: number; status: string; reason?: string }[] = [];

  for (const issueNum of ALL_ISSUES) {
    console.log('\n' + '='.repeat(60));
    console.log(`Processing Issue #${issueNum}`);
    console.log('='.repeat(60));

    const startTime = new Date();

    // Fetch issue
    const issue = fetchIssue(issueNum);
    if (!issue) {
      console.log(`Skipping #${issueNum} - could not fetch`);
      results.push({ issue: issueNum, status: 'skipped', reason: 'Could not fetch' });
      continue;
    }

    console.log(`Title: ${issue.title}`);
    console.log(`State: ${issue.state}`);

    // Skip if closed
    if (issue.state === 'closed') {
      console.log(`Skipping #${issueNum} - already closed`);
      results.push({ issue: issueNum, status: 'skipped', reason: 'Already closed' });
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

      results.push({ issue: issueNum, status: 'aborted', reason: validation.reason });
      continue;
    }

    // Work on issue
    console.log(`\nWorking on issue #${issueNum}...`);
    const work = workOnIssue(issue);

    // Run tests
    const testsPassed = runTests();

    // Save report
    const report: IterationReport = {
      issueNumber: issueNum,
      iteration: 1,
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
    console.log(`  #${r.issue}: ${r.status}${r.reason ? ` - ${r.reason}` : ''}`);
  }
}

main().catch(console.error);
