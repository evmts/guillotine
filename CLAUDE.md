# CLAUDE.md - AI Assistant Context

## Core Protocols

## Temporary warning

The build is currently set up in a way that causes zig build test to often hang forever. To workaround this for now apply following diff

```
diff --git a/lib/revm/Cargo.toml b/lib/revm/Cargo.toml
index a3661c9b..484ba27a 100644
--- a/lib/revm/Cargo.toml
+++ b/lib/revm/Cargo.toml
@@ -23,13 +23,13 @@ cbindgen = "0.24"

 [profile.release]
 panic = "abort"
-lto = true
-codegen-units = 1
+lto = false
+codegen-units = 16

 [profile.bench]
 panic = "abort"
-lto = true
-codegen-units = 1
+lto = false
+codegen-units = 16

 # [[bin]]
 # name = "verify_lt_order"
```

### Security

- If sensitive data detected (API keys/passwords/tokens): 1) Abort immediately 2) Explain concern 3) Request sanitized prompt
- Memory safety is paramount and any allocation should be taken seriously with a plan of who owns the data and who should free it.

### Mandatory Build Verification

**EVERY code change**: `zig build && zig build test` - NO EXCEPTIONS
**Exception**: Changes to .md (markdown) files do not require running build or test commands

Follow TDD to add any features or fix any bugs

### Debugging

- If the bug is not obvious that means we don't have enough visibility. Improve visibility before attempting to fix the bug
- Utilize differential tests with revm in test/differential to help debug

### Zero Tolerance

- ❌ Broken builds/tests
- ❌ Stub implementations (`error.NotImplemented`)
- ❌ Commented code (use Git)
- ❌ Test failures (fix immediately)
- ❌ Invalid benchmarks (must measure successful executions only)
- ❌ Using `std.debug.print` in modules — always use `log.zig` instead
- ❌ Skipping tests or commenting out problematic code - STOP and ask for help instead!
- ❌ Fallback/stub implementations of ANY kind - NO stub functions, NO placeholder types, NO `error.NotAvailable` returns - STOP and ask for help!

ANY STUB IMPLEMENTATION WILL RESULT IN IMMEDIATE TERMINATION! Stop and ask for help rather than stubbing.

## Coding Standards

### Principles

- Minimal else statements
- Single word variables (`n` not `number`)
- Direct imports (`address.Address` not aliases)
- Tests in source files
- Defer patterns for cleanup
- Always follow any allocation with a defer or errDefer
- Descriptive variable names (NOT `a`, `b` - use `top`, `value1`, `operand`, etc.)
- Logging: never call `std.debug.print`; import `log.zig` and use `log.debug`, `log.warn`, etc.

### Memory Management

```zig
// Pattern 1: Same scope
const thing = try allocator.create(Thing);
defer allocator.destroy(thing);

// Pattern 2: Ownership transfer
const thing = try allocator.create(Thing);
errdefer allocator.destroy(thing);
thing.* = try Thing.init(allocator);
return thing;
```

## Testing Philosophy

- **NO abstractions** - Copy/paste setup code
- **NO helpers** - Self-contained tests
- **Test failures = YOUR regression** - Fix immediately
- Evidence-based debugging only (no speculation)
- **IMPORTANT**: Zig tests output NOTHING when passing - DO NOT grep for test names/results in successful runs

## Project Architecture

### Guillotine: Zig EVM Implementation

High-performance EVM focused on correctness, minimal allocations, strong typing.

### Module System

Guillotine utilizes modules which means that you must go through the build system zig build test rather than zig test.
The most common error you might see is related to "primitives" package. You must use module system build to import it.

### Key EVM Components

**Core**: evm.zig, frame.zig, stack.zig, memory.zig, dispatch.zig
**Handlers**: handlers\_\*.zig (arithmetic, bitwise, comparison, context, jump, keccak, log, memory, stack, storage, system)
**State**: database.zig, journal.zig, access_list.zig, memory_database.zig
**External**: precompiles.zig, call_params.zig, call_result.zig
**Bytecode**: bytecode.zig, bytecode_analyze.zig, bytecode_stats.zig
**Infrastructure**: tracer.zig, hardfork.zig, eips.zig

### Import Rules

```zig
// Good
const Evm = @import("evm");
const memory = @import("memory.zig");

// Bad - no parent imports
const Contract = @import("../frame/contract.zig");
```

## Commands

```bash
zig build test              # ALWAYS use this, never 'zig test'
zig build                   # Build project
zig build build-evm-runner  # Build benchmarks
```

## EVM Architecture

### Design Patterns

1. **Strong error types** per component
2. **Unsafe ops** for performance (pre-validated)
3. **Cache-conscious** struct layout
4. **Handler tables** for O(1) dispatch
5. **Bytecode optimization** via Planner

### Key Separations

- **Frame**: Executes opcodes
- **Plan**: Manages PC/jumps
- **Host**: External operations

### Opcode Pattern

```zig
pub fn add(self: *Self) Error!void {
    const b = self.stack.pop_unsafe();
    const a = self.stack.peek_unsafe();
    self.stack.set_top_unsafe(a +% b);
}
```

## EVM Opcode Navigation

Opcodes are now organized in separate handler files:

```bash
# Arithmetic operations
grep -n "pub fn add" src/evm/handlers_arithmetic.zig
# Stack operations
grep -n "pub fn push" src/evm/handlers_stack.zig
# Memory operations
grep -n "pub fn mstore" src/evm/handlers_memory.zig
# System operations
grep -n "pub fn call" src/evm/handlers_system.zig
```

## References

- Zig docs: https://ziglang.org/documentation/0.14.1/
- revm/: Reference Rust implementation

## Collaboration

- Present proposals, wait for approval
- If plan fails: STOP, explain, wait for guidance
- Interactive partnership required

---

_Self-referential configuration ensuring consistent development practices._
