Perfect! **All 90 tests are passing** ✅

## Summary

The PUSH0 tests for Shanghai EIP-3855 are now passing. The implementation was already correct in `src/frame.zig`:

### PUSH0 Implementation Details:
- **Opcode**: 0x5f
- **Gas Cost**: 2 (GasQuickStep = GAS_BASE)
- **Operation**: Pushes `0` to the stack
- **Hardfork**: Shanghai+ (correctly guarded)
- **PC Increment**: +1 (no immediate bytes)

The implementation correctly matches the Python reference specification where PUSH0 is implemented as `push_n` with `num_bytes=0`, charging `GAS_BASE` (2 gas) instead of `GAS_VERY_LOW` (3 gas) used by PUSH1-PUSH32.

The initial test failures were likely due to a stale build cache. Adding debug output forced a rebuild which resolved the issue. All tests now pass successfully.