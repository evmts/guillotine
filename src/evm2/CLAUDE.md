# CLAUDE.md - EVM2 Module Development Guide

This document provides development guidelines for the EVM2 module, a new implementation of the Ethereum Virtual Machine in Zig.

## Test-Driven Development (TDD) Workflow

**MANDATORY**: Always follow Test-Driven Development when working on the EVM2 module:

1. **Write tests first** - Create tests that define the expected behavior before implementing
2. **Run tests to see them fail** - Ensure tests fail for the right reasons
3. **Implement minimal code** - Write just enough code to make tests pass
4. **Refactor** - Clean up code while keeping tests green

### Build and Test Commands

```bash
# Build the EVM2 module
zig build evm2

# Run EVM2 tests
zig build test-evm2
```

**IMPORTANT**: After every code change, run both commands to ensure:
- Code compiles without errors
- All tests continue to pass
- No regressions are introduced

## Module Structure

### ColdFrame
The `ColdFrame` is a stack-based execution frame for EVM operations. It's designed for:
- Simple, unoptimized execution
- Debugging and tracing
- Small contracts

Key features:
- Generic over stack size, word type, and bytecode size
- Stack-allocated frame with heap-allocated stack
- Index-based stack management for safety
- Gas tracking with smart type selection

### Module Dependencies

When adding new features that require external modules, you must update `build.zig`:

```zig
// In build.zig, add imports to both evm2_mod and test_evm2:
evm2_mod.addImport("crypto", crypto_mod);
test_evm2.root_module.addImport("crypto", crypto_mod);
```

Currently imported modules:
- `primitives` - Basic types and utilities
- `evm` - EVM implementation reference
- `build_options` - Build configuration
- `crypto` - Cryptographic functions (for KECCAK256, etc.)

### Importing Common Types

When importing types from the primitives module, use the full path:

```zig
// Importing Address type
const Address = @import("primitives").Address.Address;

// Importing multiple types
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const Bytes32 = primitives.Bytes32;
```

### Creating a ColdFrame

```zig
const Frame = createColdFrame(.{
    .stack_size = 1024,          // default
    .WordType = u256,            // default
    .max_bytecode_size = 24576,  // default
    .block_gas_limit = 30_000_000, // default
});

var frame = try Frame.init(allocator, bytecode, gas_remaining);
defer frame.deinit(allocator);
```

## Opcode Implementation Pattern

When implementing new opcodes:

1. **Study the reference** - Check `src/evm/execution/` for the reference implementation
2. **Write comprehensive tests** - Cover edge cases, gas costs, and error conditions
3. **Follow the pattern**:
   ```zig
   pub fn op_example(self: *Self) Error!void {
       // Pop operands
       const b = try self.pop();
       const a = try self.peek();
       
       // Perform operation
       const result = /* operation logic */;
       
       // Update stack
       try self.set_top(result);
   }
   ```

## Gas Management

- Gas is tracked as `i32` or `i64` based on `block_gas_limit`
- Negative gas indicates out-of-gas condition
- Always check gas before operations that can fail

## Stack Operations

The frame provides both safe and unsafe variants:
- `push`/`push_unsafe` - Add to stack
- `pop`/`pop_unsafe` - Remove from stack
- `peek`/`peek_unsafe` - View top without removing
- `set_top`/`set_top_unsafe` - Modify top value

Use unsafe variants only when bounds are guaranteed by prior checks.

## Comparison Operations

All comparison operations return:
- `1` for true
- `0` for false

This follows EVM specification exactly.

## Error Handling

The frame defines these errors:
- `StackOverflow` - Stack is full
- `StackUnderflow` - Stack is empty
- `STOP` - Normal execution termination
- `BytecodeTooLarge` - Bytecode exceeds configured limit
- `AllocationError` - Memory allocation failed

## Development Best Practices

1. **Always run tests** - Use `zig build test-evm2` frequently
2. **Check compilation** - Use `zig build evm2` after changes
3. **Use clear names** - Prefer `numerator`/`denominator` over `a`/`b`
4. **Document edge cases** - Explain handling of division by zero, overflows, etc.
5. **Follow existing patterns** - Study implemented opcodes before adding new ones

## Future Improvements

- Add memory operations
- Implement JUMP/JUMPI with valid jump destination analysis
- Add CALL/CREATE operations with nested frame support
- Optimize hot paths with specialized implementations

---

*This guide ensures consistent, test-driven development of the EVM2 module.*