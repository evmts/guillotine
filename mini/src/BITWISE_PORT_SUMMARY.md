# Bitwise Handlers TypeScript Port Summary

## Files Created

### 1. `/Users/williamcory/guillotine-mini/src/utils/bigint-bitwise.ts`
**Purpose:** BigInt bitwise utility functions for 256-bit EVM operations

**Exports:**
- `MASK_256` - Constant for 2^256 - 1
- `SIGN_BIT_256` - Constant for 2^255
- `mask256()` - Mask bigint to 256 bits
- `isNegative256()` - Check if sign bit is set
- `toSigned256()` - Convert unsigned to signed (two's complement)
- `toUnsigned256()` - Convert signed to unsigned (two's complement)
- `shl256()` - Left shift with 256-bit masking
- `shr256()` - Logical right shift (zero-fill)
- `sar256()` - Arithmetic right shift (sign-extending)
- `byte256()` - Extract byte from 256-bit word

**Key Features:**
- Proper 256-bit masking for all operations
- Sign extension for arithmetic right shift
- Handles edge cases (shift >= 256, out of bounds byte index)

### 2. `/Users/williamcory/guillotine-mini/src/instructions/handlers_bitwise.ts`
**Purpose:** EVM bitwise opcode handlers (port of handlers_bitwise.zig)

**Exports:**
- `op_and()` - AND opcode (0x16)
- `op_or()` - OR opcode (0x17)
- `op_xor()` - XOR opcode (0x18)
- `op_not()` - NOT opcode (0x19)
- `byte()` - BYTE opcode (0x1a)
- `shl()` - SHL opcode (0x1b, Constantinople+)
- `shr()` - SHR opcode (0x1c, Constantinople+)
- `sar()` - SAR opcode (0x1d, Constantinople+)

**Implementation Details:**
- All operations consume 3 gas (GasFastestStep)
- All operations increment PC by 1
- Results are properly masked to 256 bits
- SHL/SHR/SAR check hardfork (Constantinople+) before executing
- SAR correctly implements sign extension

### 3. `/Users/williamcory/guillotine-mini/src/utils/bigint-bitwise.test.ts`
**Purpose:** Comprehensive tests for bigint utilities

**Test Coverage:**
- 36 tests covering all utility functions
- Edge cases: zero, max 256-bit value, overflow
- Sign handling for arithmetic shift
- Byte extraction from all positions
- Round-trip testing (signed ↔ unsigned conversion)

### 4. `/Users/williamcory/guillotine-mini/src/instructions/handlers_bitwise.test.ts`
**Purpose:** Tests for bitwise opcode handlers

**Test Coverage:**
- 43 tests covering all opcodes
- Basic operation tests (AND, OR, XOR, NOT)
- Bit manipulation tests (SHL, SHR, SAR)
- Byte extraction tests
- Gas consumption verification
- PC increment verification
- Hardfork checks for Constantinople opcodes
- Edge cases (zero, all ones, overflow)

## Test Results

```
✅ bigint-bitwise.test.ts: 36 pass, 181 expect() calls
✅ handlers_bitwise.test.ts: 43 pass, 104 expect() calls
✅ Combined: 79 pass, 285 expect() calls
```

## Key Implementation Notes

### Bitwise Operations
- **AND/OR/XOR/NOT**: Standard bigint bitwise operators with 256-bit masking
- **Result masking**: All results are masked with `mask256()` to ensure 256-bit bounds

### Shift Operations
- **SHL (Shift Left)**: Zero-fill, mask result to 256 bits, return 0 if shift >= 256
- **SHR (Logical Shift Right)**: Zero-fill, return 0 if shift >= 256
- **SAR (Arithmetic Shift Right)**: Sign-extending shift
  - Preserves sign bit by converting to signed, shifting, then converting back
  - Returns all 1s (if negative) or all 0s (if positive) for shift >= 256

### BYTE Operation
- Extracts single byte from 256-bit value
- Index 0 = most significant byte
- Index 31 = least significant byte
- Returns 0 for index >= 32

### Hardfork Support
- SHL/SHR/SAR introduced in Constantinople (EIP-145)
- Throws `InvalidOpcode` error if called on earlier hardforks
- Checked via `evm.hardfork.isBefore('CONSTANTINOPLE')`

## Comparison with Zig Implementation

| Aspect | Zig | TypeScript |
|--------|-----|------------|
| Type system | u256 native | bigint + masking |
| Bitwise ops | Native operators | Native + mask256 |
| Sign extension | @as(i256, @bitCast()) | toSigned256/toUnsigned256 |
| Shift overflow | Automatic wrap | Explicit mask |
| Gas constants | GasConstants import | Local constant |
| Error handling | error.InvalidOpcode | throw Error |

## Usage Example

```typescript
import { op_and, op_or, op_xor, op_not, byte, shl, shr, sar } from './instructions/handlers_bitwise';

// Create a mock frame
const frame = {
  stack: [0xffn, 0xaan],
  pc: 0,
  gasUsed: 0n,
  consumeGas(amount: bigint) { this.gasUsed += amount; },
  popStack() { return this.stack.pop()!; },
  pushStack(value: bigint) { this.stack.push(value); },
  getEvm() {
    return {
      hardfork: {
        isBefore: (fork: string) => false, // Cancun hardfork
      },
    };
  },
};

// Execute AND operation
op_and(frame);
console.log(frame.stack[0]); // 0xaa (170n)
```

## Next Steps

To integrate these handlers into the main EVM:

1. Import handlers in frame executor
2. Map opcodes to handler functions:
   - 0x16 → op_and
   - 0x17 → op_or
   - 0x18 → op_xor
   - 0x19 → op_not
   - 0x1a → byte
   - 0x1b → shl
   - 0x1c → shr
   - 0x1d → sar
3. Add hardfork context to frame
4. Ensure gas tracking and PC updates are consistent with other handlers

## References

- **Zig source:** `/Users/williamcory/guillotine-mini/src/instructions/handlers_bitwise.zig`
- **EIP-145:** Bitwise shifting instructions (SHL, SHR, SAR)
- **Yellow Paper:** Section 9.4 (Instruction Set)
