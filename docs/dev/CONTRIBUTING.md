# Contributing

This document covers development workflow, coding conventions, and patterns for contributing to Guillotine.

## Development Setup

### Prerequisites

```bash
# Zig 0.15.1+
zig version

# Cargo (for BN254/ARK dependencies)
cargo --version

# Python 3.8+ with uv (for spec test generation)
python3 --version
uv --version

# Bun (for helper scripts)
bun --version
```

### Building

```bash
# Build project
zig build

# Build with specific hardfork
zig build -Devm-hardfork=CANCUN

# Build optimized
zig build --release=fast

# Build WASM
zig build wasm
```

### Running Tests

```bash
# All tests
zig build test

# Specific categories
zig build test-unit
zig build test-integration
zig build specs
```

## Coding Conventions

### Naming

```zig
// Functions and variables: snake_case
pub fn get_storage(address: Address, slot: u256) u256 { }
const gas_remaining: u64 = 0;

// Types: PascalCase
pub const StorageKey = struct { };
pub const Hardfork = enum { };

// Constants: SCREAMING_SNAKE_CASE
pub const MAX_STACK_SIZE: usize = 1024;
```

### Single-Word Variables

```zig
// Prefer short, descriptive names
const n = items.len;          // NOT: const number = items.len;
const a = frame.popStack();   // OK for binary ops
const top = frame.peekStack(0); // Descriptive when needed
```

### Imports

```zig
// Direct imports, no aliases
const Address = primitives.Address.Address;  // NOT: const Addr = ...

// Group related imports
const std = @import("std");
const primitives = @import("voltaire");
const GasConstants = primitives.GasConstants;
```

### Error Handling

```zig
// NEVER swallow errors
slots.append(allocator, key) catch {};  // BAD!

// Always propagate or handle
try slots.append(allocator, key);        // GOOD

// Or handle explicitly
slots.append(allocator, key) catch |err| {
    log.err("Failed to append: {}", .{err});
    return err;
};
```

### Memory Management

```zig
// Pattern 1: Same scope cleanup
const thing = try allocator.create(Thing);
defer allocator.destroy(thing);
// use thing...

// Pattern 2: Ownership transfer
const thing = try allocator.create(Thing);
errdefer allocator.destroy(thing);  // Only if error
thing.* = try Thing.init(allocator);
return thing;  // Caller owns it now
```

### Logging

```zig
// Use log module, NOT std.debug.print
const log = @import("log.zig");

log.debug("Processing opcode: {}", .{opcode});
log.warn("Gas limit exceeded: {}", .{gas});
log.err("Invalid jump: {}", .{target});

// NEVER in production modules:
std.debug.print("...", .{});  // BAD!
```

### Assertions

```zig
// Use tracer assertions, NOT std.debug.assert
self.getTracer().assert(condition, "message");

// NEVER:
std.debug.assert(condition);  // BAD - crashes are security bugs!
```

## Handler Patterns

### Mini EVM Handler

```zig
pub fn Handlers(FrameType: type) type {
    return struct {
        pub fn add(frame: *FrameType) FrameType.EvmError!void {
            // 1. Gas
            try frame.consumeGas(GasConstants.GasFastestStep);

            // 2. Stack operations (bounds checked)
            const a = try frame.popStack();
            const b = try frame.popStack();

            // 3. Compute
            const result = a +% b;

            // 4. Push result
            try frame.pushStack(result);

            // 5. Advance PC
            frame.pc += 1;
        }
    };
}
```

### Performance EVM Handler

```zig
pub fn Handlers(FrameType: type) type {
    return struct {
        pub fn add(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            // 1. Tracer sync
            self.beforeInstruction(.ADD, cursor);

            // 2. Execute (pre-validated, use unsafe)
            self.stack.binary_op_unsafe(struct {
                fn op(top: WordType, second: WordType) WordType {
                    return top +% second;
                }
            }.op);

            // 3. Tail-call next (NEVER returns)
            const next = dispatch.getOpData(.ADD);
            return @call(.always_tail, next.handler, .{self, next.cursor});
        }
    };
}
```

## Adding a New Opcode

### Step 1: Add to opcode enum

```zig
// src/opcodes/opcode.zig
pub const Opcode = enum(u8) {
    // ... existing opcodes
    NEW_OP = 0xXX,
};
```

### Step 2: Add gas constant

```zig
// primitives gas_constants.zig or local constants
pub const NEW_OP_GAS: u64 = X;
```

### Step 3: Implement handler

```zig
// src/instructions/handlers_*.zig
pub fn new_op(frame: *FrameType) Error!void {
    try frame.consumeGas(NEW_OP_GAS);
    // Implementation
    frame.pc += 1;  // Or appropriate advancement
}
```

### Step 4: Add to dispatch

```zig
// In opcode dispatch/switch
0xXX => return Handlers.new_op(frame),
```

### Step 5: Add hardfork guard (if needed)

```zig
if (!frame.hardfork.isAtLeast(.HARDFORK_NAME)) {
    return error.InvalidOpcode;
}
```

### Step 6: Add tests

```zig
test "NEW_OP correctly handles edge case" {
    var frame = try TestFrame.init(testing.allocator);
    defer frame.deinit();

    // Setup
    try frame.pushStack(input);

    // Execute
    try Handlers.new_op(&frame);

    // Verify
    try testing.expectEqual(expected, frame.stack.items[0]);
}
```

## Testing Guidelines

### Test Organization

- Unit tests: In source files
- Integration tests: In `test/` directory
- Spec tests: Auto-generated from fixtures

### Test Philosophy

```zig
// NO abstractions - copy/paste setup
test "ADD with two positive values" {
    var frame = try Frame.init(allocator, &[_]u8{0x01}, 100, ...);
    defer frame.deinit();
    // Direct setup, no helpers
}

// NO helpers - self-contained tests
// BAD:
test "ADD" {
    try setupAndTest(.ADD, &[_]u256{5, 3}, 8);
}

// GOOD:
test "ADD with 5 and 3 returns 8" {
    var frame = ...;
    try frame.pushStack(5);
    try frame.pushStack(3);
    try Handlers.add(&frame);
    try testing.expectEqual(@as(u256, 8), frame.stack.items[0]);
}
```

### Running Specific Tests

```bash
# Filter by name
zig build test-unit -Dtest-filter='ADD'

# Specific hardfork
zig build specs -Devm-hardfork=CANCUN

# Isolate failing test (Mini)
bun scripts/isolate-test.ts "test_name"
```

## Pull Request Process

### Before Submitting

1. **Build passes**
   ```bash
   zig build
   ```

2. **All tests pass**
   ```bash
   zig build test
   ```

3. **Format code**
   ```bash
   zig fmt src/ test/
   ```

4. **No forbidden patterns**
   - No `std.debug.print`
   - No `std.debug.assert`
   - No `catch {}` error swallowing
   - No stub implementations

### Commit Messages

```
# Format
<type>: <description>

# Types
feat: New feature
fix: Bug fix
refactor: Code restructure
test: Test additions
docs: Documentation

# Examples
feat: Add EIP-1153 transient storage
fix: Correct SSTORE gas calculation for Berlin+
refactor: Extract gas constants to primitives
```

### PR Description

```markdown
## Summary
Brief description of changes

## Changes
- List of specific changes
- ...

## Testing
- How this was tested
- Test commands run

## Related Issues
Fixes #123
```

## Zero Tolerance Policies

From CLAUDE.md - these will block PRs:

- Broken builds/tests
- Stub implementations (`error.NotImplemented`)
- Commented code (use Git)
- `std.debug.print` in modules
- `std.debug.assert` (use tracer assertions)
- Skipping/commenting tests
- `catch {}` error swallowing
- `.backup` files (use git)

## Getting Help

### Resources

- [CLAUDE.md](../../CLAUDE.md) - Project instructions
- [docs/dev/](./README.md) - Developer documentation
- [execution-specs](https://github.com/ethereum/execution-specs) - Python reference

### Debugging

```bash
# Enable debug logging
std.testing.log_level = .debug;

# Isolate test (Mini)
bun scripts/isolate-test.ts "test_name"

# Trace comparison
TEST_FILTER="test_name" zig build specs
```

### Questions

Open an issue on GitHub with:
- What you're trying to do
- What you've tried
- Error messages/output
