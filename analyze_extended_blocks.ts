#!/usr/bin/env bun
/**
 * Extended Basic Block Analysis for EVM Bytecode
 * 
 * This analyzer identifies opportunities to extend basic blocks by:
 * 1. Following deterministic jumps
 * 2. Speculatively continuing through assert-pattern JUMPIs
 * 3. Building larger blocks suitable for register allocation
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
  isDeterministicJump?: boolean;
  jumpTarget?: number;
}

interface ExtendedBlock {
  blocks: BasicBlock[];
  speculationPoints: SpeculationPoint[];
  totalInstructions: number;
  maxStackDepth: number;
  arithmeticDensity: number;
}

interface SpeculationPoint {
  pc: number;
  type: 'assert' | 'require' | 'other';
  fallbackBlock: number;
  confidence: number;
}

interface AssertPattern {
  pattern: string[];
  confidence: number;
}

const ASSERT_PATTERNS: AssertPattern[] = [
  {
    // require(condition) pattern
    pattern: ["ISZERO", "PUSH", "JUMPI"],
    confidence: 0.95
  },
  {
    // assert(condition) pattern
    pattern: ["ISZERO", "PUSH", "JUMPI", "INVALID"],
    confidence: 0.99
  },
  {
    // if (!condition) revert() pattern
    pattern: ["NOT", "PUSH", "JUMPI"],
    confidence: 0.90
  },
  {
    // Common overflow check pattern
    pattern: ["DUP", "LT", "ISZERO", "PUSH", "JUMPI"],
    confidence: 0.95
  }
];

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
    
    blocks.push({
      startPc,
      endPc,
      instructions: blockInstructions,
      successors: [],
      predecessors: []
    });
  }
  
  // Build CFG edges
  for (let i = 0; i < blocks.length; i++) {
    const block = blocks[i];
    if (block.instructions.length === 0) continue;
    
    const lastInst = block.instructions[block.instructions.length - 1];
    
    // Check for deterministic JUMP
    if (lastInst.name === "JUMP" && block.instructions.length >= 2) {
      const prevInst = block.instructions[block.instructions.length - 2];
      if (prevInst.name.startsWith("PUSH") && prevInst.data.length > 0) {
        const target = prevInst.data.reduce((acc, byte) => (acc << 8) | byte, 0);
        block.isDeterministicJump = true;
        block.jumpTarget = target;
        
        // Find target block
        const targetBlockIdx = blocks.findIndex(b => b.startPc <= target && target < b.endPc);
        if (targetBlockIdx !== -1) {
          block.successors.push(targetBlockIdx);
          blocks[targetBlockIdx].predecessors.push(i);
        }
      }
    }
    
    // Handle JUMPI - conditional has two successors
    if (lastInst.name === "JUMPI") {
      // Fall through
      if (i + 1 < blocks.length) {
        block.successors.push(i + 1);
        blocks[i + 1].predecessors.push(i);
      }
      
      // Jump target (if we can determine it)
      if (block.instructions.length >= 2) {
        const prevInst = block.instructions[block.instructions.length - 2];
        if (prevInst.name.startsWith("PUSH") && prevInst.data.length > 0) {
          const target = prevInst.data.reduce((acc, byte) => (acc << 8) | byte, 0);
          const targetBlockIdx = blocks.findIndex(b => b.startPc <= target && target < b.endPc);
          if (targetBlockIdx !== -1) {
            block.successors.push(targetBlockIdx);
            blocks[targetBlockIdx].predecessors.push(i);
          }
        }
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

function detectAssertPattern(block: BasicBlock): SpeculationPoint | null {
  const instructions = block.instructions;
  if (instructions.length < 3) return null;
  
  // Check each assert pattern
  for (const assertPattern of ASSERT_PATTERNS) {
    const patternLength = assertPattern.pattern.length;
    if (instructions.length < patternLength) continue;
    
    // Check if the last N instructions match the pattern
    let matches = true;
    for (let i = 0; i < patternLength; i++) {
      const inst = instructions[instructions.length - patternLength + i];
      if (inst.name !== assertPattern.pattern[i] && 
          (assertPattern.pattern[i] !== "PUSH" || !inst.name.startsWith("PUSH"))) {
        matches = false;
        break;
      }
    }
    
    if (matches) {
      // Found an assert pattern
      const jumpiInst = instructions[instructions.length - 1];
      
      // Try to find the fallback block (where it jumps on failure)
      let fallbackBlock = -1;
      if (instructions.length >= 2) {
        const pushInst = instructions[instructions.length - 2];
        if (pushInst.name.startsWith("PUSH") && pushInst.data.length > 0) {
          const target = pushInst.data.reduce((acc, byte) => (acc << 8) | byte, 0);
          // The fallback is where it jumps to (usually revert)
          fallbackBlock = target;
        }
      }
      
      return {
        pc: jumpiInst.pc,
        type: assertPattern.pattern.includes("INVALID") ? 'assert' : 'require',
        fallbackBlock: fallbackBlock,
        confidence: assertPattern.confidence
      };
    }
  }
  
  return null;
}

function createExtendedBlocks(blocks: BasicBlock[]): ExtendedBlock[] {
  const extendedBlocks: ExtendedBlock[] = [];
  const visited = new Set<number>();
  
  for (let i = 0; i < blocks.length; i++) {
    if (visited.has(i)) continue;
    
    const extendedBlock: ExtendedBlock = {
      blocks: [],
      speculationPoints: [],
      totalInstructions: 0,
      maxStackDepth: 0,
      arithmeticDensity: 0
    };
    
    // Build extended block by following deterministic jumps and assert patterns
    const queue = [i];
    
    while (queue.length > 0) {
      const blockIdx = queue.shift()!;
      if (visited.has(blockIdx)) continue;
      
      visited.add(blockIdx);
      const block = blocks[blockIdx];
      extendedBlock.blocks.push(block);
      extendedBlock.totalInstructions += block.instructions.length;
      
      // Check if this block ends with deterministic JUMP
      if (block.isDeterministicJump && block.successors.length === 1) {
        queue.push(block.successors[0]);
        continue;
      }
      
      // Check if this block ends with an assert pattern JUMPI
      const assertPoint = detectAssertPattern(block);
      if (assertPoint && assertPoint.confidence >= 0.90) {
        extendedBlock.speculationPoints.push(assertPoint);
        
        // Continue with the fall-through path (assert success)
        const fallThroughIdx = block.successors.find(idx => {
          const successor = blocks[idx];
          return successor.startPc !== assertPoint.fallbackBlock;
        });
        
        if (fallThroughIdx !== undefined) {
          queue.push(fallThroughIdx);
        }
      }
    }
    
    // Calculate metrics for the extended block
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

function analyzeContract(name: string, bytecode: Uint8Array) {
  console.log(`\n${'='.repeat(60)}`);
  console.log(`Contract: ${name}`);
  console.log(`${'='.repeat(60)}`);
  
  const instructions = disassemble(bytecode);
  const basicBlocks = identifyBasicBlocks(instructions);
  const extendedBlocks = createExtendedBlocks(basicBlocks);
  
  console.log(`Total Instructions: ${instructions.length}`);
  console.log(`Basic Blocks: ${basicBlocks.length}`);
  console.log(`Extended Blocks: ${extendedBlocks.length}`);
  
  // Calculate improvement
  const avgBasicBlockSize = instructions.length / basicBlocks.length;
  const avgExtendedBlockSize = instructions.length / extendedBlocks.length;
  const improvement = ((avgExtendedBlockSize / avgBasicBlockSize - 1) * 100).toFixed(1);
  
  console.log(`\nBlock Size Improvement:`);
  console.log(`  Average Basic Block: ${avgBasicBlockSize.toFixed(1)} instructions`);
  console.log(`  Average Extended Block: ${avgExtendedBlockSize.toFixed(1)} instructions`);
  console.log(`  Improvement: ${improvement}% larger blocks`);
  
  // Analyze speculation points
  let totalSpeculations = 0;
  let assertSpeculations = 0;
  let requireSpeculations = 0;
  
  for (const extBlock of extendedBlocks) {
    totalSpeculations += extBlock.speculationPoints.length;
    assertSpeculations += extBlock.speculationPoints.filter(sp => sp.type === 'assert').length;
    requireSpeculations += extBlock.speculationPoints.filter(sp => sp.type === 'require').length;
  }
  
  console.log(`\nSpeculation Analysis:`);
  console.log(`  Total Speculation Points: ${totalSpeculations}`);
  console.log(`  Assert Patterns: ${assertSpeculations}`);
  console.log(`  Require Patterns: ${requireSpeculations}`);
  
  // Find the largest extended blocks
  const sortedExtBlocks = extendedBlocks.sort((a, b) => b.totalInstructions - a.totalInstructions);
  console.log(`\nTop 5 Largest Extended Blocks:`);
  for (let i = 0; i < Math.min(5, sortedExtBlocks.length); i++) {
    const block = sortedExtBlocks[i];
    console.log(`  Block ${i + 1}: ${block.totalInstructions} instructions, ${block.blocks.length} basic blocks merged`);
    if (block.speculationPoints.length > 0) {
      console.log(`    - ${block.speculationPoints.length} speculation points`);
    }
  }
  
  // Register allocation suitability
  const suitableBlocks = extendedBlocks.filter(eb => 
    eb.totalInstructions >= 10 && 
    eb.maxStackDepth <= 8 &&
    eb.arithmeticDensity >= 0.2
  );
  
  const suitableInstructions = suitableBlocks.reduce((sum, eb) => sum + eb.totalInstructions, 0);
  const suitabilityPercentage = (suitableInstructions / instructions.length * 100).toFixed(1);
  
  console.log(`\nRegister Allocation Suitability:`);
  console.log(`  Suitable Extended Blocks: ${suitableBlocks.length}/${extendedBlocks.length}`);
  console.log(`  Instructions in Suitable Blocks: ${suitableInstructions}/${instructions.length} (${suitabilityPercentage}%)`);
  
  if (parseFloat(suitabilityPercentage) >= 50) {
    console.log(`  ✓ HIGHLY SUITABLE for register-based execution with extended blocks!`);
  } else if (parseFloat(suitabilityPercentage) >= 25) {
    console.log(`  ~ MODERATELY SUITABLE for register-based execution`);
  } else {
    console.log(`  ✗ Limited benefit from register allocation`);
  }
}

async function main() {
  const casesDir = "/Users/williamcory/guillotine/bench/official/cases";
  
  const benchmarks = [
    "snailtracer",
    "ten-thousand-hashes",
    "erc20-transfer",
    "opcodes-arithmetic",
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