# CLAUDE.md - EVM Fuzz Testing

⚠️ **CRITICAL: macOS ONLY** - `std.testing.fuzzInput()` requires macOS. Linux/Windows will fail.

## Purpose

**Find crashes, NOT correctness**: Segfaults, infinite loops, memory leaks, assertions, overflows.
**NOT testing**: EVM semantics, gas accuracy, state transitions, spec compliance.

## Mandatory Pattern

```zig
test "fuzz [component] [aspect]" {
    const input = std.testing.fuzzInput(.{});
    if (input.len < min_size) return;

    // Resource limits
    const safe_input = input[0..@min(input.len, MAX_SIZE)];

    // Setup with cleanup
    var component = Component.init(allocator, config) catch return;
    defer component.deinit();

    // ALL errors must be caught
    component.operation(safe_input) catch return;
}
```

## Resource Limits

```zig
const MAX_BYTECODE = 64 * 1024;  // 64KB
const MAX_GAS = 1_000_000;       // 1M
const STACK_SIZE = 1024;         // EVM standard
```

## Input Processing

```zig
// Multiple values
if (input.len < 64) return;
const a = std.mem.readInt(u256, input[0..32], .big);
const b = std.mem.readInt(u256, input[32..64], .big);

// Bytecode
const bytecode = input[0..@min(input.len, 1024)];
```

## Priority Components

1. **Planner** (CRITICAL): Bytecode analysis, PUSH lengths, jumps, cache, SIMD/scalar, fusion
2. **Journal**: Snapshot/revert sequences, nested scenarios, allocation failures
3. **Database**: Storage keys/values, balances, TLOAD/TSTORE
4. **Host**: CALL/DELEGATECALL/STATICCALL, CREATE/CREATE2, environment

## Expected Errors (catch all)

`OutOfGas`, `StackOverflow`, `StackUnderflow`, `OutOfMemory`, `InvalidJump`, `InvalidOpcode`, `AllocationError`

## Unacceptable

Crashes, panics, infinite loops, memory leaks

## Coverage Goals

Planner: 90%+, Journal: 95%+, Database: 85%+, Host: 80%+, Integration: 70%+

## Debug Failures

1. Capture seed: `--seed` flag
2. Minimize input
3. Find root cause
4. Add regression test
5. Fix and verify

## Checklist

- [ ] All ops have `catch`
- [ ] Input sizes limited
- [ ] Resources cleaned (`defer`)
- [ ] Name: `test "fuzz [component] [aspect]"`
- [ ] macOS-only noted
- [ ] No correctness assumptions

## Performance

- < 30 seconds typical
- Bounded memory
- No infinite loops
- Limited complexity

## CI/CD

- macOS runners only
- Not every commit (slow)
- Release quality gates
- Performance monitoring

*Fuzz for crashes, unit test for correctness.*