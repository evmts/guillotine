# Agent Orchestrator

Automates the agent loop workflow for continuous development on Guillotine EVM.

## Overview

The orchestrator manages an iterative agent loop:

1. **Initialize** - Start with a high-quality prompt (from issue or manual input)
2. **Execute** - Run agent until context limit or task completion
3. **Handoff** - Generate handoff prompt and iteration report
4. **Commit** - Commit changes with clear message
5. **Continue** - Loop back with handoff prompt

## Installation

```bash
cd scripts/agent-orchestrator
npm install
```

## Usage

### From GitHub Issue

```bash
# Run with issue number (will fetch from GitHub)
npm run dev -- --issue 850

# With max iterations limit
npm run dev -- --issue 850 --max-iterations 5
```

### From Prompt File

```bash
# Create a prompt file
cat > prompts/my-task.md << 'EOF'
## Task: Fix the authentication module

### Context
The auth module has a bug where tokens expire too quickly.

### Key Files
- src/auth/token.zig
- src/auth/validator.zig

### Commands
zig build && zig build test-unit -Dtest-filter='auth'
EOF

# Run with prompt file
npm run dev -- --prompt-file prompts/my-task.md
```

### From Direct Prompt

```bash
npm run dev -- --prompt "Fix the memory leak in stack.zig line 42"
```

## Workflow

### What Happens Each Iteration

1. Agent receives prompt and works on the task
2. When context is running low, agent generates handoff summary
3. Orchestrator saves iteration report to `reports/`
4. Changes are committed with standardized message
5. Handoff prompt becomes the next iteration's input

### Reports

Each iteration generates a markdown report in `reports/`:

```
reports/
├── issue-850-iter-1-2025-01-15T10-30-00.md
├── issue-850-iter-2-2025-01-15T10-45-00.md
└── issue-850-iter-3-2025-01-15T11-00-00.md
```

Report contents:
- Iteration metadata (timing, status)
- Initial prompt (truncated)
- Summary of work done
- Files modified
- Test results
- Handoff prompt for next iteration

### Commits

Each iteration commits with format:
```
fix(#850): Iteration 1 - Fixed SELFDESTRUCT balance transfer

Automated commit from agent-orchestrator.
Files changed: 2

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
```

## Writing Good Initial Prompts

### Structure

```markdown
## Issue #NUMBER: TITLE

### Overview
Clear description of the problem and expected outcome.

### Technical Context
Relevant background information, error messages, etc.

### Key Files
- `path/to/file.zig` - Description
- `another/file.zig` - Description

### Commands
\`\`\`bash
zig build && zig build test-opcodes
\`\`\`

### Constraints (from CLAUDE.md)
- Key rules from CLAUDE.md that apply

### CRITICAL: Handoff Protocol
Before context runs out, provide handoff prompt.
```

### Key Elements

1. **Clear Problem Statement** - What needs to be fixed
2. **Relevant Files** - Where to look
3. **Commands** - How to test
4. **Constraints** - Rules to follow
5. **Handoff Instruction** - Ensures continuity

## Configuration

### Environment Variables

- `GITHUB_TOKEN` - For fetching issue details (optional)
- `ANTHROPIC_API_KEY` - For Claude API (required by claude-code)

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--issue` | - | GitHub issue number |
| `--prompt-file` | - | Path to prompt file |
| `--prompt` | - | Direct prompt text |
| `--max-iterations` | 10 | Maximum iterations |

## Example Session

```bash
$ npm run dev -- --issue 850 --max-iterations 3

============================================================
Agent Orchestrator - Issue #850
============================================================

--- Iteration 1 ---

Running agent with prompt...
[Agent output streaming...]

Requesting handoff summary...
[Agent provides summary...]

Running tests...
Tests passed!

Report saved to: reports/issue-850-iter-1-2025-01-15T10-30-00.md
[main abc1234] fix(#850): Iteration 1 - Fixed SELFDESTRUCT

--- Iteration 2 ---
...

============================================================
Orchestrator finished after 2 iteration(s)
Status: COMPLETED
============================================================
```

## Troubleshooting

### Agent Not Providing Handoff

If the agent doesn't provide a handoff prompt, the orchestrator will:
1. Explicitly request one
2. If still missing, stop the loop

### Tests Failing

The orchestrator will:
1. Record test failures in the report
2. Include failure info in handoff prompt
3. Continue to next iteration

### Context Exhausted Mid-Task

The agent should proactively provide handoff when context is low.
The orchestrator will request handoff if not provided.

## Development

```bash
# Build TypeScript
npm run build

# Run directly with tsx
npm run dev -- --issue 850

# Run compiled version
npm start -- --issue 850
```
