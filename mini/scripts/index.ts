import { query } from '@anthropic-ai/claude-agent-sdk';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

// Get repo root (parent of scripts directory)
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const REPO_ROOT = join(__dirname, '..');

// Agent pipeline configuration
interface AgentConfig {
  id: string;
  name: string;
  promptFile: string;
  phase: number;
  dependsOn?: string[];
  outputFile: string;
}

const AGENTS: AgentConfig[] = [
  // Phase 1: Foundation
  {
    id: 'agent1',
    name: 'Primitives Auditor',
    promptFile: 'prompts/phase1-agent1-primitives.md',
    phase: 1,
    outputFile: 'reports/phase1-agent1-primitives-report.md',
  },
  {
    id: 'agent2',
    name: 'State Management Auditor',
    promptFile: 'prompts/phase1-agent2-state-management.md',
    phase: 1,
    outputFile: 'reports/phase1-agent2-state-management-report.md',
  },

  // Phase 2: Opcodes (can run in parallel)
  {
    id: 'agent3',
    name: 'Arithmetic Opcodes Auditor',
    promptFile: 'prompts/phase2-agent3-arithmetic.md',
    phase: 2,
    dependsOn: ['agent1'],
    outputFile: 'reports/phase2-agent3-arithmetic-report.md',
  },
  {
    id: 'agent4',
    name: 'Bitwise and Comparison Opcodes Auditor',
    promptFile: 'prompts/phase2-agent4-bitwise.md',
    phase: 2,
    dependsOn: ['agent1'],
    outputFile: 'reports/phase2-agent4-bitwise-report.md',
  },
  {
    id: 'agent5',
    name: 'Stack and Memory Opcodes Auditor',
    promptFile: 'prompts/phase2-agent5-stack-memory.md',
    phase: 2,
    dependsOn: ['agent1'],
    outputFile: 'reports/phase2-agent5-stack-memory-report.md',
  },
  {
    id: 'agent6',
    name: 'Storage Opcodes Auditor',
    promptFile: 'prompts/phase2-agent6-storage.md',
    phase: 2,
    dependsOn: ['agent1', 'agent2'],
    outputFile: 'reports/phase2-agent6-storage-report.md',
  },
  {
    id: 'agent7',
    name: 'Environment Opcodes Auditor',
    promptFile: 'prompts/phase2-agent7-environment.md',
    phase: 2,
    dependsOn: ['agent1', 'agent2'],
    outputFile: 'reports/phase2-agent7-environment-report.md',
  },
  {
    id: 'agent8',
    name: 'Block Context Opcodes Auditor',
    promptFile: 'prompts/phase2-agent8-block.md',
    phase: 2,
    dependsOn: ['agent1'],
    outputFile: 'reports/phase2-agent8-block-report.md',
  },
  {
    id: 'agent9',
    name: 'Keccak256 and Logging Opcodes Auditor',
    promptFile: 'prompts/phase2-agent9-keccak-log.md',
    phase: 2,
    dependsOn: ['agent1', 'agent2'],
    outputFile: 'reports/phase2-agent9-keccak-log-report.md',
  },
  {
    id: 'agent10',
    name: 'Control Flow Opcodes Auditor',
    promptFile: 'prompts/phase2-agent10-control.md',
    phase: 2,
    dependsOn: ['agent1'],
    outputFile: 'reports/phase2-agent10-control-report.md',
  },
  {
    id: 'agent11',
    name: 'System Call Opcodes Auditor',
    promptFile: 'prompts/phase2-agent11-system-calls.md',
    phase: 2,
    dependsOn: ['agent1', 'agent2'],
    outputFile: 'reports/phase2-agent11-system-calls-report.md',
  },
  {
    id: 'agent12',
    name: 'Precompiled Contracts Auditor',
    promptFile: 'prompts/phase2-agent12-precompiles.md',
    phase: 2,
    dependsOn: ['agent1'],
    outputFile: 'reports/phase2-agent12-precompiles-report.md',
  },

  // Phase 3: Integration
  {
    id: 'agent13',
    name: 'Interpreter Loop Auditor',
    promptFile: 'prompts/phase3-agent13-interpreter.md',
    phase: 3,
    dependsOn: ['agent3', 'agent4', 'agent5', 'agent6', 'agent7', 'agent8', 'agent9', 'agent10', 'agent11'],
    outputFile: 'reports/phase3-agent13-interpreter-report.md',
  },
  {
    id: 'agent14',
    name: 'Transaction Processing Auditor',
    promptFile: 'prompts/phase3-agent14-transaction.md',
    phase: 3,
    dependsOn: ['agent1', 'agent2'],
    outputFile: 'reports/phase3-agent14-transaction-report.md',
  },
  {
    id: 'agent15',
    name: 'EIP Compliance Auditor',
    promptFile: 'prompts/phase3-agent15-eip-compliance.md',
    phase: 3,
    dependsOn: ['agent1', 'agent2', 'agent11'],
    outputFile: 'reports/phase3-agent15-eip-compliance-report.md',
  },

  // Phase 4: Test Infrastructure
  {
    id: 'agent16',
    name: 'Test Runner Setup and Fixes',
    promptFile: 'prompts/phase4-agent16-test-runner.md',
    phase: 4,
    dependsOn: [],
    outputFile: 'reports/phase4-agent16-test-runner-report.md',
  },

  // Phase 5: Validation and Iterative Improvement
  {
    id: 'agent17',
    name: 'Test Result Analyzer',
    promptFile: 'prompts/phase5-agent17-test-analyzer.md',
    phase: 5,
    dependsOn: ['agent16'],
    outputFile: 'reports/phase5-agent17-test-analyzer-report.md',
  },
  {
    id: 'agent18',
    name: 'Fix Validator and Iterative Improvement',
    promptFile: 'prompts/phase5-agent18-fix-validator.md',
    phase: 5,
    dependsOn: ['agent17'],
    outputFile: 'reports/phase5-agent18-fix-validator-report.md',
  },
];

interface AgentResult {
  agentId: string;
  agentName: string;
  success: boolean;
  outputFile: string;
  cost: number;
  turns: number;
  duration: number;
  error?: string;
}

class AgentPipeline {
  private results: Map<string, AgentResult> = new Map();
  private reportsDir = join(REPO_ROOT, 'reports');

  constructor() {
    // Create reports directory if it doesn't exist
    if (!existsSync(this.reportsDir)) {
      mkdirSync(this.reportsDir, { recursive: true });
    }
  }

  async runAgent(agent: AgentConfig): Promise<AgentResult> {
    console.log(`\n${'='.repeat(80)}`);
    console.log(`🤖 Running ${agent.name} (${agent.id})`);
    console.log(`${'='.repeat(80)}\n`);

    const startTime = Date.now();

    try {
      // Read the prompt file from repo root
      const promptPath = join(REPO_ROOT, agent.promptFile);
      const promptContent = readFileSync(promptPath, 'utf-8');

      // Build the full prompt
      const fullPrompt = `You are an expert EVM auditor. Your task is to perform a detailed audit following the instructions below.

${promptContent}

IMPORTANT:
- Use the Read tool to examine Zig source files in src/
- Use the Read tool to examine Python reference spec files in execution-specs/
- Use Grep to search for specific patterns or constants
- Provide detailed, actionable findings with specific line numbers
- Format your output as a comprehensive markdown report matching the template in the prompt

Begin your audit now.`;

      let fullResult = '';
      let totalCost = 0;
      let totalTurns = 0;

      // Run the agent from repo root
      const result = query({
        prompt: fullPrompt,
        options: {
          model: 'claude-sonnet-4-5-20250929',
          maxTurns: 1000, // EXHAUSTIVE analysis for mission-critical financial software
          permissionMode: 'bypassPermissions',
          cwd: REPO_ROOT, // Always run from repo root
        }
      });

      // Stream and collect results
      for await (const message of result) {
        if (message.type === 'assistant') {
          const content = message.message.content;
          for (const block of content) {
            if (block.type === 'text') {
              process.stdout.write(block.text);
              // Don't accumulate streaming text, we'll use final result
            }
          }
        } else if (message.type === 'result') {
          if (message.subtype === 'success') {
            console.log(`\n\n✅ ${agent.name} completed successfully`);
            console.log(`💰 Cost: $${message.total_cost_usd.toFixed(4)}`);
            console.log(`🔄 Turns: ${message.num_turns}`);
            totalCost = message.total_cost_usd;
            totalTurns = message.num_turns;
            fullResult = message.result; // Use final result, not streaming text
          } else {
            console.log(`\n\n❌ ${agent.name} failed`);
            // Agent hit error or maxTurns, but might still have partial output
            fullResult = `# ${agent.name} - Incomplete\n\nThe agent did not complete successfully. This may be due to hitting the maxTurns limit or an error.\n\nCheck the console output for details.`;
          }
        }
      }

      const duration = Date.now() - startTime;

      // Save the report
      const reportPath = join(this.reportsDir, agent.outputFile.split('/').pop()!);
      writeFileSync(reportPath, fullResult, 'utf-8');
      console.log(`📄 Report saved to: ${reportPath}`);

      const agentResult: AgentResult = {
        agentId: agent.id,
        agentName: agent.name,
        success: true,
        outputFile: reportPath,
        cost: totalCost,
        turns: totalTurns,
        duration,
      };

      this.results.set(agent.id, agentResult);
      return agentResult;

    } catch (error) {
      const duration = Date.now() - startTime;
      const agentResult: AgentResult = {
        agentId: agent.id,
        agentName: agent.name,
        success: false,
        outputFile: '',
        cost: 0,
        turns: 0,
        duration,
        error: error instanceof Error ? error.message : String(error),
      };

      this.results.set(agent.id, agentResult);
      console.error(`\n❌ Error running ${agent.name}:`, error);
      return agentResult;
    }
  }

  async runPhase(phase: number): Promise<void> {
    const phaseAgents = AGENTS.filter(a => a.phase === phase);
    console.log(`\n${'█'.repeat(80)}`);
    console.log(`🚀 PHASE ${phase}: Running ${phaseAgents.length} agents`);
    console.log(`${'█'.repeat(80)}\n`);

    // Check dependencies
    for (const agent of phaseAgents) {
      if (agent.dependsOn) {
        for (const dep of agent.dependsOn) {
          const depResult = this.results.get(dep);
          if (!depResult || !depResult.success) {
            console.log(`⚠️  Skipping ${agent.name} - dependency ${dep} not completed`);
            continue;
          }
        }
      }
    }

    // Run agents in parallel within the phase
    const results = await Promise.all(phaseAgents.map(agent => this.runAgent(agent)));

    // Phase summary
    console.log(`\n${'█'.repeat(80)}`);
    console.log(`📊 PHASE ${phase} SUMMARY`);
    console.log(`${'█'.repeat(80)}`);

    for (const result of results) {
      const status = result.success ? '✅' : '❌';
      console.log(`${status} ${result.agentName}`);
      if (result.success) {
        console.log(`   Cost: $${result.cost.toFixed(4)} | Turns: ${result.turns} | Duration: ${(result.duration / 1000).toFixed(1)}s`);
        console.log(`   Report: ${result.outputFile}`);
      } else {
        console.log(`   Error: ${result.error}`);
      }
    }
  }

  async runAll(): Promise<void> {
    const phases = [...new Set(AGENTS.map(a => a.phase))].sort();

    console.log(`\n${'█'.repeat(80)}`);
    console.log(`🎯 GUILLOTINE EVM AUDIT PIPELINE`);
    console.log(`${'█'.repeat(80)}`);
    console.log(`Total Agents: ${AGENTS.length}`);
    console.log(`Phases: ${phases.join(', ')}`);
    console.log(`${'█'.repeat(80)}\n`);

    const pipelineStart = Date.now();

    for (const phase of phases) {
      await this.runPhase(phase);
    }

    const pipelineDuration = Date.now() - pipelineStart;

    // Final summary
    console.log(`\n${'█'.repeat(80)}`);
    console.log(`🏁 PIPELINE COMPLETE`);
    console.log(`${'█'.repeat(80)}`);

    const successful = Array.from(this.results.values()).filter(r => r.success).length;
    const failed = Array.from(this.results.values()).filter(r => !r.success).length;
    const totalCost = Array.from(this.results.values()).reduce((sum, r) => sum + r.cost, 0);

    console.log(`✅ Successful: ${successful}`);
    console.log(`❌ Failed: ${failed}`);
    console.log(`💰 Total Cost: $${totalCost.toFixed(4)}`);
    console.log(`⏱️  Total Duration: ${(pipelineDuration / 1000 / 60).toFixed(1)} minutes`);
    console.log(`📁 Reports saved to: ${this.reportsDir}`);
    console.log(`${'█'.repeat(80)}\n`);

    // Save summary report
    const summary = this.generateSummaryReport();
    const summaryPath = join(this.reportsDir, 'pipeline-summary.md');
    writeFileSync(summaryPath, summary, 'utf-8');
    console.log(`📊 Summary report: ${summaryPath}\n`);
  }

  generateSummaryReport(): string {
    const successful = Array.from(this.results.values()).filter(r => r.success);
    const failed = Array.from(this.results.values()).filter(r => !r.success);
    const totalCost = Array.from(this.results.values()).reduce((sum, r) => sum + r.cost, 0);
    const totalDuration = Array.from(this.results.values()).reduce((sum, r) => sum + r.duration, 0);

    let report = `# Guillotine EVM Audit Pipeline - Summary Report

**Generated**: ${new Date().toISOString()}

## Overview

- **Total Agents**: ${this.results.size}
- **Successful**: ${successful.length}
- **Failed**: ${failed.length}
- **Total Cost**: $${totalCost.toFixed(4)}
- **Total Duration**: ${(totalDuration / 1000 / 60).toFixed(1)} minutes

## Agent Results

### ✅ Successful Agents

| Agent | Phase | Cost | Turns | Duration | Report |
|-------|-------|------|-------|----------|--------|
`;

    for (const result of successful) {
      report += `| ${result.agentName} | - | $${result.cost.toFixed(4)} | ${result.turns} | ${(result.duration / 1000).toFixed(1)}s | [Report](${result.outputFile}) |\n`;
    }

    if (failed.length > 0) {
      report += `\n### ❌ Failed Agents\n\n`;
      for (const result of failed) {
        report += `- **${result.agentName}**: ${result.error}\n`;
      }
    }

    report += `\n## Next Steps

1. Review individual agent reports in the \`reports/\` directory
2. Prioritize fixes based on agent findings
3. Focus on CRITICAL and HIGH priority issues first
4. Run Phase 4 (Test Infrastructure) after implementing fixes
5. Use Phase 5 (Test Validation) to verify fixes

## Key Findings Summary

Review the following reports for critical issues:
`;

    for (const result of successful) {
      report += `- [${result.agentName}](${result.outputFile})\n`;
    }

    return report;
  }

  async runSingleAgent(agentId: string): Promise<void> {
    const agent = AGENTS.find(a => a.id === agentId);
    if (!agent) {
      console.error(`❌ Agent ${agentId} not found`);
      console.log(`Available agents: ${AGENTS.map(a => a.id).join(', ')}`);
      return;
    }

    await this.runAgent(agent);
  }
}

// CLI
async function main() {
  const args = process.argv.slice(2);
  if (!process.env.ANTHROPIC_API_KEY) {
    console.log(
      "ℹ️  ANTHROPIC_API_KEY not set. Agent pipeline requires an Anthropic API key.\n" +
        "    Set it in your environment, e.g.:\n" +
        "      export ANTHROPIC_API_KEY=sk-ant-...\n" +
        "    Or create a .env file at repo root (Bun loads it automatically).\n" +
        "    See scripts/README.md for setup.\n",
    );
    // Still allow printing usage/help without failing hard
  }
  const pipeline = new AgentPipeline();

  if (args.length === 0) {
    // Run all phases
    await pipeline.runAll();
  } else if (args[0] === 'phase' && args[1]) {
    // Run specific phase
    const phase = parseInt(args[1]);
    await pipeline.runPhase(phase);
  } else if (args[0] === 'agent' && args[1]) {
    // Run specific agent
    await pipeline.runSingleAgent(args[1]);
  } else {
    console.log(`
Guillotine EVM Audit Pipeline

Usage:
  bun run scripts/index.ts              # Run all phases
  bun run scripts/index.ts phase <N>    # Run specific phase
  bun run scripts/index.ts agent <ID>   # Run specific agent

Available agents:
${AGENTS.map(a => `  ${a.id.padEnd(10)} - Phase ${a.phase}: ${a.name}`).join('\n')}

Examples:
  bun run scripts/index.ts phase 1
  bun run scripts/index.ts agent agent1
    `);
  }
}

main().catch(console.error);
