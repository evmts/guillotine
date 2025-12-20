/**
 * BigInt Utilities - Usage Examples
 *
 * Demonstrates common EVM operation patterns using bigint helpers.
 */

import {
  MAX_U256,
  MIN_SIGNED_256,
  MAX_SIGNED_256,
  wrap256,
  addMod256,
  subMod256,
  mulMod256,
  divMod256,
  modMod256,
  toSigned,
  toUnsigned,
  isNegative,
  sdivMod256,
  smodMod256,
  slt,
  sgt,
} from "./bigint";

console.log("=".repeat(60));
console.log("BigInt Utilities - EVM Operations Examples");
console.log("=".repeat(60));

// ============================================================================
// Example 1: Overflow Handling (ADD opcode)
// ============================================================================
console.log("\n1. Overflow Handling (ADD):");
console.log("-".repeat(40));
const overflow = addMod256(MAX_U256, 1n);
console.log(`MAX_U256 + 1 = ${overflow}`);
console.log(`Expected: 0 (wraps around)`);

// ============================================================================
// Example 2: Underflow Handling (SUB opcode)
// ============================================================================
console.log("\n2. Underflow Handling (SUB):");
console.log("-".repeat(40));
const underflow = subMod256(0n, 1n);
console.log(`0 - 1 = ${underflow.toString(16)}`);
console.log(`Expected: ${MAX_U256.toString(16)} (wraps to MAX_U256)`);

// ============================================================================
// Example 3: Multiplication Overflow (MUL opcode)
// ============================================================================
console.log("\n3. Multiplication Overflow (MUL):");
console.log("-".repeat(40));
const halfMax = 1n << 255n;
const mulOverflow = mulMod256(2n, halfMax);
console.log(`2 * 2^255 = ${mulOverflow}`);
console.log(`Expected: 0 (2^256 wraps to 0)`);

// ============================================================================
// Example 4: Division by Zero (DIV opcode)
// ============================================================================
console.log("\n4. Division by Zero (DIV):");
console.log("-".repeat(40));
const divByZero = divMod256(42n, 0n);
console.log(`42 / 0 = ${divByZero}`);
console.log(`Expected: 0 (EVM returns 0 for div by zero)`);

// ============================================================================
// Example 5: Signed Integer Conversion
// ============================================================================
console.log("\n5. Signed Integer Conversion:");
console.log("-".repeat(40));
const negOne = MAX_U256; // Unsigned representation of -1
const negOneSigned = toSigned(negOne);
console.log(`toSigned(${negOne.toString(16).slice(0, 10)}...) = ${negOneSigned}`);
console.log(`Expected: -1`);

const backToUnsigned = toUnsigned(-1n);
console.log(`toUnsigned(-1) = ${backToUnsigned.toString(16).slice(0, 10)}...`);
console.log(`Expected: MAX_U256`);

// ============================================================================
// Example 6: Signed Division (SDIV opcode)
// ============================================================================
console.log("\n6. Signed Division (SDIV):");
console.log("-".repeat(40));
const neg10 = toUnsigned(-10n);
const result = sdivMod256(neg10, 3n);
const resultSigned = toSigned(result);
console.log(`-10 / 3 = ${resultSigned}`);
console.log(`Expected: -3 (truncates toward zero)`);

// ============================================================================
// Example 7: Signed Modulo (SMOD opcode)
// ============================================================================
console.log("\n7. Signed Modulo (SMOD):");
console.log("-".repeat(40));
const smodResult = smodMod256(neg10, 3n);
const smodSigned = toSigned(smodResult);
console.log(`-10 % 3 = ${smodSigned}`);
console.log(`Expected: -1 (sign matches dividend)`);

// ============================================================================
// Example 8: Signed Comparisons (SLT/SGT opcodes)
// ============================================================================
console.log("\n8. Signed Comparisons (SLT/SGT):");
console.log("-".repeat(40));
const neg5 = toUnsigned(-5n);
console.log(`-5 < 0: ${slt(neg5, 0n)}`);
console.log(`0 > -5: ${sgt(0n, neg5)}`);
console.log(`Expected: true for both`);

// ============================================================================
// Example 9: Sign Detection
// ============================================================================
console.log("\n9. Sign Detection:");
console.log("-".repeat(40));
const values = [
  { name: "0", val: 0n },
  { name: "42", val: 42n },
  { name: "MAX_SIGNED_256", val: MAX_SIGNED_256 },
  { name: "MIN_SIGNED_256 (unsigned)", val: toUnsigned(MIN_SIGNED_256) },
  { name: "-1 (unsigned)", val: toUnsigned(-1n) },
];

for (const { name, val } of values) {
  const negative = isNegative(val);
  console.log(`${name}: ${negative ? "negative" : "positive"}`);
}

// ============================================================================
// Example 10: Boundary Values
// ============================================================================
console.log("\n10. Boundary Values:");
console.log("-".repeat(40));
console.log(`MAX_U256: ${MAX_U256.toString(16).slice(0, 16)}...${MAX_U256.toString(16).slice(-16)}`);
console.log(`MIN_SIGNED_256: ${MIN_SIGNED_256}`);
console.log(`MAX_SIGNED_256: ${MAX_SIGNED_256.toString(16)}`);

// ============================================================================
// Example 11: Complex Calculation (Simulating EVM stack operations)
// ============================================================================
console.log("\n11. Complex EVM Stack Simulation:");
console.log("-".repeat(40));
// Simulate: PUSH 10, PUSH 3, DIV, PUSH 2, MUL, PUSH 1, ADD
let stack: bigint[] = [];
stack.push(10n);
stack.push(3n);
// DIV pops two values: b (top), a (second) -> pushes a / b
const b1 = stack.pop()!;
const a1 = stack.pop()!;
const div = divMod256(a1, b1);
stack.push(div);
stack.push(2n);
// MUL pops two values and multiplies
const b2 = stack.pop()!;
const a2 = stack.pop()!;
const mul = mulMod256(a2, b2);
stack.push(mul);
stack.push(1n);
// ADD pops two values and adds
const b3 = stack.pop()!;
const a3 = stack.pop()!;
const add = addMod256(a3, b3);
stack.push(add);
console.log(`(10 / 3) * 2 + 1 = ${stack[0]}`);
console.log(`Expected: 7 (10/3=3, 3*2=6, 6+1=7)`);

console.log("\n" + "=".repeat(60));
console.log("Examples complete!");
console.log("=".repeat(60) + "\n");
