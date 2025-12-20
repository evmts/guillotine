# Voltaire TypeScript Setup

## Overview

This document explains the TypeScript infrastructure setup for using Voltaire primitives in guillotine-mini.

## Repository Locations

- **guillotine-mini**: `/Users/williamcory/guillotine-mini`
- **voltaire**: `/Users/williamcory/voltaire` (cloned from https://github.com/evmts/voltaire)

## Package Configuration

### src/package.json

Located at `/Users/williamcory/guillotine-mini/src/package.json`:

```json
{
  "name": "guillotine-mini-ts",
  "version": "0.0.0",
  "type": "module",
  "private": true,
  "dependencies": {
    "@tevm/voltaire": "file:/Users/williamcory/voltaire"
  },
  "devDependencies": {
    "@types/bun": "latest",
    "typescript": "^5.3.0",
    "vitest": "^2.0.0"
  }
}
```

### src/tsconfig.json

Located at `/Users/williamcory/guillotine-mini/src/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["ES2022"],
    "module": "ES2022",
    "moduleResolution": "bundler",
    "strict": true,
    "allowJs": true,
    "baseUrl": ".",
    "paths": {
      "@voltaire/*": ["./utils/voltaire-imports"],
      "@/*": ["./*"]
    }
  }
}
```

## Import Helper

The file `src/utils/voltaire-imports.ts` provides centralized re-exports of Voltaire primitives.

**Current Status**: Voltaire requires a build step (`bun run build`) before TypeScript imports work correctly. The package uses a complex build system with:

- Zig native bindings
- WASM compilation
- TypeScript transpilation (tsup)
- Type generation

## Building Voltaire

To use voltaire imports, you need to build it first:

```bash
cd /Users/williamcory/voltaire
bun install
bun run build
```

This will generate:
- `dist/` - Compiled JavaScript
- `types/` - TypeScript type definitions
- `zig-out/` - Native binaries and WASM modules

## Usage Examples

After building voltaire, you can import primitives:

```typescript
import { Address, Hash, Uint, GasConstants, Hardfork } from './utils/voltaire-imports';

// Address example
const addr = Address.fromHex('0xa0cf798816d4b9b9866b5330eea46a18382f251e');
const checksum = Address.toChecksummed(addr);

// U256 example
const value = Uint.U256.fromHex('0x1234');
const bigInt = Uint.U256.toBigInt(value);

// Hardfork example
const fork = Hardfork.fromString('Cancun');
```

## Alternative: Direct Source Imports (Not Recommended)

If you want to bypass the build step, you would need to:

1. Use voltaire's TypeScript source files directly
2. Configure module resolution to handle `.js` extensions in import statements (TypeScript quirk)
3. Handle WASM/native bindings fallback manually

This approach is complex and not recommended for production use.

## Recommended Workflow

1. **One-time setup**: Build voltaire
   ```bash
   cd /Users/williamcory/voltaire && bun run build
   ```

2. **Install dependencies** in guillotine-mini/src:
   ```bash
   cd /Users/williamcory/guillotine-mini/src && bun install
   ```

3. **Use the import helper**:
   ```typescript
   import { Address, Uint, Hardfork } from './utils/voltaire-imports';
   ```

4. **Run tests**:
   ```bash
   cd /Users/williamcory/guillotine-mini/src && bun test
   ```

## Troubleshooting

### "Cannot find module" errors

- Ensure voltaire is built: `cd /Users/williamcory/voltaire && bun run build`
- Check symlink: `ls -la /Users/williamcory/guillotine-mini/src/node_modules/@tevm/voltaire`
- Reinstall: `cd /Users/williamcory/guillotine-mini/src && rm -rf node_modules && bun install`

### Type errors

- Run type check: `cd /Users/williamcory/guillotine-mini/src && bun run type-check`
- Ensure voltaire types are generated: `cd /Users/williamcory/voltaire && bun run build:types`

### Import resolution issues

- Use the import helper (`./utils/voltaire-imports.ts`) instead of importing directly from `@tevm/voltaire`
- Ensure `tsconfig.json` has correct `moduleResolution: "bundler"`

## Files Created

1. `/Users/williamcory/guillotine-mini/src/package.json` - Package configuration
2. `/Users/williamcory/guillotine-mini/src/tsconfig.json` - TypeScript configuration
3. `/Users/williamcory/guillotine-mini/src/utils/voltaire-imports.ts` - Import helper (needs voltaire built)
4. `/Users/williamcory/guillotine-mini/src/utils/voltaire-imports.test.ts` - Test file
5. `/Users/williamcory/guillotine-mini/src/VOLTAIRE_SETUP.md` - This documentation

## Next Steps

To complete the setup:

```bash
# 1. Build voltaire
cd /Users/williamcory/voltaire
bun install
bun run build

# 2. Return to guillotine-mini and test
cd /Users/williamcory/guillotine-mini/src
bun test utils/voltaire-imports.test.ts
```

Once voltaire is built, the import helper will work correctly and you can start using Ethereum primitives in your TypeScript code.
