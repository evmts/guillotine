# Utils - EVM TypeScript Utilities

Comprehensive utility libraries for EVM operations in TypeScript.

## Overview

This directory contains specialized utility modules that provide low-level primitives for EVM development, matching Ethereum Virtual Machine semantics exactly.

## Modules

### bigint.ts - BigInt Arithmetic Utilities

**Purpose:** EVM-compliant bigint operations with proper overflow/underflow handling and signed/unsigned conversions.

**Key Features:**
- ✅ Wrapping operations for u256, u128, u64, u32
- ✅ Modular arithmetic (ADD, SUB, MUL, DIV, MOD opcodes)
- ✅ Signed arithmetic (SDIV, SMOD, SLT, SGT opcodes)
- ✅ Two's complement conversions
- ✅ Division by zero returns 0 (EVM semantics)
- ✅ All operations match EVM Yellow Paper specifications

**Usage:**
```typescript
import {
  MAX_U256,
  wrap256,
  addMod256,
  toSigned,
  sdivMod256,
  slt,
} from "./utils/bigint";

// Overflow wrapping (ADD opcode)
const result = addMod256(MAX_U256, 1n); // 0n

// Signed division (SDIV opcode)
const neg10 = toUnsigned(-10n);
const quotient = sdivMod256(neg10, 3n); // -3 in two's complement

// Signed comparison (SLT opcode)
const isLess = slt(toUnsigned(-1n), 0n); // true
```

**Constants:**
- `MAX_U256`, `MAX_U128`, `MAX_U64`, `MAX_U32` - Maximum unsigned values
- `MIN_SIGNED_256`, `MAX_SIGNED_256` - Signed range boundaries

**Functions:**

| Function | Description | EVM Opcode |
|----------|-------------|------------|
| `wrap256(value)` | Wrap to u256 (value & MAX_U256) | - |
| `toU256(value)` | Validate u256 range (throws on error) | - |
| `addMod256(a, b)` | Addition with wrapping | ADD |
| `subMod256(a, b)` | Subtraction with wrapping | SUB |
| `mulMod256(a, b)` | Multiplication with wrapping | MUL |
| `divMod256(a, b)` | Division (0 if b==0) | DIV |
| `modMod256(a, b)` | Modulo (0 if b==0) | MOD |
| `isNegative(value)` | Check if sign bit set | - |
| `toSigned(value)` | Convert to signed (two's complement) | - |
| `toUnsigned(value)` | Convert to unsigned | - |
| `abs256(value)` | Absolute value | - |
| `sdivMod256(a, b)` | Signed division | SDIV |
| `smodMod256(a, b)` | Signed modulo | SMOD |
| `slt(a, b)` | Signed less-than | SLT |
| `sgt(a, b)` | Signed greater-than | SGT |

**Test Coverage:** 74 tests, 436 assertions

### bigint-bitwise.ts - Bitwise Operations

**Purpose:** EVM bitwise operations (AND, OR, XOR, NOT, SHL, SHR, SAR, BYTE, SIGNEXTEND).

**Key Features:**
- ✅ All EVM bitwise opcodes
- ✅ Shift operations with u256 wrapping
- ✅ Arithmetic right shift (sign-extending)
- ✅ BYTE extraction (index-based)
- ✅ SIGNEXTEND for variable-width integers

**Usage:**
```typescript
import {
  and256,
  shl256,
  sar256,
  signextend256,
} from "./utils/bigint-bitwise";

// Bitwise AND
const masked = and256(0xFFn, 0x0Fn); // 0x0F

// Shift left (SHL)
const shifted = shl256(2n, 1n); // 4n (1 << 2)

// Arithmetic right shift (SAR)
const negOne = toUnsigned(-1n);
const sar = sar256(1n, negOne); // Still -1 (sign extends)
```

**Test Coverage:** Comprehensive test suite with edge cases

### voltaire-imports.ts - EVM Primitives Integration

**Purpose:** Bridge between Voltaire (@voltaire/evm) primitives and guillotine-mini utilities.

**Key Features:**
- ✅ Type conversions (Address, Hash, Bytes)
- ✅ ABI encoding/decoding helpers
- ✅ Transaction type handling
- ✅ Gas constant lookups

## Testing

Run all utility tests:
```bash
cd src
bun test utils/
```

Run specific module tests:
```bash
bun test utils/bigint.test.ts
bun test utils/bigint-bitwise.test.ts
```

Run with examples:
```bash
bun utils/bigint.example.ts
```

## Design Principles

1. **EVM Semantics First**: All operations match EVM Yellow Paper specifications exactly
2. **Type Safety**: TypeScript with strict types, no implicit conversions
3. **Explicit Wrapping**: Overflow/underflow behavior is explicit and tested
4. **Zero Special Cases**: Division/modulo by zero returns 0 (per EVM spec)
5. **Comprehensive Testing**: Every function has multiple test cases including edge cases

## Integration with Zig Implementation

These TypeScript utilities are designed to mirror the Zig implementation in `src/*.zig`. Key parallels:

| TypeScript Module | Zig Implementation |
|-------------------|-------------------|
| `bigint.ts` | `src/frame.zig` (opcode arithmetic) |
| `bigint-bitwise.ts` | `src/frame.zig` (bitwise opcodes) |
| `voltaire-imports.ts` | `src/primitives/` (gas constants, types) |

Use these utilities for:
- ✅ Prototyping new opcodes before Zig implementation
- ✅ Test case generation
- ✅ Reference implementations for debugging
- ✅ JavaScript/WASM interface development

## Performance Considerations

**BigInt Operations:**
- Native JavaScript BigInt (fast for < 2^53)
- Bitwise operations are efficient (O(1) for most)
- String conversions (toString/parseInt) can be slow for large values

**Recommendations:**
- Cache constants (MAX_U256, etc.) - don't recompute
- Use bitwise operations over arithmetic when possible
- Avoid string conversions in hot paths
- Profile before optimizing (premature optimization is evil)

## Contributing

When adding new utilities:

1. **Match EVM Spec**: Reference Yellow Paper or execution-specs
2. **Write Tests First**: TDD approach ensures correctness
3. **Document Behavior**: Include JSDoc with examples
4. **Test Edge Cases**: 0, MAX_U256, negative values, overflow/underflow
5. **Update README**: Add function to this documentation

## Resources

- **Ethereum Yellow Paper**: https://ethereum.github.io/yellowpaper/paper.pdf
- **execution-specs**: https://github.com/ethereum/execution-specs
- **EVM Codes**: https://www.evm.codes/
- **BigInt MDN**: https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/BigInt

## License

Same as parent project (see LICENSE file).
