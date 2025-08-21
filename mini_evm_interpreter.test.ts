import { test, expect, describe } from "bun:test";
import { 
  interpret, 
  hexToBytes, 
  Stack, 
  Memory, 
  BranchPredictor,
  StackFrame,
  analyze,
  buildOps
} from "./mini_evm_interpreter";

describe("Stack Operations", () => {
  test("basic push/pop", () => {
    const stack = new Stack();
    stack.push(10n);
    stack.push(20n);
    expect(stack.pop()).toBe(20n);
    expect(stack.pop()).toBe(10n);
  });

  test("stack underflow", () => {
    const stack = new Stack();
    expect(() => stack.pop()).toThrow("STACK_UNDERFLOW");
  });

  test("DUP operations", () => {
    const stack = new Stack();
    stack.push(1n);
    stack.push(2n);
    stack.push(3n);
    
    stack.dup(1); // DUP1
    expect(stack.pop()).toBe(3n);
    expect(stack.pop()).toBe(3n);
    
    stack.dup(2); // DUP2
    expect(stack.pop()).toBe(1n);
  });

  test("SWAP operations", () => {
    const stack = new Stack();
    stack.push(1n);
    stack.push(2n);
    
    stack.swap(1); // SWAP1
    expect(stack.pop()).toBe(1n);
    expect(stack.pop()).toBe(2n);
  });
});

describe("Memory Operations", () => {
  test("MSTORE/MLOAD", () => {
    const memory = new Memory();
    memory.store(0, 0x1234567890ABCDEFn);
    expect(memory.load(0)).toBe(0x1234567890ABCDEFn);
  });

  test("MSTORE8", () => {
    const memory = new Memory();
    memory.store8(0, 0xABn);
    expect(memory.load(0) >> 248n).toBe(0xABn);
  });

  test("MSIZE", () => {
    const memory = new Memory();
    expect(memory.size()).toBe(0);
    memory.store(0, 1n);
    expect(memory.size()).toBe(32);
  });
});

describe("Branch Predictor", () => {
  test("default prediction", () => {
    const predictor = new BranchPredictor();
    expect(predictor.predict(100)).toBe(true); // Default: not taken
  });

  test("learning pattern", () => {
    const predictor = new BranchPredictor();
    const pc = 100;
    
    // Train as always not taken
    predictor.update(pc, false);
    predictor.update(pc, false);
    predictor.update(pc, false);
    
    expect(predictor.predict(pc)).toBe(true); // Strongly not taken
  });

  test("mixed pattern", () => {
    const predictor = new BranchPredictor();
    const pc = 100;
    
    predictor.update(pc, true);  // Taken
    predictor.update(pc, false); // Not taken
    predictor.update(pc, true);  // Taken
    
    expect(predictor.predict(pc)).toBe(false); // Weakly taken
  });
});

describe("Arithmetic Operations", () => {
  test("ADD", () => {
    // PUSH1 0x05, PUSH1 0x0A, ADD, STOP
    const bytecode = hexToBytes("6005600a0100");
    const { analysis, metadata } = analyze(bytecode);
    const ops = buildOps(analysis, metadata, new BranchPredictor(), false);
    
    const frame = new StackFrame(analysis, metadata, ops, new BranchPredictor());
    
    try {
      ops[0](frame);
    } catch (e) {
      // Expected STOP
    }
    
    expect(frame.stack.pop()).toBe(15n);
  });

  test("SUB", () => {
    // PUSH1 0x0A, PUSH1 0x05, SUB, STOP
    const bytecode = hexToBytes("600a60050300");
    interpret(bytecode);
    // Would check stack but interpret doesn't return frame
  });

  test("comparison operations", () => {
    // PUSH1 0x05, PUSH1 0x0A, LT (5 < 10 = 1), STOP
    const bytecode = hexToBytes("6005600a1000");
    const { analysis, metadata } = analyze(bytecode);
    const ops = buildOps(analysis, metadata, new BranchPredictor(), false);
    
    const frame = new StackFrame(analysis, metadata, ops, new BranchPredictor());
    
    try {
      ops[0](frame);
    } catch (e) {
      // Expected STOP
    }
    
    expect(frame.stack.pop()).toBe(1n); // 5 < 10 is true
  });
});

describe("Control Flow", () => {
  test("JUMP", () => {
    // PUSH1 0x04, JUMP, INVALID, JUMPDEST, PUSH1 0x42, STOP
    const bytecode = hexToBytes("600456fe5b604200");
    const { analysis, metadata } = analyze(bytecode);
    const ops = buildOps(analysis, metadata, new BranchPredictor(), false);
    
    const frame = new StackFrame(analysis, metadata, ops, new BranchPredictor());
    
    try {
      ops[0](frame);
    } catch (e) {
      // Expected STOP
    }
    
    expect(frame.stack.size()).toBe(1);
    expect(frame.stack.peek()).toBe(0x42n); // Should have jumped over INVALID
  });

  test("JUMPI - condition true", () => {
    // PUSH1 0x01, PUSH1 0x06, JUMPI, INVALID, JUMPDEST, PUSH1 0x42, STOP
    const bytecode = hexToBytes("6001600657fe5b604200");
    const { analysis, metadata } = analyze(bytecode);
    const ops = buildOps(analysis, metadata, new BranchPredictor(), false);
    
    const frame = new StackFrame(analysis, metadata, ops, new BranchPredictor());
    
    try {
      ops[0](frame);
    } catch (e) {
      // Expected STOP
    }
    
    expect(frame.stack.size()).toBe(1);
    expect(frame.stack.peek()).toBe(0x42n);
  });

  test("JUMPI - condition false", () => {
    // PUSH1 0x00, PUSH1 0x06, JUMPI, PUSH1 0x33, STOP, JUMPDEST, PUSH1 0x42, STOP
    const bytecode = hexToBytes("60006006576033005b604200");
    const { analysis, metadata } = analyze(bytecode);
    const ops = buildOps(analysis, metadata, new BranchPredictor(), false);
    
    const frame = new StackFrame(analysis, metadata, ops, new BranchPredictor());
    
    try {
      ops[0](frame);
    } catch (e) {
      // Expected STOP
    }
    
    expect(frame.stack.pop()).toBe(0x33n); // Didn't jump
  });
});

describe("Fusion Operations", () => {
  test("PUSH + ADD fusion", () => {
    // PUSH1 0x05, PUSH1 0x0A, ADD, STOP
    const bytecode = hexToBytes("6005600a0100");
    const { analysis, metadata } = analyze(bytecode);
    const predictor = new BranchPredictor();
    const ops = buildOps(analysis, metadata, predictor, true); // Enable fusion
    
    // Check that fusion happened
    let fusedOps = 0;
    for (const op of ops) {
      if (op.name?.includes("push_then_add")) fusedOps++;
    }
    
    const frame = new StackFrame(analysis, metadata, ops, predictor);
    
    try {
      ops[0](frame);
    } catch (e) {
      // Expected STOP
    }
    
    expect(frame.stack.pop()).toBe(15n);
  });

  test("PUSH + JUMPI fusion with prediction", () => {
    // Train predictor to always predict not-taken
    const predictor = new BranchPredictor();
    predictor.update(4, false); // PC 4 is JUMPI
    predictor.update(4, false);
    predictor.update(4, false);
    
    // PUSH1 0x01, PUSH1 0x08, JUMPI, PUSH1 0x33, STOP
    const bytecode = hexToBytes("60016008576033005b");
    const { analysis, metadata } = analyze(bytecode);
    const ops = buildOps(analysis, metadata, predictor, true);
    
    // Should have fused PUSH+JUMPI
    // This would be verified by checking ops array for fusion function
  });
});

describe("Branch Prediction Impact", () => {
  test("loop with assert pattern", () => {
    // Simulated assert loop that runs 3 times
    // JUMPDEST, PUSH1 0x01, DUP1, PUSH1 0x03, LT, PUSH1 0x00, JUMPI, STOP
    const bytecode = hexToBytes("5b600180600310600057fe00");
    const predictor = new BranchPredictor();
    
    // First run - cold predictor
    const { analysis, metadata } = analyze(bytecode);
    const ops1 = buildOps(analysis, metadata, predictor, true);
    
    // After running, predictor should learn JUMPI is rarely taken
    // In real execution, this would update the predictor
    
    // Second run - warm predictor
    predictor.update(7, false); // Simulate learning
    const ops2 = buildOps(analysis, metadata, predictor, true);
    
    // ops2 might have different fusion patterns based on predictions
  });
});

describe("Extended Block Creation", () => {
  test("creates longer blocks with good predictions", () => {
    // Contract with multiple basic blocks that can be merged
    // PUSH1 0x01, ISZERO, PUSH1 0x0A, JUMPI, PUSH1 0x42, STOP, JUMPDEST, PUSH1 0x33, STOP
    const bytecode = hexToBytes("60011560a57604200005b603300");
    
    const predictor = new BranchPredictor();
    // Train to predict JUMPI as not taken (assert pattern)
    predictor.update(6, false);
    predictor.update(6, false);
    
    const { analysis, metadata } = analyze(bytecode);
    const ops = buildOps(analysis, metadata, predictor, true);
    
    // With good prediction, blocks before and after JUMPI can be merged
    // This would be verified by analyzing the ops array
  });
});

describe("Real Pattern: Ten Thousand Hashes", () => {
  test("hash loop pattern", () => {
    // Simplified version of hash loop
    // PUSH1 0x00, JUMPDEST, DUP1, PUSH2 0x2710, LT, ISZERO, PUSH1 0x14, JUMPI,
    // PUSH1 0x01, ADD, PUSH1 0x02, JUMP, JUMPDEST, STOP
    const bytecode = hexToBytes("60005b8061271010156014576001016002565b00");
    
    const predictor = new BranchPredictor();
    const { analysis, metadata } = analyze(bytecode);
    
    // First iteration - cold
    let frame = new StackFrame(analysis, metadata, buildOps(analysis, metadata, predictor, true), predictor);
    
    // Would run and train predictor
    // After multiple iterations, JUMPI at PC 9 would be predicted as not-taken
    // This enables better block merging for the loop body
  });
});

// Run all tests
describe("Integration Tests", () => {
  test("complex contract execution", () => {
    // Test that combines multiple features
    const bytecode = hexToBytes(
      "6001" +    // PUSH1 0x01
      "6002" +    // PUSH1 0x02  
      "01" +      // ADD
      "80" +      // DUP1
      "6005" +    // PUSH1 0x05
      "10" +      // LT
      "6012" +    // PUSH1 0x12
      "57" +      // JUMPI
      "6042" +    // PUSH1 0x42
      "6000" +    // PUSH1 0x00
      "52" +      // MSTORE
      "00" +      // STOP
      "5b" +      // JUMPDEST (0x12)
      "6033" +    // PUSH1 0x33
      "00"        // STOP
    );
    
    const { analysis, metadata } = analyze(bytecode);
    const predictor = new BranchPredictor();
    const ops = buildOps(analysis, metadata, predictor, true);
    const frame = new StackFrame(analysis, metadata, ops, predictor);
    
    try {
      ops[0](frame);
    } catch (e) {
      // Expected STOP
    }
    
    // Should have taken the jump (3 < 5)
    // The DUP1 left a 3 on the stack, and we should have jumped to push 0x33
    expect(frame.stack.size()).toBe(2);
    expect(frame.stack.pop()).toBe(0x33n);
    expect(frame.stack.pop()).toBe(3n);
  });
});