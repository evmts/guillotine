# Testing Guide

Complete guide to running tests, debugging failures, and writing new tests for Guillotine.

## Quick Start

```bash
# Build everything
zig build

# Run all tests (no output = all passed)
zig build test

# Run a specific test by name
zig build test-opcodes -Dtest-filter='ADD opcode'

# Run with debug output
zig build test-unit -Dtest-filter='stack'
```

**CRITICAL**: Zig tests produce NO OUTPUT when passing. No output = success.

## Test Organization

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          TEST HIERARCHY                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   zig build test                                                            │
│   │                                                                         │
│   ├── specs           Ethereum execution spec tests (~5000 cases)          │
│   │   └── test/specs/ethereum_specs_test.zig                               │
│   │                                                                         │
│   ├── test-integration  Integration tests                                   │
│   │   └── test/**/*.zig (aggregated via test/root.zig)                     │
│   │       ├── differential/   Compare with revm reference                   │
│   │       ├── fixtures/       JSON test fixtures                            │
│   │       └── evm/            Cross-module tests                            │
│   │                                                                         │
│   └── test-unit        Unit tests in source files                           │
│       └── src/**/*.zig (aggregated via src/root.zig)                       │
│           ├── frame.zig        Frame tests                                  │
│           ├── stack.zig        Stack tests                                  │
│           └── handlers_*.zig   Opcode tests                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Test Commands

| Command | What it runs | Use when |
|---------|--------------|----------|
| `zig build test` | All tests (specs → integration → unit) | CI, final check |
| `zig build specs` | Ethereum execution spec tests | Spec compliance |
| `zig build test-integration` | Integration tests | Cross-module testing |
| `zig build test-unit` | Unit tests in src/ | Quick iteration |
| `zig build test-lib` | Library tests in lib/ | External wrappers |
| `zig build test-opcodes` | Per-opcode differential tests | Opcode correctness |
| `zig build test-synthetic` | Synthetic opcode tests | Fusion testing |
| `zig build test-fusions` | Fusion optimization tests | Optimization testing |

### Test Filtering

```bash
# Run tests matching a pattern
zig build test-opcodes -Dtest-filter='ADD opcode'

# Multiple words (partial match)
zig build test-unit -Dtest-filter='stack push'

# Hardfork-specific
zig build specs -Devm-hardfork='SHANGHAI'

# Combine filters
zig build test-integration -Dtest-filter='storage' -Devm-hardfork='CANCUN'
```

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
│   $ cd execution-specs/src/ethereum/                                       │
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

```bash
# Run isolated test with maximum debug output
bun scripts/isolate-test.ts "test_name"

# Run subset by hardfork
bun scripts/test-subset.ts --hardfork CANCUN

# Run subset by EIP
bun scripts/test-subset.ts --eip 1153

# Auto-fix spec tests
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
// In handler
pub fn add(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
    // Add tracing
    const log = @import("log.zig");
    log.debug("ADD: stack[0]={} stack[1]={}", .{
        self.stack.peek_unsafe(0),
        self.stack.peek_unsafe(1),
    });

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
// In source file (src/module.zig)
test "ADD correctly adds two values" {
    const allocator = std.testing.allocator;

    var frame = try Frame.init(allocator, .{});
    defer frame.deinit();

    // Push operands (3 is top, 5 is second)
    try frame.stack.push(5);
    try frame.stack.push(3);

    // Execute
    try handlers.add(&frame);

    // Verify: 5 + 3 = 8
    try std.testing.expectEqual(@as(u256, 8), frame.stack.peek(0));
    try std.testing.expectEqual(@as(usize, 1), frame.stack.size());
}
```

### Integration Test Pattern

```zig
// In test/**/*.zig
test "ERC20 transfer executes correctly" {
    const allocator = std.testing.allocator;

    var evm = try Evm.init(allocator, .{});
    defer evm.deinit();

    // Set up contract
    try evm.setCode(contract_address, erc20_bytecode);
    try evm.setBalance(sender, 1000);

    // Execute transfer
    const result = try evm.call(.{
        .caller = sender,
        .address = contract_address,
        .calldata = transfer_calldata,
        .gas = 100000,
    });

    // Verify
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u256, 100), try evm.balanceOf(recipient));
}
```

### Differential Test Pattern

```zig
// In test/differential/*.zig
test "ADD matches revm implementation" {
    const allocator = std.testing.allocator;

    const bytecode = [_]u8{
        0x60, 0x05,  // PUSH1 5
        0x60, 0x03,  // PUSH1 3
        0x01,        // ADD
        0x00,        // STOP
    };

    // Execute in Guillotine
    const guillotine_result = try runGuillotine(allocator, &bytecode);
    defer allocator.free(guillotine_result.output);

    // Execute in revm (via FFI)
    const revm_result = try runRevm(allocator, &bytecode);
    defer allocator.free(revm_result.output);

    // Compare
    try std.testing.expectEqual(guillotine_result.gas_used, revm_result.gas_used);
    try std.testing.expectEqualSlices(u8, guillotine_result.output, revm_result.output);
}
```

### Spec Test Format

Ethereum execution spec tests use JSON fixtures:

```json
{
    "test_name": {
        "env": {
            "currentCoinbase": "0x2adc25665018aa1fe0e6bc666dac8fc2697ff9ba",
            "currentGasLimit": "0x1000000",
            "currentNumber": "0x1",
            "currentTimestamp": "0x3e8"
        },
        "pre": {
            "0x1000000000000000000000000000000000000001": {
                "balance": "0x0",
                "code": "0x6001600101",
                "nonce": "0x0",
                "storage": {}
            }
        },
        "exec": {
            "address": "0x1000000000000000000000000000000000000001",
            "caller": "0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b",
            "gas": "0x100000",
            "data": "0x",
            "value": "0x0"
        },
        "post": {
            "0x1000000000000000000000000000000000000001": {
                "storage": {
                    "0x0": "0x2"
                }
            }
        }
    }
}
```

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

    var frame = try Frame.init(allocator, .{});
    defer frame.deinit();

    // Push operands (3 is top, 5 is second)
    try frame.stack.push(5);
    try frame.stack.push(3);

    // Execute ADD
    try handlers.add(&frame);

    // Verify result
    try std.testing.expectEqual(@as(u256, 8), frame.stack.peek(0));
    try std.testing.expectEqual(@as(usize, 1), frame.stack.size());
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
├── evm/                    # Full EVM execution tests
│   ├── access_list_test.zig
│   ├── erc20_deploy_test.zig
│   ├── transfer_test.zig
│   └── snailtracer_test.zig
├── differential/           # Comparison with revm
│   ├── math_ops_test.zig
│   ├── stack_ops_test.zig
│   ├── storage_ops_test.zig
│   └── precompiles_test.zig
├── fusion/                 # Opcode fusion tests
├── fuzz/                   # Fuzz testing
├── eips_and_hardforks/     # EIP-specific tests
├── execution-spec-tests/   # Ethereum spec tests
└── official/               # Official Ethereum tests
```

### Mini EVM Tests

```
mini/test/
├── specs/
│   ├── runner.zig          # Test runner infrastructure
│   ├── test_host.zig       # Mock host implementation
│   └── assembler.zig       # Bytecode assembly
└── unit_test_helpers.zig   # Test utilities
```

## Build Options

```bash
# Hardfork selection
zig build test -Devm-hardfork=CANCUN

# Optimization level
zig build test -Doptimize=ReleaseSafe

# Disable gas checks (testing only)
zig build test -Devm-disable-gas=true

# Enable/disable fusion
zig build test -Devm-enable-fusion=true

# Test filtering
zig build test -Dtest-filter='storage'
```

## Expected Output

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          TEST OUTPUT EXPECTATIONS                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   PASS: No output at all                                                    │
│   ──────────────────────                                                    │
│   $ zig build test                                                          │
│   $                            ← Empty output = all passed                  │
│                                                                             │
│   FAIL: Error messages printed                                              │
│   ────────────────────────────                                              │
│   $ zig build test                                                          │
│   Test [1/10] test.my_test... FAIL                                         │
│   error: expected 8, found 5                                               │
│                                                                             │
│   If you see NO output, ALL tests passed!                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Troubleshooting

### "Module not found" Error

```
error: module 'primitives' not found
```

**Solution**: Use `zig build test`, not `zig test src/file.zig`

```bash
# WRONG
zig test src/frame.zig

# RIGHT
zig build test-unit -Dtest-filter='frame'
```

### Tests Hang

```
Possible causes:

1. Infinite loop in handler
   └── Check loop termination conditions
   └── Safety counter should trigger after 300M iterations

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
zig build test -Doptimize=Debug
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

```bash
# Run all mini tests
cd mini && zig build test

# Cancun-specific tests
zig build specs-cancun-tstore-basic
zig build specs-cancun-mcopy

# Hardfork specs
zig build specs-berlin
zig build specs-london
zig build specs-shanghai
zig build specs-cancun
```

## Safety Counter

The EVM includes a safety counter to prevent infinite loops:

```zig
const LOOP_QUOTA: u64 = 300_000_000;  // 300 million instructions

// Checked in each handler
if (self.instruction_counter >= LOOP_QUOTA) {
    return Error.InfiniteLoop;
}
self.instruction_counter += 1;
```

If tests hang, this will eventually trigger.
