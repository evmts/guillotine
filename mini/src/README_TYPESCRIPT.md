# TypeScript Infrastructure for Guillotine-Mini

## Overview

This document describes the TypeScript setup for the guillotine-mini EVM implementation, including integration with the Voltaire primitives library.

## Directory Structure

```
src/
├── package.json            # TypeScript dependencies (vitest, @tevm/voltaire)
├── tsconfig.json           # TypeScript configuration
├── utils/
│   ├── voltaire-imports.ts      # Centralized Voltaire imports
│   └── voltaire-imports.test.ts # Tests for voltaire imports
├── bytecode.ts             # Example: Bytecode utilities (TypeScript port)
└── VOLTAIRE_SETUP.md       # Detailed voltaire setup instructions
```

## Quick Start

### 1. Install Dependencies

```bash
cd /Users/williamcory/guillotine-mini/src
bun install
```

### 2. Run Tests

```bash
cd /Users/williamcory/guillotine-mini/src
bun test
```

### 3. Type Check

```bash
cd /Users/williamcory/guillotine-mini/src
bun run type-check
```

## Configuration Files

### package.json

Key dependencies:
- `@tevm/voltaire` - Ethereum primitives (linked from local /Users/williamcory/voltaire)
- `vitest` - Testing framework
- `typescript` - Type checking

### tsconfig.json

Configured for:
- ES2022 target (BigInt support required for u256)
- Bundler module resolution (Bun-compatible)
- Strict type checking enabled
- Path aliases: `@/*` for relative imports

## Voltaire Integration

### Current Status

**Voltaire** is a TypeScript/Zig library providing Ethereum primitives (Address, Hash, Uint, etc.). It's currently cloned locally at `/Users/williamcory/voltaire`.

**Build Status**: The voltaire build process has some issues (missing files, typecheck errors). As a temporary solution, we're using placeholder implementations in `src/utils/voltaire-imports.ts`.

### Using Voltaire Primitives

Import from the centralized helper:

```typescript
import { Address, Uint, Hardfork, GasConstants } from './utils/voltaire-imports';

// Address operations
const addr = Address.fromHex('0xa0cf798816d4b9b9866b5330eea46a18382f251e');
const hex = Address.toHex(addr);
const isZero = Address.isZero(addr);

// U256 operations
const value = Uint.U256.fromHex('0x1234');
const bigInt = Uint.U256.toBigInt(value);
const valueFromNumber = Uint.U256.fromNumber(42);

// Hardfork detection
const fork = Hardfork.fromString('Cancun');
const isCancun = Hardfork.isAtLeast(fork, 'Berlin'); // true

// Gas constants
const sloadCost = GasConstants.G_SLOAD; // 2100n
```

### Placeholder vs Real Voltaire

**Current**: Placeholder implementations (basic functionality)
- Simple TypeScript implementations
- No native Zig/WASM performance
- Sufficient for prototyping

**Future**: Real Voltaire (once built)
- Native Zig implementations via FFI
- WASM bindings for performance
- Full feature parity with Zig primitives

To switch from placeholder to real voltaire:
1. Build voltaire: `cd /Users/williamcory/voltaire && bun run build`
2. Update `src/utils/voltaire-imports.ts` to import from `@tevm/voltaire`
3. Remove placeholder implementations

See `src/VOLTAIRE_SETUP.md` for detailed instructions.

## Example: Bytecode Port

The existing `src/bytecode.ts` demonstrates a TypeScript port of the Zig bytecode analysis:

```typescript
import { Bytecode } from './bytecode';

// Analyze bytecode
const code = new Uint8Array([0x60, 0x01, 0x5b, 0x00]); // PUSH1 1, JUMPDEST, STOP
const bytecode = new Bytecode(code);

// Check JUMPDEST validity
console.log(bytecode.isValidJumpDest(2)); // true (position 2 is JUMPDEST)
console.log(bytecode.isValidJumpDest(1)); // false (position 1 is PUSH1 data)

// Read immediate data
const value = bytecode.readImmediate(0, 1); // Read 1 byte after PUSH1
console.log(value); // 1n
```

## Testing

### Unit Tests

Run all tests:
```bash
bun test
```

Run specific test file:
```bash
bun test utils/voltaire-imports.test.ts
```

Watch mode:
```bash
bun test --watch
```

### Test Coverage

```bash
bun test --coverage
```

## Development Workflow

### Adding New TypeScript Modules

1. Create `.ts` file in `src/`
2. Add corresponding `.test.ts` file
3. Import voltaire primitives from `./utils/voltaire-imports`
4. Run tests: `bun test`
5. Type check: `bun run type-check`

### Example: Creating a Stack Module

```typescript
// src/stack.ts
import { Uint } from './utils/voltaire-imports';

export class Stack {
  private items: bigint[] = [];
  private readonly maxSize = 1024;

  push(value: bigint): void {
    if (this.items.length >= this.maxSize) {
      throw new Error('Stack overflow');
    }
    this.items.push(value);
  }

  pop(): bigint {
    const value = this.items.pop();
    if (value === undefined) {
      throw new Error('Stack underflow');
    }
    return value;
  }

  peek(depth: number = 0): bigint {
    const index = this.items.length - 1 - depth;
    if (index < 0) {
      throw new Error('Stack underflow');
    }
    return this.items[index];
  }

  get size(): number {
    return this.items.length;
  }
}
```

```typescript
// src/stack.test.ts
import { describe, it, expect } from 'vitest';
import { Stack } from './stack';

describe('Stack', () => {
  it('should push and pop values', () => {
    const stack = new Stack();
    stack.push(42n);
    expect(stack.size).toBe(1);
    expect(stack.pop()).toBe(42n);
    expect(stack.size).toBe(0);
  });

  it('should enforce max size', () => {
    const stack = new Stack();
    for (let i = 0; i < 1024; i++) {
      stack.push(BigInt(i));
    }
    expect(() => stack.push(1025n)).toThrow('Stack overflow');
  });
});
```

## Integration with Zig

The TypeScript implementation complements the Zig implementation:

| Aspect | Zig | TypeScript |
|--------|-----|------------|
| **Performance** | Native speed | Adequate for prototyping |
| **Use Case** | Production EVM | Testing, scripting, tooling |
| **Primitives** | Built-in | Voltaire library |
| **Testing** | Zig test | Vitest |
| **Build** | `zig build` | `bun test` |

### Shared Test Cases

You can use TypeScript to generate test cases for the Zig implementation:

```typescript
// scripts/generate-test-vectors.ts
import { Uint, Address } from '../src/utils/voltaire-imports';

const testCases = [
  {
    name: 'simple_addition',
    bytecode: '0x6001600201', // PUSH1 1 PUSH1 2 ADD
    expectedStack: [Uint.U256.fromNumber(3)],
  },
  // ... more cases
];

console.log(JSON.stringify(testCases, null, 2));
```

## Troubleshooting

### Module Resolution Errors

If you see "Cannot find module" errors:

1. Check `tsconfig.json` path mappings
2. Ensure dependencies are installed: `bun install`
3. Verify voltaire symlink: `ls -la node_modules/@tevm/voltaire`

### TypeScript Errors

If you see type errors:

1. Run type check: `bun run type-check`
2. Check that `strict: true` isn't causing issues
3. Add `// @ts-expect-error` for temporary workarounds

### Test Failures

If tests fail:

1. Check that placeholder implementations match expected behavior
2. Verify test assertions are correct
3. Run single test: `bun test path/to/test.ts`

## Next Steps

1. **Build Voltaire**: Once voltaire's build issues are resolved, replace placeholders with real imports
2. **Port More Modules**: Continue porting Zig modules to TypeScript (Frame, EVM, Host)
3. **Integration Tests**: Create tests that validate TypeScript and Zig implementations match
4. **Benchmarking**: Compare TypeScript and Zig performance for key operations

## Resources

- **Voltaire**: https://github.com/evmts/voltaire
- **Vitest**: https://vitest.dev/
- **Bun**: https://bun.sh/
- **TypeScript**: https://www.typescriptlang.org/
- **EVMTS**: https://github.com/evmts/tevm-monorepo

## Files Created

This setup created the following files:

1. `/Users/williamcory/guillotine-mini/src/package.json` - Package configuration
2. `/Users/williamcory/guillotine-mini/src/tsconfig.json` - TypeScript configuration
3. `/Users/williamcory/guillotine-mini/src/utils/voltaire-imports.ts` - Import helper (with placeholders)
4. `/Users/williamcory/guillotine-mini/src/utils/voltaire-imports.test.ts` - Import tests
5. `/Users/williamcory/guillotine-mini/src/VOLTAIRE_SETUP.md` - Detailed setup docs
6. `/Users/williamcory/guillotine-mini/src/README_TYPESCRIPT.md` - This file

All tests passing with placeholder implementations!
