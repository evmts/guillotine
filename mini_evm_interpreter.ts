#!/usr/bin/env bun
/**
 * Mini EVM Interpreter POC with Tailcall Pattern
 * 
 * Demonstrates:
 * 1. Tailcall-based execution like Zig implementation
 * 2. Branch prediction with 2-bit counters
 * 3. Extended block creation based on predictions
 * 4. Subset of EVM opcodes for testing
 */

// Types
type u256 = bigint;
type TailcallFunc = (frame: StackFrame) => void;

// Errors
class EVMError extends Error {
  constructor(public type: string) {
    super(type);
  }
}

const STOP = new EVMError("STOP");
const INVALID_JUMP = new EVMError("INVALID_JUMP");
const STACK_UNDERFLOW = new EVMError("STACK_UNDERFLOW");
const STACK_OVERFLOW = new EVMError("STACK_OVERFLOW");

// Stack implementation
class Stack {
  private data: u256[] = [];
  static readonly MAX_DEPTH = 1024;

  push(value: u256): void {
    if (this.data.length >= Stack.MAX_DEPTH) {
      throw STACK_OVERFLOW;
    }
    this.data.push(value);
  }

  pop(): u256 {
    const value = this.data.pop();
    if (value === undefined) {
      throw STACK_UNDERFLOW;
    }
    return value;
  }

  peek(): u256 {
    if (this.data.length === 0) {
      throw STACK_UNDERFLOW;
    }
    return this.data[this.data.length - 1];
  }

  dup(n: number): void {
    if (this.data.length < n) {
      throw STACK_UNDERFLOW;
    }
    const value = this.data[this.data.length - n];
    this.push(value);
  }

  swap(n: number): void {
    if (this.data.length < n + 1) {
      throw STACK_UNDERFLOW;
    }
    const topIdx = this.data.length - 1;
    const swapIdx = this.data.length - n - 1;
    [this.data[topIdx], this.data[swapIdx]] = [this.data[swapIdx], this.data[topIdx]];
  }

  size(): number {
    return this.data.length;
  }

  clear(): void {
    this.data = [];
  }
}

// Memory implementation
class Memory {
  private data: Uint8Array = new Uint8Array(0);

  resize(newSize: number): void {
    if (newSize > this.data.length) {
      const newData = new Uint8Array(newSize);
      newData.set(this.data);
      this.data = newData;
    }
  }

  load(offset: number): u256 {
    this.resize(offset + 32);
    let value = 0n;
    for (let i = 0; i < 32; i++) {
      value = (value << 8n) | BigInt(this.data[offset + i]);
    }
    return value;
  }

  store(offset: number, value: u256): void {
    this.resize(offset + 32);
    for (let i = 31; i >= 0; i--) {
      this.data[offset + i] = Number(value & 0xFFn);
      value >>= 8n;
    }
  }

  store8(offset: number, value: u256): void {
    this.resize(offset + 1);
    this.data[offset] = Number(value & 0xFFn);
  }

  size(): number {
    return this.data.length;
  }
}

// Simple analysis result
interface SimpleAnalysis {
  instToPc: number[];      // Instruction index to PC mapping
  pcToInst: number[];      // PC to instruction index mapping
  bytecode: Uint8Array;
}

// Branch predictor
class BranchPredictor {
  private counters: Map<number, number> = new Map();
  
  predict(pc: number): boolean {
    const counter = this.counters.get(pc) ?? 2;
    return counter >= 2; // Predict not taken if counter >= 2
  }
  
  update(pc: number, taken: boolean): void {
    let counter = this.counters.get(pc) ?? 2;
    if (taken) {
      counter = Math.max(0, counter - 1);
    } else {
      counter = Math.min(3, counter + 1);
    }
    this.counters.set(pc, counter);
  }
}

// Stack frame
class StackFrame {
  stack: Stack = new Stack();
  memory: Memory = new Memory();
  ip: number = 0;
  
  constructor(
    public analysis: SimpleAnalysis,
    public metadata: number[],
    public ops: TailcallFunc[],
    public predictor: BranchPredictor
  ) {}
}

// Helper to advance to next instruction
function next(frame: StackFrame): void {
  frame.ip += 1;
  if (frame.ip >= frame.ops.length) {
    throw STOP;
  }
  // Simulate tailcall with trampoline
  const nextOp = frame.ops[frame.ip];
  // console.log(`Executing ip=${frame.ip}, op=${nextOp.name || 'unknown'}`);
  nextOp(frame);
}

// Opcode implementations

function op_stop(frame: StackFrame): void {
  throw STOP;
}

function op_add(frame: StackFrame): void {
  const b = frame.stack.pop();
  const a = frame.stack.pop();
  frame.stack.push(a + b);
  next(frame);
}

function op_mul(frame: StackFrame): void {
  const b = frame.stack.pop();
  const a = frame.stack.pop();
  frame.stack.push(a * b);
  next(frame);
}

function op_sub(frame: StackFrame): void {
  const b = frame.stack.pop();
  const a = frame.stack.pop();
  frame.stack.push(a - b);
  next(frame);
}

function op_div(frame: StackFrame): void {
  const b = frame.stack.pop();
  const a = frame.stack.pop();
  frame.stack.push(b === 0n ? 0n : a / b);
  next(frame);
}

function op_lt(frame: StackFrame): void {
  const b = frame.stack.pop();
  const a = frame.stack.pop();
  frame.stack.push(a < b ? 1n : 0n);
  next(frame);
}

function op_gt(frame: StackFrame): void {
  const b = frame.stack.pop();
  const a = frame.stack.pop();
  frame.stack.push(a > b ? 1n : 0n);
  next(frame);
}

function op_eq(frame: StackFrame): void {
  const b = frame.stack.pop();
  const a = frame.stack.pop();
  frame.stack.push(a === b ? 1n : 0n);
  next(frame);
}

function op_iszero(frame: StackFrame): void {
  const a = frame.stack.pop();
  frame.stack.push(a === 0n ? 1n : 0n);
  next(frame);
}

function op_pop(frame: StackFrame): void {
  frame.stack.pop();
  next(frame);
}

function op_mload(frame: StackFrame): void {
  const offset = frame.stack.pop();
  const value = frame.memory.load(Number(offset));
  frame.stack.push(value);
  next(frame);
}

function op_mstore(frame: StackFrame): void {
  const offset = frame.stack.pop();
  const value = frame.stack.pop();
  frame.memory.store(Number(offset), value);
  next(frame);
}

function op_mstore8(frame: StackFrame): void {
  const offset = frame.stack.pop();
  const value = frame.stack.pop();
  frame.memory.store8(Number(offset), value);
  next(frame);
}

function op_msize(frame: StackFrame): void {
  frame.stack.push(BigInt(frame.memory.size()));
  next(frame);
}

function op_jump(frame: StackFrame): void {
  const dest = frame.stack.pop();
  const instIdx = frame.analysis.pcToInst[Number(dest)];
  
  if (instIdx === undefined || instIdx === 0xFFFF) {
    throw INVALID_JUMP;
  }
  
  // Verify JUMPDEST
  if (frame.analysis.bytecode[Number(dest)] !== 0x5B) {
    throw INVALID_JUMP;
  }
  
  frame.ip = instIdx;
  // Call the operation at the new IP
  frame.ops[frame.ip](frame);
}

function op_jumpi(frame: StackFrame): void {
  const dest = frame.stack.pop();
  const condition = frame.stack.pop();
  
  // Get current PC for branch prediction
  const currentPc = frame.analysis.instToPc[frame.ip];
  
  if (condition !== 0n) {
    // Jump taken
    frame.predictor.update(currentPc, true);
    
    const instIdx = frame.analysis.pcToInst[Number(dest)];
    if (instIdx === undefined || instIdx === 0xFFFF) {
      throw INVALID_JUMP;
    }
    
    if (frame.analysis.bytecode[Number(dest)] !== 0x5B) {
      throw INVALID_JUMP;
    }
    
    frame.ip = instIdx;
    // Call the operation at the new IP
    frame.ops[frame.ip](frame);
  } else {
    // Jump not taken (fall through)
    frame.predictor.update(currentPc, false);
    next(frame);
  }
}

function op_jumpdest(frame: StackFrame): void {
  // No-op
  next(frame);
}

function op_push(frame: StackFrame): void {
  const pc = frame.analysis.instToPc[frame.ip];
  const opcode = frame.analysis.bytecode[pc];
  
  if (opcode >= 0x60 && opcode <= 0x7F) {
    // Regular PUSH with data
    const pushSize = opcode - 0x5F;
    let value = 0n;
    for (let i = 0; i < pushSize && pc + 1 + i < frame.analysis.bytecode.length; i++) {
      value = (value << 8n) | BigInt(frame.analysis.bytecode[pc + 1 + i]);
    }
    frame.stack.push(value);
  } else if (opcode === 0x5F) {
    // PUSH0
    frame.stack.push(0n);
  }
  
  next(frame);
}

// DUP operations
function op_dup1(frame: StackFrame): void {
  frame.stack.dup(1);
  next(frame);
}

function op_dup2(frame: StackFrame): void {
  frame.stack.dup(2);
  next(frame);
}

// SWAP operations
function op_swap1(frame: StackFrame): void {
  frame.stack.swap(1);
  next(frame);
}

function op_swap2(frame: StackFrame): void {
  frame.stack.swap(2);
  next(frame);
}

// Fused operations
function op_push_then_add(frame: StackFrame): void {
  const pushVal = BigInt(frame.metadata[frame.ip]);
  const other = frame.stack.peek();
  frame.stack.push(other + pushVal);
  frame.ip += 1; // Skip the fused ADD
  next(frame);
}

function op_push_then_jumpi(frame: StackFrame): void {
  const condition = frame.stack.pop();
  const currentPc = frame.analysis.instToPc[frame.ip];
  
  if (condition !== 0n) {
    frame.predictor.update(currentPc, true);
    const destInstIdx = frame.metadata[frame.ip];
    frame.ip = destInstIdx;
    next(frame);
  } else {
    frame.predictor.update(currentPc, false);
    frame.ip += 1; // Skip the fused JUMPI
    next(frame);
  }
}

function op_nop(frame: StackFrame): void {
  next(frame);
}

// Opcode mapping
const OPCODE_MAP: Record<number, TailcallFunc> = {
  0x00: op_stop,
  0x01: op_add,
  0x02: op_mul,
  0x03: op_sub,
  0x04: op_div,
  0x10: op_lt,
  0x11: op_gt,
  0x14: op_eq,
  0x15: op_iszero,
  0x50: op_pop,
  0x51: op_mload,
  0x52: op_mstore,
  0x53: op_mstore8,
  0x56: op_jump,
  0x57: op_jumpi,
  0x59: op_msize,
  0x5B: op_jumpdest,
  0x80: op_dup1,
  0x81: op_dup2,
  0x90: op_swap1,
  0x91: op_swap2,
};

// Simple bytecode analysis
function analyze(bytecode: Uint8Array): { analysis: SimpleAnalysis, metadata: number[] } {
  const instToPc: number[] = [];
  const pcToInst: number[] = new Array(bytecode.length).fill(0xFFFF);
  const metadata: number[] = [];
  
  let pc = 0;
  let instIdx = 0;
  
  while (pc < bytecode.length) {
    const opcode = bytecode[pc];
    instToPc.push(pc);
    pcToInst[pc] = instIdx;
    
    if (opcode >= 0x60 && opcode <= 0x7F) {
      // PUSH instruction
      const pushSize = opcode - 0x5F;
      let value = 0;
      for (let i = 0; i < pushSize && pc + 1 + i < bytecode.length; i++) {
        value = (value << 8) | bytecode[pc + 1 + i];
      }
      metadata.push(value);
      pc += 1 + pushSize;
    } else {
      metadata.push(0);
      pc += 1;
    }
    
    instIdx++;
  }
  
  return {
    analysis: { instToPc, pcToInst, bytecode },
    metadata
  };
}

// Build ops array with optional fusion
function buildOps(
  analysis: SimpleAnalysis, 
  metadata: number[],
  predictor: BranchPredictor,
  enableFusion: boolean = true
): TailcallFunc[] {
  const ops: TailcallFunc[] = [];
  
  for (let i = 0; i < analysis.instToPc.length; i++) {
    const pc = analysis.instToPc[i];
    const opcode = analysis.bytecode[pc];
    
    // Check for fusion opportunities
    if (enableFusion && opcode >= 0x60 && opcode <= 0x7F) {
      // PUSH instruction - check next instruction
      if (i + 1 < analysis.instToPc.length) {
        const nextPc = analysis.instToPc[i + 1];
        const nextOpcode = analysis.bytecode[nextPc];
        
        if (nextOpcode === 0x01) {
          // PUSH + ADD fusion
          ops.push(op_push_then_add);
          ops.push(op_nop); // Replace ADD with NOP
          i++;
          continue;
        } else if (nextOpcode === 0x57) {
          // PUSH + JUMPI fusion (for predicted not-taken)
          if (predictor.predict(nextPc)) {
            ops.push(op_push_then_jumpi);
            ops.push(op_nop);
            i++;
            continue;
          }
        }
      }
    }
    
    // Regular opcode mapping
    if (opcode >= 0x60 && opcode <= 0x7F) {
      ops.push(op_push);
    } else {
      ops.push(OPCODE_MAP[opcode] || op_stop);
    }
  }
  
  // Add terminating STOP
  ops.push(op_stop);
  
  return ops;
}

// Main interpreter function
function interpret(bytecode: Uint8Array, predictor: BranchPredictor = new BranchPredictor()): void {
  const { analysis, metadata } = analyze(bytecode);
  const ops = buildOps(analysis, metadata, predictor);
  
  const frame = new StackFrame(analysis, metadata, ops, predictor);
  
  try {
    // Start execution with trampoline
    ops[0](frame);
  } catch (e) {
    if (e === STOP) {
      // Normal termination
      return;
    }
    throw e;
  }
}

// Test helpers
function hexToBytes(hex: string): Uint8Array {
  if (hex.startsWith('0x')) hex = hex.slice(2);
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.substr(i, 2), 16);
  }
  return bytes;
}

export { 
  interpret, 
  hexToBytes, 
  Stack, 
  Memory, 
  BranchPredictor,
  StackFrame,
  analyze,
  buildOps
};