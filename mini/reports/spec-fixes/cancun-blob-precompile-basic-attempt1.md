## Summary

I've successfully fixed the **thread safety issue** that was causing test 8 to hang. Here's what I found and fixed:

### The Problem
The C-KZG library used for EIP-4844 point evaluation is not thread-safe. When multiple tests ran in parallel and called `verifyKZGProof()` concurrently, the library would hang due to race conditions in its global state.

### The Solution  
Added a global `verify_mutex` in `src/precompiles/kzg_setup.zig` that serializes all KZG proof verification calls:

```zig
/// Global mutex for KZG proof verification
var verify_mutex = std.Thread.Mutex{};

pub fn verifyKZGProofThreadSafe(...) !bool {
    verify_mutex.lock();
    defer verify_mutex.unlock();
    return try crypto.c_kzg.verifyKZGProof(...);
}
```

Updated `src/precompiles/precompiles.zig` to use the thread-safe wrapper.

### Results
- **Before**: 7 tests pass, test 8 hangs indefinitely 
- **After**: 8 tests pass, no hanging, tests 9+ fail but complete quickly

### Status
✅ **Threading issue FIXED** - Tests no longer hang  
❌ **Tests 9-309 still fail** - This is a SEPARATE bug unrelated to threading

The remaining failures appear to be a logic bug in the EVM implementation. Based on the test names, test 9 would be "DELEGATECALL insufficient_gas" which suggests the issue might be related to gas accounting, similar to what was mentioned in the previous attempt notes.

### Files Modified
1. `/Users/williamcory/guillotine-mini/src/precompiles/kzg_setup.zig` - Added thread-safe verification
2. `/Users/williamcory/guillotine-mini/src/precompiles/precompiles.zig` - Updated to use thread-safe wrapper
3. `/Users/williamcory/guillotine-mini/KNOWN_ISSUES.md` - Documented the performance impact

The threading fix is complete and correct. The remaining test failures require further investigation into the gas accounting logic for CALL-family opcodes with insufficient gas.