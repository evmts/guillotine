# Testing Guide

Complete guide to running tests, debugging failures, and writing new tests for Guillotine.

## Quick Start

```bash
# Build everything
zig build

# The gate CLAUDE.md requires for every code change (no output = all passed)
zig build test-opcodes

# Run tests whose names contain a string
zig build test-opcodes -Dtest-filter='ADD:'
zig build test-unit -Dtest-filter='Stack'
```

`zig build test` runs every suite, including the legacy `specs` suite, which
does not pass yet. CI runs `zig build`, `zig build test-unit` and
`zig build test-opcodes` (.github/workflows/ci.yml).

**CRITICAL**: Zig tests produce NO OUTPUT when passing. No output = success.

## Test Organization

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          TEST HIERARCHY                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   zig build test                                                            │
│   │                                                                         │
│   ├── specs           Legacy execution spec tests (not passing yet)         │
│   │   └── specs/cases/root.zig (generated test files)                       │
│   │                                                                         │
│   ├── test-integration  Integration tests                                   │
│   │   └── test/**/*.zig (aggregated via test/root.zig)                     │
│   │       ├── differential/   Compare with MinimalEvm                       │
│   │       ├── fixtures.zig    Runs bytecode from fixtures/<name>/           │
│   │       └── evm/            Cross-module tests                            │
│   │                                                                         │
│   ├── test-unit        Unit tests in source files                           │
│   │   └── src/**/*.zig (aggregated via src/root.zig)                       │
│   │       ├── frame/frame.zig  Frame tests                                  │
│   │       ├── stack/stack.zig  Stack tests                                  │
│   │       └── instructions/handlers_*.zig   Opcode tests                    │
│   │                                                                         │
│   └── test-lib         Library tests in lib/                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Test Commands

| Command | What it runs | Use when |
|---------|--------------|----------|
| `zig build test` | All tests (specs → integration → unit → lib) | Final check (fails until `specs` passes) |
| `zig build specs` | Legacy execution spec tests | Spec compliance |
| `zig build state-tests` | Official EEST state tests ([specs/README.md](../../specs/README.md)) | Spec compliance |
| `zig build test-integration` | Integration tests | Cross-module testing |
| `zig build test-unit` | Unit tests in src/ | Quick iteration |
| `zig build test-lib` | Library tests in lib/ | External wrappers |
| `zig build test-opcodes` | Per-opcode tests (most assert only a successful run; see below) | CI gate (CLAUDE.md) |
| `zig build test-opcodes-0xNN` | One opcode's tests (`test/evm/opcodes/NN_test.zig`) | Single opcode |
| `zig build test-synthetic` | Synthetic opcode tests | Fusion testing |
| `zig build test-fusions` | Fusion optimization tests | Optimization testing |

### Test Filtering

```bash
# Run tests whose names contain a substring
zig build test-opcodes -Dtest-filter='ADD:'

# Multiple words match as one substring
zig build test-unit -Dtest-filter='Stack push'

# Hardfork-specific (EEST state tests)
zig build state-tests -Dspec-fork=Shanghai

# Combine a fork with a name filter
zig build state-tests -Dspec-fork=Cancun -Dtest-filter='tstore'
```

Pass `-Dtest-filter` once. Zig rejects a repeated `-D` option ("received a list").
`-Devm-hardfork` is declared in build.zig but no code reads it; the hardfork is
the comptime field `EvmConfig.eips.hardfork` (default `OSAKA`).

## Debugging Failures

### Debugging Flowchart

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         TEST FAILURE DEBUGGING FLOWCHART                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Test Failed                                                               │
│   │                                                                         │
│   ▼                                                                         │
│   ┌───────────────────────────────────────────────────────────────────┐    │
│   │ What type of failure?                                             │    │
│   └───────────────────────────────────────────────────────────────────┘    │
│   │                                                                         │
│   ├── "Gas mismatch"                                                        │
│   │   │                                                                     │
│   │   └─▶ 1. Check operation gas cost                                      │
│   │       2. Check memory expansion cost                                    │
│   │       3. Check warm/cold access (EIP-2929)                             │
│   │       4. Check hardfork gas rules                                       │
│   │       └─▶ See: GAS-METERING.md                                         │
│   │                                                                         │
│   ├── "Stack mismatch"                                                      │
│   │   │                                                                     │
│   │   └─▶ 1. Check LIFO order (first pop = top)                            │
│   │       2. Check pop count matches opcode spec                            │
│   │       3. Check push value/size                                          │
│   │       4. Trace stack state before/after                                 │
│   │       └─▶ Add log.debug() in handler                                   │
│   │                                                                         │
│   ├── "Invalid jump destination"                                            │
│   │   │                                                                     │
│   │   └─▶ 1. Verify JUMPDEST at target PC                                  │
│   │       2. Check JUMPDEST analysis (push data masking)                   │
│   │       3. Verify jump target calculation                                 │
│   │       └─▶ See: ARCHITECTURE.md#bytecode-analysis                       │
│   │                                                                         │
│   ├── "Storage mismatch"                                                    │
│   │   │                                                                     │
│   │   └─▶ 1. Check original vs current value tracking                      │
│   │       2. Verify journal rollback on REVERT                             │
│   │       3. Check transient vs persistent storage                         │
│   │       └─▶ See: STATE-MANAGEMENT.md                                     │
│   │                                                                         │
│   ├── "Out of gas"                                                          │
│   │   │                                                                     │
│   │   └─▶ 1. Calculate intrinsic gas                                       │
│   │       2. Check SSTORE 0→non-zero (20000 gas)                           │
│   │       3. Check memory expansion                                         │
│   │       4. Check cold access costs                                        │
│   │       └─▶ See: GAS-METERING.md#common-out-of-gas-causes                │
│   │                                                                         │
│   └── "Tracer divergence"                                                   │
│       │                                                                     │
│       └─▶ 1. Frame and MinimalEvm out of sync                              │
│           2. Missing beforeInstruction() call                               │
│           3. Synthetic opcode step count mismatch                          │
│           └─▶ See: ../performance/TRACER.md                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Step-by-Step Debugging Workflow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         DEBUGGING WORKFLOW                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Step 1: Identify the failing test                                         │
│   ──────────────────────────────────                                        │
│   $ zig build specs                                                         │
│   Test [42/1000] test.stTransStorage_Cancun... FAIL                        │
│                                                                             │
│   Step 2: Isolate with filter                                               │
│   ───────────────────────────────                                           │
│   $ zig build specs -Dtest-filter='stTransStorage_Cancun'                  │
│                                                                             │
│   Step 3: For Mini EVM, use isolate script                                  │
│   ──────────────────────────────────────────                                │
│   $ cd mini                                                                 │
│   $ bun scripts/isolate-test.ts "stTransStorage_Cancun"                    │
│                                                                             │
│   Step 4: Read the trace output                                             │
│   ─────────────────────────────                                             │
│   Look for:                                                                 │
│   • Divergence point (PC, opcode)                                           │
│   • Gas values before/after                                                 │
│   • Stack state                                                             │
│   • Storage keys accessed                                                   │
│                                                                             │
│   Step 5: Find reference implementation                                     │
│   ─────────────────────────────────────                                     │
│   $ cd specs/execution-specs/src/ethereum/forks/   (git submodule)         │
│   $ grep -r "def tstore" cancun/vm/instructions/                           │
│                                                                             │
│   Step 6: Compare implementations                                           │
│   ─────────────────────────────────                                         │
│   Open both:                                                                │
│   • src/instructions/handlers_storage.zig                                  │
│   • execution-specs/.../instructions/storage.py                            │
│                                                                             │
│   Step 7: Fix and verify                                                    │
│   ─────────────────────────                                                 │
│   Make fix, run same filter:                                                │
│   $ zig build specs -Dtest-filter='stTransStorage_Cancun'                  │
│   No output = fixed!                                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Isolating Failures

These Mini EVM scripts live in `mini/scripts/`; run them from `mini/`.

```bash
cd mini

# Run isolated test with maximum debug output
bun scripts/isolate-test.ts "test_name"

# Run the spec tests whose names contain a string (one positional filter)
bun scripts/test-subset.ts Cancun
bun scripts/test-subset.ts transientStorage

# Automated fixer: runs a Claude Agent SDK pipeline and commits fixes
bun scripts/fix-specs.ts
```

### Debug Logging

```zig
// Enable debug logging in tests
test "my test" {
    std.testing.log_level = .debug;

    // Debug output will appear if test FAILS
    log.debug("State: {}", .{state});
}
```

**IMPORTANT**: Even with debug logging enabled, passing tests produce NO output. Debug logs only appear on FAILURE.

### Adding Trace Points

```zig
// src/instructions/handlers_arithmetic.zig already imports log:
// const log = @import("../log.zig");
pub fn add(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
    // Add tracing: get_slice()[0] is the top of the stack
    const items = self.stack.get_slice();
    log.debug("ADD: top={} second={}", .{ items[0], items[1] });

    // ... rest of handler
}
```

## Common Failure Types

### 1. Gas Mismatch

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ ERROR: Gas mismatch                                                         │
│ Expected: 79991                                                             │
│ Got:      79888                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

Diagnosis checklist:
─────────────────────

□ Static gas cost correct?
  └── Check GasConstants for opcode tier

□ Dynamic gas calculated correctly?
  └── Memory expansion: 3*words + words²/512
  └── SSTORE: original vs current vs new
  └── EXP: 10 + 50*byte_length

□ Warm/cold access (Berlin+)?
  └── First SLOAD: 2100 (cold)
  └── Second SLOAD: 100 (warm)

□ Hardfork-specific?
  └── Pre-Berlin: flat costs
  └── London+: reduced refund cap
  └── Shanghai+: warm coinbase
```

### 2. Stack Mismatch

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ ERROR: Stack mismatch at position 0                                         │
│ Expected: 0x8                                                               │
│ Got:      0x5                                                               │
└─────────────────────────────────────────────────────────────────────────────┘

Diagnosis checklist:
─────────────────────

□ LIFO order correct?
  └── First pop returns TOP of stack (most recent push)
  └── ADD: pop b (top), pop a (second), push a+b

□ Operation semantics correct?
  └── Check Yellow Paper for exact behavior
  └── Verify signed vs unsigned operations

□ Stack depth tracking correct?
  └── Each opcode changes stack by: delta = pushed - popped
```

### 3. Invalid Jump

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ ERROR: Invalid jump destination at PC=42                                    │
└─────────────────────────────────────────────────────────────────────────────┘

Diagnosis checklist:
─────────────────────

□ Is there a JUMPDEST at PC=42?
  └── Check bytecode[42] == 0x5B

□ Is it valid (not inside PUSH data)?
  └── Bytecode: [60 5B ...] - 0x5B at PC=1 is PUSH1 data, not JUMPDEST
  └── JUMPDEST analysis should mark PC=1 as invalid

□ Is jump target calculation correct?
  └── JUMP: pop target from stack, verify JUMPDEST
  └── JUMPI: pop target AND condition, jump if condition != 0
```

### 4. Storage Mismatch

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ ERROR: Storage mismatch for slot 0x1                                        │
│ Expected: 0x42                                                              │
│ Got:      0x0                                                               │
└─────────────────────────────────────────────────────────────────────────────┘

Diagnosis checklist:
─────────────────────

□ SSTORE executed correctly?
  └── Check value was written to correct slot

□ Revert handling correct?
  └── On REVERT, storage changes should roll back
  └── Check journal restore logic

□ Transient vs persistent?
  └── TSTORE writes to transient storage
  └── SSTORE writes to persistent storage
  └── Don't mix them up!

□ Address correct?
  └── Storage is per-contract
  └── Check contract address matches
```

### 5. Tracer Divergence

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ ERROR: Tracer divergence                                                    │
│ Frame PC: 10                                                                │
│ MinimalEvm PC: 8                                                            │
└─────────────────────────────────────────────────────────────────────────────┘

Diagnosis checklist:
─────────────────────

□ Handler calls beforeInstruction()?
  └── EVERY handler MUST call self.beforeInstruction(.OPCODE, cursor)

□ Synthetic opcode step count correct?
  └── PUSH_ADD_INLINE = 2 MinimalEvm steps
  └── FUNCTION_DISPATCH = 4 MinimalEvm steps

□ Cursor vs PC confusion?
  └── Frame uses cursor (schedule index)
  └── MinimalEvm uses PC (bytecode index)
  └── These do NOT correspond 1:1
```

## Writing Tests

### Unit Test Pattern

```zig
// In the source file under test (here src/stack/stack.zig)
test "binary_op_unsafe adds the top two items" {
    const allocator = std.testing.allocator;
    const StackType = Stack(.{});

    var stack = try StackType.init(allocator, null);
    defer stack.deinit(allocator);

    // Push operands (3 is top, 5 is second)
    try stack.push(5);
    try stack.push(3);

    // Execute
    stack.binary_op_unsafe(struct {
        fn op(top: u256, second: u256) u256 {
            return top +% second;
        }
    }.op);

    // Verify: 5 + 3 = 8
    try std.testing.expectEqual(@as(u256, 8), try stack.peek());
    try std.testing.expectEqual(@as(usize, 1), stack.size());
}
```

Performance handlers tail-call the next handler and never return, so tests
exercise them by running bytecode through `Evm.call` (see below), not by
calling a handler directly.

### Integration Test Pattern

```zig
// In test/**/*.zig (condensed from test/evm/transfer_test.zig)
const evm = @import("evm");
const primitives = @import("voltaire");
const DefaultEvm = evm.Evm(.{});

test "value transfer succeeds" {
    const allocator = std.testing.allocator;

    var database = evm.Database.init(allocator);
    defer database.deinit();
    try database.set_account(sender.bytes, .{
        .balance = 1_000_000_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    var vm = try DefaultEvm.init(allocator, &database, block_info, tx_context, 0, sender);
    defer vm.deinit();

    var result = vm.call(.{ .call = .{
        .caller = sender,
        .to = recipient,
        .input = &.{},
        .value = 100,
        .gas = 100_000,
    } });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    const account = (try database.get_account(recipient.bytes)).?;
    try std.testing.expectEqual(@as(u256, 100), account.balance);
}
```

### Differential Test Pattern

`test/differential/` runs the same bytecode through the Performance EVM and
MinimalEvm (`src/tracer/minimal_evm.zig`) and compares the results. revm is no
longer used (src/modules.build.zig).

```zig
// In test/differential/*.zig (from stop_opcode_test.zig)
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

test "differential: PUSH1 5 PUSH1 3 ADD" {
    const allocator = std.testing.allocator;

    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    const bytecode = [_]u8{
        0x60, 0x05,  // PUSH1 5
        0x60, 0x03,  // PUSH1 3
        0x01,        // ADD
        0x00,        // STOP
    };

    // Fails the test if success, gas, output or trace differ
    try testor.test_bytecode(&bytecode);
}
```

The per-opcode tests in `test/evm/opcodes/NN_test.zig` (`zig build test-opcodes`)
run bytecode through `evm.Evm` in Debug. As of 2026-11-23, 127 of the 138 files
contain no `expect` call, so they catch crashes, leaks and logged errors but not
wrong results. The tracer's MinimalEvm validation is off by default
(`TracerConfig.enable_validation = false`).

### Spec Test Format

`zig build state-tests` reads official pre-filled EEST state test fixtures
(fetch them with `scripts/fetch-eest-fixtures.sh`). Each case lists the
expected post-state root and logs hash per fork:

```json
{
    "<file>::<test name>": {
        "env": {
            "currentCoinbase": "0x2adc25665018aa1fe0e6bc666dac8fc2697ff9ba",
            "currentGasLimit": "0x05f5e100",
            "currentNumber": "0x01",
            "currentTimestamp": "0x03e8",
            "currentBaseFee": "0x0a"
        },
        "pre": {
            "0x1000000000000000000000000000000000000001": {
                "balance": "0x00",
                "code": "0x6001600101600055",
                "nonce": "0x00",
                "storage": {}
            }
        },
        "transaction": {
            "data": ["0x"],
            "gasLimit": ["0x0186a0"],
            "gasPrice": "0x0a",
            "nonce": "0x00",
            "to": "0x1000000000000000000000000000000000000001",
            "value": ["0x00"],
            "secretKey": "0x45a915e4d060149eb4365960e6a7a45f334393093061116b197e3240065ff2d8"
        },
        "post": {
            "Cancun": [
                {
                    "hash": "0x<post-state root>",
                    "logs": "0x<RLP logs hash>",
                    "indexes": { "data": 0, "gas": 0, "value": 0 }
                }
            ]
        }
    }
}
```

A case passes when the post-state root equals `hash` and the logs hash equals
`logs`. See [specs/README.md](../../specs/README.md) for the runner, its flags
and the current pass rate.

## Test Philosophy

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          TEST PHILOSOPHY                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   DO:                                                                       │
│   ───                                                                       │
│   ✓ Self-contained tests (no shared state)                                 │
│   ✓ Copy/paste setup (avoid abstractions)                                  │
│   ✓ Test one thing per test                                                │
│   ✓ Use descriptive test names                                             │
│   ✓ Fix failures immediately                                               │
│   ✓ Evidence-based debugging only                                          │
│                                                                             │
│   DON'T:                                                                    │
│   ──────                                                                    │
│   ✗ Create test helpers/abstractions                                       │
│   ✗ Share state between tests                                              │
│   ✗ Skip or comment out failing tests                                      │
│   ✗ Guess at fixes without evidence                                        │
│   ✗ Leave tests in broken state                                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Why No Abstractions?

```zig
// BAD: Shared helper hides complexity
test "add works" {
    try runOpTest(.ADD, &[_]u256{5, 3}, &[_]u256{8});
}

// GOOD: Self-contained, explicit
test "ADD: 5 + 3 = 8" {
    const allocator = std.testing.allocator;
    const StackType = Stack(.{});

    var stack = try StackType.init(allocator, null);
    defer stack.deinit(allocator);

    // Push operands (3 is top, 5 is second)
    try stack.push(5);
    try stack.push(3);

    // Execute ADD
    stack.binary_op_unsafe(struct {
        fn op(top: u256, second: u256) u256 {
            return top +% second;
        }
    }.op);

    // Verify result
    try std.testing.expectEqual(@as(u256, 8), try stack.peek());
    try std.testing.expectEqual(@as(usize, 1), stack.size());
}
```

Benefits:
- Clear what's being tested
- Easy to debug (no hidden state)
- Copy-paste to create variations
- No "magic" to understand

## Test Structure

### Performance EVM Tests

```
test/
├── root.zig                # Integration test root (zig build test-integration)
├── evm/                    # Full EVM execution tests
│   ├── access_list_test.zig
│   ├── erc20_deployment_issue.zig
│   ├── transfer_test.zig
│   └── opcodes/            # Per-opcode tests (zig build test-opcodes)
├── differential/           # Comparison with MinimalEvm
│   ├── math_operations_test.zig
│   ├── stack_operations_test.zig
│   ├── storage_operations_test.zig
│   └── precompiles_test.zig
├── fusion/                 # Opcode fusion tests
├── fuzz/                   # Fuzz targets (zig build test-fuzz)
├── eips_and_hardforks/     # EIP override tests
├── provider/               # RPC provider tests
└── official/               # Execution-spec fixture smoke tests (zig build test-official)
```

Spec runners live in `specs/`, not `test/` (see [specs/README.md](../../specs/README.md)).

### Mini EVM Tests

```
mini/test/
├── specs/
│   ├── root.zig            # Spec test root
│   ├── runner.zig          # Test runner infrastructure
│   ├── test_host.zig       # Mock host implementation
│   └── assembler.zig       # Bytecode assembly
├── fuzz/                   # Fuzz tests (zig build test-mini-fuzz)
└── unit_test_helpers.zig   # Test utilities
```

## Build Options

```bash
# Optimization level
zig build test-unit -Doptimize=ReleaseSafe

# Test filtering (pass once; a repeated -D option fails)
zig build test-unit -Dtest-filter='storage'

# Fork selection for EEST state tests
zig build state-tests -Dspec-fork=Cancun,Prague

# Instruction tracing (the only -D EVM option code reads)
zig build test-unit -Denable-tracing=true
```

build.zig also declares `-Devm-hardfork`, `-Devm-enable-fusion`,
`-Devm-disable-gas`, `-Devm-optimize`, `-Ddisable-tailcall-dispatch`,
`-Ddisable-balance-checks` and the size and limit options (`-Dstack-size`,
`-Dmemory-limit`, ...), but no code reads them. Change behavior through the
comptime `EvmConfig` fields in src/evm_config.zig instead:

```zig
const Engine = evm.Evm(.{
    .eips = .{ .hardfork = .CANCUN },  // default OSAKA
    .enable_fusion = false,            // default true
    .disable_gas_checks = true,        // default false
});
```

## Expected Output

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          TEST OUTPUT EXPECTATIONS                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   PASS: No output at all                                                    │
│   ──────────────────────                                                    │
│   $ zig build test-opcodes                                                  │
│   $                            ← Empty output = all passed                  │
│                                                                             │
│   FAIL: Error messages printed                                              │
│   ────────────────────────────                                              │
│   $ zig build test-opcodes                                                  │
│   Test [1/10] test.my_test... FAIL                                         │
│   error: expected 8, found 5                                               │
│                                                                             │
│   If you see NO output, ALL tests passed!                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Troubleshooting

### "Module not found" Error

`zig test` on a single source file fails to resolve imports such as
`@import("voltaire")`, because only build.zig wires up those modules.

**Solution**: Use a `zig build` test step, not `zig test src/file.zig`

```bash
# WRONG
zig test src/frame/frame.zig

# RIGHT
zig build test-unit -Dtest-filter='frame'
```

### Tests Hang

```
Possible causes:

1. Infinite loop in handler
   └── Check loop termination conditions
   └── In Debug and ReleaseSafe, the tracer's safety counter panics after 300M instructions

2. Blocking on stdin
   └── Tests should not require input
   └── Remove any blocking operations

3. Deadlock
   └── Check mutex/lock ordering
   └── Use defer for unlock
```

### Memory Leaks

```bash
# Run with leak detection (automatic with std.testing.allocator)
zig build test-unit -Doptimize=Debug
```

```zig
test "no memory leaks" {
    // std.testing.allocator detects leaks automatically
    const allocator = std.testing.allocator;

    var thing = try Thing.init(allocator);
    // MUST call deinit, or allocator will fail test
    defer thing.deinit();

    // If you forget defer, you'll see:
    // "error: memory leak detected"
}
```

### Flaky Tests

```
Test sometimes passes, sometimes fails:

1. Uninitialized memory
   └── Always initialize all fields
   └── Use = undefined only when intentional

2. Order dependence
   └── Tests should be independent
   └── Don't rely on execution order

3. Race condition
   └── Avoid shared mutable state
   └── Use proper synchronization
```

## Mini EVM Specific Commands

Run these from `mini/` (mini has its own build.zig). From the repository root,
`zig build test-mini`, `test-mini-specs`, `test-mini-full` and `test-mini-fuzz`
wrap them.

```bash
cd mini

# Run all mini tests (spec tests need Python and uv)
zig build test

# Cancun-specific tests
zig build specs-cancun-tstore-basic
zig build specs-cancun-mcopy

# Hardfork specs (frontier, homestead, byzantium, constantinople, istanbul,
# berlin, paris, shanghai, cancun, prague, osaka)
zig build specs-berlin
zig build specs-shanghai
zig build specs-cancun
zig build specs-prague
```

## Safety Counter

Two counters stop runaway execution:

- **Performance EVM**: the tracer's `instruction_safety` counter
  (`SafetyCounter(u64, .enabled)` from src/internal/safety_counter.zig)
  increments in `Tracer.before_instruction` and panics at 300,000,000
  instructions. Handlers call it through `beforeInstruction`, which runs only in
  Debug and ReleaseSafe builds.
- **Mini EVM**: `Frame.execute` returns `error.ExecutionTimeout` after
  `config.loop_quota` iterations (1,000,000 in Debug and ReleaseSafe, no limit
  otherwise).

```zig
// src/internal/safety_counter.zig
pub fn inc(self: *Self) void {
    if (mode == .disabled) return;
    self.count += 1;
    if (self.count >= self.limit) {
        // logs the count and limit, then:
        @panic("EVM instruction limit exceeded - possible infinite loop or excessive bytecode execution");
    }
}
```

If tests hang in a Debug build, the panic eventually fires.
