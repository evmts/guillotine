import { query } from '@anthropic-ai/claude-agent-sdk';
import { readFileSync, writeFileSync, mkdirSync, existsSync, rmSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { execSync } from 'child_process';

// Get repo root (parent of scripts directory)
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = join(__dirname, '..');
const WORKTREES_DIR = join(REPO_ROOT, 'worktrees');
const MAX_CONCURRENT = 8;
const MAX_RETRIES = 10;

interface TestFixTask {
  testName: string;
  status: 'pending' | 'in-progress' | 'fixed' | 'failed';
  attempts: number;
  cost: number;
  duration: number;
  error?: string;
  commitSha?: string;
}

class TestFixPipeline {
  private tasks = new Map<string, TestFixTask>();
  private activeAgents = 0;
  private reportsDir = join(REPO_ROOT, 'fix-reports');

  constructor(failedTestsFile: string) {
    // Create directories
    if (!existsSync(this.reportsDir)) {
      mkdirSync(this.reportsDir, { recursive: true });
    }
    if (!existsSync(WORKTREES_DIR)) {
      mkdirSync(WORKTREES_DIR, { recursive: true });
    }

    // Load failed tests
    const content = readFileSync(failedTestsFile, 'utf-8');
    const tests = content
      .split('\n')
      .filter(line => line.trim().length > 0)
      .filter(line => !line.includes('assembler.test')); // Skip non-EVM tests

    console.log(`📋 Loaded ${tests.length} failed tests\n`);

    // Initialize tasks
    for (const testName of tests) {
      this.tasks.set(testName, {
        testName,
        status: 'pending',
        attempts: 0,
        cost: 0,
        duration: 0,
      });
    }
  }

  private sanitizeTestName(testName: string): string {
    return testName
      .replace(/[^a-zA-Z0-9_.-]/g, '_')
      .substring(0, 200);
  }

  private async verifyTestPasses(worktreePath: string, testName: string): Promise<boolean> {
    try {
      const result = execSync(
        `cd "${worktreePath}" && TEST_FILTER="${testName}" zig build specs 2>&1`,
        { encoding: 'utf-8', timeout: 120000 }
      );

      // Check if test passed
      const failedMatch = result.match(/Tests\s+(\d+)\s+failed/);
      if (failedMatch) {
        return parseInt(failedMatch[1]) === 0;
      }
      return false;
    } catch (error) {
      return false;
    }
  }

  private async fixTestInWorktree(testName: string): Promise<TestFixTask> {
    const task = this.tasks.get(testName)!;
    task.status = 'in-progress';

    const sanitized = this.sanitizeTestName(testName);
    const branchName = `fix/${sanitized}`;
    const worktreePath = join(WORKTREES_DIR, sanitized);

    console.log(`\n${'='.repeat(80)}`);
    console.log(`🔧 Fixing: ${testName}`);
    console.log(`📁 Worktree: ${worktreePath}`);
    console.log(`🌿 Branch: ${branchName}`);
    console.log(`${'='.repeat(80)}\n`);

    const taskStart = Date.now();

    try {
      // Create worktree
      console.log('🌳 Creating worktree...');
      execSync(`cd "${REPO_ROOT}" && git worktree add -b "${branchName}" "${worktreePath}" HEAD`, {
        encoding: 'utf-8'
      });

      for (task.attempts = 1; task.attempts <= MAX_RETRIES; task.attempts++) {
        console.log(`\n🔄 Attempt ${task.attempts}/${MAX_RETRIES}`);

        // Run fixing agent in worktree
        const prompt = `You are debugging a failing EVM test in the Guillotine EVM implementation.

**Failing Test**: ${testName}

**Your Task**:
1. First, run the test to see the failure:
   \`\`\`bash
   TEST_FILTER="${testName}" zig build specs
   \`\`\`

2. Analyze the failure output to understand:
   - What the test expects vs what the EVM produces
   - The root cause (opcodes, gas, state, etc.)
   - Any error messages or stack traces

3. Fix the implementation in src/ directory:
   - Make minimal, targeted changes
   - Don't break other functionality
   - Consider edge cases

4. Verify your fix by running the test again with TEST_FILTER

5. Once the test passes, commit your fix:
   \`\`\`bash
   git add src/
   git commit -m "fix: <brief description of fix for test>"
   \`\`\`

**Critical Requirements**:
- The test MUST pass before you commit
- Only fix THIS specific test
- Make minimal changes
- Commit with descriptive message

Begin debugging now.`;

        let agentCost = 0;

        const result = query({
          prompt,
          options: {
            model: 'claude-sonnet-4-5-20250929',
            maxTurns: 50,
            permissionMode: 'bypassPermissions',
            cwd: worktreePath,
          }
        });

        // Stream agent output
        for await (const message of result) {
          if (message.type === 'assistant') {
            const content = message.message.content;
            for (const block of content) {
              if (block.type === 'text') {
                process.stdout.write(block.text);
              }
            }
          } else if (message.type === 'result') {
            if (message.subtype === 'success') {
              console.log(`\n✅ Agent completed (Cost: $${message.total_cost_usd.toFixed(4)})`);
              agentCost = message.total_cost_usd;
            }
          }
        }

        task.cost += agentCost;

        // Verify test passes independently
        console.log('\n🧪 Independently verifying test passes...');
        const testPasses = await this.verifyTestPasses(worktreePath, testName);

        if (testPasses) {
          console.log('✅ Test verified as PASSING!');

          // Get commit SHA
          const commitSha = execSync(`cd "${worktreePath}" && git rev-parse HEAD`, {
            encoding: 'utf-8'
          }).trim();

          task.commitSha = commitSha;
          task.status = 'fixed';
          task.duration = Date.now() - taskStart;

          return task;
        } else {
          console.log(`❌ Test still FAILING after attempt ${task.attempts}`);
          if (task.attempts < MAX_RETRIES) {
            console.log('🔄 Retrying...');
          }
        }
      }

      // Max retries exceeded
      task.status = 'failed';
      task.error = 'Max retries exceeded - test still failing';
      task.duration = Date.now() - taskStart;
      return task;

    } catch (error) {
      task.status = 'failed';
      task.error = error instanceof Error ? error.message : String(error);
      task.duration = Date.now() - taskStart;
      return task;
    } finally {
      // Cleanup worktree
      try {
        console.log('\n🧹 Cleaning up worktree...');
        execSync(`cd "${REPO_ROOT}" && git worktree remove "${worktreePath}" --force`, {
          encoding: 'utf-8'
        });
        execSync(`cd "${REPO_ROOT}" && git branch -D "${branchName}"`, {
          encoding: 'utf-8'
        });
      } catch (error) {
        console.error('⚠️ Error during cleanup:', error);
      }
    }
  }

  private async cherryPickFix(commitSha: string, testName: string): Promise<boolean> {
    try {
      console.log(`\n🍒 Cherry-picking ${commitSha.substring(0, 7)} to main...`);

      // Cherry-pick from main branch
      execSync(`cd "${REPO_ROOT}" && git cherry-pick "${commitSha}"`, {
        encoding: 'utf-8'
      });

      console.log('✅ Successfully cherry-picked fix to main');
      return true;
    } catch (error) {
      console.error(`❌ Cherry-pick failed for ${testName}:`, error);
      return false;
    }
  }

  async runAll(): Promise<void> {
    console.log(`\n${'█'.repeat(80)}`);
    console.log(`🎯 AUTOMATED TEST FIX PIPELINE`);
    console.log(`${'█'.repeat(80)}`);
    console.log(`Total Failed Tests: ${this.tasks.size}`);
    console.log(`Max Concurrent Agents: ${MAX_CONCURRENT}`);
    console.log(`Max Retries per Test: ${MAX_RETRIES}`);
    console.log(`${'█'.repeat(80)}\n`);

    const pipelineStart = Date.now();
    const pending = Array.from(this.tasks.keys());
    const inProgress = new Map<string, Promise<TestFixTask>>();
    const fixed: TestFixTask[] = [];
    const failed: TestFixTask[] = [];

    // Main processing loop
    while (pending.length > 0 || inProgress.size > 0) {
      // Start new agents up to concurrency limit
      while (pending.length > 0 && inProgress.size < MAX_CONCURRENT) {
        const testName = pending.shift()!;
        const promise = this.fixTestInWorktree(testName);
        inProgress.set(testName, promise);
      }

      // Wait for at least one agent to complete
      if (inProgress.size > 0) {
        const completed = await Promise.race(
          Array.from(inProgress.entries()).map(async ([name, promise]) => {
            const result = await promise;
            return { name, result };
          })
        );

        // Remove from in-progress
        inProgress.delete(completed.name);

        // Track result
        if (completed.result.status === 'fixed') {
          fixed.push(completed.result);
        } else {
          failed.push(completed.result);
        }

        // Print progress
        const remaining = pending.length + inProgress.size;
        console.log(`\n📊 Progress: ${fixed.length} fixed | ${failed.length} failed | ${remaining} remaining\n`);
      }
    }

    // Cherry-pick all fixes back to main
    console.log(`\n${'█'.repeat(80)}`);
    console.log(`🍒 CHERRY-PICKING FIXES TO MAIN`);
    console.log(`${'█'.repeat(80)}\n`);

    let cherryPickedCount = 0;
    for (const task of fixed) {
      if (task.commitSha) {
        const success = await this.cherryPickFix(task.commitSha, task.testName);
        if (success) {
          cherryPickedCount++;
        }
      }
    }

    const pipelineDuration = Date.now() - pipelineStart;

    // Final summary
    console.log(`\n${'█'.repeat(80)}`);
    console.log(`🏁 PIPELINE COMPLETE`);
    console.log(`${'█'.repeat(80)}`);

    const totalCost = Array.from(this.tasks.values()).reduce((sum, t) => sum + t.cost, 0);
    const avgAttempts = fixed.length > 0
      ? fixed.reduce((sum, t) => sum + t.attempts, 0) / fixed.length
      : 0;

    console.log(`✅ Tests Fixed: ${fixed.length}`);
    console.log(`🍒 Cherry-picked to Main: ${cherryPickedCount}`);
    console.log(`❌ Tests Still Failing: ${failed.length}`);
    console.log(`💰 Total Cost: $${totalCost.toFixed(4)}`);
    console.log(`🔄 Average Attempts (fixed): ${avgAttempts.toFixed(1)}`);
    console.log(`⏱️  Total Duration: ${(pipelineDuration / 1000 / 60).toFixed(1)} minutes`);
    console.log(`${'█'.repeat(80)}\n`);

    // Generate report
    const report = this.generateReport();
    const reportPath = join(this.reportsDir, 'test-fix-summary.md');
    writeFileSync(reportPath, report, 'utf-8');
    console.log(`📊 Summary report: ${reportPath}\n`);

    // Save detailed task list
    const tasksJson = JSON.stringify(Array.from(this.tasks.values()), null, 2);
    writeFileSync(join(this.reportsDir, 'test-fix-details.json'), tasksJson, 'utf-8');
  }

  generateReport(): string {
    const fixed = Array.from(this.tasks.values()).filter(t => t.status === 'fixed');
    const failed = Array.from(this.tasks.values()).filter(t => t.status === 'failed');
    const totalCost = Array.from(this.tasks.values()).reduce((sum, t) => sum + t.cost, 0);
    const totalDuration = Array.from(this.tasks.values()).reduce((sum, t) => sum + t.duration, 0);

    let report = `# Automated Test Fix Report

**Generated**: ${new Date().toISOString()}

## Summary

- **Total Tests**: ${this.tasks.size}
- **Fixed**: ${fixed.length}
- **Still Failing**: ${failed.length}
- **Success Rate**: ${((fixed.length / this.tasks.size) * 100).toFixed(1)}%
- **Total Cost**: $${totalCost.toFixed(4)}
- **Total Duration**: ${(totalDuration / 1000 / 60).toFixed(1)} minutes

`;

    if (fixed.length > 0) {
      const avgAttempts = fixed.reduce((sum, t) => sum + t.attempts, 0) / fixed.length;
      const avgCost = fixed.reduce((sum, t) => sum + t.cost, 0) / fixed.length;

      report += `## ✅ Fixed Tests (${fixed.length})

**Average Attempts**: ${avgAttempts.toFixed(1)}
**Average Cost**: $${avgCost.toFixed(4)}

| Test Name | Attempts | Cost | Duration | Commit |
|-----------|----------|------|----------|--------|
`;

      for (const task of fixed) {
        const duration = (task.duration / 1000).toFixed(1);
        const commit = task.commitSha?.substring(0, 7) || 'N/A';
        report += `| ${task.testName} | ${task.attempts} | $${task.cost.toFixed(4)} | ${duration}s | ${commit} |\n`;
      }
      report += '\n';
    }

    if (failed.length > 0) {
      report += `## ❌ Failed Tests (${failed.length})

| Test Name | Attempts | Error |
|-----------|----------|-------|
`;

      for (const task of failed) {
        report += `| ${task.testName} | ${task.attempts} | ${task.error || 'Unknown'} |\n`;
      }
      report += '\n';
    }

    report += `## Next Steps

1. Run full test suite to verify fixes didn't break anything:
   \`\`\`bash
   zig build specs
   \`\`\`

2. Review failed tests and consider:
   - Are they edge cases that need different approaches?
   - Do they require architectural changes?
   - Should they be investigated manually?

3. For remaining failures, try:
   - Increasing MAX_RETRIES
   - Running individual fixes with more agent turns
   - Manual debugging with targeted fixes
`;

    return report;
  }
}

// CLI
async function main() {
  const args = process.argv.slice(2);

  if (args.length === 0) {
    console.log(`
Automated Test Fix Pipeline

Usage:
  bun run scripts/fix-tests.ts <failed-tests-file>

Example:
  bun run scripts/fix-tests.ts failed_tests.txt
    `);
    process.exit(1);
  }

  const failedTestsFile = args[0];

  if (!existsSync(failedTestsFile)) {
    console.error(`❌ File not found: ${failedTestsFile}`);
    process.exit(1);
  }

  const pipeline = new TestFixPipeline(failedTestsFile);
  await pipeline.runAll();
}

main().catch(console.error);
