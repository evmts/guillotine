# Contributing

This document covers development workflow, coding conventions, and patterns for contributing to Guillotine.

## Development Setup

### Prerequisites

```bash
# Zig 0.15.x (CI uses 0.15.2; build.zig.zon requires 0.15.1). Zig 0.16+ is not supported.
zig version

# Cargo: zig build runs it for the Rust workspace (lib/ark, lib/foundry-compilers)
cargo --version

# Python 3.8+ with uv (for Mini spec test generation, zig build test-mini-full)
python3 --version
uv --version

# Bun (for helper scripts)
bun --version
```

### Building

```bash
# Build project
zig build

# Build optimized
zig build --release=fast

# Build the FFI libraries
zig build shared
zig build static
```

The hardfork is a comptime field, `EvmConfig.eips.hardfork` (src/evm_config.zig,
default `OSAKA`). `-Devm-hardfork` and the other `-Devm-*` options are declared
in build.zig, but no code reads them. The root build has no WASM step; the WASM
helper in sdks/wasm/build.zig is not wired into build.zig.

### Running Tests

```bash
# The gate CLAUDE.md requires for every code change
zig build && zig build test-opcodes

# Specific categories
zig build test-unit
zig build test-integration
zig build specs          # legacy filler specs; not passing yet
zig build state-tests    # official EEST state tests (see specs/README.md)

# All tests (runs specs, so it fails until the spec suite passes)
zig build test
```

## Coding Conventions

### Naming

Function names mix two styles: src/ mostly uses snake_case (`create_snapshot`,
`push_unsafe`) and mini/src/ uses camelCase (`pushStack`, `consumeGas`). Match
the file you edit.

```zig
// Variables: snake_case
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
const n = items.len;                 // NOT: const number = items.len;
const top = try frame.popStack();    // NOT: const a = ... (CLAUDE.md)
const value = try frame.peekStack(0);
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
(&self.getEvm().tracer).assert(condition, "message");

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
            // 1. Tracer sync (Debug and ReleaseSafe builds only)
            self.beforeInstruction(.ADD, cursor);

            // 2. Execute (pre-validated, use unsafe)
            self.stack.binary_op_unsafe(struct {
                fn op(top: WordType, second: WordType) WordType {
                    return top +% second;
                }
            }.op);

            // 3. Look up the next handler and tail-call it (NEVER returns)
            return dispatch_next.nextInstruction(FrameType, self, cursor, .ADD);
        }
    };
}
```

## Adding a New Opcode

CLZ (0x1e, EIP-7939, Osaka) is a complete recent example in the Performance EVM. Follow its trail through the files below.

### Step 1: Add to the opcode enums

```zig
// src/opcodes/opcode.zig
pub const Opcode = enum(u8) {
    // ... existing opcodes
    NEW_OP = 0xXX,
};
// Also add NEW_OP to UnifiedOpcode and the name tables in the same file.
```

### Step 2: Add static gas and stack metadata

```zig
// src/opcodes/opcode_data.zig - the preprocessor sums gas_cost per basic block
info[0xXX] = .{ .gas_cost = GasConstants.GasFastStep, .stack_inputs = 1, .stack_outputs = 1 };
```

Shared gas constants live in lib/voltaire/src/primitives/gas_constants.zig (`GasConstants`).

### Step 3: Implement the handler

```zig
// src/instructions/handlers_*.zig (inside Handlers(FrameType))
pub fn new_op(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
    // Hardfork guard (if needed): the fork is comptime in the Performance EVM
    if (comptime FrameType.config.hardfork.isBefore(.HARDFORK_NAME)) {
        self.gas_remaining = 0;
        return error.InvalidOpcode;
    }
    self.beforeInstruction(.NEW_OP, cursor);
    // Implementation (static gas and stack bounds were checked at block entry)
    return dispatch_next.nextInstruction(FrameType, self, cursor, .NEW_OP);
}
```

### Step 4: Register the handler

```zig
// src/frame/frame_handlers.zig, in getOpcodeHandlers
h[@intFromEnum(Opcode.NEW_OP)] = &BitwiseHandlers.new_op;
```

### Step 5: Add it to the reference EVMs

- `src/tracer/minimal_frame.zig`: add a case to the MinimalEvm switch. The tests in `test/differential/` and `1e_test.zig` compare the Performance EVM against MinimalEvm.
- `mini/src/frame.zig`: add a case to the `executeOpcode` switch and implement the handler in `mini/src/instructions/`. Mini checks the fork at runtime:

```zig
// mini/src/instructions/handlers_*.zig
const evm = frame.getEvm();
if (evm.hardfork.isBefore(.HARDFORK_NAME)) return error.InvalidOpcode;
```

### Step 6: Add tests

Add `test/evm/opcodes/XX_test.zig` and import it from `test/evm/opcodes/all_opcodes.zig`. Assert on output and gas, as `1e_test.zig` does; most older `NN_test.zig` files only run the bytecode. build.zig creates a `zig build test-opcodes-0xXX` step for each `XX_test.zig` file.

```bash
zig build test-opcodes-0xXX
zig build test-opcodes
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
# Filter by name (pass -Dtest-filter once; a repeated -D option fails)
zig build test-unit -Dtest-filter='ADD'

# Specific hardforks (EEST state tests)
zig build state-tests -Dspec-fork=Cancun,Prague

# Isolate failing test (Mini; the script lives in mini/scripts/)
cd mini && bun scripts/isolate-test.ts "test_name"
```

## Pull Request Process

### Before Submitting

1. **Build passes**
   ```bash
   zig build
   ```

2. **Tests pass**
   ```bash
   zig build test-opcodes   # required by CLAUDE.md for every code change
   zig build test-unit      # also run by CI
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

- Broken builds/tests and test failures
- Stub or fallback implementations (`error.NotImplemented`)
- Commented code (use Git)
- Invalid benchmarks
- `std.debug.print` in modules
- `std.debug.assert` (use tracer assertions)
- Skipping/commenting tests
- Swallowing errors with `catch` (`catch {}`, `catch &.{}`, `catch null`)

## Getting Help

### Resources

- [CLAUDE.md](../../CLAUDE.md) - Project instructions
- [docs/dev/](./README.md) - Developer documentation
- [specs/README.md](../../specs/README.md) - Spec test runners and current pass rates
- [execution-specs](https://github.com/ethereum/execution-specs) - Python reference

### Debugging

```zig
// Enable debug logging inside a test
std.testing.log_level = .debug;
```

```bash
# Isolate test (Mini)
cd mini && bun scripts/isolate-test.ts "test_name"

# Run one legacy spec test by name
zig build specs -Dtest-filter="test_name"
```

### Questions

Open an issue on GitHub with:
- What you're trying to do
- What you've tried
- Error messages/output
