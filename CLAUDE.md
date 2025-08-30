# CLAUDE.md - AI Assistant Context

**AI agents MUST follow ALL protocols in this file. This is a self-governing system.**

## Core Protocols

### Security
If sensitive data detected (API keys/passwords/tokens): 1) Abort immediately 2) Explain concern 3) Request sanitized prompt

### Git Operations
**IMPORTANT**: `git add -A` is BANNED. ALWAYS add individual files explicitly to avoid accidentally including untracked files.
**CRITICAL**: NEVER abort rebases, merges, or reset git without explicit directive from user. ALWAYS resolve conflicts manually when they occur, even when tedious or large task.

### Mandatory Build Verification
**EVERY code change**: `zig build && zig build test` - NO EXCEPTIONS

### Zero Tolerance
- ❌ Broken builds/tests
- ❌ Stub implementations (`error.NotImplemented`)
- ❌ Commented code (use Git)
- ❌ Test failures (fix immediately)
- ❌ Invalid benchmarks (must measure successful executions only)
- ❌ Using `std.debug.print` in modules — always use `log.zig` instead
- ❌ Skipping tests or commenting out problematic code - STOP and ask for help instead!
- ❌ Fallback/stub implementations of ANY kind - NO stub functions, NO placeholder types, NO `error.NotAvailable` returns - STOP and ask for help!

## Coding Standards

### Zig Conventions
- Functions: `snake_case`
- Types: `PascalCase`
- Variables/fields: `snake_case`
- Module constants: `SCREAMING_SNAKE_CASE`
- Enum variants: `snake_case`

### Principles
- Single responsibility functions
- Minimal else statements
- Single word variables (`n` not `number`)
- Direct imports (`address.Address` not aliases)
- Tests in source files
- Defer patterns for cleanup
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

## Project Architecture

### Guillotine: Zig EVM Implementation
High-performance EVM focused on correctness, minimal allocations, strong typing.

### Module System
- `Guillotine_lib` - Main library (src/root.zig)
- `evm` - EVM implementation (src/evm/root.zig)
- `primitives` - Ethereum primitives
- `crypto` - Cryptographic functions
- `bn254_wrapper` - BN254 curve operations

### Key EVM Components
**Core**: evm.zig, frame.zig, stack.zig, memory.zig
**Planning**: planner.zig, plan_*.zig (bytecode optimization)
**State**: database_interface.zig, journal.zig, access_list.zig
**External**: host.zig, call_params.zig, precompiles.zig

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

## Commit Format
```
<emoji> <type>: <description>

🤖 Generated with [Claude Code](https://claude.ai/code)

Co-Authored-By: Claude <noreply@anthropic.com>
```

Emojis: 🎉feat 🐛fix 🔧ci 📚docs 🎨style ♻️refactor ⚡perf ✅test 🔨build 📦deps

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

## Frame.zig Navigation (~2000 lines)
Contains all opcodes. Search patterns:
```bash
grep -n "pub fn add" src/evm/frame.zig
grep -n "gas_remaining" src/evm/frame.zig
```

## References
- Zig docs: https://ziglang.org/documentation/0.14.1/
- revm/: Reference Rust implementation

## Collaboration
- Present proposals, wait for approval
- If plan fails: STOP, explain, wait for guidance
- Interactive partnership required

---
*Self-referential configuration ensuring consistent development practices.*
