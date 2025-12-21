/**
 * Prompt Templates for Agent Orchestrator
 *
 * These templates ensure consistent, high-quality prompts for:
 * - Initial issue prompts
 * - Handoff prompts between iterations
 * - Summary requests
 */

/**
 * Generate a high-quality initial prompt from GitHub issue details
 */
export function generateIssuePrompt(
  issueNumber: string,
  issueTitle: string,
  issueBody: string,
  relevantFiles?: string[],
  relevantCommands?: string[]
): string {
  const filesSection = relevantFiles?.length
    ? `### Key Files\n${relevantFiles.map(f => `- \`${f}\``).join('\n')}\n`
    : '';

  const commandsSection = relevantCommands?.length
    ? `### Commands\n\`\`\`bash\n${relevantCommands.join('\n')}\n\`\`\`\n`
    : `### Commands\n\`\`\`bash\n# Build and verify\nzig build && zig build test-opcodes\n\n# Run specific tests\nzig build test-integration -Dtest-filter='<pattern>'\n\`\`\`\n`;

  return `## Issue #${issueNumber}: ${issueTitle}

### Overview
${issueBody}

${filesSection}
${commandsSection}

### Constraints (from CLAUDE.md)

**ZERO TOLERANCE - These patterns are BANNED:**
\`\`\`zig
// NEVER do this
something() catch {};
something() catch null;
something() catch &.{};

// Instead, propagate or handle explicitly
something() catch |err| {
    log.err("Operation failed: {}", .{err});
    return err;
};
\`\`\`

**Other Requirements:**
- Use \`tracer.assert()\` not \`std.debug.assert\`
- Use \`log.debug/warn/err\` not \`std.debug.print\`
- All changes must pass \`zig build && zig build test-opcodes\`
- Follow TDD: understand -> minimal repro -> fix -> verify

### Work Process

1. **Understand**: Read relevant files, understand the problem
2. **Plan**: Design the fix before implementing
3. **Implement**: Make minimal, focused changes
4. **Test**: Run tests after each significant change
5. **Verify**: Ensure all tests pass

### CRITICAL: Handoff Protocol

Before context runs out, you MUST:
1. Summarize all progress made
2. List all files modified with descriptions
3. Document remaining work
4. Provide a complete handoff prompt

Format handoff as:
\`\`\`
## Handoff Prompt
[Complete context for next agent]
\`\`\`
`;
}

/**
 * Generate a handoff request prompt to ask agent for summary
 */
export function generateHandoffRequest(): string {
  return `## CONTEXT HANDOFF REQUEST

The context is approaching its limit. Please provide a comprehensive handoff summary.

### Required Sections

#### 1. Progress Summary
What has been accomplished in this iteration?

#### 2. Files Modified
List all files modified with brief descriptions:
- \`path/to/file.zig\` - Description of changes

#### 3. Test Results
- What tests were run?
- Did they pass? If not, what failed?

#### 4. Remaining Work
What work remains to complete the issue?

#### 5. Key Context
Important context the next agent needs:
- Technical decisions made
- Gotchas discovered
- Dependencies between components

### 6. Handoff Prompt

Provide a COMPLETE, SELF-CONTAINED prompt for the next agent:

\`\`\`
## Handoff Prompt for Issue #[NUMBER]

### Previous Progress
[Summary of what was done]

### Current State
- Files modified: [list]
- Tests passing: [yes/no]

### Remaining Tasks
1. [Task 1]
2. [Task 2]

### Key Context
[Important details]

### Commands
\`\`\`bash
# Continue with:
[relevant commands]
\`\`\`

### Constraints (from CLAUDE.md)
- Zero tolerance for error swallowing
- Use tracer.assert() not std.debug.assert
- All changes must pass: zig build && zig build test-opcodes
\`\`\`

IMPORTANT: The handoff prompt must be self-contained. The next agent will NOT have access to this conversation's context.
`;
}

/**
 * Generate a continuation prompt from previous iteration's handoff
 */
export function generateContinuationPrompt(
  handoffPrompt: string,
  iterationNumber: number,
  previousSummary?: string
): string {
  return `## Continuation from Iteration ${iterationNumber - 1}

This is a continuation of previous work. Review the context below and continue.

---

${handoffPrompt}

---

### Instructions for This Iteration

1. Review the handoff context above
2. Verify the current state matches expectations
3. Continue with the remaining tasks
4. Test changes: \`zig build && zig build test-opcodes\`
5. Before context runs out, provide a handoff summary

${previousSummary ? `### Previous Iteration Summary\n${previousSummary}` : ''}
`;
}

/**
 * Standard issue prompt template
 */
export const ISSUE_TEMPLATE = `## Issue #{{ISSUE_NUMBER}}: {{ISSUE_TITLE}}

### Overview
{{ISSUE_BODY}}

### Technical Context
{{TECHNICAL_CONTEXT}}

### Key Files
{{KEY_FILES}}

### Commands
\`\`\`bash
# Build and test
zig build && zig build test-opcodes

# Run specific tests
zig build test-integration -Dtest-filter='{{FILTER}}'
\`\`\`

### Constraints (from CLAUDE.md)
- Zero tolerance for broken builds/tests
- Zero tolerance for error swallowing (\`catch {}\`)
- Use \`tracer.assert()\` not \`std.debug.assert\`
- All changes must pass tests before completion

### CRITICAL: Handoff Protocol
Before context is exhausted, provide handoff in format:
\`\`\`
## Handoff Prompt
[Complete self-contained context for next agent]
\`\`\`
`;

/**
 * Example of a well-structured issue prompt (Issue #850)
 */
export const EXAMPLE_ISSUE_850 = `## Issue #850: MinimalEvm Error Swallowing in Selfdestruct Cleanup Can Corrupt State

### Overview

**Impact**: Silent state corruption, unreliable differential testing, potential fund loss if bugs go undetected

The MinimalEvm implementation has two critical issues:
1. SELFDESTRUCT pops beneficiary but doesn't transfer balance
2. Error handling swallows errors silently with \`catch {}\`

### Technical Context

**Error Swallowing Patterns Found:**
\`\`\`zig
// src/tracer/minimal_evm.zig:389
frame.execute() catch {
    return CallResult{ .success = false, .gas_left = 0, .output = &[_]u8{} };
};
\`\`\`

**SELFDESTRUCT Implementation (minimal_frame.zig:2001-2016):**
\`\`\`zig
0xff => {
    const beneficiary = try self.popStack();
    _ = beneficiary;  // <-- UNUSED! Should transfer balance
    // ... missing balance transfer and account deletion
},
\`\`\`

### Key Files
- \`src/tracer/minimal_frame.zig\` - SELFDESTRUCT at lines 2001-2016
- \`src/tracer/minimal_evm.zig\` - Error handling at line 389
- \`src/instructions/handlers_system.zig\` - Reference implementation

### Commands
\`\`\`bash
# Build and test
zig build && zig build test-opcodes

# Run SELFDESTRUCT tests
zig build test-opcodes -Dtest-filter='ff_test'
zig build test-integration -Dtest-filter='selfdestruct'

# Search for catch patterns
grep -rn "catch {}" src/tracer/ --include="*.zig"
\`\`\`

### Constraints (from CLAUDE.md)
- Zero tolerance for error swallowing (\`catch {}\`)
- Use \`log.debug/warn/err\` for logging
- All changes must pass: \`zig build && zig build test-opcodes\`

### Expected Deliverables
1. Fixed SELFDESTRUCT to transfer balance
2. Removed error swallowing with proper logging
3. All tests passing
`;
