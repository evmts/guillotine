# CLAUDE.md - TypeScript SDK Development Guidelines

## Core Architecture

### WASM FFI Bridge

The TypeScript SDK is a wrapper around the Guillotine Evm WASM implementation, which is compiled from the Zig FFI interface located at `src/evm_c.zig`. This provides:

- **High Performance**: Native Zig execution via WASM
- **Type Safety**: Full TypeScript typing over the FFI boundary
- **Memory Safety**: Controlled memory management through the WASM sandbox

### Key Design Principles

1. **Type Safety**: Full TypeScript typing over the FFI boundary
2. **Zero-Copy Where Possible**: Minimize data copying between JS and WASM
3. **Async-First**: All potentially blocking operations are async
4. **Automatic Resource Management**: Memory is allocated and freed properly
5. **Consistent Byte Order**: Big-endian throughout, matching Ethereum standards

## Primitive Classes

### U256 Class
```typescript
// Standard big-endian byte operations
U256.fromBytes(bytes)     // Expects big-endian bytes
U256.toBytes()            // Returns big-endian bytes (32 bytes)
U256.fromHex(hex)         // Parse from hex string
U256.toHex()              // Convert to hex string
```

### Bytes Class
- Represents raw byte arrays
- Used for arbitrary data (bytecode, input data, etc.)
- No endianness concerns - just raw bytes

### Address Class  
- Always 20 bytes
- Stored as raw bytes internally
- No endianness concerns

## Memory Management

### Allocation Pattern

```typescript
// ALWAYS follow this pattern for WASM memory:
const ptr = memory.malloc(size);
try {
  // Use the allocated memory
  wasm.some_function(ptr);
} finally {
  memory.free(ptr, size);
}
```

### Key Rules

1. **Always Free**: Every `malloc` must have a corresponding `free`
2. **Use try/finally**: Ensure cleanup even on errors
3. **Track Sizes**: Keep allocation sizes for proper deallocation
4. **No Leaks**: The WASM heap is limited; leaks will crash the runtime

## WASM Interface Structure

### FFI Data Structures

Located in `src/evm_c.zig`, these structures define the binary layout:

```zig
// CallParams - 124 bytes total
pub const CallParams = extern struct {
    caller: [20]u8,        // Address
    to: [20]u8,            // Address  
    value: [32]u8,         // U256 as bytes (big-endian)
    input: [*]const u8,    // Pointer
    input_len: usize,      // Length
    gas: u64,              // Gas limit
    call_type: u8,         // CallType enum
    salt: [32]u8,          // For CREATE2
};
```

### Handle-Based Architecture

- Evm instances are managed via opaque handles
- Multiple instances can coexist (separate state)
- Handles must be properly destroyed to prevent leaks

## Testing Philosophy

### Test Helpers

Use the standardized helpers in `test/test-helpers.ts`:

```typescript
// Create test addresses
testAddress(1)  // 0x0000...0001

// Create test bytecode
returnBytecode(42)       // Returns 42
storeBytecode(0, 100)    // Stores 100 at slot 0
logBytecode(2)           // Emits LOG2
selfDestructBytecode(addr) // Self-destructs
```

### Test Patterns

1. **Setup Evm Instance**: Always create fresh instances for isolation
2. **Use Helpers**: Leverage test helpers for common scenarios
3. **Verify State**: Check balances, storage, and code after operations
4. **Clean Assertions**: Use clear, descriptive assertions
5. **Resource Cleanup**: Always destroy Evm instances after tests

### Example Test Structure

```typescript
describe('Feature', () => {
  let evm: GuillotineEvm;
  
  beforeEach(async () => {
    evm = await GuillotineEvm.create();
  });
  
  afterEach(() => {
    evm.destroy();
  });
  
  it('should do something', async () => {
    // Setup
    await evm.setBalance(addr, U256.from(1000));
    
    // Execute
    const result = await evm.call({ /* params */ });
    
    // Assert
    expect(result.success).toBe(true);
    expect(result.gasUsed).toBeLessThan(100000n);
  });
});
```

## Error Handling

### Error Types

Use the `GuillotineError` class for all errors:

```typescript
// Specific error types
GuillotineError.vmNotInitialized(message)
GuillotineError.executionFailed(message, cause?)
GuillotineError.stateError(message, cause?)
GuillotineError.invalidInput(message)
```

### Error Patterns

1. **Wrap Native Errors**: Always wrap WASM errors in GuillotineError
2. **Preserve Context**: Include original error as cause
3. **Check WASM Errors**: Use `guillotine_get_last_error()` for details
4. **Clear Messages**: Provide actionable error messages

## Performance Considerations

### Optimization Guidelines

1. **Batch Operations**: Group related state changes
2. **Reuse Instances**: Don't recreate Evm instances unnecessarily
3. **Minimize Copies**: Use views where possible
4. **Async Patterns**: Use Promise.all for parallel operations

### Memory Limits

- WASM heap is limited (default: 256MB)
- Monitor allocation patterns in tests
- Free memory promptly to avoid exhaustion

## Module System

### Import Structure

```typescript
// Primitives
import { Address, U256, Bytes } from '../primitives';

// Evm Core
import { GuillotineEvm, CallType, ExecutionParams } from '../evm';

// Errors
import { GuillotineError } from '../errors';

// WASM (internal only)
import { getWasmLoader } from '../wasm/loader';
```

### Export Pattern

- Export only public API from index.ts
- Keep WASM internals private
- Use barrel exports for clean imports

## Build and Development

### Commands

```bash
# Install dependencies
pnpm install

# Build TypeScript
pnpm build

# Run tests
pnpm test

# Type checking
pnpm tsc --noEmit

# Linting
pnpm biome check
```

### WASM Build

The WASM module is built from the Zig source:

```bash
# From project root
zig build wasm

# Output: sdks/typescript/src/wasm/guillotine.wasm
```

### Development Workflow

1. **Zig Changes**: Rebuild WASM after any evm_c.zig changes
2. **Type Sync**: Ensure TypeScript types match FFI structures
3. **Test Coverage**: Add tests for new functionality
4. **Memory Checks**: Verify no leaks in new code

## Common Pitfalls

### ❌ DON'T

- Forget to free allocated memory
- Use synchronous operations for WASM calls
- Access WASM memory after freeing
- Create multiple loaders (singleton pattern)
- Assume byte order - always use big-endian

### ✅ DO

- Use type-safe wrappers (Address, U256, Bytes)
- Follow the try/finally pattern for cleanup
- Test with various input sizes
- Validate inputs before WASM calls
- Use standard big-endian byte order throughout

## Debugging Tips

### WASM Debugging

1. **Check Alignment**: WASM requires proper alignment for structs
2. **Verify Sizes**: Ensure struct sizes match between TS and Zig
3. **Log Pointers**: Debug pointer values when issues arise
4. **Memory Dumps**: Use memory.getBuffer() to inspect

### Common Issues

- **Invalid Memory Access**: Usually freed memory or wrong offset
- **Alignment Errors**: Struct fields not properly aligned
- **Memory Leaks**: Missing free() calls
- **Size Mismatches**: Ensure struct sizes match between TS and Zig

## Future Considerations

### Planned Improvements

- Streaming API for large data
- Worker thread support
- SharedArrayBuffer optimization
- SIMD acceleration where applicable

### Compatibility

- Node.js 18+ required (WASM support)
- Browser support via bundlers
- Deno compatibility planned

## References

- Main Zig source: `src/evm_c.zig`
- WASM FFI types: `src/wasm/loader.ts`
- Test examples: `src/evm/*.test.ts`
- API design: `API_DESIGN.md`

---

_Remember: The SDK's purpose is to make the powerful Guillotine Evm accessible to JavaScript developers while maintaining performance and safety._