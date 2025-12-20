Perfect! ✅ **All 30 tests are now passing!**

## Summary

The issue was in the **gas cost calculation for PUSH0** opcode (EIP-3855).

### The Problem
The `push()` handler in `src/instructions/handlers_stack.zig` was charging **3 gas** (`GasFastestStep`) for ALL push operations, including PUSH0. However, according to EIP-3855 and the Python reference implementation:
- **PUSH0** (opcode 0x5f) should cost **2 gas** (`GAS_BASE` / `GasQuickStep`)
- **PUSH1-PUSH32** (opcodes 0x60-0x7f) should cost **3 gas** (`GAS_VERY_LOW` / `GasFastestStep`)

This 1 gas overcharge per PUSH0 instruction caused balance mismatches in the tests.

### The Fix
Added a conditional check in the `push()` handler:
```zig
if (push_size == 0) {
    try frame.consumeGas(GasConstants.GasQuickStep);  // 2 gas for PUSH0
} else {
    try frame.consumeGas(GasConstants.GasFastestStep);  // 3 gas for PUSH1-PUSH32
}
```

This matches the Python reference implementation which explicitly checks `if num_bytes == 0` to charge `GAS_BASE` for PUSH0.

**Test Results**: 30/30 tests passing ✅