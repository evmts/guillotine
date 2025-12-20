Perfect! All 12 tests are passing! 

## Summary

I successfully fixed the failing tests in Cancun EIP-6780 SELFDESTRUCT revert tests. The issue was:

**Root Cause**: The `EXTCODECOPY` opcode handler in `src/instructions/handlers_context.zig` (lines 256-262) was writing zeros to memory instead of actually copying code from external addresses. This was a stub implementation that was never completed.

**Impact**: 
- CREATE operations that used EXTCODECOPY to copy initcode were deploying contracts with empty code
- The initcode would execute STOP (0x00) instead of the expected instructions  
- No runtime code was being deployed
- SELFDESTRUCT was never called because the created contracts had no code

**Fix**: I implemented the correct EXTCODECOPY behavior:
1. Get the actual code from the external address using `evm.host.getCode()` or `evm.code.get()`
2. Copy code bytes to memory
3. Handle the case where the offset is beyond code length (write 0 per EVM spec)

**Result**: All 12 tests now pass (6 "created_in_same_tx_with_revert" + 6 "not_created_in_same_tx_with_revert").