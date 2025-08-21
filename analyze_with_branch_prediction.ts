#!/usr/bin/env bun
/**
 * EVM Bytecode Analysis with Simple Branch Prediction
 * 
 * Uses 2-bit saturating counters to predict JUMPI behavior and create
 * extended blocks based on runtime behavior rather than static analysis.
 */

interface Opcode {
  name: string;
  inputs: number;
  outputs: number;
}

const OPCODES: Record<number, Opcode> = {
  0x00: { name: "STOP", inputs: 0, outputs: 0 },
  0x01: { name: "ADD", inputs: 2, outputs: 1 },
  0x02: { name: "MUL", inputs: 2, outputs: 1 },
  0x03: { name: "SUB", inputs: 2, outputs: 1 },
  0x04: { name: "DIV", inputs: 2, outputs: 1 },
  0x05: { name: "SDIV", inputs: 2, outputs: 1 },
  0x06: { name: "MOD", inputs: 2, outputs: 1 },
  0x07: { name: "SMOD", inputs: 2, outputs: 1 },
  0x08: { name: "ADDMOD", inputs: 3, outputs: 1 },
  0x09: { name: "MULMOD", inputs: 3, outputs: 1 },
  0x0a: { name: "EXP", inputs: 2, outputs: 1 },
  0x0b: { name: "SIGNEXTEND", inputs: 2, outputs: 1 },
  0x10: { name: "LT", inputs: 2, outputs: 1 },
  0x11: { name: "GT", inputs: 2, outputs: 1 },
  0x12: { name: "SLT", inputs: 2, outputs: 1 },
  0x13: { name: "SGT", inputs: 2, outputs: 1 },
  0x14: { name: "EQ", inputs: 2, outputs: 1 },
  0x15: { name: "ISZERO", inputs: 1, outputs: 1 },
  0x16: { name: "AND", inputs: 2, outputs: 1 },
  0x17: { name: "OR", inputs: 2, outputs: 1 },
  0x18: { name: "XOR", inputs: 2, outputs: 1 },
  0x19: { name: "NOT", inputs: 1, outputs: 1 },
  0x1a: { name: "BYTE", inputs: 2, outputs: 1 },
  0x1b: { name: "SHL", inputs: 2, outputs: 1 },
  0x1c: { name: "SHR", inputs: 2, outputs: 1 },
  0x1d: { name: "SAR", inputs: 2, outputs: 1 },
  0x20: { name: "KECCAK256", inputs: 2, outputs: 1 },
  0x30: { name: "ADDRESS", inputs: 0, outputs: 1 },
  0x31: { name: "BALANCE", inputs: 1, outputs: 1 },
  0x32: { name: "ORIGIN", inputs: 0, outputs: 1 },
  0x33: { name: "CALLER", inputs: 0, outputs: 1 },
  0x34: { name: "CALLVALUE", inputs: 0, outputs: 1 },
  0x35: { name: "CALLDATALOAD", inputs: 1, outputs: 1 },
  0x36: { name: "CALLDATASIZE", inputs: 0, outputs: 1 },
  0x37: { name: "CALLDATACOPY", inputs: 3, outputs: 0 },
  0x38: { name: "CODESIZE", inputs: 0, outputs: 1 },
  0x39: { name: "CODECOPY", inputs: 3, outputs: 0 },
  0x3a: { name: "GASPRICE", inputs: 0, outputs: 1 },
  0x3b: { name: "EXTCODESIZE", inputs: 1, outputs: 1 },
  0x3c: { name: "EXTCODECOPY", inputs: 4, outputs: 0 },
  0x3d: { name: "RETURNDATASIZE", inputs: 0, outputs: 1 },
  0x3e: { name: "RETURNDATACOPY", inputs: 3, outputs: 0 },
  0x3f: { name: "EXTCODEHASH", inputs: 1, outputs: 1 },
  0x40: { name: "BLOCKHASH", inputs: 1, outputs: 1 },
  0x41: { name: "COINBASE", inputs: 0, outputs: 1 },
  0x42: { name: "TIMESTAMP", inputs: 0, outputs: 1 },
  0x43: { name: "NUMBER", inputs: 0, outputs: 1 },
  0x44: { name: "DIFFICULTY", inputs: 0, outputs: 1 },
  0x45: { name: "GASLIMIT", inputs: 0, outputs: 1 },
  0x46: { name: "CHAINID", inputs: 0, outputs: 1 },
  0x47: { name: "SELFBALANCE", inputs: 0, outputs: 1 },
  0x48: { name: "BASEFEE", inputs: 0, outputs: 1 },
  0x50: { name: "POP", inputs: 1, outputs: 0 },
  0x51: { name: "MLOAD", inputs: 1, outputs: 1 },
  0x52: { name: "MSTORE", inputs: 2, outputs: 0 },
  0x53: { name: "MSTORE8", inputs: 2, outputs: 0 },
  0x54: { name: "SLOAD", inputs: 1, outputs: 1 },
  0x55: { name: "SSTORE", inputs: 2, outputs: 0 },
  0x56: { name: "JUMP", inputs: 1, outputs: 0 },
  0x57: { name: "JUMPI", inputs: 2, outputs: 0 },
  0x58: { name: "PC", inputs: 0, outputs: 1 },
  0x59: { name: "MSIZE", inputs: 0, outputs: 1 },
  0x5a: { name: "GAS", inputs: 0, outputs: 1 },
  0x5b: { name: "JUMPDEST", inputs: 0, outputs: 0 },
  0x5f: { name: "PUSH0", inputs: 0, outputs: 1 },
  0xf3: { name: "RETURN", inputs: 2, outputs: 0 },
  0xfd: { name: "REVERT", inputs: 2, outputs: 0 },
  0xfe: { name: "INVALID", inputs: 0, outputs: 0 },
  0xff: { name: "SELFDESTRUCT", inputs: 1, outputs: 0 },
};

// Add PUSH opcodes
for (let i = 1; i <= 32; i++) {
  OPCODES[0x60 + i - 1] = { name: `PUSH${i}`, inputs: 0, outputs: 1 };
}

// Add DUP opcodes
for (let i = 1; i <= 16; i++) {
  OPCODES[0x80 + i - 1] = { name: `DUP${i}`, inputs: i, outputs: i + 1 };
}

// Add SWAP opcodes
for (let i = 1; i <= 16; i++) {
  OPCODES[0x90 + i - 1] = { name: `SWAP${i}`, inputs: i + 1, outputs: i + 1 };
}

// Add LOG opcodes
for (let i = 0; i <= 4; i++) {
  OPCODES[0xa0 + i] = { name: `LOG${i}`, inputs: i + 2, outputs: 0 };
}

// Add CALL opcodes
OPCODES[0xf0] = { name: "CREATE", inputs: 3, outputs: 1 };
OPCODES[0xf1] = { name: "CALL", inputs: 7, outputs: 1 };
OPCODES[0xf2] = { name: "CALLCODE", inputs: 7, outputs: 1 };
OPCODES[0xf4] = { name: "DELEGATECALL", inputs: 6, outputs: 1 };
OPCODES[0xf5] = { name: "CREATE2", inputs: 4, outputs: 1 };
OPCODES[0xfa] = { name: "STATICCALL", inputs: 6, outputs: 1 };

interface Instruction {
  pc: number;
  opcode: number;
  name: string;
  data: Uint8Array;
}

interface BasicBlock {
  startPc: number;
  endPc: number;
  instructions: Instruction[];
  successors: number[];
  predecessors: number[];
  endsWithJumpi?: boolean;
  jumpiPc?: number;
}

interface ExtendedBlock {
  blocks: BasicBlock[];
  totalInstructions: number;
  maxStackDepth: number;
  arithmeticDensity: number;
  predictedJumpis: number[];  // PCs of JUMPIs we're predicting as not-taken
}

// 2-bit saturating counter
// 0 = strongly taken (jump)
// 1 = weakly taken (jump) 
// 2 = weakly not taken (fall through)
// 3 = strongly not taken (fall through)
class BranchPredictor {
  private counters: Map<number, number> = new Map();
  
  predict(pc: number): boolean {
    const counter = this.counters.get(pc) ?? 2; // Default to weakly not taken
    return counter >= 2; // Predict not taken (fall through) if counter >= 2
  }
  
  update(pc: number, taken: boolean) {
    let counter = this.counters.get(pc) ?? 2;
    
    if (taken) {
      // Decrement towards strongly taken (min 0)
      counter = Math.max(0, counter - 1);
    } else {
      // Increment towards strongly not taken (max 3)
      counter = Math.min(3, counter + 1);
    }
    
    this.counters.set(pc, counter);
  }
  
  getConfidence(pc: number): string {
    const counter = this.counters.get(pc) ?? 2;
    switch (counter) {
      case 0: return "strongly taken";
      case 1: return "weakly taken";
      case 2: return "weakly not taken";
      case 3: return "strongly not taken";
      default: return "unknown";
    }
  }
  
  getStats(): { pc: number, counter: number, confidence: string }[] {
    const stats: { pc: number, counter: number, confidence: string }[] = [];
    for (const [pc, counter] of this.counters) {
      stats.push({ pc, counter, confidence: this.getConfidence(pc) });
    }
    return stats.sort((a, b) => a.pc - b.pc);
  }
}

function parseBytecode(hexStr: string): Uint8Array {
  hexStr = hexStr.trim();
  if (hexStr.startsWith('0x')) {
    hexStr = hexStr.slice(2);
  }
  const bytes = new Uint8Array(hexStr.length / 2);
  for (let i = 0; i < hexStr.length; i += 2) {
    bytes[i / 2] = parseInt(hexStr.substr(i, 2), 16);
  }
  return bytes;
}

function disassemble(bytecode: Uint8Array): Instruction[] {
  const instructions: Instruction[] = [];
  let pc = 0;
  
  while (pc < bytecode.length) {
    const opcode = bytecode[pc];
    const opcodeInfo = OPCODES[opcode] || { name: "UNKNOWN", inputs: 0, outputs: 0 };
    
    let data = new Uint8Array(0);
    if (opcode >= 0x60 && opcode <= 0x7f) {
      const pushSize = opcode - 0x5f;
      data = bytecode.slice(pc + 1, pc + 1 + pushSize);
      pc += pushSize;
    }
    
    instructions.push({
      pc: pc,
      opcode: opcode,
      name: opcodeInfo.name,
      data: data
    });
    
    pc++;
  }
  
  return instructions;
}

function identifyBasicBlocks(instructions: Instruction[]): BasicBlock[] {
  const blocks: BasicBlock[] = [];
  const leaders = new Set<number>([0]);
  
  // Identify block leaders
  for (let i = 0; i < instructions.length; i++) {
    const inst = instructions[i];
    
    if (inst.name === "JUMPDEST") {
      leaders.add(inst.pc);
    }
    
    if (inst.name === "JUMP" || inst.name === "JUMPI") {
      if (i + 1 < instructions.length) {
        leaders.add(instructions[i + 1].pc);
      }
    }
    
    if (["STOP", "RETURN", "REVERT", "SELFDESTRUCT", "INVALID"].includes(inst.name)) {
      if (i + 1 < instructions.length) {
        leaders.add(instructions[i + 1].pc);
      }
    }
  }
  
  // Create blocks
  const sortedLeaders = Array.from(leaders).sort((a, b) => a - b);
  
  for (let i = 0; i < sortedLeaders.length; i++) {
    const startPc = sortedLeaders[i];
    const endPc = i + 1 < sortedLeaders.length ? sortedLeaders[i + 1] : instructions[instructions.length - 1].pc + 1;
    
    const blockInstructions = instructions.filter(inst => inst.pc >= startPc && inst.pc < endPc);
    
    const block: BasicBlock = {
      startPc,
      endPc,
      instructions: blockInstructions,
      successors: [],
      predecessors: []
    };
    
    // Check if block ends with JUMPI
    if (blockInstructions.length > 0) {
      const lastInst = blockInstructions[blockInstructions.length - 1];
      if (lastInst.name === "JUMPI") {
        block.endsWithJumpi = true;
        block.jumpiPc = lastInst.pc;
      }
    }
    
    blocks.push(block);
  }
  
  // Build CFG edges
  for (let i = 0; i < blocks.length; i++) {
    const block = blocks[i];
    if (block.instructions.length === 0) continue;
    
    const lastInst = block.instructions[block.instructions.length - 1];
    
    // Handle JUMPI - conditional has two successors
    if (lastInst.name === "JUMPI") {
      // Fall through
      if (i + 1 < blocks.length) {
        block.successors.push(i + 1);
        blocks[i + 1].predecessors.push(i);
      }
    }
    
    // Handle fall-through for non-terminating instructions
    if (!["JUMP", "STOP", "RETURN", "REVERT", "SELFDESTRUCT", "INVALID"].includes(lastInst.name)) {
      if (i + 1 < blocks.length) {
        block.successors.push(i + 1);
        blocks[i + 1].predecessors.push(i);
      }
    }
  }
  
  return blocks;
}

function createExtendedBlocks(blocks: BasicBlock[], predictor: BranchPredictor): ExtendedBlock[] {
  const extendedBlocks: ExtendedBlock[] = [];
  const visited = new Set<number>();
  
  for (let i = 0; i < blocks.length; i++) {
    if (visited.has(i)) continue;
    
    const extendedBlock: ExtendedBlock = {
      blocks: [],
      totalInstructions: 0,
      maxStackDepth: 0,
      arithmeticDensity: 0,
      predictedJumpis: []
    };
    
    // Build extended block following predictions
    const queue = [i];
    
    while (queue.length > 0) {
      const blockIdx = queue.shift()!;
      if (visited.has(blockIdx)) continue;
      
      visited.add(blockIdx);
      const block = blocks[blockIdx];
      extendedBlock.blocks.push(block);
      extendedBlock.totalInstructions += block.instructions.length;
      
      // If block ends with JUMPI, check prediction
      if (block.endsWithJumpi && block.jumpiPc !== undefined) {
        if (predictor.predict(block.jumpiPc)) {
          // Predicted not taken - continue with fall through
          extendedBlock.predictedJumpis.push(block.jumpiPc);
          const fallThroughIdx = block.successors[0]; // Assuming first successor is fall-through
          if (fallThroughIdx !== undefined) {
            queue.push(fallThroughIdx);
          }
        }
        // If predicted taken, don't extend the block
      } else if (block.instructions.length > 0) {
        const lastInst = block.instructions[block.instructions.length - 1];
        // Continue extending for non-branching blocks
        if (!["JUMP", "JUMPI", "STOP", "RETURN", "REVERT", "SELFDESTRUCT", "INVALID"].includes(lastInst.name)) {
          if (block.successors.length > 0) {
            queue.push(block.successors[0]);
          }
        }
      }
    }
    
    // Calculate metrics
    let arithmeticOps = 0;
    let maxDepth = 0;
    let currentDepth = 0;
    
    for (const block of extendedBlock.blocks) {
      for (const inst of block.instructions) {
        const opcode = OPCODES[inst.opcode];
        if (opcode) {
          currentDepth -= opcode.inputs;
          currentDepth += opcode.outputs;
          maxDepth = Math.max(maxDepth, currentDepth);
          
          if (["ADD", "SUB", "MUL", "DIV", "MOD", "LT", "GT", "EQ", "AND", "OR", "XOR"].includes(inst.name)) {
            arithmeticOps++;
          }
        }
      }
    }
    
    extendedBlock.maxStackDepth = maxDepth;
    extendedBlock.arithmeticDensity = arithmeticOps / extendedBlock.totalInstructions;
    
    extendedBlocks.push(extendedBlock);
  }
  
  return extendedBlocks;
}

// Simulate execution to train branch predictor
function simulateExecution(blocks: BasicBlock[], predictor: BranchPredictor, pattern: string) {
  // Simulate different execution patterns
  let jumpiPcs: number[] = [];
  
  // Collect all JUMPI PCs
  for (const block of blocks) {
    if (block.jumpiPc !== undefined) {
      jumpiPcs.push(block.jumpiPc);
    }
  }
  
  // Apply pattern
  switch (pattern) {
    case "all_asserts_pass":
      // All JUMPIs not taken (typical for assert/require checks)
      for (const pc of jumpiPcs) {
        predictor.update(pc, false);
      }
      break;
    
    case "mixed_50_50":
      // 50/50 mix
      for (let i = 0; i < jumpiPcs.length; i++) {
        predictor.update(jumpiPcs[i], i % 2 === 0);
      }
      break;
    
    case "mostly_not_taken":
      // 90% not taken (fall through)
      for (const pc of jumpiPcs) {
        for (let i = 0; i < 10; i++) {
          predictor.update(pc, i === 0); // Only first is taken
        }
      }
      break;
  }
}

function analyzeContract(name: string, bytecode: Uint8Array) {
  console.log(`\n${'='.repeat(60)}`);
  console.log(`Contract: ${name}`);
  console.log(`${'='.repeat(60)}`);
  
  const instructions = disassemble(bytecode);
  const basicBlocks = identifyBasicBlocks(instructions);
  
  console.log(`Total Instructions: ${instructions.length}`);
  console.log(`Basic Blocks: ${basicBlocks.length}`);
  
  // Count JUMPIs
  let jumpiCount = 0;
  for (const block of basicBlocks) {
    if (block.endsWithJumpi) jumpiCount++;
  }
  console.log(`JUMPI Instructions: ${jumpiCount}`);
  
  // Test with different training patterns
  const patterns = [
    { name: "Cold (no training)", pattern: null },
    { name: "All asserts pass", pattern: "all_asserts_pass" },
    { name: "Mostly not taken (90%)", pattern: "mostly_not_taken" },
    { name: "Mixed 50/50", pattern: "mixed_50_50" }
  ];
  
  console.log(`\nExtended Block Analysis with Different Branch Predictions:`);
  
  for (const { name: patternName, pattern } of patterns) {
    const predictor = new BranchPredictor();
    
    if (pattern) {
      // Train predictor
      simulateExecution(basicBlocks, predictor, pattern);
    }
    
    const extendedBlocks = createExtendedBlocks(basicBlocks, predictor);
    const avgExtendedBlockSize = instructions.length / extendedBlocks.length;
    const avgBasicBlockSize = instructions.length / basicBlocks.length;
    const improvement = ((avgExtendedBlockSize / avgBasicBlockSize - 1) * 100).toFixed(1);
    
    console.log(`\n  ${patternName}:`);
    console.log(`    Extended Blocks: ${extendedBlocks.length}`);
    console.log(`    Average Size: ${avgExtendedBlockSize.toFixed(1)} instructions`);
    console.log(`    Improvement: ${improvement}%`);
    
    // Show predictor state for first few JUMPIs
    if (pattern && jumpiCount > 0) {
      const stats = predictor.getStats().slice(0, 3);
      console.log(`    Sample predictions:`);
      for (const stat of stats) {
        console.log(`      PC ${stat.pc}: ${stat.confidence} (counter=${stat.counter})`);
      }
    }
    
    // Find largest extended blocks
    const sortedBlocks = extendedBlocks.sort((a, b) => b.totalInstructions - a.totalInstructions);
    const largest = sortedBlocks[0];
    if (largest) {
      console.log(`    Largest block: ${largest.totalInstructions} instructions (${largest.blocks.length} basic blocks)`);
      if (largest.predictedJumpis.length > 0) {
        console.log(`    Predicted ${largest.predictedJumpis.length} JUMPIs as not-taken`);
      }
    }
    
    // Register allocation suitability
    const suitable = extendedBlocks.filter(eb => 
      eb.totalInstructions >= 10 && 
      eb.maxStackDepth <= 8 &&
      eb.arithmeticDensity >= 0.2
    );
    const suitableInstructions = suitable.reduce((sum, eb) => sum + eb.totalInstructions, 0);
    const percentage = (suitableInstructions / instructions.length * 100).toFixed(1);
    console.log(`    Register-suitable: ${suitableInstructions}/${instructions.length} instructions (${percentage}%)`);
  }
}

async function main() {
  const casesDir = "/Users/williamcory/guillotine/bench/official/cases";
  
  const benchmarks = [
    "snailtracer",
    "ten-thousand-hashes",
    "erc20-transfer",
  ];
  
  for (const benchmark of benchmarks) {
    const bytecodePath = `${casesDir}/${benchmark}/bytecode.txt`;
    
    try {
      const hexStr = await Bun.file(bytecodePath).text();
      const bytecode = parseBytecode(hexStr);
      analyzeContract(benchmark, bytecode);
    } catch (e) {
      console.error(`Failed to analyze ${benchmark}:`, e);
    }
  }
}

main();