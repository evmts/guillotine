# MinimalEvm Gas Accounting Test Failures

## Summary
22 test failures in `test/minimal_evm_gas_accounting_test.zig`

## Test Failures by Category

### SSTORE Operations (5 failures)
1. **sstore clear applies refund cap** 
   - Expected: 94315 gas left
   - Actual: 95995 gas left
   - Difference: +1680 gas (not applying refund cap correctly)

2. **sstore warm restore original**
   - Expected: 97689 gas left
   - Actual: 98231 gas left
   - Difference: +542 gas (warm access cost incorrect)

3. **sstore eip2200 state transitions**
   - Failure: gas_refund > 0 assertion failed
   - Issue: Not accumulating gas refunds properly

4. **sstore refunds with gas limit**
   - Failure: gas_refund > 0 assertion failed  
   - Issue: Not accumulating gas refunds properly

5. **Gas refund calculation differential**
   - Failure: gas_refund > 0 assertion failed
   - Issue: Gas refund mechanism not working

### CALL Family Operations (9 failures)
1. **call cold no value**
   - Expected: 97279 gas left
   - Actual: 100000 gas left
   - Issue: Not deducting cold access cost (2721 gas)

2. **call warm with value transfer**
   - Expected: 88158 gas left
   - Actual: 100000 gas left
   - Issue: Not deducting any gas (11842 gas difference)

3. **call new account surcharge**
   - Expected: 63279 gas left
   - Actual: 75679 gas left
   - Difference: +12400 gas (not applying new account penalty)

4. **delegatecall cold**
   - Expected: 97282 gas left
   - Actual: 100000 gas left
   - Issue: Not deducting cold access cost (2718 gas)

5. **callcode cold**
   - Expected: 97279 gas left
   - Actual: 100000 gas left
   - Issue: Not deducting cold access cost (2721 gas)

6. **staticcall cold**
   - Expected: 97279 gas left
   - Actual: 100000 gas left
   - Issue: Not deducting cold access cost (2721 gas)

7. **call hardfork transitions**
   - Expected: 99939 gas left
   - Actual: 100000 gas left
   - Issue: Not applying hardfork-specific gas rules (61 gas)

8. **call account state detection**
   - Expected: 25000 gas difference
   - Actual: 24321 gas difference
   - Issue: Account state detection off by 679 gas

9. **call eip150 gas limit calculations**
   - Failure: Integer overflow panic
   - Issue: Critical bug in gas calculation logic

### CREATE Operations (2 failures)
1. **create2 base and hash cost**
   - Expected: 167946 gas left
   - Actual: 167988 gas left
   - Difference: +42 gas (hash cost calculation incorrect)

2. **create eip3860 size limits**
   - Failure: Assertion failed
   - Issue: Not enforcing EIP-3860 size limits

### SELFDESTRUCT Operations (2 failures)
1. **selfdestruct cold beneficiary**
   - Expected: 67397 gas left
   - Actual: 94997 gas left
   - Difference: +27600 gas (not applying cold beneficiary cost)

2. **selfdestruct hardfork gas and refund**
   - Expected: 99997 gas left
   - Actual: 99998 gas left
   - Difference: +1 gas (minor hardfork rule discrepancy)

### Memory Operations (2 failures)
1. **mcopy base copy and memory expansion**
   - Expected: 99967 gas left
   - Actual: 99973 gas left
   - Difference: +6 gas (memory expansion cost off)

2. **copy operations gas costs**
   - Failure: result.success assertion failed
   - Issue: Operation failing due to incorrect gas calculation

### Other Operations (3 failures)
1. **extcodecopy hardfork transitions**
   - Expected: 99983 gas left
   - Actual: 99980 gas left
   - Difference: -3 gas (hardfork rule slightly off)

2. **auth and authcall gas accounting**
   - Expected: 94161 gas left
   - Actual: 96761 gas left
   - Difference: +2600 gas (AUTH operation cost missing)

3. **precompiles start warm**
   - Expected: 100 gas (warm cost)
   - Actual: 2600 gas (cold cost)
   - Issue: Precompiles not starting as warm addresses

## Key Issues Identified

1. **Cold Access Tracking**: Many CALL operations return 100000 gas (no deduction), indicating cold access costs aren't being applied
2. **Gas Refunds**: Multiple SSTORE tests show gas_refund = 0, indicating refund mechanism is broken
3. **Account State Detection**: Not properly detecting new accounts vs existing accounts
4. **Hardfork Rules**: Several tests show hardfork-specific gas rules aren't being applied
5. **Integer Overflow**: Critical bug in EIP-150 gas limit calculation causing panic
6. **Precompile Addresses**: Not treating precompile addresses as warm by default

## Priority Fixes

1. **CRITICAL**: Fix integer overflow in call eip150 gas limit calculations
2. **HIGH**: Implement cold/warm access tracking for CALL operations
3. **HIGH**: Fix gas refund mechanism for SSTORE operations
4. **MEDIUM**: Apply hardfork-specific gas rules correctly
5. **MEDIUM**: Ensure precompiles start as warm addresses
6. **LOW**: Fix minor gas calculation discrepancies in memory operations