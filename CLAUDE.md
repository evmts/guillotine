# CLAUDE.md - AI Assistant Context

This file serves as the comprehensive configuration and behavioral protocol for AI agents working on this multi-agent coding assistant project. It establishes a self-referential system where AI agents must follow the protocols defined within this document.

**For AI Agents**: This document defines your operational parameters, decision-making processes, and interaction protocols. You MUST adhere to all specifications herein.

**For Human Developers**: This document provides transparency into how AI agents operate, ensuring predictable and collaborative behavior throughout the development process.

## File Structure
- **Self-Referential Compliance**: Core governance principles
- **Project Architecture**: Zig EVM implementation design and structure
- **Coding Standards**: Style preferences and patterns
- **Memory Management**: Critical allocation and deallocation protocols
- **Testing Philosophy**: No abstractions approach
- **Codebase Structure**: Project organization and key components

## Self-Referential Compliance Declaration

CRITICAL: The agent MUST follow all protocols defined in this CLAUDE.md file. This creates a self-governing system where:
- All code follows the standards defined herein
- All memory management follows the allocation patterns specified
- All tests follow the no-abstraction philosophy
- All changes require user approval as specified
- Security protocol is enforced before any code processing

## Security Protocol

CRITICAL SECURITY REQUIREMENT: If the agent detects that a prompt contains sensitive secrets (API keys, passwords, tokens, private keys, personal information, or other confidential data), the agent MUST:
1. Immediately abort execution without processing the prompt
2. Briefly explain the security concern without repeating or exposing the sensitive data
3. Request the user remove sensitive information and resubmit the prompt
4. Take no further action until a sanitized prompt is provided

Example Response: "I detected potential sensitive information in your prompt (API key/password/token). Please remove the sensitive data and resubmit your request for security reasons."

## Coding Standards

### Core Principles
- **Single responsibility**: Keep functions focused on one task
- **Minimal else statements**: Avoid else statements unless necessary
- **Single word variables**: Prefer single word variable names where possible (e.g., `n` over `number`, `i` over `index`)
- **Defer patterns**: Always use defer for cleanup immediately after allocation
- **Memory consciousness**: Always think about memory ownership and lifecycle
- **Zig standard naming conventions**: Follow the conventions used by Zig's standard library
- **Tests in source files**: Always include tests in the same file as the source code, not in separate test files
- **Direct imports**: Import modules directly without creating unnecessary aliases (e.g., use `address.Address` not `Address = address.Address`)

### Zig Naming Conventions

Following Zig standard library conventions:

1. **Functions**: `snake_case`
   - `pub fn init_with_allocator(allocator: Allocator) !Self`
   - `pub fn parse_integer(str: []const u8) !u32`
   - `pub fn is_valid() bool`

2. **Types**: `PascalCase`
   - `const ArrayList = struct { ... }`
   - `const ExecutionError = error{ ... }`
   - `pub const HashMap = struct { ... }`

3. **Variables**: `snake_case`
   - `const max_value = 100;`
   - `var current_index: usize = 0;`
   - `const allocator = std.testing.allocator;`

4. **Constants**: `SCREAMING_SNAKE_CASE` for module-level constants
   - `pub const MAX_STACK_SIZE = 1024;`
   - `const DEFAULT_GAS_LIMIT = 30_000_000;`

5. **Struct fields**: `snake_case`
   - `gas_remaining: u64,`
   - `is_static: bool,`
   - `memory_size: usize,`

6. **Enum variants**: `snake_case`
   - `.out_of_gas`
   - `.invalid_jump`
   - `.stack_underflow`

### Function Design
```zig
// Good - single responsibility, no else
pub fn validate(n: u256) !void {
    if (n > MAX_VALUE) return error.Overflow;
    if (n == 0) return error.Zero;
}

// Bad - unnecessary else
pub fn validate(number: u256) !void {
    if (number > MAX_VALUE) {
        return error.Overflow;
    } else {
        // unnecessary else
    }
}
```

## Memory Management and Allocation Awareness

### CRITICAL: Always Think About Memory Ownership

When working with Zig code, **ALWAYS** be conscious of memory allocations:

1. **Every allocation needs a corresponding deallocation**
   - If you see `allocator.create()` or `allocator.alloc()`, immediately think: "Where is this freed?"
   - If you see `init()` that takes an allocator, check if there's a corresponding `deinit()`

2. **Defer patterns are mandatory**:
   ```zig
   // Pattern 1: Function owns memory for its scope
   const thing = try allocator.create(Thing);
   defer allocator.destroy(thing);
   
   // Pattern 2: Error handling before ownership transfer
   const thing = try allocator.create(Thing);
   errdefer allocator.destroy(thing);
   thing.* = try Thing.init(allocator);
   return thing; // Caller now owns
   ```

3. **Allocation philosophy**:
   - Allocate minimally
   - Prefer upfront allocation
   - Think hard about ownership transfer
   - Use `defer` if deallocating in same scope
   - Use `errdefer` if passing ownership to caller on success

4. **EVM-specific patterns**:
   - `Contract.init()` requires `contract.deinit(allocator, null)`
   - `Frame.init()` requires `frame.deinit()`
   - `Vm.init()` requires `vm.deinit()`
   - Always use defer immediately after initialization

## Testing Philosophy

### No Abstractions in Tests
All tests in this codebase should be written with **zero abstractions or indirections**. This means:

1. **No test helper functions** - Copy and paste setup code directly in each test
2. **No shared test utilities** - Each test should be completely self-contained
3. **Explicit is better than DRY** - Readability and clarity over code reuse in tests

### CRITICAL: Test Failures Are Always Regressions You Caused

**FUNDAMENTAL PRINCIPLE**: If tests were passing before your changes and failing after, YOU caused a regression. There are NO pre-existing test failures in this codebase.

**Never assume**:
- "These tests were probably already broken"
- "This looks like a pre-existing issue"
- "The test failure might be unrelated to my changes"

**Always assume**:
- Your changes broke something that was working
- You need to fix the regression you introduced
- The codebase was in a working state before your modifications

**When tests fail after your changes**:
1. **STOP** - Don't continue with additional changes
2. **Fix the regression** - Debug and resolve the failing tests
3. **Verify the fix** - Ensure all tests pass again
4. **Only then proceed** - Continue with your work after restoring functionality

This principle ensures code quality and prevents the accumulation of broken functionality.

## CRITICAL: Zero Tolerance for Compilation and Test Failures

**ABSOLUTE MANDATE**: Any code change that breaks compilation or tests is UNACCEPTABLE.

## CRITICAL: Benchmark Validity Requirements

**ABSOLUTE MANDATE**: Benchmarks MUST ONLY measure successful executions.

**NEVER ALLOW**:
- ❌ Benchmarking failing transactions
- ❌ Benchmarking reverting calls
- ❌ Ignoring execution failures in benchmarks
- ❌ Reporting timings for failed operations

**WHY THIS IS CRITICAL**:
- Failed transactions have different execution paths
- Reverts short-circuit execution
- Measuring failures gives FALSE performance data
- Invalid benchmarks are WORSE than no benchmarks

**REQUIRED BEHAVIOR**:
- All benchmark transactions MUST succeed
- Setup proper initial state for all operations
- For ERC20: Ensure sender has sufficient token balance
- For contracts: Deploy and initialize correctly
- Exit with error if ANY benchmark operation fails

### MANDATORY BUILD VERIFICATION PROTOCOL

**EVERY SINGLE CODE CHANGE** must be immediately followed by:

```bash
zig build && zig build test
```

**NO EXCEPTIONS. NO SHORTCUTS. NO DELAYS.**

### Why This is NON-NEGOTIABLE

1. **Build and tests are FAST** - Under 10 seconds total
2. **Broken code blocks ALL development** - No excuses
3. **Professional standards** - Working code is the baseline, not an aspiration
4. **Debugging hell** - Broken state makes it impossible to isolate issues
5. **Wasted time** - Fixing broken code later takes exponentially more time

### IMMEDIATE CONSEQUENCES OF VIOLATIONS

If you make ANY code change without verifying the build:
- You are operating unprofessionally
- You are creating technical debt
- You are wasting everyone's time
- You are violating the fundamental requirement of working code

### MANDATORY VERIFICATION STEPS

**AFTER EVERY SINGLE EDIT** (not just commits):

1. **IMMEDIATELY** run `zig build`
2. **IMMEDIATELY** run `zig build test`
3. **ONLY PROCEED** if both commands succeed with zero errors
4. **IF EITHER FAILS** - STOP everything and fix it before making any other changes

### ABSOLUTELY FORBIDDEN PRACTICES

- ❌ Making multiple changes without testing
- ❌ "I'll test it later"
- ❌ "It's just a small change"
- ❌ "I'll fix the build issues at the end"
- ❌ Assuming changes work without verification
- ❌ Continuing development with broken builds

### REQUIRED MINDSET

- ✅ **Working code is the ONLY acceptable state**
- ✅ **Test after EVERY change**
- ✅ **Fix broken builds IMMEDIATELY**
- ✅ **Never commit broken code**
- ✅ **Professional development practices**

### ENFORCEMENT

This is not a suggestion. This is a **HARD REQUIREMENT**. Violation of this protocol demonstrates unprofessional development practices and is unacceptable.

**THE CODEBASE MUST ALWAYS COMPILE AND PASS TESTS.**

**NO EXCEPTIONS.**

### CRITICAL REMINDER

Every single code change must be verified immediately - no exceptions, no shortcuts, no delays.

## CRITICAL: Debugging Philosophy - No Speculation, Only Evidence

**FUNDAMENTAL PRINCIPLE**: Never guess what causes bugs. Always use logging and direct evidence to understand issues.

### MANDATORY DEBUGGING PROTOCOL

When encountering bugs, crashes, or unexpected behavior:

1. **NEVER SPECULATE** about root causes without direct evidence
2. **ALWAYS ADD LOGGING** to understand what is actually happening
3. **TRACE EXECUTION** step by step until the exact failure point is identified
4. **VERIFY ASSUMPTIONS** with concrete evidence before making changes

### FORBIDDEN DEBUGGING PRACTICES

- ❌ "This might be because..."
- ❌ "It's probably a null pointer..."
- ❌ "The issue could be..."
- ❌ Making changes based on guesses
- ❌ "Let me try this and see if it works"

### REQUIRED DEBUGGING PRACTICES

- ✅ Add debug logging to trace execution
- ✅ "Let me add logging to see what's happening"
- ✅ Verify each assumption with concrete evidence
- ✅ Trace execution until exact failure point is found
- ✅ Only make changes after understanding the root cause

### Logging and Tracing

- `Log.debug` calls are compiled out at comptime in non-safe builds by default, so they impose no runtime overhead in release. Do not rely on side effects within debug log expressions. If a log requires heavy formatting or backtracing, still prefer gating it with a comptime flag (e.g., `builtin.mode == .Debug or .ReleaseSafe`).

### ENFORCEMENT

Speculating about bugs without evidence demonstrates unprofessional debugging practices. All debugging must be evidence-based.

### Why This Approach?
- **Tests are documentation** - A developer should understand what's being tested without jumping between files
- **Tests should be obvious** - No mental overhead from abstractions
- **Copy-paste is encouraged** - Verbose, repetitive test code is acceptable and preferred
- **Each test tells a complete story** - From setup to assertion, everything is visible

### Example Pattern

```zig
// Good - everything inline
test "ADD opcode adds two values" {
    const allocator = std.testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    var contract = try Contract.init(allocator, &[_]u8{0x01}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();

    try frame.stack.push(5);
    try frame.stack.push(10);

    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try vm.table.execute(0, interpreter_ptr, state_ptr, 0x01);

    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 15), result);
}
```

## Project Architecture

### Guillotine: Zig EVM Implementation

This is a high-performance Ethereum Virtual Machine (EVM) implementation written in Zig, designed for:
- Correctness and spec compliance
- Minimal allocations and high performance
- Strong typing and comprehensive error handling
- Modularity and testability

### Key Design Decisions
1. **No abstractions in tests** - Tests serve as documentation
2. **Minimal memory allocations** - Prefer stack allocation and upfront allocation
3. **Strong error types** - Every component has specific error types
4. **Module boundaries** - Clear separation between EVM components
5. **Jump table architecture** - Efficient opcode dispatch

## Codebase Structure

### Root Level
- `build.zig` - Build configuration defining modules and dependencies
- `build.zig.zon` - Package dependencies
- `src/` - Main source code
- `test/` - Integration tests spanning multiple modules
- `CLAUDE.md` - This file (AI agent configuration)

### Module System (defined in build.zig)
- **`Guillotine_lib`** - Main library module (src/root.zig)
- **`evm`** - EVM implementation module (src/evm/root.zig)
- **`Address`** - Ethereum address utilities (src/address/address.zig)
- **`Rlp`** - RLP encoding/decoding (src/rlp/rlp.zig)

### Core EVM Components (`src/evm/`)

#### Virtual Machine Core
- `evm.zig` - Main VM implementation and execution engine
- `root.zig` - Module exports and documentation

#### Execution Framework
- `frame/` - Execution context management
  - `frame.zig` - Call frame implementation
  - `contract.zig` - Contract code and metadata
  - `analysis2.zig` - Simplified bytecode analysis for tailcall dispatch
  - `bitvec.zig` - Bit vector for valid jump destinations

#### Opcodes and Operations
- `opcodes/` - Opcode definitions and metadata
  - `opcode.zig` - Opcode enumeration
  - `operation.zig` - Operation metadata (gas, stack effects)
- `jump_table/` - Opcode dispatch
  - `jump_table.zig` - Maps opcodes to implementations
- `execution/` - Opcode implementations organized by category
  - `arithmetic.zig` - ADD, SUB, MUL, DIV, etc.
  - `stack.zig` - PUSH, POP, DUP, SWAP
  - `memory.zig` - MLOAD, MSTORE, MSIZE
  - `storage.zig` - SLOAD, SSTORE
  - `control.zig` - JUMP, JUMPI, PC, STOP
  - `system.zig` - CALL, CREATE, RETURN, REVERT
  - `environment.zig` - ADDRESS, BALANCE, ORIGIN
  - `block.zig` - BLOCKHASH, COINBASE, TIMESTAMP
  - `crypto.zig` - KECCAK256
  - `log.zig` - LOG0, LOG1, LOG2, LOG3, LOG4

#### State Management
- `state/` - Blockchain state handling
  - `state.zig` - Main state implementation
  - `database_interface.zig` - Abstract database interface
  - `memory_database.zig` - In-memory implementation
  - `journal.zig` - State change tracking for reverts

#### Memory and Stack
- `memory/` - Byte-addressable memory
  - `memory.zig` - Main memory implementation
  - `read.zig`, `write.zig` - Memory operations
- `stack/` - 256-bit word stack
  - `stack.zig` - Stack implementation (max 1024 elements)
  - `stack_validation.zig` - Stack depth validation

#### Gas and Fees
- `constants/` - EVM constants
  - `gas_constants.zig` - Gas costs for operations
  - `memory_limits.zig` - Memory expansion limits

#### Precompiled Contracts
- `precompiles/` - Built-in contracts
  - `ecrecover.zig` - Signature recovery
  - `sha256.zig`, `ripemd160.zig` - Hash functions
  - `identity.zig` - Data copy
  - `modexp.zig` - Modular exponentiation
  - And more...

#### Hard Fork Support
- `hardforks/` - Fork-specific behavior
  - `hardfork.zig` - Fork enumeration
  - `chain_rules.zig` - Fork-specific validation

### Test Organization
- **Unit tests**: Colocated with implementation files
- **Integration tests**: In `test/evm/` directory
  - Each test file is self-contained
  - No test utilities or helpers
  - Direct setup and assertion

### Import Rules

1. **No relative imports with `../`** - Cannot import from parent directories
2. **Same folder imports** - Can import files in the same directory directly
3. **Subfolder imports** - Can import from subdirectories
4. **Cross-module imports** - Must use the module system defined in `build.zig`

```zig
// Good - importing from module system
const Evm = @import("evm");
const Address = @import("Address");

// Good - same directory
const ExecutionError = @import("execution_error.zig");

// Bad - parent directory (will fail)
const Contract = @import("../frame/contract.zig");
```

## Build and Test Commands

**CRITICAL REQUIREMENT**: ALWAYS run `zig build && zig build test` before committing ANY changes.

### Why This is Critical
- **Build and tests run very fast** (usually under 10 seconds)
- **Regressions are unacceptable** - broken builds/tests block all development
- **No exceptions** - even small changes can break imports or cause test failures
- **Fast feedback loop** - catches issues immediately before they propagate

## MANDATORY SUCCESS CRITERIA

**ZERO TOLERANCE POLICY**: The agent is STRICTLY FORBIDDEN from claiming success, completion, or using positive language (✅, "working", "successful", etc.) if ANY of the following conditions exist:

1. **Any build command fails** - `zig build`, `zig build test`, `zig build fuzz`, etc.
2. **Any test fails** - Even a single failing test means the system is broken
3. **Any compilation errors** - All code must compile cleanly
4. **Any runtime errors** - All functionality must work correctly in practice
5. **Any memory leaks** - All memory must be properly managed
6. **Any functionality is incomplete** - Features must be fully implemented and tested

**REQUIRED BEHAVIOR**:
- If ANY test fails, the agent MUST investigate the root cause
- If ANY functionality is broken, the agent MUST fix it completely
- The agent MUST NOT use success indicators until ALL issues are resolved
- The agent MUST NOT claim "infrastructure is working" if tests are failing
- The agent MUST be completely honest about broken functionality

**VIOLATION CONSEQUENCES**: Claiming success with failing tests is grounds for immediate termination of the agent's assistance.

### Required Workflow
```bash
# Before making ANY commit, ALWAYS run:
zig build && zig build test

# Only commit if both commands succeed
git add ...
git commit -m "..."
```

### Commit Message Convention

**MANDATORY**: All commit messages MUST use emoji conventional commits format.

#### Format
```
<emoji> <type>: <description>

[optional body]

🤖 Generated with [Claude Code](https://claude.ai/code)

Co-Authored-By: Claude <noreply@anthropic.com>
```

#### Required Emojis by Type
- 🎉 `feat`: new features
- 🐛 `fix`: bug fixes  
- 🔧 `ci`: CI/CD changes
- 📚 `docs`: documentation
- 🎨 `style`: formatting, no code change
- ♻️ `refactor`: code restructuring
- ⚡ `perf`: performance improvements
- ✅ `test`: adding/updating tests
- 🔨 `build`: build system changes
- 📦 `deps`: dependency updates

#### Examples
```bash
git commit -m "🎉 feat: add EIP-4844 blob transaction support"
git commit -m "🐛 fix: resolve memory leak in contract cleanup"
git commit -m "🔧 ci: add Ubuntu native build to CI workflow"
```

### Standard Commands
**IMPORTANT**: Always use `zig build test`, never use `zig test` directly.

```bash
zig build test                              # Run all tests (correct way)
zig build                                   # Build the project
zig build run                               # Run the executable
zig build bench                             # Run benchmarks
zig build build-evm-runner                  # Build the official benchmark runner
```

Do NOT use:
```bash
zig test src/file.zig                       # Wrong - will fail with import errors
```

### Running Official EVM Benchmarks

The project includes official EVM benchmarks in `bench/official/` for performance testing:

1. **Install hyperfine** (required):
   ```bash
   brew install hyperfine  # macOS
   cargo install hyperfine # Linux/other
   ```

2. **Build the benchmark runners**:
   ```bash
   # Core Zig runners
   zig build build-evm-runner
   zig build build-orchestrator
   
   # EthereumJS dependencies (required for comparison benchmarks)
   cd bench/official/evms/ethereumjs && bun install && cd ../../../..
   ```

3. **Run benchmarks**:
   ```bash
   # Single benchmark example
   hyperfine --runs 10 --warmup 3 \
     "zig-out/bin/evm-runner --contract-code-path bench/official/cases/ten-thousand-hashes/bytecode.txt --calldata 0x30627b7c"
   
   # Cross-EVM comparison benchmarks
   ./zig-out/bin/orchestrator --compare --export markdown
   ```

Available benchmark cases:
- `erc20-approval-transfer` - ERC20 approval and transfer
- `erc20-mint` - ERC20 minting
- `erc20-transfer` - Basic ERC20 transfers
- `snailtracer` - Complex computation
- `ten-thousand-hashes` - Hash-intensive operations

### Enabling Debug Logging in Tests

To see `std.log.debug` output when running tests, add this to your test file:

```zig
test {
    std.testing.log_level = .warn;
}
```

This will enable all debug logging statements in the code being tested, which is essential for debugging EVM execution issues.

## Commenting Guidelines

### Comments Should Be Minimal and Purposeful
- **Only add useful and necessary comments** - avoid overcommenting
- **Do not add comments for obvious operations** - code should be self-explanatory
- **Avoid explaining what the code does** - explain why when needed
- **No redundant comments** - if removing code, don't add comments about what was removed

### Code Removal Policy
- **NEVER comment out code** - always delete unused or obsolete code completely
- **Do not leave commented-out code blocks** - remove them entirely
- **Version control tracks history** - there's no need to preserve old code as comments
- **Clean codebase only** - the codebase should only contain active, working code

## Source Control Best Practices

### CRITICAL: Git is Our Only Source Control

**ABSOLUTE MANDATE**: We use Git for version control. The following practices are FORBIDDEN:

1. **NEVER comment out code** - Delete it completely, Git preserves history
2. **NEVER comment out tests** - If a test is failing, fix it or understand why
3. **NEVER create .bak files** - Git handles version history, not manual backups
4. **NEVER use comments as source control** - Comments are for documentation, not history

### Handling Failing Tests

**FORBIDDEN PRACTICES**:
- ❌ Commenting out failing tests to make the build pass
- ❌ Deleting tests that expose bugs
- ❌ Skipping tests without understanding the root cause
- ❌ Creating backup files of tests before modifying them

**REQUIRED PRACTICES**:
- ✅ Fix the code that causes tests to fail
- ✅ If a test is invalid, update it to match correct behavior
- ✅ Use Git to track all changes, including test modifications
- ✅ Every test must pass - no exceptions

### Why This Matters

1. **Commented code creates confusion** - Is it still needed? Why was it disabled?
2. **Backup files pollute the codebase** - Git already tracks all history
3. **Disabled tests hide regressions** - Every test exists for a reason
4. **Clean code is professional** - The codebase should only contain active, working code

### ENFORCEMENT

Creating .bak files or commenting out code/tests demonstrates unprofessional development practices and violates our source control principles.

## EVM Architecture and Development Guidelines

### EVM Module Structure

The EVM implementation follows a modular architecture with clear separation of concerns:

#### Core Components
- **Evm (evm.zig)**: Main virtual machine orchestrating execution
- **Frame/StackFrame**: Execution contexts for calls and creates
- **Stack**: 256-bit word stack (max 1024 elements)
- **Memory**: Byte-addressable memory with hierarchical isolation
- **State**: Account and storage management with journaling

#### Key Design Patterns

1. **Strong Error Types**: Every component has specific error types
   ```zig
   pub const MemoryError = error{
       OutOfMemory,
       InvalidOffset,
       MemoryLimitExceeded,
       // ... specific errors
   };
   ```

2. **Unsafe Operations for Performance**: 
   - Jump table validates stack requirements
   - Opcodes use `_unsafe` variants for speed
   ```zig
   const top = frame.stack.pop_unsafe(); // Bounds already checked
   ```

3. **Comprehensive Documentation**: Every opcode includes:
   - Stack input/output specification
   - Gas costs
   - Execution steps
   - Examples

4. **Cache-Conscious Field Layout**: Structs organized by access patterns
   ```zig
   // Hot fields together (cache line 1)
   stack: Stack,
   pc: u32,
   gas_remaining: i64,
   
   // Cold fields together (later cache lines)
   tracer: ?std.io.AnyWriter,
   ```

### EVM-Specific Coding Standards

1. **Opcode Implementation Pattern**:
   ```zig
   pub fn op_example(frame: *Frame) ExecutionError.Error!void {
       // Pop operands (validated by jump table)
       const b = frame.stack.pop_unsafe();
       const a = frame.stack.peek_unsafe();
       
       // Perform operation
       const result = /* operation logic */;
       
       // Update stack
       frame.stack.set_top_unsafe(result);
   }
   ```

2. **Memory Management in EVM**:
   - Use checkpoint system for nested calls
   - Shared buffer with lazy expansion
   - Always calculate gas before expansion
   ```zig
   const checkpoint = memory.get_checkpoint();
   const child_memory = try memory.init_child_memory(checkpoint);
   defer child_memory.deinit();
   ```

3. **Error Handling Philosophy**:
   - Normal termination (STOP, RETURN) are errors for control flow
   - Real errors indicate failure conditions
   - Database errors are propagated from state interface
   ```zig
   return switch (err) {
       Error.STOP => RunResult{ .success = output },
       Error.REVERT => RunResult{ .revert = output },
       else => RunResult{ .failure = err },
   };
   ```

4. **Gas Calculation Rules**:
   - Check gas before operations
   - Use wrapping arithmetic for gas costs
   - Track gas as i64 (negative = out of gas)
   ```zig
   frame.gas_remaining -= cost;
   if (frame.gas_remaining < 0) return error.OutOfGas;
   ```

### EVM Testing Patterns

1. **In-File Tests**: All unit tests colocated with implementation
2. **Fuzz Testing**: Use for boundary conditions and edge cases
3. **No Test Abstractions**: Each test is self-contained
4. **Test Categories**:
   - Basic operations
   - Edge cases (overflow, underflow)
   - Gas consumption
   - Error conditions

### Performance Considerations

1. **Jump Table Dispatch**: Opcodes dispatched via function pointers
2. **Analysis Caching**: Code analysis cached for nested calls
3. **Memory Pooling**: Frame pool for temporary allocations
4. **Inline Hot Paths**: Critical opcodes can be inlined

### Advanced Architectural Patterns

#### 1. Tail Call Recursion for Zero-Overhead Dispatch

The EVM uses Zig's `@call(.always_tail, ...)` for optimal interpreter performance:

```zig
// interpret2.zig - Start execution with tail call
const first_op = frame.ops[0];
return try (@call(.always_tail, first_op, .{frame}));

// Each opcode handler tail calls to the next
pub fn op_add(frame: *StackFrame) Error!noreturn {
    // Perform operation
    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe();
    frame.stack.set_top_unsafe(a +% b);
    
    // Tail call to next instruction
    frame.ip += 1;
    const next_op = frame.ops[frame.ip];
    return @call(.always_tail, next_op, .{frame});
}
```

This eliminates call stack growth and enables CPU return prediction optimization.

#### 2. Data-Driven Design with Jump Tables

The EVM uses pure data structures for opcode dispatch instead of switch statements:

```zig
// OpcodeMetadata - Struct of Arrays for cache efficiency
pub const OpcodeMetadata = struct {
    execute_funcs: [256]ExecutionFunc align(CACHE_LINE_SIZE),
    constant_gas: [256]u64 align(CACHE_LINE_SIZE),
    min_stack: [256]u32,
    max_stack: [256]u32,
    // ... other arrays
};

// Direct O(1) dispatch without branching
const opcode = bytecode[pc];
const handler = table.execute_funcs[opcode];
```

Benefits:
- No branch prediction penalties
- Hot data (functions, gas) in contiguous cache lines
- Cold data separated to avoid cache pollution

#### 3. Generic Plan Interface for Bytecode Analysis

The Planner system provides configurable bytecode analysis:

```zig
pub fn createPlanner(comptime Cfg: PlannerConfig) type {
    // Returns a specialized planner based on config
    return struct {
        const PcType = Cfg.PcType();
        const Plan = plan_mod.createPlan(PlanCfg);
        
        pub fn create_instruction_stream(...) !Plan {
            // Analyzes bytecode and produces optimized instruction stream
            // Identifies jump destinations, fuses opcodes, inline constants
        }
    };
}
```

The plan includes:
- Pre-validated jump destinations
- Fused opcode sequences (PUSH+ADD → PUSH_ADD)
- Inline constants for common patterns
- Block metadata for gas calculation

#### 4. Cache-Conscious Struct Layout

Structs are carefully organized by access patterns:

```zig
// EVM struct layout with cache line annotations
pub const Evm = struct {
    // CACHE LINE 1-2 (128 bytes) - HOT PATH
    state: EvmState,        // Frequently accessed
    access_list: AccessList,
    journal: CallJournal,
    allocator: Allocator,
    gas_refunds: i64,
    
    // CACHE LINE 3 (64 bytes) - TRANSACTION LIFECYCLE
    created_contracts: CreatedContracts,
    self_destruct: SelfDestruct,
    internal_arena: ArenaAllocator,
    
    // CACHE LINE 5+ - COLD PATH
    table: OpcodeMetadata,  // Large, rarely accessed
    context: Context,       // Transaction context
    tracer: ?AnyWriter,     // Debug only
};
```

#### 5. Comptime Validation and Documentation

While explicit size/alignment assertions aren't common, the codebase uses:

1. **Alignment directives** for performance:
   ```zig
   execute_funcs: [256]ExecutionFunc align(CACHE_LINE_SIZE),
   ```

2. **Size-aware type selection**:
   ```zig
   pub const InstructionElement = if (@sizeOf(usize) == 8)
       u64  // 64-bit platforms
   else if (@sizeOf(usize) == 4)
       u32; // 32-bit platforms
   ```

3. **Comptime configuration validation**:
   ```zig
   pub fn validate(self: @This()) void {
       if (self.stack_size > 1024) @compileError("Stack size exceeds EVM limit");
       if (self.max_bytecode_size > 24576) @compileError("Bytecode size exceeds EVM limit");
   }
   ```

### Module Dependencies

When working with EVM modules:
- Import from module system, not relative paths
- Use full type paths for clarity
```zig
const Address = @import("primitives").Address.Address;
const ExecutionError = @import("execution/execution_error.zig");
```

### EVM Module Organization

The EVM is organized into functional modules:

1. **Core Execution** (`src/evm/`):
   - `evm.zig` - Main VM with Host interface
   - `stack_frame.zig` - Execution contexts
   - `interpret2.zig` - Tailcall interpreter

2. **Opcodes** (`src/evm/execution/`):
   - `arithmetic.zig` - ADD, MUL, DIV, MOD
   - `stack.zig` - PUSH, POP, DUP, SWAP
   - `memory.zig` - MLOAD, MSTORE, MSIZE
   - `storage.zig` - SLOAD, SSTORE
   - `control.zig` - JUMP, JUMPI, PC, STOP
   - `system.zig` - CALL, CREATE, RETURN
   - `crypto.zig` - KECCAK256
   - `log.zig` - LOG0-LOG4

3. **State Management** (`src/evm/state/`):
   - `state.zig` - Account and storage state
   - `database_interface.zig` - Pluggable storage
   - `journal.zig` - Revertible state changes
   - `memory_database.zig` - In-memory implementation

4. **Analysis** (`src/evm/`):
   - `analysis2.zig` - Jump destination validation
   - `jumpdest_validation.zig` - JUMPDEST analysis
   - `bitvec.zig` - Efficient jump tracking

5. **Precompiles** (`src/evm/precompiles/`):
   - Standard Ethereum precompiled contracts
   - Each with gas calculation and implementation

### Working with EVM State

1. **Database Interface Pattern**:
   ```zig
   pub const DatabaseInterface = struct {
       get_account: *const fn(self: *anyopaque, address: Address) DatabaseError!Account,
       set_account: *const fn(self: *anyopaque, address: Address, account: Account) DatabaseError!void,
       // ... other methods
   };
   ```

2. **Journaling for Reverts**:
   - All state changes are journaled
   - Snapshots enable nested transaction rollback
   - Self-destruct and created contracts tracked separately

3. **Access List (EIP-2929/2930)**:
   - Tracks warm/cold storage access
   - Reduces gas costs for repeated access
   - Pre-warming for transaction access lists

## EVM2 Frame.zig Navigation Guide

### File Structure Overview for `src/evm2/frame.zig` (~2000+ lines)

**CRITICAL**: This file is too large to read in one operation. Use targeted reads with offset/limit or Grep for specific sections.

#### Key Line Number Ranges:
- **Lines 1-90**: Imports, FrameConfig struct, and configuration validation
- **Lines 91-165**: Frame struct definition, Error enum, init/deinit functions
- **Lines 166-583**: `interpret()` function - instruction array building and execution loop
- **Lines 584-898**: Instruction handlers (op_stop_handler, op_add_handler, etc.)
- **Lines 900-975**: Core opcode implementations (op_pc, op_stop, op_pop, push_n helper)
- **Lines 976-1098**: PUSH opcode implementations (op_push0 through op_push32)
- **Lines 1099-1186**: DUP/SWAP and bitwise operations (op_dup1, op_and, op_or, etc.)
- **Lines 1187-1356**: Arithmetic operations (op_add, op_mul, op_div, op_exp, etc.)
- **Lines 1357-1375**: Gas management (consumeGasUnchecked, checkGas, op_gas)
- **Lines 1376-1471**: Comparison and control flow (op_lt, op_jump, op_jumpi, op_invalid)
- **Lines 1472-1555**: Memory and crypto operations (op_keccak256, op_mload, op_mstore)
- **Lines 1560+**: Extensive test suite

#### Common Search Patterns:
```bash
# Find specific opcode implementation
grep -n "pub fn op_[opcode_name]" src/evm2/frame.zig

# Find handler functions
grep -n "_handler.*fn" src/evm2/frame.zig

# Find test for specific functionality
grep -n "test.*[functionality]" src/evm2/frame.zig
```

#### Efficient Reading Strategies:
1. **For opcode implementations**: Read lines 900-1555
2. **For handler dispatch**: Read lines 584-898
3. **For configuration**: Read lines 1-165
4. **For tests**: Use Grep to find specific test, then read with offset/limit
5. **For interpret loop**: Read lines 166-583

#### Key Functions by Purpose:
- **Initialization**: `init()` (~line 137), `deinit()` (~line 160)
- **Execution**: `interpret()` (~line 166), `execute_instruction()` (~line 585)
- **Stack Operations**: `push_unsafe()`, `pop_unsafe()`, `peek_unsafe()`, `set_top_unsafe()`
- **Memory**: `op_mload()` (~line 1497), `op_mstore()` (~line 1518)
- **Arithmetic**: `op_add()` (~line 1189), `op_mul()` (~line 1195), etc.
- **Control Flow**: `op_jump()` (~line 1436), `op_jumpi()` (~line 1448)

#### Configuration Types:
- **FrameConfig**: Lines 9-64, defines stack size, word type, memory limits
- **Frame struct**: Lines 91+, contains stack, bytecode, pc, gas_remaining, memory
- **Error enum**: Lines 94-104, defines all possible execution errors

## Essential Documentation References

### Zig Programming Language Documentation
- **Zig Language Reference**: https://ziglang.org/documentation/0.14.1/
  - Complete language specification and syntax reference
  - Memory management patterns and allocator usage
  - Comptime programming and metaprogramming
  - Error handling with error unions and error sets
  
- **Zig Standard Library**: https://ziglang.org/documentation/master/std/
  - Standard library modules and functions
  - Data structures (ArrayList, HashMap, etc.)
  - I/O operations and file system interfaces
  - Testing framework and debugging tools

### Ethereum Specifications
- **Ethereum Yellow Paper**: Technical specification of the EVM
- **EIP Repository**: Ethereum Improvement Proposals for protocol changes

### Reference Implementation
- **revm codebase**: The `revm/` directory contains a reference Rust implementation of the EVM
  - Use this to verify correct behavior when implementing opcodes
  - Check `revm/crates/interpreter/src/instructions/contract.rs` for CALL/DELEGATECALL/STATICCALL implementations
  - DELEGATECALL preserves the original caller and value from the parent context

## Interactive Collaboration Requirements

This project operates on mandatory interactive collaboration - every significant decision, change, or implementation requires user partnership and approval. Key principles:

- No autonomous decisions on architecture, implementation details, or workflow changes
- Always present proposals and wait for explicit approval
- Treat every interaction as a collaborative partnership
- When uncertain, ask rather than assume
- Document all decisions and their rationale

## Important: When Things Don't Go As Planned

**If the plan outlined by the user isn't working:**
1. **STOP immediately** - Don't try to continue or find workarounds
2. **Explain clearly** what is happening and why it's not working
3. **Wait for instructions** - Let the user provide guidance on how to proceed
4. **Don't assume** - Ask for clarification rather than guessing the next step

This ensures we stay aligned with the project's intentions and don't create unintended complexity.

## Amendment Protocol

When this CLAUDE.md file needs updates:
1. Present proposed changes clearly with rationale
2. Show before/after diffs for modified sections
3. Explain impact on existing workflows
4. Request explicit approval before implementing changes
5. Document amendment history in commit messages

---

*This configuration establishes a self-referential system where the AI agent governs its own behavior according to these documented protocols, ensuring consistent, collaborative, and methodical development practices.*