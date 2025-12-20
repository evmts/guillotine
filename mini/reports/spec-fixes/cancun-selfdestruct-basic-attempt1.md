## Summary

I've conducted an extensive investigation of the Cancun EIP-6780 SELFDESTRUCT test failures but was unable to identify and fix the root cause. Here's what I found:

### Current Status
- **Tests:** 246 failed | 36 passed (282 total)
- **Gas Discrepancy:** ~398,000 wei balance difference (39,800 gas with gas_price=10)
- **Passing:** SELFDESTRUCT in init code during CREATE (36 tests)  
- **Failing:** SELFDESTRUCT in pre-existing contracts (246 tests)

### Key Findings

1. **The issue is NOT with refunds** - Debug logging showed NO refund cases are being triggered in Cancun for these tests, which is correct behavior.

2. **The issue is with gas costs** - We're consuming LESS gas than expected, meaning gas is not being charged somewhere it should be.

3. **All code matches Python reference** - I verified:
   - SSTORE refund logic matches Python exactly (lines 106-124)
   - Gas constants are correct (5000, 2600, 25000, 20000, 100)
   - Storage original tracking logic is correct
   - Refund capping (1/5 for London+) is correct

4. **Storage originals are tracked correctly** - When `getOriginal()` is called, it correctly returns values from the host interface (test pre-state).

### Recommended Next Steps

The issue requires **step-by-step execution trace comparison** between Zig and Python:

```bash
bun scripts/isolate-test.ts "test_selfdestruct_pre_existing_fork_Cancun_state_test_selfdestruct_contract_initial_balance_0_single_call"
```

Focus areas for trace comparison:
1. Gas charged for each SSTORE operation
2. Gas charged for CALL operations to pre-existing contracts  
3. Gas charged for SELFDESTRUCT operation
4. Total gas accounting at transaction end

The bug is subtle and likely involves an edge case in gas accounting that's not apparent from code inspection alone.