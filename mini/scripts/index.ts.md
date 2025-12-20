# Code Review: scripts/index.ts

**File:** `/Users/williamcory/guillotine-mini/scripts/index.ts`
**Reviewed:** 2025-10-26
**Total Lines:** 497

---

## Executive Summary

This TypeScript file implements an agent pipeline orchestration system for running automated EVM audit agents using the Anthropic Claude API. The code is generally well-structured but has several issues related to error handling, incomplete features, potential race conditions, and missing validation logic.

**Overall Assessment:** 🟡 Needs Improvement

**Key Concerns:**
- Critical error handling gaps
- Dependency validation logic bypassed
- Missing validation for agent configuration
- No retry/recovery mechanisms
- Type safety could be improved

---

## 1. Incomplete Features

### 1.1 Dependency Validation Bypass (Lines 309-320)

**Severity:** 🔴 CRITICAL

```typescript
// Check dependencies
for (const agent of phaseAgents) {
  if (agent.dependsOn) {
    for (const dep of agent.dependsOn) {
      const depResult = this.results.get(dep);
      if (!depResult || !depResult.success) {
        console.log(`⚠️  Skipping ${agent.name} - dependency ${dep} not completed`);
        continue;  // ❌ BUG: This only skips the inner loop iteration
      }
    }
  }
}
```

**Problem:** The `continue` statement only skips the current dependency check iteration, not the agent itself. All agents are still run via `Promise.all()` on line 323, even if dependencies failed.

**Fix Required:**
```typescript
// Track agents to skip
const agentsToRun = phaseAgents.filter(agent => {
  if (agent.dependsOn) {
    for (const dep of agent.dependsOn) {
      const depResult = this.results.get(dep);
      if (!depResult || !depResult.success) {
        console.log(`⚠️  Skipping ${agent.name} - dependency ${dep} not completed`);
        return false;
      }
    }
  }
  return true;
});

// Run only agents with satisfied dependencies
const results = await Promise.all(agentsToRun.map(agent => this.runAgent(agent)));
```

### 1.2 Missing Result Recording for Skipped Agents

**Severity:** 🟡 MEDIUM

When agents are skipped (or would be, with the fix above), no result is recorded in `this.results`. This means:
- Summary reports may be incomplete
- Downstream phases may not know why dependencies failed
- Cost/duration tracking is inaccurate

**Recommendation:** Record skipped agents with a `skipped` status.

### 1.3 Incomplete Error Handling in Result Streaming (Lines 248-262)

**Severity:** 🟡 MEDIUM

```typescript
} else if (message.type === 'result') {
  if (message.subtype === 'success') {
    // ... success handling
  } else {
    console.log(`\n\n❌ ${agent.name} failed`);
    fullResult = `# ${agent.name} - Incomplete\n\n...`;
  }
}
```

**Problem:** When agent fails, `totalCost` and `totalTurns` are never set (remain 0), but the function continues and marks `success: true` on line 274.

**Fix Required:**
```typescript
} else {
  console.log(`\n\n❌ ${agent.name} failed`);
  totalCost = message.total_cost_usd || 0;
  totalTurns = message.num_turns || 0;
  fullResult = `# ${agent.name} - Incomplete\n\n...`;

  const agentResult: AgentResult = {
    agentId: agent.id,
    agentName: agent.name,
    success: false,  // Mark as failed
    outputFile: reportPath,
    cost: totalCost,
    turns: totalTurns,
    duration: Date.now() - startTime,
  };
  this.results.set(agent.id, agentResult);
  return agentResult;
}
```

### 1.4 Missing Validation for Agent Configuration

**Severity:** 🟡 MEDIUM

No validation that:
- Agent IDs are unique
- Prompt files exist
- Circular dependencies don't exist
- Phase numbers are valid
- Output file paths are valid

**Recommendation:** Add validation in constructor or separate `validate()` method:

```typescript
private validateAgentConfig(): void {
  const ids = new Set<string>();
  const seenDeps = new Map<string, string[]>();

  for (const agent of AGENTS) {
    // Check unique IDs
    if (ids.has(agent.id)) {
      throw new Error(`Duplicate agent ID: ${agent.id}`);
    }
    ids.add(agent.id);

    // Check prompt file exists
    const promptPath = join(REPO_ROOT, agent.promptFile);
    if (!existsSync(promptPath)) {
      throw new Error(`Prompt file not found for ${agent.id}: ${promptPath}`);
    }

    // Check dependencies exist
    if (agent.dependsOn) {
      for (const dep of agent.dependsOn) {
        if (!AGENTS.find(a => a.id === dep)) {
          throw new Error(`Agent ${agent.id} depends on non-existent agent: ${dep}`);
        }
      }
      seenDeps.set(agent.id, agent.dependsOn);
    }
  }

  // Check for circular dependencies (would need graph traversal)
  this.checkCircularDependencies(seenDeps);
}
```

---

## 2. TODOs and Technical Debt

### 2.1 No Explicit TODOs Found

No `TODO`, `FIXME`, or `HACK` comments in the code.

### 2.2 Implicit Technical Debt

1. **No retry logic** - Network failures or transient API errors cause immediate failure
2. **No rate limiting** - Parallel agents may hit API rate limits
3. **No checkpointing** - If pipeline fails midway, entire run is lost
4. **Hardcoded values** - Model name, maxTurns, permissionMode not configurable
5. **No incremental progress save** - Results only saved at end

---

## 3. Bad Code Practices

### 3.1 Silent Error Suppression (Line 245)

```typescript
// Don't accumulate streaming text, we'll use final result
```

**Issue:** Streaming text is displayed but not captured. If `message.result` is empty/missing, the report will be blank with no diagnostic information.

**Recommendation:** Capture streaming text as fallback:
```typescript
if (block.type === 'text') {
  process.stdout.write(block.text);
  fullResult += block.text; // Capture as fallback
}
```

### 3.2 Non-Atomic File Operations (Line 268)

```typescript
const reportPath = join(this.reportsDir, agent.outputFile.split('/').pop()!);
writeFileSync(reportPath, fullResult, 'utf-8');
```

**Issues:**
1. **Non-null assertion (`!`)** - Could crash if `outputFile` is malformed
2. **No atomic write** - Partial writes on crash/interrupt
3. **No write verification** - File could be corrupted but success reported

**Recommendation:**
```typescript
const filename = agent.outputFile.split('/').pop();
if (!filename) {
  throw new Error(`Invalid output file path: ${agent.outputFile}`);
}
const reportPath = join(this.reportsDir, filename);

// Atomic write pattern
const tmpPath = `${reportPath}.tmp`;
writeFileSync(tmpPath, fullResult, 'utf-8');
renameSync(tmpPath, reportPath);
```

### 3.3 Race Condition in Parallel Phase Execution (Line 323)

```typescript
const results = await Promise.all(phaseAgents.map(agent => this.runAgent(agent)));
```

**Issue:** Multiple agents write to `this.results` concurrently without synchronization. While JavaScript's event loop prevents true race conditions, logical errors could occur if agents check `this.results` during execution.

**Current Risk:** LOW (agents don't currently read `this.results` during execution)
**Future Risk:** MEDIUM (if agents start checking dependency results during execution)

### 3.4 Inconsistent Error Handling

**Lines 284-300:** Exception handler returns `AgentResult` with `success: false`
**Lines 248-262:** Non-success result path still marks `success: true`

**Recommendation:** Unify error handling logic into a single code path.

### 3.5 Magic Numbers

```typescript
maxTurns: 1000, // EXHAUSTIVE analysis for mission-critical financial software
```

**Issue:** Hardcoded values make testing and configuration difficult.

**Recommendation:** Extract to configuration:
```typescript
interface PipelineConfig {
  maxTurns: number;
  model: string;
  permissionMode: 'bypassPermissions' | 'requirePermissions';
  parallelAgents?: number; // Add limit on parallel execution
}

const DEFAULT_CONFIG: PipelineConfig = {
  maxTurns: 1000,
  model: 'claude-sonnet-4-5-20250929',
  permissionMode: 'bypassPermissions',
};
```

### 3.6 Missing Input Sanitization

**Line 472:** `parseInt(args[1])` - No validation that result is valid phase number
**Line 476:** `args[1]` - No validation that agent ID exists

**Recommendation:**
```typescript
} else if (args[0] === 'phase' && args[1]) {
  const phase = parseInt(args[1]);
  if (isNaN(phase) || !AGENTS.some(a => a.phase === phase)) {
    console.error(`❌ Invalid phase: ${args[1]}`);
    console.log(`Available phases: ${[...new Set(AGENTS.map(a => a.phase))].join(', ')}`);
    process.exit(1);
  }
  await pipeline.runPhase(phase);
}
```

---

## 4. Missing Test Coverage

### 4.1 No Tests Found

No test files exist for this module. Critical functionality is untested:

**Should have tests for:**
- ✅ Agent configuration validation
- ✅ Dependency resolution logic
- ✅ Parallel execution coordination
- ✅ Error handling paths
- ✅ Report generation
- ✅ CLI argument parsing
- ✅ File I/O operations
- ✅ Result aggregation

### 4.2 Recommended Test Structure

```typescript
// index.test.ts
import { test, expect, describe, beforeEach } from "bun:test";
import { AgentPipeline } from "./index";

describe("AgentPipeline", () => {
  describe("Dependency Resolution", () => {
    test("skips agents with failed dependencies", async () => {
      // Test the critical bug found in section 1.1
    });

    test("runs agents with satisfied dependencies", async () => {
      // ...
    });

    test("detects circular dependencies", async () => {
      // ...
    });
  });

  describe("Error Handling", () => {
    test("marks agents as failed when they don't complete", async () => {
      // Test the bug found in section 1.3
    });

    test("records partial results on failure", async () => {
      // ...
    });

    test("handles missing prompt files gracefully", async () => {
      // ...
    });
  });

  describe("Report Generation", () => {
    test("generates valid markdown summary", () => {
      // ...
    });

    test("includes all agent results", () => {
      // ...
    });
  });
});
```

---

## 5. Additional Issues

### 5.1 Performance Concerns

**Line 323:** Unbounded parallelism could:
- Exceed API rate limits
- Consume excessive memory
- Cause connection pool exhaustion

**Recommendation:** Add concurrency limiting:
```typescript
// Use p-limit or similar
import pLimit from 'p-limit';

const limit = pLimit(config.parallelAgents || 5);
const results = await Promise.all(
  phaseAgents.map(agent => limit(() => this.runAgent(agent)))
);
```

### 5.2 Logging and Observability

**Issues:**
- No structured logging (JSON logs for parsing)
- No log levels (debug vs info vs error)
- No timestamps in console output
- No request/response correlation IDs

**Recommendation:** Use structured logging library:
```typescript
import { createLogger } from 'bunyan';

const log = createLogger({
  name: 'agent-pipeline',
  level: process.env.LOG_LEVEL || 'info',
});

log.info({ agentId: agent.id, phase: agent.phase }, 'Starting agent');
```

### 5.3 No Graceful Shutdown

**Issue:** No signal handlers (SIGINT, SIGTERM) to:
- Save partial results
- Clean up temporary files
- Cancel in-flight API requests

**Recommendation:**
```typescript
process.on('SIGINT', async () => {
  console.log('\n🛑 Shutting down gracefully...');

  // Save current results
  const summary = pipeline.generateSummaryReport();
  writeFileSync(join(this.reportsDir, 'pipeline-partial.md'), summary);

  // Clean up
  // ...

  process.exit(0);
});
```

### 5.4 Type Safety Issues

**Line 267:**
```typescript
const reportPath = join(this.reportsDir, agent.outputFile.split('/').pop()!);
```

Non-null assertion operator (`!`) bypasses TypeScript's safety. Should validate instead.

**Line 294:**
```typescript
error: error instanceof Error ? error.message : String(error),
```

Consider using a proper error type:
```typescript
interface AgentError {
  message: string;
  stack?: string;
  code?: string;
}

function toAgentError(error: unknown): AgentError {
  if (error instanceof Error) {
    return {
      message: error.message,
      stack: error.stack,
    };
  }
  return { message: String(error) };
}
```

### 5.5 Missing Cost Budget Checks

**Issue:** No validation that total cost stays within budget.

**Recommendation:**
```typescript
interface PipelineConfig {
  maxBudgetUSD?: number;
}

async runAgent(agent: AgentConfig): Promise<AgentResult> {
  const currentTotal = Array.from(this.results.values())
    .reduce((sum, r) => sum + r.cost, 0);

  if (this.config.maxBudgetUSD && currentTotal >= this.config.maxBudgetUSD) {
    throw new Error(`Budget exceeded: $${currentTotal.toFixed(2)}`);
  }
  // ...
}
```

### 5.6 Prompt Injection Risk

**Lines 210-221:** User-controlled `promptContent` is directly concatenated into the final prompt without sanitization.

**Current Risk:** LOW (prompt files are checked into repo, not user input)
**Future Risk:** MEDIUM (if allowing custom prompts via CLI)

**Recommendation:** If adding custom prompt support, validate/sanitize input.

---

## 6. Security Considerations

### 6.1 API Key Exposure

**Line 455-464:** Warning about missing API key is good, but doesn't prevent execution.

**Current Behavior:** Pipeline continues and fails on first agent run.

**Recommendation:** Fail fast:
```typescript
if (!process.env.ANTHROPIC_API_KEY && args.length > 0 && args[0] !== 'help') {
  console.error('❌ ANTHROPIC_API_KEY is required to run agents');
  process.exit(1);
}
```

### 6.2 Path Traversal

**Line 206:**
```typescript
const promptPath = join(REPO_ROOT, agent.promptFile);
```

If `agent.promptFile` contains `../`, could read files outside intended directory.

**Current Risk:** LOW (AGENTS array is hardcoded)
**Future Risk:** MEDIUM (if loading agent configs from files)

**Recommendation:** Validate paths:
```typescript
import { resolve, relative } from 'path';

const promptPath = resolve(REPO_ROOT, agent.promptFile);
const relativePath = relative(REPO_ROOT, promptPath);

if (relativePath.startsWith('..')) {
  throw new Error(`Invalid prompt path (outside repo): ${agent.promptFile}`);
}
```

### 6.3 No File Size Limits

**Line 207:** `readFileSync(promptPath, 'utf-8')` - No size validation

**Recommendation:**
```typescript
const MAX_PROMPT_SIZE = 1024 * 1024; // 1MB
const stats = statSync(promptPath);

if (stats.size > MAX_PROMPT_SIZE) {
  throw new Error(`Prompt file too large: ${promptPath} (${stats.size} bytes)`);
}
```

---

## 7. Recommendations Summary

### High Priority (Must Fix)

1. 🔴 **Fix dependency validation bypass** (Section 1.1) - Agents run despite failed dependencies
2. 🔴 **Fix success marking on failure** (Section 1.3) - Failed agents marked as successful
3. 🟡 **Add agent configuration validation** (Section 1.4) - Catch errors early
4. 🟡 **Add input validation** (Section 3.6) - Prevent invalid CLI usage

### Medium Priority (Should Fix)

5. 🟡 **Add concurrency limiting** (Section 5.1) - Prevent rate limit issues
6. 🟡 **Implement atomic file writes** (Section 3.2) - Prevent corrupted reports
7. 🟡 **Record skipped agents** (Section 1.2) - Complete audit trail
8. 🟡 **Add graceful shutdown** (Section 5.3) - Save work on interruption

### Low Priority (Nice to Have)

9. 🟢 **Add test coverage** (Section 4) - Catch regressions
10. 🟢 **Add structured logging** (Section 5.2) - Better observability
11. 🟢 **Extract configuration** (Section 3.5) - More flexible
12. 🟢 **Add retry logic** (Section 2.2) - Handle transient failures
13. 🟢 **Add cost budget checks** (Section 5.5) - Prevent runaway costs

---

## 8. Positive Aspects

Despite the issues, the code has several strengths:

✅ **Clear structure** - Well-organized classes and methods
✅ **Good naming** - Variables and functions are descriptive
✅ **Comprehensive comments** - Key sections explained
✅ **Progress reporting** - Excellent user feedback during execution
✅ **Phase-based execution** - Logical organization of agent pipeline
✅ **Summary generation** - Helpful final report
✅ **CLI interface** - Flexible execution modes

---

## 9. Conclusion

The code provides a solid foundation for agent orchestration but requires critical bug fixes before production use, particularly around:

1. Dependency validation
2. Error handling consistency
3. Result recording accuracy

The codebase would significantly benefit from:
- Comprehensive test suite
- Configuration externalization
- Enhanced error recovery mechanisms
- Better observability

**Recommended Action:** Address high-priority items before deploying to production, especially for "mission-critical financial software" (as noted in the comment on line 232).

---

**Review Completed:** 2025-10-26
**Reviewer:** Claude Code Agent
**Next Review:** After implementing high-priority fixes
