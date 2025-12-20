# Code Review: bytecode.zig

**File:** `/Users/williamcory/guillotine-mini/src/bytecode.zig`
**Review Date:** 2025-10-26
**Lines of Code:** 188 (including tests)

---

## Executive Summary

The `bytecode.zig` module provides bytecode analysis and utilities for EVM execution, specifically jump destination validation and immediate value reading for PUSH operations. The implementation is **generally sound** with good test coverage, but has several areas requiring attention:

- **2 Critical Issues** (integer overflow risks)
- **1 Potential Bug** (PUSH0 edge case)
- **3 Code Quality Improvements** needed
- **2 Missing Test Cases**
- **1 API Design Consideration**

---

## 1. Critical Issues

### 1.1 Integer Overflow Risk in `analyzeJumpDests`

**Location:** Lines 75-98
**Severity:** CRITICAL
**Impact:** Could cause infinite loop or crash on malicious bytecode

**Issue:**
```zig
fn analyzeJumpDests(code: []const u8, valid_jumpdests: *std.AutoArrayHashMap(u32, void)) !void {
    var pc: u32 = 0;

    while (pc < code.len) {
        const opcode = code[pc];

        if (opcode == 0x5b) {
            try valid_jumpdests.put(pc, {});
            pc += 1;
        } else if (opcode >= 0x60 and opcode <= 0x7f) {
            const push_size = opcode - 0x5f;
            pc += 1 + push_size;  // ⚠️ POTENTIAL OVERFLOW
        } else {
            pc += 1;
        }
    }
}
```

**Problem:**
- `pc` is `u32`, `push_size` is `u8` (max 32)
- Line 93: `pc += 1 + push_size` can overflow if:
  - `pc > (2^32 - 33)` (extremely large bytecode near 4GB)
  - After overflow, `pc` wraps to small value, `pc < code.len` is still true
  - Loop continues, potentially infinite

**Attack Vector:**
```
Bytecode at position 0xFFFFFFFC (4GB - 4):
  0x7F (PUSH32) + 32 bytes of data
  pc = 0xFFFFFFFC
  pc += 1 + 32 = 0xFFFFFFFD + 32 = wraps to 0x0000001D
  Loop continues from beginning!
```

**Recommendation:**
```zig
// Option 1: Use saturating arithmetic
const new_pc = @min(pc + 1 + push_size, code.len);
pc = new_pc;

// Option 2: Check before addition
if (pc > code.len - 1 - push_size) {
    // Truncated PUSH at end of bytecode, stop analysis
    break;
}
pc += 1 + push_size;

// Option 3: Use usize instead of u32 (matches code.len type)
var pc: usize = 0;
```

**Note:** In practice, EVM bytecode is limited to 24KB (EIP-170), so this is theoretical. However, defensive programming is critical for VM implementations.

### 1.2 Integer Overflow Risk in `readImmediate`

**Location:** Lines 52-68
**Severity:** MEDIUM-HIGH
**Impact:** Could return incorrect values or crash

**Issue:**
```zig
pub fn readImmediate(self: *const Bytecode, pc: u32, size: u8) ?u256 {
    const pc_usize: usize = @intCast(pc);
    const size_usize: usize = size;

    // Check if we have enough bytes: current position + 1 (opcode) + size
    if (pc_usize + 1 + size_usize > self.code.len) {
        return null;
    }

    var result: u256 = 0;
    var i: u8 = 0;
    while (i < size) : (i += 1) {
        const idx: usize = pc_usize + 1 + i;  // ⚠️ SAFE DUE TO BOUNDS CHECK
        result = (result << 8) | self.code[idx];
    }
    return result;
}
```

**Problem:**
- Line 65: `result << 8` could overflow if `size > 32` (since u256 is 32 bytes)
- Currently safe because callers pass `size = opcode - 0x5f` (1-32), but:
  - No validation that `size <= 32`
  - API allows arbitrary `size: u8` (0-255)
  - Future refactoring could introduce bugs

**Attack Scenarios:**
```zig
// Scenario 1: Caller passes size > 32
bytecode.readImmediate(0, 40);  // 40 bytes into 32-byte u256
// Result: Overflow, returns incorrect value (higher bytes lost)

// Scenario 2: Malicious bytecode with invalid PUSH opcode
// Bytecode: [0xFF, 0x01, 0x02, ...]  (0xFF is not a valid opcode)
// If handler treats 0xFF as PUSH160, size = 0xFF - 0x5F = 160
// readImmediate(0, 160) -> overflow
```

**Recommendation:**
```zig
pub fn readImmediate(self: *const Bytecode, pc: u32, size: u8) ?u256 {
    // Validate size (u256 is 32 bytes max)
    if (size > 32) return null;  // ← ADD THIS CHECK

    const pc_usize: usize = @intCast(pc);
    const size_usize: usize = size;

    if (pc_usize + 1 + size_usize > self.code.len) {
        return null;
    }

    var result: u256 = 0;
    var i: u8 = 0;
    while (i < size) : (i += 1) {
        const idx: usize = pc_usize + 1 + i;
        result = (result << 8) | self.code[idx];
    }
    return result;
}
```

---

## 2. Potential Bugs

### 2.1 PUSH0 Edge Case (Shanghai+)

**Location:** Lines 84-93
**Severity:** LOW-MEDIUM
**Impact:** Potential misclassification of jump destinations

**Issue:**
```zig
} else if (opcode >= 0x60 and opcode <= 0x7f) {
    // PUSH1 (0x60) through PUSH32 (0x7f)
    const push_size = opcode - 0x5f;
    pc += 1 + push_size;
} else {
    // All other opcodes are single byte
    pc += 1;
}
```

**Problem:**
- PUSH0 (0x5F, introduced in Shanghai) pushes zero without immediate data
- Current code: `0x5F >= 0x60` is FALSE, so falls through to `else` branch (correct!)
- However, this is implicit behavior that's easy to break

**Risk:**
If someone "fixes" the PUSH range to be `>= 0x5f` (reasonable-looking change):
```zig
} else if (opcode >= 0x5f and opcode <= 0x7f) {  // ⚠️ BREAKS PUSH0
    const push_size = opcode - 0x5f;  // PUSH0: 0x5F - 0x5F = 0 (correct!)
    pc += 1 + push_size;  // pc += 1 + 0 = pc + 1 (correct!)
}
```

Actually, the "fix" would work correctly (PUSH0 has `size = 0`), so this is **not a bug**, but the current range `0x60..0x7f` is confusing.

**Recommendation:**
```zig
} else if (opcode >= 0x5f and opcode <= 0x7f) {
    // PUSH0 (0x5f) through PUSH32 (0x7f)
    // PUSH0 introduced in Shanghai, pushes 0 with no immediate data
    const push_size = opcode - 0x5f;  // PUSH0 = 0, PUSH1 = 1, ..., PUSH32 = 32
    pc += 1 + push_size;
}
```

This makes the code more explicit and handles PUSH0 correctly (even though current code works by accident).

---

## 3. Code Quality Issues

### 3.1 Inconsistent Integer Types

**Location:** Throughout
**Severity:** LOW
**Impact:** Code clarity, potential conversion bugs

**Issue:**
- `pc` is `u32` in most places
- `code.len` is `usize` (platform-dependent: u32 on 32-bit, u64 on 64-bit)
- Frequent conversions required:

```zig
// Line 53-54
const pc_usize: usize = @intCast(pc);
const size_usize: usize = size;

// Line 44
if (pc >= self.code.len) {  // Comparing u32 to usize
```

**Recommendation:**
Use `usize` consistently for all bytecode indexing:
```zig
pub const Bytecode = struct {
    code: []const u8,
    valid_jumpdests: std.AutoArrayHashMap(usize, void),  // ← Change to usize

    pub fn isValidJumpDest(self: *const Bytecode, pc: usize) bool {
        return self.valid_jumpdests.contains(pc);
    }

    pub fn getOpcode(self: *const Bytecode, pc: usize) ?u8 {
        if (pc >= self.code.len) {
            return null;
        }
        return self.code[pc];
    }

    pub fn readImmediate(self: *const Bytecode, pc: usize, size: u8) ?u256 {
        if (size > 32) return null;
        if (pc + 1 + size > self.code.len) {
            return null;
        }
        // ... no conversions needed
    }
};
```

**Rationale:**
- `usize` is the natural type for array/slice indexing in Zig
- Eliminates conversions and potential truncation bugs
- Matches the type of `code.len`
- EVM's `pc` fits in `usize` on all platforms (max bytecode ~24KB)

### 3.2 Missing Opcode Constants

**Location:** Lines 81, 84-89
**Severity:** LOW
**Impact:** Code readability, maintenance

**Issue:**
Magic numbers used directly:
```zig
if (opcode == 0x5b) {  // What is 0x5b?
    // ...
} else if (opcode >= 0x60 and opcode <= 0x7f) {  // PUSH range?
    const push_size = opcode - 0x5f;  // Why 0x5f?
```

**Recommendation:**
```zig
const JUMPDEST: u8 = 0x5b;
const PUSH0: u8 = 0x5f;
const PUSH1: u8 = 0x60;
const PUSH32: u8 = 0x7f;

fn analyzeJumpDests(...) !void {
    // ...
    if (opcode == JUMPDEST) {
        try valid_jumpdests.put(pc, {});
        pc += 1;
    } else if (opcode >= PUSH0 and opcode <= PUSH32) {
        const push_size = opcode - PUSH0;
        pc += 1 + push_size;
    } else {
        pc += 1;
    }
}
```

**Note:** Check if these constants already exist in `src/opcode.zig` and import them if so.

### 3.3 Redundant Type Conversion in `readImmediate`

**Location:** Lines 53-54
**Severity:** TRIVIAL
**Impact:** Negligible

**Issue:**
```zig
const pc_usize: usize = @intCast(pc);
const size_usize: usize = size;  // ← u8 to usize doesn't need @intCast
```

**Fix:**
```zig
const pc_usize: usize = @intCast(pc);
const size_usize: usize = @as(usize, size);  // Or just: const size_usize = size;
```

In Zig, `u8` to `usize` is a widening conversion (always safe), so `@intCast` is unnecessary. However, if you switch `pc` to `usize` (recommendation 3.1), this goes away entirely.

---

## 4. Missing Test Coverage

### 4.1 Edge Case: Empty Bytecode

**Missing Test:**
```zig
test "analyzeJumpDests: empty bytecode" {
    const code = [_]u8{};
    var valid_jumpdests = std.AutoArrayHashMap(u32, void).init(std.testing.allocator);
    defer valid_jumpdests.deinit();

    try analyzeJumpDests(&code, &valid_jumpdests);
    try std.testing.expectEqual(@as(usize, 0), valid_jumpdests.count());
}

test "Bytecode: empty bytecode operations" {
    const code = [_]u8{};
    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit();

    try std.testing.expectEqual(@as(usize, 0), bytecode.len());
    try std.testing.expect(bytecode.getOpcode(0) == null);
    try std.testing.expect(bytecode.readImmediate(0, 1) == null);
}
```

### 4.2 Edge Case: Truncated PUSH at End

**Missing Test:**
```zig
test "analyzeJumpDests: truncated PUSH at end" {
    const code = [_]u8{
        0x60, 0x01, // PUSH1 0x01 (complete)
        0x61, 0xff, // PUSH2 0xff?? (truncated - missing 1 byte)
    };
    var valid_jumpdests = std.AutoArrayHashMap(u32, void).init(std.testing.allocator);
    defer valid_jumpdests.deinit();

    try analyzeJumpDests(&code, &valid_jumpdests);

    // Should not crash, should handle gracefully
    // Currently: pc = 0, pc += 1 = 1, pc += 1 = 2, pc += 1 + 2 = 5 > len, exits
    // This is correct behavior! But should be explicitly tested.
}

test "Bytecode: readImmediate with truncated data" {
    const code = [_]u8{ 0x61, 0xff }; // PUSH2 but only 1 byte follows

    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit();

    // Should return null (not enough data)
    try std.testing.expect(bytecode.readImmediate(0, 2) == null);
}
```

### 4.3 Edge Case: PUSH0 (Shanghai)

**Missing Test:**
```zig
test "analyzeJumpDests: PUSH0 followed by JUMPDEST" {
    const code = [_]u8{
        0x5f, // PUSH0 (no immediate data)
        0x5b, // JUMPDEST (should be valid)
    };
    var valid_jumpdests = std.AutoArrayHashMap(u32, void).init(std.testing.allocator);
    defer valid_jumpdests.deinit();

    try analyzeJumpDests(&code, &valid_jumpdests);

    // PUSH0 at position 0 should not be in jumpdests
    // JUMPDEST at position 1 should be valid
    try std.testing.expect(!valid_jumpdests.contains(0));
    try std.testing.expect(valid_jumpdests.contains(1));
}
```

### 4.4 Boundary Test: Maximum PUSH Size

**Missing Test:**
```zig
test "Bytecode: readImmediate size validation" {
    const code = [_]u8{ 0x7f } ++ [_]u8{0xFF} ** 32; // PUSH32 with 32 bytes
    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit();

    // Should succeed for size <= 32
    try std.testing.expect(bytecode.readImmediate(0, 32) != null);

    // Should fail for size > 32 (if validation added)
    try std.testing.expect(bytecode.readImmediate(0, 33) == null);
}
```

---

## 5. API Design Considerations

### 5.1 Should `readImmediate` Take Opcode Instead of Size?

**Current API:**
```zig
pub fn readImmediate(self: *const Bytecode, pc: u32, size: u8) ?u256
```

**Usage in frame.zig:**
```zig
// handlers_stack.zig:36
const value = frame.readImmediate(push_size) orelse return error.InvalidPush;
```

**Alternative API:**
```zig
pub fn readPushImmediate(self: *const Bytecode, pc: u32, opcode: u8) ?u256 {
    // Validate opcode is a PUSH instruction
    if (opcode < 0x5f or opcode > 0x7f) return null;

    const size = opcode - 0x5f;
    // ... rest of implementation
}
```

**Pros:**
- Encapsulates PUSH opcode logic (size = opcode - 0x5f)
- Validates opcode is actually a PUSH instruction
- Clearer intent: "read the immediate value for this PUSH opcode"

**Cons:**
- Less flexible (can't use for other purposes)
- Current API is more general-purpose

**Recommendation:**
Keep current API (more flexible), but add opcode validation in the caller (handlers_stack.zig).

### 5.2 Should `Bytecode` Be Opaque?

**Current Design:**
```zig
pub const Bytecode = struct {
    code: []const u8,  // ← Publicly accessible
    valid_jumpdests: std.AutoArrayHashMap(u32, void),  // ← Publicly accessible
};
```

**Usage in handlers_context.zig:178:**
```zig
const byte = frame.bytecode.getOpcode(src_idx_u32) orelse 0;
```

This is correct usage (calling the public API), but direct field access is possible:
```zig
const byte = frame.bytecode.code[idx];  // ← Bypasses bounds checking
```

**Recommendation:**
Consider making fields private in a future refactor:
```zig
pub const Bytecode = struct {
    code: []const u8,
    valid_jumpdests: std.AutoArrayHashMap(u32, void),

    // Add method to get raw code if needed
    pub fn getCode(self: *const Bytecode) []const u8 {
        return self.code;
    }
};
```

However, this is low priority and may not be necessary given Zig's explicit design philosophy.

---

## 6. Documentation Quality

### 6.1 Module Documentation: Good

The file header (lines 1-3) clearly explains the module's purpose:
```zig
/// Bytecode utilities and validation
/// This module provides abstractions for working with EVM bytecode,
/// including jump destination analysis and bytecode traversal.
```

### 6.2 Function Documentation: Adequate

Most public functions have clear doc comments:
- `init`: Explains initialization with jump analysis
- `isValidJumpDest`: Clear one-liner
- `readImmediate`: Explains purpose and parameters

### 6.3 Implementation Comments: Good

Critical algorithm details are explained:
```zig
// Lines 86-92: Excellent explanation of PUSH size calculation
// Calculate number of bytes to push: opcode - 0x5f
// e.g., PUSH1 (0x60) = 0x60 - 0x5f = 1 byte
//       PUSH32 (0x7f) = 0x7f - 0x5f = 32 bytes
```

### 6.4 Missing Documentation

**Missing:**
- No explanation of WHY jump destination analysis is needed (prevents jumping into PUSH data)
- No reference to EVM spec or Yellow Paper section
- No discussion of gas implications (jump validation is cheap due to pre-analysis)

**Recommendation:**
Add to module header:
```zig
/// Bytecode utilities and validation
/// This module provides abstractions for working with EVM bytecode,
/// including jump destination analysis and bytecode traversal.
///
/// Jump destination analysis (analyzeJumpDests):
/// - Pre-validates all JUMPDEST positions during bytecode initialization
/// - Prevents invalid jumps into PUSH immediate data
/// - Amortizes validation cost: O(n) once vs O(1) per JUMP/JUMPI
/// - Required by EVM spec: JUMP/JUMPI must target valid JUMPDEST
///
/// References:
/// - EVM Yellow Paper: Section 9.4.3 (Jump Destination Analysis)
/// - EIP-3541: Reject code starting with 0xEF (future bytecode versioning)
```

---

## 7. Performance Considerations

### 7.1 AutoArrayHashMap Choice: Good

**Current:**
```zig
valid_jumpdests: std.AutoArrayHashMap(u32, void),
```

**Analysis:**
- `AutoArrayHashMap` is optimized for small-to-medium key sets with good cache locality
- Typical bytecode has ~10-100 JUMPDEST instructions (small key set)
- Iteration is fast (dense array)
- Lookup is O(1) average case

**Alternative:** `std.AutoHashMap`
- Slightly faster lookup for very large key sets
- Worse cache locality

**Verdict:** Current choice is optimal for typical EVM bytecode.

### 7.2 Pre-Analysis Trade-off: Excellent

Pre-analyzing jump destinations amortizes the cost:
- **Without pre-analysis:** O(1) per JUMP/JUMPI, but must scan from bytecode start each time
- **With pre-analysis:** O(n) once during init, then O(1) per JUMP/JUMPI

For contracts with loops (repeated jumps), pre-analysis is a significant win.

### 7.3 Potential Optimization: Bitset for Dense Jump Ranges

If most bytecode positions are potential jumpdests (rare), a bitset could be more efficient:
```zig
valid_jumpdests: std.bit_set.DynamicBitSet,
```

However, this is premature optimization. Current implementation is fine.

---

## 8. Security Considerations

### 8.1 Jump Destination Validation: Critical for Security

**Purpose:**
Prevents attackers from jumping into PUSH immediate data, which could:
1. Execute arbitrary "opcodes" (data bytes interpreted as code)
2. Bypass security checks
3. Create unexpected control flow

**Current Implementation:** ✅ Secure (with integer overflow fix)

### 8.2 Input Validation: Good

- `readImmediate`: Bounds checking prevents out-of-bounds reads
- `getOpcode`: Returns `null` for invalid PC (caller handles)
- `analyzeJumpDests`: Skips PUSH data correctly

**Missing:** Size validation in `readImmediate` (see Issue 1.2)

### 8.3 DoS Resistance: Good

- Jump analysis is O(n) in bytecode length (linear, not exponential)
- No recursion (no stack overflow risk)
- Memory usage is O(j) where j = number of JUMPDESTs (typically << n)

**Attack Vector:** Extremely large bytecode (4GB) could cause:
1. Integer overflow (Issue 1.1)
2. Memory exhaustion for hashmap

EIP-170 limits contract code to 24KB, so this is mitigated at protocol level.

---

## 9. Integration with Frame

**Usage in frame.zig:**
```zig
// Line 92: Initialization
var bytecode = try Bytecode.init(allocator, bytecode_raw);

// Line 192: Get current opcode
return self.bytecode.getOpcode(self.pc);

// Line 197: Read PUSH immediate
return self.bytecode.readImmediate(self.pc, size);
```

**handlers_control_flow.zig:**
```zig
// Line 25, 40: Validate jump destinations
if (!frame.bytecode.isValidJumpDest(dest_pc)) return error.InvalidJump;
```

**handlers_context.zig:**
```zig
// Line 178: CODECOPY reads bytecode
const byte = frame.bytecode.getOpcode(src_idx_u32) orelse 0;
```

**Integration Quality:** Excellent
- Clean API boundaries
- Proper error handling
- Efficient (no redundant validation)

---

## 10. Comparison with Ethereum Specs

### 10.1 Jump Destination Analysis Algorithm

**Python Reference (execution-specs):**
```python
# ethereum/paris/vm/interpreter.py (or later forks)
def analyze_code(code: Bytes) -> Set[Uint]:
    pc = Uint(0)
    jumpdests = set()

    while pc < len(code):
        if code[pc] == 0x5B:  # JUMPDEST
            jumpdests.add(pc)
            pc += 1
        elif 0x60 <= code[pc] <= 0x7F:  # PUSH1-PUSH32
            push_len = code[pc] - 0x5F
            pc += 1 + push_len
        else:
            pc += 1

    return jumpdests
```

**Zig Implementation:**
```zig
fn analyzeJumpDests(code: []const u8, valid_jumpdests: *std.AutoArrayHashMap(u32, void)) !void {
    var pc: u32 = 0;

    while (pc < code.len) {
        const opcode = code[pc];

        if (opcode == 0x5b) {
            try valid_jumpdests.put(pc, {});
            pc += 1;
        } else if (opcode >= 0x60 and opcode <= 0x7f) {
            const push_size = opcode - 0x5f;
            pc += 1 + push_size;
        } else {
            pc += 1;
        }
    }
}
```

**Verdict:** ✅ Matches Python reference exactly (modulo PUSH0 implicit handling)

### 10.2 PUSH0 Handling (EIP-3855, Shanghai)

**Python Reference:**
```python
# execution-specs/src/ethereum/shanghai/vm/instructions/stack.py
def push0(evm: Evm) -> None:
    push(evm.stack, U256(0))
```

**PUSH0 opcode:** 0x5F (no immediate data)

**Current Zig:**
- Implicitly handled correctly (0x5F < 0x60, falls to `else` branch)
- Should be made explicit (see Issue 2.1 recommendation)

---

## 11. Recommendations Priority

### P0 (Critical - Fix Immediately)
1. **Add integer overflow protection in `analyzeJumpDests`** (Issue 1.1)
2. **Add size validation in `readImmediate`** (Issue 1.2)

### P1 (High - Fix Before Production)
3. **Make PUSH0 handling explicit** (Issue 2.1)
4. **Switch to `usize` for consistency** (Issue 3.1)
5. **Add missing test cases** (Section 4)

### P2 (Medium - Code Quality)
6. **Use opcode constants instead of magic numbers** (Issue 3.2)
7. **Improve module documentation** (Section 6.4)

### P3 (Low - Nice to Have)
8. **Fix redundant type conversion** (Issue 3.3)
9. **Consider API improvements** (Section 5)

---

## 12. Test Coverage Analysis

**Current Tests:**
- ✅ Simple JUMPDEST identification
- ✅ PUSH data masking JUMPDEST
- ✅ PUSH32 with embedded JUMPDEST bytes
- ✅ Bytecode initialization
- ✅ readImmediate for PUSH1 and PUSH2
- ✅ readImmediate bounds checking

**Missing Tests:**
- ❌ Empty bytecode
- ❌ Truncated PUSH at end
- ❌ PUSH0 explicit test
- ❌ readImmediate size > 32
- ❌ Large bytecode (performance test)

**Coverage Estimate:** ~70% (good, but room for improvement)

---

## 13. Refactoring Suggestions

### 13.1 Extract Opcode Constants

Create `src/opcode_constants.zig` or use existing `src/opcode.zig`:
```zig
pub const JUMPDEST: u8 = 0x5b;
pub const PUSH0: u8 = 0x5f;
pub const PUSH1: u8 = 0x60;
pub const PUSH32: u8 = 0x7f;

pub fn isPushOpcode(opcode: u8) bool {
    return opcode >= PUSH0 and opcode <= PUSH32;
}

pub fn getPushSize(opcode: u8) u8 {
    return opcode - PUSH0;
}
```

### 13.2 Separate Concerns

Consider splitting into two modules:
- `bytecode_analysis.zig`: Jump destination analysis
- `bytecode_reader.zig`: Reading opcodes and immediates

However, current single-module design is fine for this size.

---

## 14. Summary

### Strengths
- ✅ Correct implementation of jump destination analysis
- ✅ Good test coverage for common cases
- ✅ Clean API design
- ✅ Efficient algorithm (O(n) pre-analysis)
- ✅ Proper error handling
- ✅ Well-documented

### Weaknesses
- ⚠️ Integer overflow risks (theoretical but should be fixed)
- ⚠️ Missing validation for `readImmediate` size parameter
- ⚠️ Inconsistent integer types (u32 vs usize)
- ⚠️ Missing edge case tests
- ⚠️ Magic numbers instead of named constants

### Overall Grade: B+ (Good, with room for improvement)

**Action Items:**
1. Fix integer overflow issues (P0)
2. Add missing tests (P1)
3. Improve type consistency (P1)
4. Refactor magic numbers to constants (P2)

---

## 15. Appendix: Example Malicious Bytecode

### A. Jump into PUSH Data
```
Without jump analysis:
  PC=0: PUSH2 0x5b00  (pushes JUMPDEST opcode as data)
  PC=3: PUSH1 0x01     (push 1)
  PC=5: JUMP           (jump to address 1)
  PC=1: 0x5b (data!)   ← INVALID! This is PUSH2 immediate data

With jump analysis:
  Jump to PC=1 → check valid_jumpdests → NOT FOUND → error.InvalidJump ✅
```

### B. Integer Overflow Attack
```
Bytecode of size 0xFFFFFFFF (4GB):
  Position 0xFFFFFFFC: 0x7F (PUSH32)
  analyzeJumpDests:
    pc = 0xFFFFFFFC
    pc += 1 + 32 = 0x0000001D (overflow!)
    pc < code.len? YES (wraparound)
    Continue from PC=0x1D... INFINITE LOOP!

Fix: Saturating arithmetic or early break
```

---

**End of Review**
