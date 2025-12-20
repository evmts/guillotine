# Shell Script Migration to Bun TypeScript

All shell scripts in the `scripts/` directory have been converted to Bun TypeScript for better maintainability, type safety, and cross-platform compatibility.

## Migrated Scripts

| Old (.sh) | New (.ts) | Status |
|-----------|-----------|--------|
| `isolate-test.sh` | `isolate-test.ts` | ✅ Migrated |
| `test-subset.sh` | `test-subset.ts` | ✅ Migrated |
| `quick-test.sh` | `quick-test.ts` | ✅ Migrated |
| `debug-test.sh` | `debug-test.ts` | ✅ Migrated |
| `run-filtered-tests.sh` | `run-filtered-tests.ts` | ✅ Migrated |

## Usage Changes

### Before (Shell)
```bash
./scripts/isolate-test.sh "test_name"
./scripts/test-subset.sh pattern
./scripts/quick-test.sh
```

### After (TypeScript)
```bash
bun scripts/isolate-test.ts "test_name"
bun scripts/test-subset.ts pattern
bun scripts/quick-test.ts
```

## Benefits

1. **Type Safety** - TypeScript catches errors at compile time
2. **Cross-Platform** - Works on Windows, macOS, Linux without shell dependencies
3. **Better Tooling** - IDE autocomplete, refactoring, debugging
4. **Consistency** - All scripts use same runtime (Bun) and APIs
5. **Maintainability** - Easier to understand and modify
6. **Performance** - Bun is fast and efficient

## Implementation Details

All TypeScript scripts:
- Use Bun's `$` for shell commands (similar to zx)
- Use Bun's `spawn` for process management
- Maintain same colored output and formatting
- Preserve all functionality from shell versions
- Are executable (`chmod +x *.ts` already applied)

## Backwards Compatibility

The old `.sh` scripts are still present for backwards compatibility but should be considered deprecated. Update your workflows to use the `.ts` versions.

## Documentation Updates

The following files have been updated to reference the TypeScript versions:
- ✅ `CLAUDE.md` - All script references updated
- ✅ `scripts/README.md` - All examples updated
- ✅ `scripts/fix-specs.ts` - Agent prompt updated

## Testing

All scripts have been tested to ensure they work correctly:
- `isolate-test.ts` - Tested with help flag, runs tests correctly
- `test-subset.ts` - Filters tests properly
- `quick-test.ts` - Runs smoke tests
- `debug-test.ts` - Debug mode works
- `run-filtered-tests.ts` - Basic filtering works

## Migration Complete

All shell scripts have been successfully migrated to Bun TypeScript. The codebase is now more maintainable and type-safe.
