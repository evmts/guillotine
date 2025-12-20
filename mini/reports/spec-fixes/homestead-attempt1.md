Perfect! All 10 Homestead hardfork tests are now passing. Let me create a summary of the fix:

## Summary

Successfully fixed all failing tests in the Homestead hardfork test suite! ✅

### Issue
The Homestead coverage tests were failing for Constantinople, Istanbul, Berlin, London, and Paris forks with balance mismatches indicating incorrect gas calculations. The pattern was:
- ✅ Homestead and Byzantium: PASS
- ❌ Constantinople through Paris: FAIL (balance mismatches)
- ✅ Shanghai, Cancun, Prague: PASS

### Root Cause
The PUSH0 opcode (0x5f), introduced in Shanghai via EIP-3855, was being accepted in all hardforks. The test bytecode contained PUSH0, and in pre-Shanghai forks, this should be treated as an invalid opcode causing transaction reversion. Our implementation incorrectly accepted PUSH0 in all forks, leading to:
- Different execution paths (successful execution vs expected reversion)
- Incorrect gas consumption
- Balance mismatches in the final state

### Fix
Added a hardfork guard in the `push` handler (`src/instructions/handlers_stack.zig`) to reject PUSH0 (opcode 0x5f) in forks before Shanghai:

```zig
// EIP-3855: PUSH0 was introduced in Shanghai hardfork
if (push_size == 0) {
    const evm = frame.getEvm();
    if (evm.hardfork.isBefore(.SHANGHAI)) {
        return error.InvalidOpcode;
    }
    try frame.consumeGas(GasConstants.GasQuickStep);
}
```

### Test Results
All 10 tests now pass across all hardforks:
- ✅ Homestead
- ✅ Byzantium
- ✅ ConstantinopleFix
- ✅ Istanbul
- ✅ Berlin
- ✅ London
- ✅ Paris
- ✅ Shanghai
- ✅ Cancun
- ✅ Prague

The fix correctly enforces that PUSH0 is only valid in Shanghai and later forks, matching the Python reference implementation behavior.