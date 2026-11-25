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
- Use SafetyCounter (`src/internal/safety_counter.zig`) for infinite loop prevention: `EvmConfig.loop_quota` caps analysis loops at 1M iterations in Debug and ReleaseSafe. Gas bounds execution; the tracer's instruction counter only logs, it never stops a run
- **CRITICAL: Crashes are SEVERE SECURITY BUGS** - Any crash (e.g., from `std.debug.assert`) indicates memory unsafety or missing validation. The EVM must ALWAYS return errors gracefully, never crash. Before fixing the bug that triggered the crash, FIRST fix the validation/error handling that allowed the crash to occur.

### Build Verification

**EVERY code change**: `zig build && zig build test-opcodes`
**Exception**: .md files only

Follow TDD

### Debugging

- Bug not obvious = improve visibility first
- Use the MinimalEvm differential tests in `test/differential` (`zig build test-integration` runs them)

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

### ArrayList API (Zig 0.17.1)

**CRITICAL**: In Zig 0.17.1, `std.ArrayList(T)` returns an UNMANAGED type that requires allocator for all operations!

```zig
// CORRECT: std.ArrayList is UNMANAGED (no internal allocator)
var list = std.ArrayList(T){};  // Default initialization
// OR
const list = std.ArrayList(T).empty;  // Empty constant
// OR with capacity
var list = try std.ArrayList(T).initCapacity(allocator, 100);

// All operations REQUIRE allocator:
defer list.deinit(allocator);  // ✅ allocator REQUIRED
try list.append(allocator, item);  // ✅ allocator REQUIRED
try list.ensureCapacity(allocator, 100);  // ✅ allocator REQUIRED
_ = list.pop();  // No allocator needed for pop

// Direct access (no allocator needed):
list.items[0] = value;
list.items.len = 0;

// WRONG - This does NOT work in Zig 0.17.1:
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
**Tracer**: minimal_evm.zig (MinimalEvm, the reference interpreter), pc_tracker.zig, minimal_evm_sync.zig (Frame/MinimalEvm sync)

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
- `zig build test-opcodes` - Run opcode differential tests

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
- `test/specs/ethereum_specs_test.zig` - Ethereum spec test runner

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
- `zig build test-fusions` - Fusion optimization tests (unit + dispatch + differential)
- `zig build test-modexp` - Vendored ModExp arithmetic and precompile tests
- `zig build test-precompiles` - Precompile integration vectors, including KZG point evaluation
- `zig build test-layer2` - Layer 2 (Base & OP Stack) unit tests
- `zig build test-bench` - Benchmark statistics, CLI and workload construction
- `zig build test-fuzz` - Zig fuzz targets (corpus replay; add `--fuzz` on Linux)
- `zig build state-tests` - Official EEST state fixtures (`scripts/fetch-eest-fixtures.sh` first)
- `zig build verify-smt` - Bitwuzla/Z3 SMT proofs (`model_pins.json` must exist; refresh with `--update-pins` after review)

Tests use the Zig standard test runner. `zig build test-unit` only runs the
inline tests that `src/root.zig` imports; Evm-level behavior tests belong in
`test/evm/opcodes/` (run by `zig build test-opcodes`).

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
[0] = first_block_gas { gas: 15 }     // Metadata for basic block
[1] = &push_handler                   // Function pointer
[2] = push_inline { value: 1 }        // Inline metadata
[3] = &push_handler                   // Function pointer
[4] = push_inline { value: 2 }        // Inline metadata
[5] = &add_handler                    // Function pointer
[6] = &jump_handler                   // Function pointer
[7] = &jumpdest_handler               // Function pointer
[8] = jump_dest { gas: 3, min: 0 }    // Gas for next block
[9] = &stop_handler                   // Function pointer

Execution: cursor[0].opcode_handler(frame, cursor) → tail calls
```

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

Handlers use the register-passing tail-call ABI in
`src/preprocessor/handler_abi.zig`: `fn (frame, cursor, sp, gas)
callconv(handler_cc) ExitCode`. On LLVM x86_64/aarch64 `handler_cc` is
`preserve_none`, which cannot return an error union or take `u256` by value, so
handlers return an `ExitCode` and the caller maps it back with `errorFromExit`.

```zig
pub fn add(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
    var s = N.StackView{ .sp = sp };
    N.before(self, .ADD, cursor, s.sp, gas);
    s.binary_op_unsafe(struct {
        fn op(top: WordType, second: WordType) WordType {
            return top +% second;
        }
    }.op);
    return N.next(self, .ADD, cursor, s.sp, gas);
}
```

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

### Dispatch Optimization
- Static jump resolution
- Dispatch cache
- Fusion detection

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
pub fn some_opcode(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
    N.before(self, .SOME_OPCODE, cursor, sp, gas);  // ← REQUIRED! (calls beforeInstruction)
    // ... opcode implementation ...
    return N.next(self, .SOME_OPCODE, cursor, sp, gas);
}
```

### Synthetic Opcode Handling

The tracer automatically handles synthetic opcodes in `executeMinimalEvmForOpcode()`:
- **Regular opcodes**: Execute exactly 1 MinimalEvm step
- **PUSH_MSTORE_INLINE**: Execute 2 steps (PUSH1 + MSTORE)
- **ISZERO_JUMPI**: Execute 3 steps (ISZERO + PUSH + JUMPI)
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

- Zig docs: https://ziglang.org/documentation/0.17.1/ (CI uses Zig 0.17.1; `build.zig.zon` requires at least 0.17.1)
- `mini/`: guillotine-mini, the reference interpreter used for differential tests
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

Toolchain: Zig 0.17.1 (`zig version`), Rust/Cargo for `lib/voltaire` and
`lib/ark`. `zig build` compiles Voltaire's Rust crypto archive itself
(`cargo build --release --locked` into the Zig cache); no separate step.

Usage: `zig build [steps] [options]` (`zig build -l` lists every step)

Key Steps:
  test                         Run all tests (specs -> integration -> unit -> lib)
  specs                        Run Ethereum execution spec tests
  state-tests                  Run official pre-filled EEST state tests (Frontier through Osaka)
  test-integration             Run integration tests from test/root.zig
  test-unit                    Run unit tests imported by src/root.zig
  test-lib                     Run library tests from lib/root.zig
  test-opcodes                 Run all per-opcode differential tests (+ test-modexp)
  test-modexp                  Run vendored ModExp arithmetic and precompile tests
  test-precompiles             Run precompile integration tests (SHA256..KZG point evaluation)
  test-fusions                 Run focused fusion tests (unit + dispatch + differential)
  test-layer2                  Run Layer 2 (Base & OP Stack) unit tests
  test-fuzz                    Run all Zig fuzz targets (--fuzz on Linux for coverage-guided fuzzing)
  fuzz-campaign                Run the multi-threaded fuzz campaign (-- --seconds=N --threads=M)
  test-lean-diff               Differential fuzz against the Lean 4 reference specification
  test-fixtures-differential   Run differential tests for benchmark fixtures (ERC20, etc.)
  bench / bench-build          Run / build the self-contained ReleaseFast benchmark runner
  test-bench                   Check benchmark statistics, CLI, and workload construction
  shared / static              Build the C FFI shared / static library
  verify / verify-smt / verify-ir / verify-lean   Formal verification suite

Options:
  --release[=mode]             Release mode: fast, safe, small
  -Doptimize=[enum]            Debug, ReleaseSafe, ReleaseFast, ReleaseSmall
  -Dtest-filter=[string]       Filter tests by pattern (e.g., -Dtest-filter='ADD opcode')
  -Devm-hardfork=[string]      Enum tag (FRONTIER .. OSAKA, AMSTERDAM) or EEST name (Cancun); default OSAKA.
                               Invalid names are a compile error. Selects `DefaultEvm` via `getBuildConfig()`.
  -Devm-disable-gas=[bool]     Disable gas checks (Debug only; any other -Doptimize is a compile error)
  -Ddisable-balance-checks=[bool]  Disable balance checks (Debug only, same guard)
  -Devm-enable-fusion=[bool]   Enable bytecode fusion (default: true); `false` also runs state-tests with fusion off
  -Devm-optimize=[string]      fast, small or safe (default: safe); validated, exported as `optimize_strategy`
  -Denable-tracing=[bool]      Build DefaultEvm with the debug tracer
  -Dstrip=[bool]               Strip debug info from the FFI shared/static libraries (release.yml sets it)
