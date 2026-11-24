# CLAUDE.md

## MISSION CRITICAL SOFTWARE

**⚠️ WARNING: Mission-critical financial infrastructure - bugs cause fund loss.**

Every line of code must be correct. Zero error tolerance.

## Core Protocols

### Working Directory

**ALWAYS run commands from the repository root directory.** Never use `cd` except when debugging a submodule. All commands, builds, and tests are designed to run from root.

### Security

- Sensitive data detected (API keys/passwords/tokens): abort, explain, request sanitized prompt
- Memory safety: plan ownership/deallocation for every allocation
- Every change must be tested and verified
- Use SafetyCounter (`src/internal/safety_counter.zig`) for infinite loop prevention: the tracer caps execution at 300M instructions, and `EvmConfig.loop_quota` caps loops at 1M in Debug and ReleaseSafe
- **CRITICAL: Crashes are SEVERE SECURITY BUGS** - Any crash (e.g., from `std.debug.assert`) indicates memory unsafety or missing validation. The EVM must ALWAYS return errors gracefully, never crash. Before fixing the bug that triggered the crash, FIRST fix the validation/error handling that allowed the crash to occur.

### Build Verification

**EVERY code change**: `zig build && zig build test-opcodes`
**Exception**: .md files only

Follow TDD

### Debugging

- Bug not obvious = improve visibility first
- Use the MinimalEvm differential tests in `test/differential` (`DifferentialTestor` in `differential_testor.zig`; `zig build test-integration` runs them). `zig build test-opcodes` is not a differential check: 127 of its 138 per-opcode files assert nothing beyond a successful run, and the tracer's MinimalEvm validation is off by default (`TracerConfig.enabled = false`)

### Zero Tolerance

❌ Broken builds/tests
❌ Stub implementations (`error.NotImplemented`)
❌ Commented code (use Git)
❌ Test failures
❌ Invalid benchmarks
❌ `std.debug.print` in modules (use `log.zig`)
❌ `std.debug.assert` (use `tracer.assert()`)
❌ Skipping/commenting tests
❌ Any stub/fallback implementations
❌ **Swallowing errors with `catch` (e.g., `catch {}`, `catch &.{}`, `catch null`)**

**STOP and ask for help rather than stubbing.**

**WHY PLACEHOLDERS ARE BANNED**: Placeholder implementations create ambiguity - the human cannot tell if "Coming soon!" or simplified output means:
1. The AI couldn't solve it and gave up
2. The AI is planning to implement it later
3. The feature genuinely isn't ready yet
4. There's a technical blocker

This uncertainty wastes debugging time and erodes trust. Either implement it fully, explain why it can't be done, or ask for help. Never leave placeholders that pretend to work.

**NEVER swallow errors! Every error must be explicitly handled or propagated. Using `catch` to ignore errors can cause silent failures and fund loss.**

## Coding Standards

### Principles

- Minimal else statements
- Single word variables (`n` not `number`)
- Direct imports (`address.Address` not aliases)
- Tests in source files
- Defer patterns for cleanup
- Always follow allocations with defer/errDefer
- Descriptive variables (`top`, `value1`, `operand` not `a`, `b`)
- Logging: use `log.zig` (`log.debug`, `log.warn`)
- Assertions: `tracer.assert(condition, "message")`
- Stack semantics: LIFO order (first pop = top)

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

### ArrayList API (Zig 0.15)

**CRITICAL**: In Zig 0.15, `std.ArrayList(T)` returns an UNMANAGED type that requires allocator for all operations!

```zig
// CORRECT: std.ArrayList is UNMANAGED (no internal allocator)
var list = std.ArrayList(T){};  // Default initialization
// OR
var list: std.ArrayList(T) = .empty;  // Empty constant
// OR with capacity
var list = try std.ArrayList(T).initCapacity(allocator, 100);

// All operations REQUIRE allocator:
defer list.deinit(allocator);  // ✅ allocator REQUIRED
try list.append(allocator, item);  // ✅ allocator REQUIRED
try list.ensureTotalCapacity(allocator, 100);  // ✅ allocator REQUIRED
_ = list.pop();  // No allocator needed for pop

// Direct access (no allocator needed):
list.items[0] = value;
list.items.len = 0;

// WRONG - This does NOT work in Zig 0.15:
var list = std.ArrayList(T).init(allocator);  // ❌ No init() method!
list.deinit();  // ❌ Missing required allocator
try list.append(item);  // ❌ Missing required allocator

// For managed ArrayList with internal allocator, use array_list module directly:
const array_list = @import("std").array_list;
var list = array_list.AlignedManaged(T, null).init(allocator);
defer list.deinit();  // No allocator needed for managed version
```

## Testing Philosophy

- NO abstractions - copy/paste setup
- NO helpers - self-contained tests
- Test failures = fix immediately
- Evidence-based debugging only
- **CRITICAL**: Zig tests output NOTHING when passing (no output = success)
- If tests produce no output, they PASSED successfully
- Only failed tests produce output

### Debug Logging in Tests

Enable with:
```zig
test {
    std.testing.log_level = .debug;
}
```

**IMPORTANT**: Even with `std.testing.log_level = .debug`, if the test passes, you will see NO OUTPUT. This is normal Zig behavior. No output means the test passed.

## Project Architecture

### Guillotine EVM

High-performance EVM: correctness, minimal allocations, strong typing.

### Module System

Use `zig build test` not `zig test`. Common error: "primitives" package requires module system.

### Key Components

**Core**: evm.zig, frame.zig, stack.zig, memory.zig, dispatch.zig
**Handlers**: handlers_*.zig (arithmetic, bitwise, comparison, context, jump, keccak, log, memory, stack, storage, system)
**Synthetic**: handlers_*_synthetic.zig (fused ops)
**State**: database.zig, journal.zig, access_list.zig, memory_database.zig (`src/storage/`)
**External**: call_params.zig, call_result.zig (`src/frame/`); precompiles live in the vendored `lib/voltaire/src/precompiles/` and are imported as the `precompiles` module
**Bytecode**: bytecode.zig, bytecode_analyze.zig, bytecode_stats.zig
**Infrastructure**: tracer.zig, hardfork.zig, eips.zig
**Tracer**: minimal_evm.zig (MinimalEvm, the reference interpreter), pc_tracker.zig, minimal_evm_c.zig (C/WASM FFI), minimal_evm_sync.zig (Frame/MinimalEvm sync)

### Import Rules

```zig
// Good
const Evm = @import("evm");
const memory = @import("memory.zig");

// Bad - no parent imports
const Contract = @import("../frame/contract.zig");
```

## Commands

### Basic Commands
- `zig build` - Build the project
- `zig build test` - Run all tests (specs → integration → unit)
- `zig build specs` - Run Ethereum execution spec tests
- `zig build test-integration` - Run integration tests from test/**/*.zig
- `zig build test-unit` - Run unit tests from src/**/*.zig
- `zig build test-lib` - Run library tests from lib/**/*.zig
- `zig build test-opcodes` - Run the per-opcode tests plus the ModExp, ECRECOVER and spec-runner unit tests (the CI gate)

### Test Organization

**Test Categories:**
1. **Specs Tests** (`zig build specs`) - Ethereum execution spec compliance tests
2. **Integration Tests** (`zig build test-integration`) - Cross-module testing, differential testing, fixtures
3. **Unit Tests** (`zig build test-unit`) - Module-specific unit tests from src/
4. **Library Tests** (`zig build test-lib`) - External library wrapper tests

**Test Aggregator Files:**
- `src/root.zig` - Aggregates all unit tests from src/**/*.zig
- `test/root.zig` - Aggregates all integration tests from test/**/*.zig
- `lib/root.zig` - Aggregates all library tests from lib/**/*.zig
- `specs/cases/root.zig` - Ethereum spec test runner (`zig build specs`)
- `specs/eest_runner.zig` - Official EEST state test runner (`zig build state-tests`; see `specs/README.md`)

### Test Filtering
Use `-Dtest-filter='<pattern>'` to run specific tests:
```bash
# Run specific test by name
zig build test-opcodes -Dtest-filter='ADD opcode'

# Run tests matching a pattern
zig build test-integration -Dtest-filter='trace validation'

# Filter unit tests
zig build test-unit -Dtest-filter='stack'
```

### Other Test Commands
- `zig build test-opcodes-0x01` - One opcode's test file, `test/evm/opcodes/01_test.zig` (every opcode has a `test-opcodes-0xNN` step)
- `zig build test-synthetic` - Synthetic opcode tests
- `zig build test-fusions` - Fusion optimization tests
- `zig build test-fixtures-differential` - Run the erc20-transfer fixture (checks only that deploy and call succeed)
- `zig build state-tests` - Official EEST state tests

## EVM Architecture

### CRITICAL: Dispatch-Based Execution Model

**Guillotine uses a dispatch-based execution model, NOT a traditional interpreter!**

#### Traditional Interpreter (MinimalEvm)
```
Bytecode: [0x60, 0x01, 0x60, 0x02, 0x01, 0x56, 0x5b, 0x00]
           PUSH1  1   PUSH1  2   ADD  JUMP JUMPDEST STOP

Execution: while (pc < bytecode.len) {
    opcode = bytecode[pc]
    switch(opcode) { ... }  // Big switch statement
    pc++
}
```

#### Dispatch-Based Execution (Frame)
```
Bytecode: [0x60, 0x01, 0x60, 0x02, 0x01, 0x56, 0x5b, 0x00]

Dispatch Schedule (preprocessed):
[0] = first_block_gas { gas: 17 }     // PUSH1 + PUSH1 + ADD + JUMP (3+3+3+8)
[1] = &push_handler                   // Function pointer
[2] = push_inline { value: 1 }        // Inline metadata
[3] = &push_handler                   // Function pointer
[4] = push_inline { value: 2 }        // Inline metadata
[5] = &add_handler                    // Function pointer
[6] = &jump_handler                   // Function pointer
[7] = &jumpdest_handler               // Function pointer
[8] = jump_dest { gas: 1, min: 0 }    // JUMPDEST + STOP (1+0)
[9] = &stop_handler                   // Function pointer

Execution: cursor[0].opcode_handler(frame, cursor) → tail calls
```

The schedule is illustrative: it assumes `EvmConfig.enable_fusion = false`, and the
builder in `src/preprocessor/dispatch.zig` also appends terminal handlers.

**Key Differences:**
1. **No PC in Frame**: Frame uses cursor (pointer into dispatch schedule)
2. **No Switch Statement**: Direct function pointer calls with tail-call optimization
3. **Preprocessed**: Bytecode analyzed once, schedule reused
4. **Inline Metadata**: Data embedded directly in schedule (no bytecode reads)
5. **Gas Batching**: Gas calculated per basic block, not per instruction

**Schedule Index ≠ PC**: Schedule[0] might be metadata, not the PC=0 instruction!

### Design Patterns

1. Strong error types per component
2. Unsafe ops for performance (pre-validated)
3. Cache-conscious struct layout
4. Handler tables for O(1) dispatch
5. Bytecode optimization via Dispatch

### Understanding `_unsafe` Operations

**DO NOT file bugs about `_unsafe` operations lacking runtime bounds checks - that's the entire point.**

The `_unsafe` suffix is a deliberate naming convention indicating:
- **Caller is responsible for validation** (like Rust's `unsafe` blocks)
- **Bounds checks are skipped for performance** - this is intentional, not a bug
- **Pre-validation happens elsewhere** - the dispatch system validates stack requirements at bytecode analysis time

Pattern:
```zig
// Safe version - ALWAYS checks bounds, returns error
pub fn push(self: *Self, value: WordType) Error!void {
    if (overflow_condition) return Error.StackOverflow;
    self.push_unsafe(value);
}

// Unsafe version - NO bounds check, caller must pre-validate
pub fn push_unsafe(self: *Self, value: WordType) void {
    self.stack_ptr -= 1;
    self.stack_ptr[0] = value;
}
```

The `tracer.assert()` calls in unsafe operations are **development aids for debugging**, not security mechanisms. When tracer is null (production), they're no-ops by design.

### Key Separations

- **Frame**: Executes dispatch schedule (NOT bytecode)
- **Dispatch**: Builds optimized schedule from bytecode
- **Host**: External operations

### Opcode Pattern

From `src/instructions/handlers_arithmetic.zig`:

```zig
pub fn add(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
    self.beforeInstruction(.ADD, cursor);

    self.stack.binary_op_unsafe(struct {
        fn op(top: WordType, second: WordType) WordType {
            return top +% second;
        }
    }.op);

    return dispatch_next.nextInstruction(FrameType, self, cursor, .ADD);
}
```

Handlers assert through the EVM's tracer: `(&self.getEvm().tracer).assert(self.stack.size() >= 1, "PUSH_AND_INLINE requires 1 stack item");`.

## Opcode Navigation

Handlers organized by type:
- Arithmetic: `handlers_arithmetic.zig`
- Stack: `handlers_stack.zig`
- Memory: `handlers_memory.zig`
- System: `handlers_system.zig`

## Recent Updates

### Tracer System
- Replaced `std.debug.assert` with `tracer.assert()`
- Bytecode analysis lifecycle tracking
- Cursor-aware dispatch sync
- Fixed MinimalEvm stack semantics (LIFO)

### WASM Integration
- C FFI wrapper (`src/tracer/minimal_evm_c.zig`)
- Opaque handle pattern
- Complete EVM lifecycle in WASM

### Dispatch Optimization
- Static jump resolution
- Dispatch cache
- Fusion detection
- 300M instruction safety limit

### Memory Management
- Checkpoint system
- Lazy word-aligned allocation
- Cached gas calculations
- Borrowed vs owned memory

## Tracer System Architecture: Execution Synchronization

The tracer system in `@src/tracer/tracer.zig` provides sophisticated execution synchronization between Frame (optimized) and MinimalEvm (reference) implementations:

### How Synchronization Works

**Frame executes a dispatch schedule, MinimalEvm executes bytecode sequentially.**

**Every instruction handler MUST call `self.beforeInstruction(opcode, cursor)`** which:
1. Executes the equivalent operation(s) in MinimalEvm
2. For regular opcodes: Execute 1 MinimalEvm step
3. For synthetic opcodes: Execute N MinimalEvm steps (where N = number of fused operations)
4. Validates that both implementations reach identical state

**CRITICAL**: Frame's cursor is an index into the dispatch schedule, NOT a PC!
- Schedule[0] might be `first_block_gas` metadata, not PC=0
- Schedule indices do NOT correspond to bytecode PCs
- Synthetic handlers in schedule represent multiple bytecode operations

### Instruction Handler Pattern
```zig
pub fn some_opcode(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
    self.beforeInstruction(.SOME_OPCODE, cursor);  // ← REQUIRED!
    // ... opcode implementation ...
    return dispatch_next.nextInstruction(FrameType, self, cursor, .SOME_OPCODE);
}
```

**CRITICAL**: Missing `beforeInstruction()` calls cause test failures because MinimalEvm gets out of sync.

### Synthetic Opcode Handling

The tracer automatically handles synthetic opcodes in `executeMinimalEvmForOpcode()` (`src/tracer/minimal_evm_sync.zig`):
- **Regular opcodes**: Execute exactly 1 MinimalEvm step
- **PUSH_MSTORE_INLINE**: Execute 2 steps (PUSH1 + MSTORE)
- **FUNCTION_DISPATCH**: Execute 4 steps (PUSH4 + EQ + PUSH + JUMPI)
- **etc.**

This is NOT a divergence issue - it's the designed synchronization mechanism.

### Common Test Failure Root Causes

1. **Dispatch Schedule Misalignment** - Schedule[0] contains metadata, not PC=0 handler
2. **Missing beforeInstruction() calls** - Handler doesn't synchronize MinimalEvm
3. **MinimalEvm context mismatch** - Hardcoded values don't match Frame's blockchain context
4. **Implementation bugs** - Logic errors in either Frame or MinimalEvm

**Key Debugging Points:**
- Frame cursor != PC (cursor is dispatch schedule index)
- Schedule may start with metadata items (first_block_gas)
- Synthetic opcodes in Frame = multiple steps in MinimalEvm
- The tracer's `executeMinimalEvmForOpcode()` handles fusion → sequential mapping correctly

## Documentation

Detailed documentation is available in `docs/`:

- **[docs/README.md](docs/README.md)** - Documentation index
- **[docs/dev/](docs/dev/)** - Developer deep dive with code excerpts
  - [ARCHITECTURE.md](docs/dev/ARCHITECTURE.md) - Unified architecture overview
  - [EXECUTION-MODELS.md](docs/dev/EXECUTION-MODELS.md) - Mini vs Performance comparison
  - [STATE-MANAGEMENT.md](docs/dev/STATE-MANAGEMENT.md) - Storage, journal, snapshots
  - [GAS-METERING.md](docs/dev/GAS-METERING.md) - Gas calculation patterns
  - [TESTING.md](docs/dev/TESTING.md) - Test organization and debugging
  - [HARDFORKS.md](docs/dev/HARDFORKS.md) - EIP support matrix
  - [CONTRIBUTING.md](docs/dev/CONTRIBUTING.md) - Development workflow
- **[docs/performance/](docs/performance/)** - Performance EVM specifics
- **[docs/mini/](docs/mini/)** - Mini EVM specifics

## References

- Zig docs: https://ziglang.org/documentation/0.15.2/ (CI uses Zig 0.15.2; `build.zig.zon` requires at least 0.15.1)
- `mini/`: guillotine-mini, the reference interpreter used for differential tests
- `specs/execution-specs` (git submodule): Python execution specs and test fillers
- Yellow Paper: Ethereum spec
- EIPs: Ethereum Improvement Proposals

## Collaboration

- Present proposals, wait for approval
- Plan fails: STOP, explain, wait for guidance

## GitHub Issue Management

Always disclose Claude AI assistant actions:
"*Note: This action was performed by Claude AI assistant, not @roninjin10 or @fucory*"

Required for: creating, commenting, closing, updating issues and all GitHub API operations.

### Before Filing Issues

**Understand the design before claiming something is a bug:**
- `_unsafe` suffix = intentionally no bounds checks (see "Understanding `_unsafe` Operations")
- Tracer assertions = development aids, not production security
- Pre-validation patterns = security happens at a different layer
- If something looks "wrong" but follows a naming convention, it's probably intentional

## Build Commands

Usage: `zig build [steps] [options]`

Run `zig build -l` for the full list (it includes one `test-opcodes-0xNN` step per opcode).

Key Steps:
  test                         Run all tests (specs -> integration -> unit)
  specs                        Run Ethereum execution spec tests
  state-tests                  Run official pre-filled EEST state tests (Frontier through Osaka)
  test-integration             Run integration tests from test/**/*.zig
  test-unit                    Run unit tests from src/**/*.zig
  test-lib                     Run library tests from lib/**/*.zig
  test-opcodes                 Run per-opcode tests (most assert only a successful run)
  test-synthetic               Test synthetic opcodes
  test-fixtures-differential   Run the erc20-transfer fixture (checks success only)
  test-fusions                 Run focused fusion tests (unit + dispatch + differential)
  test-modexp                  Run vendored ModExp arithmetic and precompile tests
  test-layer2                  Run Layer 2 (Base & OP Stack) unit tests
  test-mini                    Run guillotine-mini unit tests
  test-fuzz                    Run all Zig fuzz targets
  shared / static              Build the shared or static library for FFI
  bench                        Run self-contained EVM benchmarks (ReleaseFast)
  verify                       Run the formal verification suite (LLVM IR + SMT + Lean 4)

Options:
  -Doptimize=[enum]            Debug, ReleaseSafe, ReleaseFast, ReleaseSmall
  -Dtest-filter=[string]       Filter tests by pattern (e.g., -Dtest-filter='ADD opcode'); pass it once
  -Denable-tracing=[bool]      Enable EVM instruction tracing
  -Dspec-max-files=[string]    Limit spec files (specs, specs-bun)
  -Dspec-fork=[string]         EEST fork(s) to run, comma-separated (state-tests)
  -Dspec-report=[string]       Write an EEST JSON summary report (state-tests)

`build.zig` also declares `-Devm-hardfork`, `-Devm-disable-gas`,
`-Devm-enable-fusion`, `-Devm-optimize`, `-Ddisable-tailcall-dispatch` and the
size and limit options (`-Dmax-call-depth`, `-Dstack-size`, ...), but no code
under `src/` reads them. Select the hardfork and limits through the comptime
`EvmConfig` in `src/evm_config.zig`, for example
`Evm(.{ .eips = .{ .hardfork = .OSAKA } })`. The default hardfork is OSAKA.
