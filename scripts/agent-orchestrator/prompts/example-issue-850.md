## Issue #850: MinimalEvm Error Swallowing in Selfdestruct Cleanup Can Corrupt State

### Overview

**Impact**: Silent state corruption, unreliable differential testing, potential fund loss if bugs go undetected

The MinimalEvm implementation has two critical issues:
1. SELFDESTRUCT pops beneficiary address but doesn't transfer balance
2. Error handling swallows errors silently with `catch {}`

---

### Technical Context

**Error Swallowing Patterns Found:**

```zig
// src/tracer/minimal_evm.zig:389
frame.execute() catch {
    // Error case - return failure (arena will clean up)
    return CallResult{
        .success = false,
        .gas_left = 0,
        .output = &[_]u8{},
    };
};
```

**SELFDESTRUCT Implementation (minimal_frame.zig:2001-2016):**

```zig
// SELFDESTRUCT
0xff => {
    const beneficiary = try self.popStack();
    _ = beneficiary;  // <-- UNUSED! Should transfer balance

    const gas_cost = self.selfdestructGasCost();
    try self.consumeGas(gas_cost);

    const refund = self.selfdestructRefund();
    if (refund > 0) {
        self.getEvm().gas_refund += refund;
    }

    self.stopped = true;
    // <-- Missing: balance transfer to beneficiary
    // <-- Missing: account deletion marking
    // <-- Missing: state update error handling
},
```

---

### Root Causes

1. **Incomplete SELFDESTRUCT** (minimal_frame.zig:2001-2016)
   - Beneficiary address popped but ignored
   - No balance transfer implemented
   - No account deletion marking

2. **Error Swallowing in Frame Execution** (minimal_evm.zig:389)
   - Catches all errors and returns generic failure
   - Loses specific error information
   - May leave state partially modified

---

### Key Files

- `src/tracer/minimal_frame.zig` - SELFDESTRUCT at lines 2001-2016
- `src/tracer/minimal_evm.zig` - Error handling at line 389
- `src/instructions/handlers_system.zig` - Reference implementation (correct behavior)

---

### Commands

```bash
# Build and verify
zig build && zig build test-opcodes

# Run SELFDESTRUCT opcode test
zig build test-opcodes -Dtest-filter='ff_test'

# Run selfdestruct integration tests
zig build test-integration -Dtest-filter='selfdestruct'

# Search for catch patterns
grep -rn "catch {}" src/tracer/ --include="*.zig"
```

---

### Constraints (from CLAUDE.md)

**ZERO TOLERANCE - These patterns are BANNED:**
```zig
// NEVER do this
something() catch {};
something() catch null;
something() catch &.{};

// Instead, propagate or handle explicitly
something() catch |err| {
    log.err("Operation failed: {}", .{err});
    return err;  // or return specific error
};
```

**Other Requirements:**
- Use `tracer.assert()` not `std.debug.assert`
- Use `log.debug/warn/err` not `std.debug.print`
- All changes must pass `zig build && zig build test-opcodes`
- Follow TDD: understand -> minimal repro -> fix -> verify

---

### Suggested Approach

**Phase 1: Understand**
1. Read `src/instructions/handlers_system.zig` selfdestruct handler
2. Understand how main EVM transfers balance
3. Identify MinimalEvm's balance management methods

**Phase 2: Fix SELFDESTRUCT**
1. Convert beneficiary u256 to Address
2. Get contract's current balance
3. Transfer balance to beneficiary
4. Handle errors properly (no catch {})

**Phase 3: Fix Error Handling**
1. Replace `catch {}` with `catch |err| { log.debug(...); ... }`
2. Add specific error types where needed

**Phase 4: Verify**
1. Run `zig build test-opcodes -Dtest-filter='ff_test'`
2. Run `zig build test-integration -Dtest-filter='selfdestruct'`
3. Ensure no new memory leaks

---

### Expected Deliverables

1. **Fixed SELFDESTRUCT** in minimal_frame.zig
   - Properly transfers balance to beneficiary
   - Returns error on storage failures

2. **Removed Error Swallowing** in minimal_evm.zig
   - Log errors before returning failure
   - Preserve error information for debugging

3. **Passing Tests**
   - All 623 opcode tests pass
   - SELFDESTRUCT differential tests pass

---

### CRITICAL: Handoff Protocol

Before context runs out, you MUST provide a handoff summary:

```
## Handoff Prompt for Issue #850

### Previous Progress
[What was accomplished]

### Current State
- Files modified: [list with descriptions]
- Tests passing: [yes/no]

### Remaining Tasks
1. [Task 1]
2. [Task 2]

### Key Context
[Important details for next agent]

### Commands
```bash
zig build && zig build test-opcodes
```

### Constraints
- Zero tolerance for error swallowing
- Use log.debug/warn/err for logging
```

The handoff prompt must be SELF-CONTAINED. The next agent will not have access to this conversation.
