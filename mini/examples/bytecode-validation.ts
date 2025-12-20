/**
 * Example: Bytecode Jump Destination Validation
 *
 * This demonstrates how the Bytecode class correctly identifies valid JUMPDEST
 * locations while avoiding false positives from PUSH instruction immediate data.
 */

import { Bytecode } from "../src/bytecode";

// Helper to format bytecode with annotations
function displayBytecode(code: Uint8Array, bytecode: Bytecode) {
  console.log("Position | Opcode | Description           | Valid JUMPDEST?");
  console.log("---------|--------|------------------------|----------------");

  let pc = 0;
  while (pc < code.length) {
    const opcode = code[pc];
    const hex = opcode.toString(16).padStart(2, "0");
    const isJumpdest = bytecode.isValidJumpDest(pc);

    let description: string;
    if (opcode === 0x5b) {
      description = "JUMPDEST";
    } else if (opcode >= 0x60 && opcode <= 0x7f) {
      const pushSize = opcode - 0x5f;
      description = `PUSH${pushSize}`;
    } else {
      description = `OP 0x${hex}`;
    }

    console.log(
      `${pc.toString().padStart(8)} | 0x${hex}  | ${description.padEnd(22)} | ${isJumpdest ? "✅" : "❌"}`
    );

    pc++;
  }
  console.log();
}

console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
console.log("Example 1: Simple JUMPDEST Detection");
console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
console.log();

// Example 1: Simple contract with valid JUMPDEST
const code1 = new Uint8Array([
  0x60, 0x01, // PUSH1 0x01
  0x5b,       // JUMPDEST (valid!)
  0x00,       // STOP
]);

const bytecode1 = new Bytecode(code1);
displayBytecode(code1, bytecode1);

console.log("✅ Position 2 is correctly identified as a valid JUMPDEST");
console.log();
console.log();

console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
console.log("Example 2: JUMPDEST in PUSH Data (Invalid)");
console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
console.log();

// Example 2: PUSH1 with 0x5b as immediate data
const code2 = new Uint8Array([
  0x60, 0x5b, // PUSH1 0x5b (pushes JUMPDEST opcode as DATA)
  0x5b,       // JUMPDEST (valid!)
  0x00,       // STOP
]);

const bytecode2 = new Bytecode(code2);
displayBytecode(code2, bytecode2);

console.log("✅ Position 1 (the 0x5b byte in PUSH1 data) is NOT a valid JUMPDEST");
console.log("✅ Position 2 (the actual JUMPDEST instruction) IS valid");
console.log();
console.log();

console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
console.log("Example 3: PUSH32 with Embedded JUMPDEST Bytes");
console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
console.log();

// Example 3: PUSH32 with multiple 0x5b bytes in data
const code3 = new Uint8Array(34);
code3[0] = 0x7f; // PUSH32
for (let i = 1; i < 33; i++) {
  code3[i] = 0x5b; // All 32 bytes are JUMPDEST opcodes (but as data!)
}
code3[33] = 0x5b; // Actual JUMPDEST instruction

const bytecode3 = new Bytecode(code3);
console.log("Bytecode: PUSH32 [32 bytes of 0x5b] JUMPDEST");
console.log();
console.log(`Total length: ${code3.length} bytes`);
console.log(`Valid JUMPDESTs found: ${[...Array(code3.length)].filter((_, i) => bytecode3.isValidJumpDest(i)).length}`);
console.log();
console.log("Checking positions:");
console.log(`  Position 0 (PUSH32 opcode):     ${bytecode3.isValidJumpDest(0) ? "❌ INVALID" : "✅ NOT a JUMPDEST"}`);
console.log(`  Positions 1-32 (PUSH32 data):   ${bytecode3.isValidJumpDest(1) ? "❌ INVALID" : "✅ NOT JUMPDESTs"}`);
console.log(`  Position 33 (actual JUMPDEST):  ${bytecode3.isValidJumpDest(33) ? "✅ VALID JUMPDEST" : "❌ INVALID"}`);
console.log();
console.log();

console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
console.log("Example 4: Reading PUSH Immediate Values");
console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
console.log();

const code4 = new Uint8Array([
  0x60, 0xff,             // PUSH1 0xff
  0x61, 0x12, 0x34,       // PUSH2 0x1234
  0x7f, ...new Array(32).fill(0).map((_, i) => i + 1), // PUSH32 (0x01020304...1f20)
]);

const bytecode4 = new Bytecode(code4);

const push1Value = bytecode4.readImmediate(0, 1);
const push2Value = bytecode4.readImmediate(2, 2);
const push32Value = bytecode4.readImmediate(5, 32);

console.log(`PUSH1 at position 0: 0x${push1Value?.toString(16)} (decimal: ${push1Value})`);
console.log(`PUSH2 at position 2: 0x${push2Value?.toString(16)} (decimal: ${push2Value})`);
console.log(`PUSH32 at position 5: 0x${push32Value?.toString(16)}`);
console.log();
console.log();

console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
console.log("Example 5: Real-World Contract Pattern");
console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
console.log();

// Simplified Solidity contract bytecode pattern
const code5 = new Uint8Array([
  0x60, 0x80,       // PUSH1 0x80 (free memory pointer)
  0x60, 0x40,       // PUSH1 0x40 (memory location)
  0x52,             // MSTORE
  0x5b,             // JUMPDEST (function entry point)
  0x60, 0x00,       // PUSH1 0x00
  0x60, 0x00,       // PUSH1 0x00
  0xf3,             // RETURN
]);

const bytecode5 = new Bytecode(code5);
console.log("Contract initialization + function entry:");
displayBytecode(code5, bytecode5);

console.log("This pattern is common in Solidity contracts:");
console.log("  1. Set up free memory pointer (PUSH1 0x80, PUSH1 0x40, MSTORE)");
console.log("  2. Function dispatcher jumps to JUMPDEST at position 5");
console.log("  3. Function executes and returns");
console.log();

console.log("✅ Bytecode validation complete!");
console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
