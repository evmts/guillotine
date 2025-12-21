#!/usr/bin/env tsx
/**
 * Agent Orchestrator
 *
 * Automates the agent loop workflow:
 * 1. Start with a high-quality prompt (from issue or manual input)
 * 2. Run agent until context limit or task completion
 * 3. Generate handoff prompt and iteration report
 * 4. Commit changes with clear message
 * 5. Loop back with handoff prompt
 */

import { spawn, execSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';

// Types
interface IterationReport {
  iteration: number;
  issueNumber: string;
  startTime: Date;
  endTime: Date;
  initialPrompt: string;
  summary: string;
  filesModified: string[];
  testsRun: string;
  testsPassed: boolean;
  handoffPrompt: string;
  status: 'completed' | 'handoff' | 'error';
  errorDetails?: string;
}

interface OrchestratorConfig {
  maxIterations: number;
  repoRoot: string;
  reportsDir: string;
  issueNumber: string;
  initialPrompt: string;
}

// Constants
const REPO_ROOT = execSync('git rev-parse --show-toplevel').toString().trim();
const REPORTS_DIR = path.join(REPO_ROOT, 'scripts/agent-orchestrator/reports');
const MAX_ITERATIONS = 10;

/**
 * Generate a high-quality initial prompt from a GitHub issue
 */
function generateInitialPrompt(issueNumber: string, issueTitle: string, issueBody: string): string {
  return `## Issue #${issueNumber}: ${issueTitle}

### Context
${issueBody}

### Instructions
1. First, thoroughly understand the issue by exploring the codebase
2. Create a plan before making changes
3. Make minimal, focused changes to fix the issue
4. Run tests after each significant change: \`zig build && zig build test-opcodes\`
5. Follow all rules in CLAUDE.md

### Constraints (from CLAUDE.md)
- Zero tolerance for broken builds/tests
- Zero tolerance for error swallowing (\`catch {}\`)
- Use \`tracer.assert()\` not \`std.debug.assert\`
- Use \`log.debug/warn/err\` not \`std.debug.print\`
- Follow TDD: understand -> minimal repro -> fix -> verify

### When Context is Running Low
Before the context runs out, you MUST:
1. Summarize all progress made so far
2. List all files modified with descriptions of changes
3. Document any remaining work
4. Provide a complete handoff prompt for the next iteration

CRITICAL: Always leave a clear handoff prompt before context compaction.
`;
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
 * Generate a report filename
 */
function getReportFilename(issueNumber: string, iteration: number): string {
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  return path.join(REPORTS_DIR, `issue-${issueNumber}-iter-${iteration}-${timestamp}.md`);
}

/**
 * Save iteration report to markdown file
 */
function saveReport(report: IterationReport): string {
  const filename = getReportFilename(report.issueNumber, report.iteration);

  const content = `# Iteration Report: Issue #${report.issueNumber} - Iteration ${report.iteration}

## Metadata
- **Start Time**: ${report.startTime.toISOString()}
- **End Time**: ${report.endTime.toISOString()}
- **Duration**: ${Math.round((report.endTime.getTime() - report.startTime.getTime()) / 1000)}s
- **Status**: ${report.status}

## Initial Prompt
\`\`\`
${report.initialPrompt.substring(0, 500)}${report.initialPrompt.length > 500 ? '...' : ''}
\`\`\`

## Summary
${report.summary}

## Files Modified
${report.filesModified.map(f => `- \`${f}\``).join('\n') || 'None'}

## Tests
- **Tests Run**: ${report.testsRun}
- **Tests Passed**: ${report.testsPassed ? 'Yes' : 'No'}

## Handoff Prompt for Next Iteration
\`\`\`
${report.handoffPrompt}
\`\`\`

${report.errorDetails ? `## Error Details\n${report.errorDetails}` : ''}
`;

  fs.writeFileSync(filename, content);
  console.log(`Report saved to: ${filename}`);
  return filename;
}

/**
 * Commit changes with standardized message
 */
function commitChanges(issueNumber: string, iteration: number, summary: string): boolean {
  const modifiedFiles = getModifiedFiles();
  if (modifiedFiles.length === 0) {
    console.log('No changes to commit');
    return false;
  }

  try {
    // Stage all changes
    execSync('git add -A', { stdio: 'inherit' });

    // Create commit message
    const commitMsg = `fix(#${issueNumber}): Iteration ${iteration} - ${summary.substring(0, 50)}

Automated commit from agent-orchestrator.
Files changed: ${modifiedFiles.length}

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>`;

    execSync(`git commit -m "${commitMsg.replace(/"/g, '\\"')}"`, { stdio: 'inherit' });
    console.log(`Committed iteration ${iteration} changes`);
    return true;
  } catch (error) {
    console.error('Failed to commit:', error);
    return false;
  }
}

/**
 * Run claude with a prompt and capture output
 */
async function runClaudeAgent(prompt: string): Promise<{ output: string; handoffPrompt: string }> {
  // Write prompt to temp file to avoid shell escaping issues
  const tempFile = '/tmp/claude-orchestrator-prompt.txt';
  fs.writeFileSync(tempFile, prompt);

  try {
    // Run claude in print mode using shell
    const output = execSync(
      `claude -p "$(cat ${tempFile})" --output-format text`,
      {
        cwd: REPO_ROOT,
        encoding: 'utf-8',
        maxBuffer: 10 * 1024 * 1024, // 10MB buffer
        timeout: 600000, // 10 min timeout
        env: { ...process.env, FORCE_COLOR: '0' }
      }
    );

    console.log(output);

    // Extract handoff prompt from output if present
    let handoffPrompt = '';
    const handoffMatch = output.match(/## Handoff Prompt[\s\S]*?```([\s\S]*?)```/);
    if (handoffMatch) {
      handoffPrompt = handoffMatch[1].trim();
    }

    return { output, handoffPrompt };
  } catch (error: any) {
    // execSync throws on non-zero exit, but we still want the output
    const output = error.stdout?.toString() || '';
    const stderr = error.stderr?.toString() || '';
    console.log(output);
    console.error(stderr);

    let handoffPrompt = '';
    const handoffMatch = output.match(/## Handoff Prompt[\s\S]*?```([\s\S]*?)```/);
    if (handoffMatch) {
      handoffPrompt = handoffMatch[1].trim();
    }

    return { output: output + '\n' + stderr, handoffPrompt };
  }
}

/**
 * Request a handoff summary from the agent
 */
async function requestHandoffSummary(): Promise<{ output: string; handoffPrompt: string }> {
  const handoffRequestPrompt = `CONTEXT HANDOFF REQUEST

The context is getting full. Please provide a comprehensive handoff summary:

## 1. Progress Summary
Summarize what has been accomplished in this iteration.

## 2. Files Modified
List all files that were modified with brief descriptions of changes.

## 3. Test Results
What tests were run? Did they pass?

## 4. Remaining Work
What work remains to be done?

## 5. Key Context
Any important context the next agent needs to know.

## Handoff Prompt
Provide a complete prompt that can be given to the next agent to continue this work. Format it as:
\`\`\`
[Your handoff prompt here]
\`\`\`

The handoff prompt should be self-contained and include all necessary context.`;

  return runClaudeAgent(handoffRequestPrompt);
}

/**
 * Main orchestration loop
 */
async function runOrchestrator(config: OrchestratorConfig): Promise<void> {
  console.log(`\n${'='.repeat(60)}`);
  console.log(`Agent Orchestrator - Issue #${config.issueNumber}`);
  console.log(`${'='.repeat(60)}\n`);

  let currentPrompt = config.initialPrompt;
  let iteration = 0;
  let isComplete = false;

  while (!isComplete && iteration < config.maxIterations) {
    iteration++;
    console.log(`\n--- Iteration ${iteration} ---\n`);

    const startTime = new Date();
    let status: 'completed' | 'handoff' | 'error' = 'handoff';
    let summary = '';
    let handoffPrompt = '';
    let errorDetails: string | undefined;
    let testsRun = 'Not run';
    let testsPassed = false;

    try {
      // Run the main task
      console.log('Running agent with prompt...\n');
      const result = await runClaudeAgent(currentPrompt);

      // Check if task is complete
      const outputLower = result.output.toLowerCase();
      if (outputLower.includes('task complete') ||
          outputLower.includes('all tasks completed') ||
          outputLower.includes('issue resolved')) {
        status = 'completed';
        isComplete = true;
        summary = 'Task completed successfully';
      } else {
        // Request handoff summary
        console.log('\nRequesting handoff summary...\n');
        const handoffResult = await requestHandoffSummary();
        handoffPrompt = handoffResult.handoffPrompt || result.handoffPrompt;
        summary = 'Iteration completed, handing off to next iteration';
      }

      // Run tests
      try {
        console.log('\nRunning tests...');
        execSync('zig build && zig build test-opcodes', {
          cwd: REPO_ROOT,
          stdio: 'pipe',
          timeout: 300000 // 5 min timeout
        });
        testsRun = 'zig build && zig build test-opcodes';
        testsPassed = true;
        console.log('Tests passed!');
      } catch (testError: any) {
        testsRun = 'zig build && zig build test-opcodes';
        testsPassed = false;
        console.log('Tests failed:', testError.message);
      }

    } catch (error: any) {
      status = 'error';
      errorDetails = error.message;
      summary = `Error during iteration: ${error.message}`;
      console.error('Iteration error:', error);
    }

    const endTime = new Date();
    const filesModified = getModifiedFiles();

    // Create and save report
    const report: IterationReport = {
      iteration,
      issueNumber: config.issueNumber,
      startTime,
      endTime,
      initialPrompt: currentPrompt,
      summary,
      filesModified,
      testsRun,
      testsPassed,
      handoffPrompt,
      status,
      errorDetails
    };

    const reportFile = saveReport(report);

    // Commit changes including the report
    if (filesModified.length > 0 || fs.existsSync(reportFile)) {
      commitChanges(config.issueNumber, iteration, summary);
    }

    // Prepare for next iteration
    if (!isComplete && handoffPrompt) {
      currentPrompt = handoffPrompt;
    } else if (!isComplete && !handoffPrompt) {
      console.log('No handoff prompt generated, stopping orchestrator');
      break;
    }
  }

  console.log(`\n${'='.repeat(60)}`);
  console.log(`Orchestrator finished after ${iteration} iteration(s)`);
  console.log(`Status: ${isComplete ? 'COMPLETED' : 'STOPPED'}`);
  console.log(`${'='.repeat(60)}\n`);
}

/**
 * Parse command line arguments
 */
function parseArgs(): OrchestratorConfig {
  const args = process.argv.slice(2);

  // Default config
  let config: OrchestratorConfig = {
    maxIterations: MAX_ITERATIONS,
    repoRoot: REPO_ROOT,
    reportsDir: REPORTS_DIR,
    issueNumber: 'unknown',
    initialPrompt: ''
  };

  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--issue' && args[i + 1]) {
      config.issueNumber = args[i + 1];
      i++;
    } else if (args[i] === '--max-iterations' && args[i + 1]) {
      config.maxIterations = parseInt(args[i + 1], 10);
      i++;
    } else if (args[i] === '--prompt-file' && args[i + 1]) {
      config.initialPrompt = fs.readFileSync(args[i + 1], 'utf-8');
      i++;
    } else if (args[i] === '--prompt' && args[i + 1]) {
      config.initialPrompt = args[i + 1];
      i++;
    }
  }

  // If no prompt provided, create from issue
  if (!config.initialPrompt && config.issueNumber !== 'unknown') {
    // In a real implementation, you'd fetch from GitHub API
    config.initialPrompt = generateInitialPrompt(
      config.issueNumber,
      'Issue title would be fetched from GitHub',
      'Issue body would be fetched from GitHub'
    );
  }

  return config;
}

// Main entry point
const config = parseArgs();

if (!config.initialPrompt) {
  console.log(`
Agent Orchestrator

Usage:
  tsx src/orchestrator.ts --issue <number> [options]
  tsx src/orchestrator.ts --prompt-file <path> [options]
  tsx src/orchestrator.ts --prompt "<prompt>" [options]

Options:
  --issue <number>       GitHub issue number to work on
  --prompt-file <path>   Path to file containing the initial prompt
  --prompt "<text>"      Initial prompt text (use quotes)
  --max-iterations <n>   Maximum number of iterations (default: 10)

Examples:
  tsx src/orchestrator.ts --issue 850 --max-iterations 5
  tsx src/orchestrator.ts --prompt-file ./prompts/issue-850.md
  tsx src/orchestrator.ts --prompt "Fix the bug in auth.py"
`);
  process.exit(1);
}

// Ensure reports directory exists
if (!fs.existsSync(REPORTS_DIR)) {
  fs.mkdirSync(REPORTS_DIR, { recursive: true });
}

// Run the orchestrator
runOrchestrator(config).catch(console.error);
