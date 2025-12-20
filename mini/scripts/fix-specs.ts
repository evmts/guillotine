import { query } from "@anthropic-ai/claude-agent-sdk";
import { execSync } from "child_process";
import { writeFileSync, mkdirSync, existsSync, readFileSync, readdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

// Get repo root
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = join(__dirname, "..");
const KNOWN_ISSUES_PATH = join(__dirname, "known-issues.json");

// Test suite configuration
interface TestSuite {
  name: string;
  command: string;
  description: string;
}

// Known issues database
interface KnownIssue {
  test_suite: string;
  description: string;
  common_causes: string[];
  relevant_files: string[];
  python_ref: string;
  key_invariants: string[];
  gas_costs?: Record<string, number>;
}

interface KnownIssuesDatabase {
  issues: Record<string, KnownIssue>;
}

const TEST_SUITES: TestSuite[] = [
  // These pass (commented out)
  { name: 'paris', command: 'zig build specs-paris', description: 'Paris/Merge hardfork tests' },
  { name: 'homestead', command: 'zig build specs-homestead', description: 'Homestead hardfork tests' },
  { name: 'shanghai-withdrawals', command: 'zig build specs-shanghai-withdrawals', description: 'Shanghai EIP-4895 withdrawal tests' },
  { name: 'shanghai-push0', command: 'zig build specs-shanghai-push0', description: 'Shanghai EIP-3855 PUSH0 tests' },

  // Cancun sub-targets (broken up from large test suite)
  { name: 'cancun-tstore-basic', command: 'zig build specs-cancun-tstore-basic', description: 'Cancun EIP-1153 basic TLOAD/TSTORE tests' },
  { name: 'cancun-tstore-reentrancy', command: 'zig build specs-cancun-tstore-reentrancy', description: 'Cancun EIP-1153 reentrancy tests' },
  { name: 'cancun-tstore-contexts-execution', command: 'zig build specs-cancun-tstore-contexts-execution', description: 'Cancun EIP-1153 execution context tests (60 tests)' },
  { name: 'cancun-tstore-contexts-tload-reentrancy', command: 'zig build specs-cancun-tstore-contexts-tload-reentrancy', description: 'Cancun EIP-1153 tload reentrancy tests (48 tests)' },
  { name: 'cancun-tstore-contexts-reentrancy', command: 'zig build specs-cancun-tstore-contexts-reentrancy', description: 'Cancun EIP-1153 reentrancy context tests (20 tests)' },
  { name: 'cancun-tstore-contexts-create', command: 'zig build specs-cancun-tstore-contexts-create', description: 'Cancun EIP-1153 create context tests (20 tests)' },
  { name: 'cancun-tstore-contexts-selfdestruct', command: 'zig build specs-cancun-tstore-contexts-selfdestruct', description: 'Cancun EIP-1153 selfdestruct tests (12 tests)' },
  { name: 'cancun-tstore-contexts-clear', command: 'zig build specs-cancun-tstore-contexts-clear', description: 'Cancun EIP-1153 clear after tx tests (4 tests)' },
  { name: 'cancun-mcopy', command: 'zig build specs-cancun-mcopy', description: 'Cancun EIP-5656 MCOPY tests' },
  { name: 'cancun-blobbasefee', command: 'zig build specs-cancun-blobbasefee', description: 'Cancun EIP-7516 BLOBBASEFEE tests' },
  { name: 'cancun-blob-precompile-basic', command: 'zig build specs-cancun-blob-precompile-basic', description: 'Cancun EIP-4844 point evaluation basic tests (310 tests)' },
  { name: 'cancun-blob-precompile-gas', command: 'zig build specs-cancun-blob-precompile-gas', description: 'Cancun EIP-4844 point evaluation gas tests (48 tests)' },
  { name: 'cancun-blob-opcodes-basic', command: 'zig build specs-cancun-blob-opcodes-basic', description: 'Cancun EIP-4844 BLOBHASH basic tests (75 tests)' },
  { name: 'cancun-blob-opcodes-contexts', command: 'zig build specs-cancun-blob-opcodes-contexts', description: 'Cancun EIP-4844 BLOBHASH context tests (23 tests)' },
  { name: 'cancun-blob-tx-small', command: 'zig build specs-cancun-blob-tx-small', description: 'Cancun EIP-4844 small blob transaction tests' },
  { name: 'cancun-blob-tx-subtraction', command: 'zig build specs-cancun-blob-tx-subtraction', description: 'Cancun EIP-4844 blob gas subtraction tests' },
  { name: 'cancun-blob-tx-insufficient', command: 'zig build specs-cancun-blob-tx-insufficient', description: 'Cancun EIP-4844 insufficient balance tests' },
  { name: 'cancun-blob-tx-sufficient', command: 'zig build specs-cancun-blob-tx-sufficient', description: 'Cancun EIP-4844 sufficient balance tests' },
  { name: 'cancun-blob-tx-valid-combos', command: 'zig build specs-cancun-blob-tx-valid-combos', description: 'Cancun EIP-4844 valid combinations tests' },

  // Prague sub-targets (broken up from large test suite)
  { name: 'prague-calldata-cost-type0', command: 'zig build specs-prague-calldata-cost-type0', description: 'Prague EIP-7623 calldata cost type 0 tests' },
  { name: 'prague-calldata-cost-type1-2', command: 'zig build specs-prague-calldata-cost-type1-2', description: 'Prague EIP-7623 calldata cost type 1/2 tests' },
  { name: 'prague-calldata-cost-type3', command: 'zig build specs-prague-calldata-cost-type3', description: 'Prague EIP-7623 calldata cost type 3 tests' },
  { name: 'prague-calldata-cost-type4', command: 'zig build specs-prague-calldata-cost-type4', description: 'Prague EIP-7623 calldata cost type 4 tests' },
  { name: 'prague-calldata-cost-refunds', command: 'zig build specs-prague-calldata-cost-refunds', description: 'Prague EIP-7623 refunds and gas tests' },
  { name: 'prague-bls-g1', command: 'zig build specs-prague-bls-g1', description: 'Prague EIP-2537 BLS12-381 G1 tests' },
  { name: 'prague-bls-g2', command: 'zig build specs-prague-bls-g2', description: 'Prague EIP-2537 BLS12-381 G2 tests' },
  { name: 'prague-bls-pairing', command: 'zig build specs-prague-bls-pairing', description: 'Prague EIP-2537 BLS12-381 pairing tests' },
  { name: 'prague-bls-map', command: 'zig build specs-prague-bls-map', description: 'Prague EIP-2537 BLS12-381 map tests' },
  { name: 'prague-bls-misc', command: 'zig build specs-prague-bls-misc', description: 'Prague EIP-2537 BLS12-381 misc tests' },
  { name: 'prague-setcode-calls', command: 'zig build specs-prague-setcode-calls', description: 'Prague EIP-7702 set code call tests' },
  { name: 'prague-setcode-gas', command: 'zig build specs-prague-setcode-gas', description: 'Prague EIP-7702 set code gas tests' },
  { name: 'prague-setcode-txs', command: 'zig build specs-prague-setcode-txs', description: 'Prague EIP-7702 set code transaction tests' },
  { name: 'prague-setcode-advanced', command: 'zig build specs-prague-setcode-advanced', description: 'Prague EIP-7702 advanced set code tests' },

  // Osaka sub-targets (broken up from large test suite)
  { name: 'osaka-modexp-variable-gas', command: 'zig build specs-osaka-modexp-variable-gas', description: 'Osaka EIP-7883 modexp variable gas tests' },
  { name: 'osaka-modexp-vectors-eip', command: 'zig build specs-osaka-modexp-vectors-eip', description: 'Osaka EIP-7883 modexp vectors from EIP tests' },
  { name: 'osaka-modexp-vectors-legacy', command: 'zig build specs-osaka-modexp-vectors-legacy', description: 'Osaka EIP-7883 modexp vectors from legacy tests' },
  { name: 'osaka-modexp-misc', command: 'zig build specs-osaka-modexp-misc', description: 'Osaka EIP-7883 modexp misc tests' },
  { name: 'osaka-other', command: 'zig build specs-osaka-other', description: 'Osaka other EIP tests' },

  // Shanghai EIPs
  { name: 'shanghai-warmcoinbase', command: 'zig build specs-shanghai-warmcoinbase', description: 'Shanghai EIP-3651 warm coinbase tests' },
  { name: 'shanghai-initcode-basic', command: 'zig build specs-shanghai-initcode-basic', description: 'Shanghai EIP-3860 initcode basic tests (162 tests)' },
  { name: 'shanghai-initcode-eof', command: 'zig build specs-shanghai-initcode-eof', description: 'Shanghai EIP-3860 initcode EOF tests (24 tests)' },

  // Byzantium sub-targets
  { name: 'byzantium-modexp', command: 'zig build specs-byzantium-modexp', description: 'Byzantium EIP-198 modexp precompile tests (352 tests)' },
  // Berlin sub-targets (broken up from large test suite)
  { name: 'berlin-acl', command: 'zig build specs-berlin-acl', description: 'Berlin EIP-2930 access list account storage tests' },
  { name: 'berlin-intrinsic-gas-cost', command: 'zig build specs-berlin-intrinsic-gas-cost', description: 'Berlin EIP-2930 transaction intrinsic gas cost tests' },
  { name: 'berlin-intrinsic-type0', command: 'zig build specs-berlin-intrinsic-type0', description: 'Berlin EIP-2930 intrinsic gas type 0 transaction tests' },
  { name: 'berlin-intrinsic-type1', command: 'zig build specs-berlin-intrinsic-type1', description: 'Berlin EIP-2930 intrinsic gas type 1 transaction tests' },

  // Frontier sub-targets (broken up from large test suite)
  { name: 'frontier-precompiles', command: 'zig build specs-frontier-precompiles', description: 'Frontier precompile tests' },
  { name: 'frontier-identity', command: 'zig build specs-frontier-identity', description: 'Frontier identity precompile tests' },
  { name: 'frontier-create', command: 'zig build specs-frontier-create', description: 'Frontier CREATE tests' },
  { name: 'frontier-call', command: 'zig build specs-frontier-call', description: 'Frontier CALL/CALLCODE tests' },
  { name: 'frontier-calldata', command: 'zig build specs-frontier-calldata', description: 'Frontier calldata opcode tests' },
  { name: 'frontier-dup', command: 'zig build specs-frontier-dup', description: 'Frontier DUP tests' },
  { name: 'frontier-push', command: 'zig build specs-frontier-push', description: 'Frontier PUSH tests' },
  { name: 'frontier-stack', command: 'zig build specs-frontier-stack', description: 'Frontier stack overflow tests' },
  { name: 'frontier-opcodes', command: 'zig build specs-frontier-opcodes', description: 'Frontier all opcodes tests' },
  { name: 'constantinople-bitshift', command: 'zig build specs-constantinople-bitshift', description: 'Constantinople EIP-145 bitwise shift tests (~250 tests)' },
  { name: 'constantinople-create2', command: 'zig build specs-constantinople-create2', description: 'Constantinople EIP-1014 CREATE2 tests (~250 tests)' },
  { name: 'istanbul-blake2', command: 'zig build specs-istanbul-blake2', description: 'Istanbul EIP-152 BLAKE2 precompile tests' },
  { name: 'istanbul-chainid', command: 'zig build specs-istanbul-chainid', description: 'Istanbul EIP-1344 CHAINID tests' },
  { name: 'cancun-selfdestruct-basic', command: 'zig build specs-cancun-selfdestruct-basic', description: 'Cancun EIP-6780 basic SELFDESTRUCT tests (306 tests)' },
  { name: 'cancun-selfdestruct-collision', command: 'zig build specs-cancun-selfdestruct-collision', description: 'Cancun EIP-6780 create2 collision tests (52 tests)' },
  { name: 'cancun-selfdestruct-reentrancy', command: 'zig build specs-cancun-selfdestruct-reentrancy', description: 'Cancun EIP-6780 reentrancy revert tests (36 tests)' },
  { name: 'cancun-selfdestruct-revert', command: 'zig build specs-cancun-selfdestruct-revert', description: 'Cancun EIP-6780 revert tests (12 tests)' },
];

interface TestResult {
  suite: string;
  passed: boolean;
  output: string;
  error?: string;
}

interface FixAttempt {
  suite: string;
  attempt: number;
  success: boolean;
  agentCost: number;
  agentTurns: number;
  agentDuration: number;
  error?: string;
}

class SpecFixerPipeline {
  private reportsDir = join(REPO_ROOT, "reports", "spec-fixes");
  private maxAttemptsPerSuite = 2;
  private fixAttempts: FixAttempt[] = [];
  private knownIssues: KnownIssuesDatabase;
  private agentEnabled: boolean;
  private testType: "state" | "blockchain";

  constructor(testType: "state" | "blockchain" = "state") {
    this.testType = testType;

    if (!existsSync(this.reportsDir)) {
      mkdirSync(this.reportsDir, { recursive: true });
    }

    // Load known issues database
    this.knownIssues = this.loadKnownIssues();

    // Check if agent is enabled
    this.agentEnabled = !!process.env.ANTHROPIC_API_KEY;
    if (!this.agentEnabled) {
      console.log(
        "ℹ️  ANTHROPIC_API_KEY not set. Agent auto-fix disabled. Tests will run, but no AI fixes will be attempted.",
      );
    }

    console.log(`🎯 Running ${testType.toUpperCase()} tests`);
  }

  private loadKnownIssues(): KnownIssuesDatabase {
    try {
      if (existsSync(KNOWN_ISSUES_PATH)) {
        const content = readFileSync(KNOWN_ISSUES_PATH, "utf-8");
        return JSON.parse(content);
      }
    } catch (error) {
      console.warn(`⚠️  Could not load known issues database: ${error}`);
    }
    return { issues: {} };
  }

  private getKnownIssueContext(suiteName: string): string {
    const issue = this.knownIssues.issues[suiteName];
    if (!issue) {
      return "";
    }

    return `
<known_issues>
## Known Issues for ${suiteName}

**Description**: ${issue.description}

### Common Causes
${issue.common_causes.map((cause, i) => `${i + 1}. ${cause}`).join("\n")}

### Relevant Files to Check
${issue.relevant_files.map((file) => `- \`${file}\``).join("\n")}

### Python Reference Location
\`${issue.python_ref}\`

### Key Invariants
${issue.key_invariants.map((inv) => `- ${inv}`).join("\n")}

${issue.gas_costs ? `### Expected Gas Costs
${Object.entries(issue.gas_costs)
  .map(([op, cost]) => `- **${op}**: ${cost} gas`)
  .join("\n")}
` : ""}

**Note**: This historical context is based on previous debugging sessions. Use it as a guide, but always verify against the current test output and Python reference implementation.
</known_issues>
`;
  }

  runTest(suite: TestSuite): TestResult {
    console.log(`\n${"=".repeat(80)}`);
    console.log(`🧪 Running: ${suite.description}`);
    console.log(`${"=".repeat(80)}`);
    console.log(`Command: ${suite.command}\n`);

    try {
      const output = execSync(suite.command, {
        cwd: REPO_ROOT,
        encoding: "utf-8",
        stdio: "pipe",
        maxBuffer: 10 * 1024 * 1024, // 10MB buffer
      });

      // Extract test count from output
      const testCountMatch = output.match(/(\d+)\s+passed/i);
      const testCount = testCountMatch ? parseInt(testCountMatch[1], 10) : null;

      if (testCount === 0) {
        console.log(`⚠️  Tests were not generated (0 tests)\n`);
      } else if (testCount) {
        console.log(`✅ Tests passed! (${testCount} tests)\n`);
      } else {
        console.log(`✅ Tests passed! (test count unknown)\n`);
      }

      return {
        suite: suite.name,
        passed: true,
        output,
      };
    } catch (error: any) {
      const output = error.stdout || "";
      const errorOutput = error.stderr || "";

      // Try to extract failure info
      const passedMatch = output.match(/(\d+)\s+passed/i);
      const failedMatch = output.match(/(\d+)\s+failed/i);
      const passed = passedMatch ? parseInt(passedMatch[1], 10) : 0;
      const failed = failedMatch ? parseInt(failedMatch[1], 10) : null;

      if (passed === 0 && failed === 0) {
        console.log(`⚠️  Tests were not generated (0 tests)\n`);
      } else if (failed !== null) {
        console.log(`❌ Tests failed (${passed} passed, ${failed} failed)\n`);
      } else {
        console.log(`❌ Tests failed (${passed} passed)\n`);
      }

      return {
        suite: suite.name,
        passed: false,
        output,
        error: errorOutput,
      };
    }
  }

  async fixWithAgent(
    suite: TestSuite,
    testResult: TestResult,
    attemptNumber: number,
  ): Promise<FixAttempt> {
    if (!this.agentEnabled) {
      console.log(
        "⚠️  Agent disabled (no ANTHROPIC_API_KEY). Skipping auto-fix for this suite.",
      );
      return {
        suite: suite.name,
        attempt: attemptNumber,
        success: false,
        agentCost: 0,
        agentTurns: 0,
        agentDuration: 0,
        error: "Agent not configured",
      };
    }
    console.log(`\n${"█".repeat(80)}`);
    console.log(
      `🤖 Starting Agent Fix - Attempt ${attemptNumber}/${this.maxAttemptsPerSuite}`,
    );
    console.log(`Suite: ${suite.description}`);
    console.log(`${"█".repeat(80)}\n`);

    const startTime = Date.now();

    // Include known issues context if available
    const knownIssueContext = this.getKnownIssueContext(suite.name);

    // Load previous pipeline summaries if they exist
    const pipelineSummaryPath = join(this.reportsDir, "pipeline-summary.md");
    const pipelineAiSummaryPath = join(this.reportsDir, "pipeline-summary-ai.md");
    let previousRunContext = "";

    if (existsSync(pipelineSummaryPath) || existsSync(pipelineAiSummaryPath)) {
      try {
        let summaryContent = "";

        // Load AI narrative summary first (high-level overview)
        if (existsSync(pipelineAiSummaryPath)) {
          const aiSummary = readFileSync(pipelineAiSummaryPath, "utf-8");
          summaryContent += `### Executive Summary\n\n${aiSummary}\n\n`;
        }

        // Then load detailed structured summary
        if (existsSync(pipelineSummaryPath)) {
          const pipelineSummary = readFileSync(pipelineSummaryPath, "utf-8");
          summaryContent += `### Detailed Results\n\n${pipelineSummary}`;
        }

        if (summaryContent) {
          previousRunContext = `
<previous_run_summary>
## Previous Pipeline Run

${summaryContent}

**Note**: This summary shows what was attempted in the last pipeline run. Use it to understand patterns, learn from previous attempts, and avoid repeating unsuccessful approaches.
</previous_run_summary>
`;
        }
      } catch (error) {
        console.warn(`⚠️  Could not load previous pipeline summary: ${error}`);
      }
    }

    // Load previous attempt reports for THIS specific suite
    // This includes:
    // 1. All attempts from PREVIOUS pipeline runs
    // 2. Attempts 1 through (attemptNumber-1) from THIS CURRENT run
    let previousAttemptContext = "";
    try {
      const files = readdirSync(this.reportsDir).filter((f) => f.endsWith(".md"));
      const suiteAttempts: { attempt: number; file: string; content: string }[] = [];

      const prefix = `${suite.name}-attempt`;
      for (const f of files) {
        if (f.startsWith(prefix)) {
          const m = f.match(/attempt(\d+)\.md$/);
          if (m) {
            const attemptNum = parseInt(m[1], 10);
            // Include all existing reports from previous runs,
            // AND reports from earlier attempts in this run (attemptNum < attemptNumber)
            // This means on attempt 1, we see previous run attempts
            // On attempt 2, we see previous run attempts + attempt 1 from this run
            // On attempt 3, we see previous run attempts + attempts 1 & 2 from this run
            const fullPath = join(this.reportsDir, f);
            if (existsSync(fullPath)) {
              const content = readFileSync(fullPath, "utf-8");
              suiteAttempts.push({ attempt: attemptNum, file: f, content });
            }
          }
        }
      }

      // Sort by attempt number
      suiteAttempts.sort((a, b) => a.attempt - b.attempt);

      if (suiteAttempts.length > 0) {
        let attemptsContent = "";
        for (const { attempt, file, content } of suiteAttempts) {
          attemptsContent += `\n### Attempt ${attempt} (${file})\n\n${truncate(content, 30 * 1024)}\n\n---\n`;
        }

        previousAttemptContext = `
<previous_attempts_for_this_suite>
## Previous Attempts for ${suite.name}

Found ${suiteAttempts.length} previous attempt(s) for this suite. Review what was tried before:

${attemptsContent}

**Note**: These include attempts from previous pipeline runs AND earlier attempts from this current run. Learn from what worked, what didn't, and what approaches were already tried.
</previous_attempts_for_this_suite>
`;
      }
    } catch (error) {
      console.warn(`⚠️  Could not load previous attempt reports for ${suite.name}: ${error}`);
    }

    const prompt = `<task>
Fix the failing tests in ${suite.description}.
Command: \`${suite.command}\`
</task>

${knownIssueContext}

${previousAttemptContext}

${previousRunContext}

<context>
You're debugging an EVM implementation in Zig. The goal is to make all tests pass by fixing bugs in the implementation.

**Key resources:**
- **Trace analysis**: \`bun scripts/isolate-test.ts "test_name"\` - Shows exact divergence point (PC, opcode, gas, stack)
- **Python reference**: \`execution-specs/src/ethereum/forks/<hardfork>/\` - The authoritative spec (if Zig differs from Python, Zig is wrong)
- **Zig implementation**: \`src/frame.zig\` (opcodes), \`src/evm.zig\` (calls, storage, state)

**Common patterns:**
- Gas divergence → Check gas calculation order, warm/cold tracking, missing charges
- Stack/memory divergence → Check pop/push order, memory expansion cost
- Crashes → Use binary search with panics to isolate exact line

**Architecture notes:**
- Python: Single \`Evm\` class with stack, memory, pc, gas, state
- Zig: Split into \`Evm\` (state, storage, refunds) + \`Frame\` (stack, memory, pc, gas)
- Python \`evm.stack\` = Zig \`frame.stack\`
- Python \`evm.message.block_env.state\` = Zig \`evm.storage\`
</context>

<guidelines>
- Use trace comparison to identify exact divergence point
- Check Python reference implementation for correct behavior
- Make minimal, targeted fixes
- Use \`hardfork.isAtLeast()\` guards for fork-specific behavior
- Verify fixes by re-running tests
- If a fix doesn't work, analyze the new failure and iterate
</guidelines>

<helpful_references>
**File mappings:**
| Issue Type | Python Location | Zig Location |
|------------|----------------|--------------|
| Opcodes | forks/<fork>/vm/instructions/*.py | src/frame.zig |
| Gas costs | forks/<fork>/vm/gas.py | src/primitives/gas_constants.zig + src/frame.zig |
| CALL/CREATE | forks/<fork>/vm/instructions/system.py | src/evm.zig (inner_call, inner_create) |
| Storage | forks/<fork>/vm/instructions/storage.py | src/evm.zig (get/set storage) |

**Common gas costs:**
- Warm access: 100 gas (Berlin+)
- Cold SLOAD: 2100 gas (Berlin+)
- Cold account access: 2600 gas (Berlin+)
- TLOAD/TSTORE: Always 100 gas (Cancun+, never cold)
- SSTORE: Complex (2300 stipend check → cold access → dynamic cost → refunds)

**Debugging commands:**
\`\`\`bash
bun scripts/isolate-test.ts "test_name"  # Detailed trace + divergence analysis
TEST_FILTER="test_name" ${suite.command}  # Run single test
\`\`\`
</helpful_references>

<execution_directive>
Fix the failing tests. Use your judgment on the best approach - trace analysis is usually the fastest path to identifying issues.
</execution_directive>`;

    try {
      let totalCost = 0;
      let totalTurns = 0;
      let agentSuccess = false;

      const result = query({
        prompt,
        options: {
          model: "claude-sonnet-4-5-20250929",
          maxTurns: 350,
          maxThinkingTokens: 32000,
          permissionMode: "bypassPermissions",
          cwd: REPO_ROOT,
        },
      });

      // Stream agent output
      for await (const message of result) {
        if (message.type === "assistant") {
          const content = message.message.content;
          for (const block of content) {
            if (block.type === "text") {
              process.stdout.write(block.text);
            }
          }
        } else if (message.type === "result") {
          if (message.subtype === "success") {
            console.log(`\n\n✅ Agent completed`);
            console.log(`💰 Cost: $${message.total_cost_usd.toFixed(4)}`);
            console.log(`🔄 Turns: ${message.num_turns}`);
            totalCost = message.total_cost_usd;
            totalTurns = message.num_turns;
            agentSuccess = true;

            // Save agent report
            const reportPath = join(
              this.reportsDir,
              `${suite.name}-attempt${attemptNumber}.md`,
            );
            writeFileSync(reportPath, message.result, "utf-8");
            console.log(`📄 Report saved to: ${reportPath}`);
          } else {
            console.log(`\n\n⚠️  Agent did not complete successfully`);
            agentSuccess = false;
          }
        }
      }

      const duration = Date.now() - startTime;

      return {
        suite: suite.name,
        attempt: attemptNumber,
        success: agentSuccess,
        agentCost: totalCost,
        agentTurns: totalTurns,
        agentDuration: duration,
      };
    } catch (error) {
      const duration = Date.now() - startTime;
      console.error(`\n❌ Error running agent:`, error);

      return {
        suite: suite.name,
        attempt: attemptNumber,
        success: false,
        agentCost: 0,
        agentTurns: 0,
        agentDuration: duration,
        error: error instanceof Error ? error.message : String(error),
      };
    }
  }

  async commitWithAgent(suite: TestSuite): Promise<void> {
    console.log(`\n${"█".repeat(80)}`);
    console.log(`📝 Creating commit for: ${suite.name}`);
    console.log(`${"█".repeat(80)}\n`);

    const prompt = `<task>
The ${suite.description} test suite is now passing. Create a git commit for the changes that fixed these tests.
</task>

<context>
This commit represents a significant milestone - a previously failing test suite now passes, bringing us closer to full Ethereum specification compliance.
</context>

<instructions>
## Step 1: Review Changes
Use \`git status\` and \`git diff\` to understand:
- Which files were modified
- What specific changes were made
- The scope and nature of the fix

## Step 2: Craft Commit Message
Follow this structure:

**Format**: \`<type>: <description>\`

**Type Options**:
- \`fix\`: Bug fix in implementation (most common for test fixes)
- \`feat\`: New feature/opcode implementation
- \`perf\`: Performance improvement
- \`refactor\`: Code restructuring without behavior change

**Description Guidelines**:
- Start with "Pass ${suite.description}" or similar
- Mention specific EIP number if relevant (e.g., "EIP-1153", "EIP-3855")
- Mention hardfork if suite-specific (e.g., "Cancun", "Shanghai")
- Be specific about what was fixed (e.g., "Fix TSTORE gas calculation" not just "Fix gas")

**Examples**:
- \`fix: Pass Cancun EIP-1153 transient storage tests\`
- \`fix: Pass Shanghai EIP-3855 PUSH0 tests\`
- \`fix: Pass Istanbul hardfork tests - Fix SELFBALANCE and CHAINID opcodes\`
- \`fix: Pass Berlin EIP-2929 gas cost tests - Correct warm/cold access tracking\`

## Step 3: Include Body (if needed)
For complex fixes, add a commit body explaining:
- Root cause of the failure
- Key changes made
- Any important implementation details

Use the standard format:
\`\`\`
fix: Pass ${suite.description}

- Root cause: [brief explanation]
- Changes: [key changes]
- EIP: [EIP number and name if applicable]
\`\`\`

## Step 4: Create Commit
Use the standard commit format with co-author attribution.
</instructions>

<critical_reminders>
- ✅ **DO** be specific about what was fixed
- ✅ **DO** mention EIP numbers when relevant
- ✅ **DO** use conventional commit format (\`type: description\`)
- ✅ **DO** keep the first line under 72 characters
- ❌ **DO NOT** be vague (e.g., "fix tests")
- ❌ **DO NOT** forget to include the co-author line
- ❌ **DO NOT** commit unrelated changes
</critical_reminders>

<execution_directive>
Create the commit now using git commands.
</execution_directive>`;

    try {
      const result = query({
        prompt,
        options: {
          model: "claude-sonnet-4-5-20250929",
          maxTurns: 10,
          permissionMode: "bypassPermissions",
          cwd: REPO_ROOT,
        },
      });

      // Stream agent output
      for await (const message of result) {
        if (message.type === "assistant") {
          const content = message.message.content;
          for (const block of content) {
            if (block.type === "text") {
              process.stdout.write(block.text);
            }
          }
        } else if (message.type === "result") {
          if (message.subtype === "success") {
            console.log(`\n\n✅ Commit created successfully`);
          } else {
            console.log(`\n\n⚠️  Commit agent did not complete successfully`);
          }
        }
      }
    } catch (error) {
      console.error(`\n❌ Error creating commit:`, error);
    }
  }

  async processTestSuite(suite: TestSuite): Promise<boolean> {
    console.log(`\n${"█".repeat(80)}`);
    console.log(`📋 Processing: ${suite.name}`);
    console.log(`${"█".repeat(80)}`);

    let attemptNumber = 0;

    while (attemptNumber < this.maxAttemptsPerSuite) {
      attemptNumber++;

      // Run the test
      const testResult = this.runTest(suite);

      if (testResult.passed) {
        console.log(`✅ ${suite.name} - All tests passing!`);

        // Only commit if we made changes (attempt > 1 means we ran the agent)
        if (attemptNumber > 1) {
          await this.commitWithAgent(suite);
        } else {
          console.log(`ℹ️  Tests already passing on first run, skipping commit`);
        }

        return true;
      }

      console.log(`❌ ${suite.name} - Tests failing, launching agent fix...`);

      // Try to fix with agent
      const fixAttempt = await this.fixWithAgent(
        suite,
        testResult,
        attemptNumber,
      );
      this.fixAttempts.push(fixAttempt);

      if (!fixAttempt.success) {
        console.log(`⚠️  Agent did not complete successfully, retrying...`);
        continue;
      }

      // Loop will re-run the test to verify the fix
      console.log(`\n🔄 Re-running tests to verify fix...\n`);
    }

    console.log(
      `❌ ${suite.name} - Failed after ${this.maxAttemptsPerSuite} attempts`,
    );
    return false;
  }

  async runAll(): Promise<void> {
    console.log(`\n${"█".repeat(80)}`);
    console.log(`🎯 GUILLOTINE SPEC FIXER PIPELINE - ${this.testType.toUpperCase()} TESTS`);
    console.log(`${"█".repeat(80)}`);
    console.log(`Total Test Suites: ${TEST_SUITES.length}`);
    console.log(`Max Attempts Per Suite: ${this.maxAttemptsPerSuite}`);
    console.log(`Test Type: ${this.testType}`);
    console.log(`${"█".repeat(80)}\n`);

    const pipelineStart = Date.now();
    const results: { suite: string; passed: boolean }[] = [];

    for (const suite of TEST_SUITES) {
      const passed = await this.processTestSuite(suite);
      results.push({ suite: suite.name, passed });

      if (!passed) {
        console.log(
          `\n⚠️  Continuing to next test suite despite failures in ${suite.name}...\n`,
        );
      }
    }

    const pipelineDuration = Date.now() - pipelineStart;

    // Final summary
    console.log(`\n${"█".repeat(80)}`);
    console.log(`🏁 PIPELINE COMPLETE`);
    console.log(`${"█".repeat(80)}`);

    const totalPassed = results.filter((r) => r.passed).length;
    const totalFailed = results.filter((r) => !r.passed).length;
    const totalCost = this.fixAttempts.reduce((sum, a) => sum + a.agentCost, 0);
    const totalAttempts = this.fixAttempts.length;

    console.log(`\n📊 Results:`);
    console.log(`  ✅ Passed: ${totalPassed}/${TEST_SUITES.length}`);
    console.log(`  ❌ Failed: ${totalFailed}/${TEST_SUITES.length}`);
    console.log(`  🤖 Agent Attempts: ${totalAttempts}`);
    console.log(`  💰 Total Cost: $${totalCost.toFixed(4)}`);
    console.log(
      `  ⏱️  Total Duration: ${(pipelineDuration / 1000 / 60).toFixed(1)} minutes`,
    );

    console.log(`\n📋 Detailed Results:`);
    for (const result of results) {
      const status = result.passed ? "✅" : "❌";
      console.log(`  ${status} ${result.suite}`);
    }

    // Save summary
    const summary = this.generateSummary(results, totalCost, pipelineDuration);
    const summaryPath = join(this.reportsDir, "pipeline-summary.md");
    writeFileSync(summaryPath, summary, "utf-8");
    console.log(`\n📊 Summary report: ${summaryPath}`);
    console.log(`${"█".repeat(80)}\n`);

    // Run AI narrative summary at the very end
    try {
      await this.generateAISummaryFromReports(results, totalCost, pipelineDuration);
    } catch (err) {
      console.error("❌ AI summary generation failed:", err);
    }
  }

  generateSummary(
    results: { suite: string; passed: boolean }[],
    totalCost: number,
    duration: number,
  ): string {
    const passed = results.filter((r) => r.passed);
    const failed = results.filter((r) => !r.passed);

    let summary = `# Guillotine Spec Fixer Pipeline - Summary Report

**Generated**: ${new Date().toISOString()}

## Overview

- **Total Test Suites**: ${results.length}
- **Passed**: ${passed.length}
- **Failed**: ${failed.length}
- **Total Agent Attempts**: ${this.fixAttempts.length}
- **Total Cost**: $${totalCost.toFixed(4)}
- **Total Duration**: ${(duration / 1000 / 60).toFixed(1)} minutes

## Test Suite Results

### ✅ Passed (${passed.length})

`;

    for (const result of passed) {
      summary += `- ${result.suite}\n`;
    }

    if (failed.length > 0) {
      summary += `\n### ❌ Failed (${failed.length})\n\n`;
      for (const result of failed) {
        summary += `- ${result.suite}\n`;
      }
    }

    summary += `\n## Agent Fix Attempts

| Suite | Attempt | Success | Cost | Turns | Duration |
|-------|---------|---------|------|-------|----------|
`;

    for (const attempt of this.fixAttempts) {
      const status = attempt.success ? "✅" : "❌";
      summary += `| ${attempt.suite} | ${attempt.attempt} | ${status} | $${attempt.agentCost.toFixed(4)} | ${attempt.agentTurns} | ${(attempt.agentDuration / 1000).toFixed(1)}s |\n`;
    }

    summary += `\n## Next Steps

`;

    if (failed.length > 0) {
      summary += `1. Review failed test suites and agent reports\n`;
      summary += `2. Manually investigate remaining failures\n`;
      summary += `3. Consider increasing maxTurns or maxAttempts for complex fixes\n`;
    } else {
      summary += `🎉 All test suites passing! Great work!\n`;
    }

    return summary;
  }

  // New: AI narrative summary at the very end of the pipeline
  private async generateAISummaryFromReports(
    results: { suite: string; passed: boolean }[],
    totalCost: number,
    durationMs: number,
  ): Promise<void> {
    console.log(`\n${"█".repeat(80)}`);
    console.log("🧠 Generating AI narrative summary (3–4 paragraphs)...");
    console.log(`${"█".repeat(80)}`);

    const pipelineSummaryPath = join(this.reportsDir, "pipeline-summary.md");
    const pipelineSummary = existsSync(pipelineSummaryPath)
      ? readFileSync(pipelineSummaryPath, "utf-8")
      : "";

    // Collect latest attempt report per suite (if available), truncated to keep prompt reasonable
    let attemptBundle = "";
    try {
      const files = readdirSync(this.reportsDir).filter((f) => f.endsWith(".md"));
      const bySuite: Record<string, { attempt: number; file: string }> = {};

      for (const r of results) {
        const prefix = `${r.suite}-attempt`;
        for (const f of files) {
          if (f.startsWith(prefix)) {
            const m = f.match(/attempt(\d+)\.md$/);
            const n = m ? parseInt(m[1], 10) : 0;
            if (!bySuite[r.suite] || n > bySuite[r.suite].attempt) {
              bySuite[r.suite] = { attempt: n, file: f };
            }
          }
        }
      }

      for (const [suite, meta] of Object.entries(bySuite)) {
        const fullPath = join(this.reportsDir, meta.file);
        if (!existsSync(fullPath)) continue;
        const content = readFileSync(fullPath, "utf-8");
        attemptBundle += `\n\n<attempt suite=\"${suite}\" file=\"${meta.file}\">\n`;
        attemptBundle += truncate(content, 20 * 1024); // 20KB per attempt
        attemptBundle += `\n</attempt>`;
      }
    } catch (_) {
      // Non-fatal; continue with whatever we have
    }

    const prompt = `
<task>
Read the pipeline summary and latest attempt reports, then write a concise narrative summary (3–4 paragraphs) of what happened in this spec-fixing run.
</task>

<audience>
Senior engineers and stakeholders tracking progress toward Ethereum execution-spec compliance.
</audience>

<style>
- Narrative prose, no bullet lists.
- 3–4 paragraphs, 250–500 words.
- Cover goals, what was attempted, key outcomes, notable blockers, and pragmatic next steps.
- Avoid code blocks; keep it readable and high level.
</style>

<context>
Total cost: $${totalCost.toFixed(4)}; Duration: ${(durationMs / 60000).toFixed(1)} minutes.
</context>

<pipeline_summary>
${truncate(pipelineSummary || "(no pipeline summary found)", 60 * 1024)}
</pipeline_summary>

<attempt_reports>
${attemptBundle || "(no attempt reports found)"}
</attempt_reports>

<output_requirements>
Only return the 3–4 paragraph narrative. Do not include headings, lists, or extraneous commentary.
</output_requirements>
`;

    try {
      const result = query({
        prompt,
        options: {
          model: "claude-sonnet-4-5-20250929",
          maxTurns: 3,
          permissionMode: "bypassPermissions",
          cwd: REPO_ROOT,
        },
      });

      let narrative = "";
      for await (const message of result) {
        if (message.type === "assistant") {
          const content = message.message.content;
          for (const block of content) {
            if (block.type === "text") {
              process.stdout.write(block.text);
              narrative += block.text;
            }
          }
        }
      }

      const outPath = join(this.reportsDir, "pipeline-summary-ai.md");
      writeFileSync(outPath, narrative.trim(), "utf-8");
      console.log(`\n\n📝 AI summary saved to: ${outPath}`);
    } catch (err) {
      console.error("Failed to run AI summary:", err);
    }
  }

  async runSingleSuite(suiteName: string): Promise<void> {
    const suite = TEST_SUITES.find((s) => s.name === suiteName);
    if (!suite) {
      console.error(`❌ Test suite '${suiteName}' not found`);
      console.log(`\nAvailable suites:`);
      for (const s of TEST_SUITES) {
        console.log(`  - ${s.name}: ${s.description}`);
      }
      return;
    }

    const passed = await this.processTestSuite(suite);

    console.log(`\n${"█".repeat(80)}`);
    if (passed) {
      console.log(`✅ ${suite.name} - All tests passing!`);
    } else {
      console.log(
        `❌ ${suite.name} - Tests still failing after ${this.maxAttemptsPerSuite} attempts`,
      );
    }
    console.log(`${"█".repeat(80)}\n`);
  }
}

// Helper: truncate long text safely
function truncate(text: string, maxBytes: number): string {
  // Simple truncation by code units is acceptable for markdown inputs
  if (Buffer.byteLength(text, "utf8") <= maxBytes) return text;
  let truncated = text;
  while (Buffer.byteLength(truncated, "utf8") > maxBytes) {
    truncated = truncated.slice(0, Math.floor(truncated.length * 0.95));
  }
  return truncated + "\n\n[...truncated for brevity...]";
}

// Extend pipeline with AI summarization

// CLI
async function main() {
  const args = process.argv.slice(2);

  // Check for BLOCKCHAIN_TESTS environment variable
  const testType: "state" | "blockchain" = process.env.BLOCKCHAIN_TESTS === "true" ? "blockchain" : "state";
  const pipeline = new SpecFixerPipeline(testType);

  if (args.length === 0) {
    // Run all test suites
    await pipeline.runAll();
  } else if (args[0] === "suite" && args[1]) {
    // Run specific test suite
    await pipeline.runSingleSuite(args[1]);
  } else {
    console.log(`
Guillotine Spec Fixer Pipeline

Usage:
  bun run scripts/fix-specs.ts              # Run all STATE test suites
  BLOCKCHAIN_TESTS=true bun run scripts/fix-specs.ts  # Run all BLOCKCHAIN test suites
  bun run scripts/fix-specs.ts suite <name> # Run specific test suite

Environment Variables:
  BLOCKCHAIN_TESTS=true     Run blockchain tests instead of state tests (default: state)

Available test suites:
${TEST_SUITES.map((s) => `  ${s.name.padEnd(25)} - ${s.description}`).join("\n")}

Examples:
  bun run scripts/fix-specs.ts suite cancun
  bun run scripts/fix-specs.ts suite shanghai-push0
  BLOCKCHAIN_TESTS=true bun run scripts/fix-specs.ts
    `);
  }
}

main().catch(console.error);
