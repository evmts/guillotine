# minimal_evm_gas_accounting_test.zig Test Failures

## Summary
Total failing tests in minimal_evm_gas_accounting_test.zig: **21**

## Detailed Failure List

### 1. minimal evm gas - sstore warm restore original
- **Location**: test/minimal_evm_gas_accounting_test.zig:195
- **Expected gas_left**: 100589
- **Actual gas_left**: 100000
- **Difference**: -589

### 2. minimal evm gas - create2 base and hash cost
- **Location**: test/minimal_evm_gas_accounting_test.zig:428
- **Expected gas_left**: 167946
- **Actual gas_left**: 167988
- **Difference**: +42

### 3. minimal evm gas - mcopy base copy and memory expansion
- **Location**: test/minimal_evm_gas_accounting_test.zig:499
- **Expected gas_left**: 99967
- **Actual gas_left**: 99973
- **Difference**: +6

### 4. minimal evm gas - selfdestruct cold beneficiary
- **Location**: test/minimal_evm_gas_accounting_test.zig:525
- **Expected gas_left**: 67397
- **Actual gas_left**: 94997
- **Difference**: +27600

### 5. minimal evm gas - auth and authcall gas accounting
- **Location**: test/minimal_evm_gas_accounting_test.zig:562
- **Expected gas_left**: 94261
- **Actual gas_left**: 96761
- **Difference**: +2500

### 6. minimal evm gas - extcodecopy hardfork transitions
- **Location**: test/minimal_evm_gas_accounting_test.zig:803
- **Expected gas_left**: 99983
- **Actual gas_left**: 99980
- **Difference**: -3

### 7. minimal evm gas - create eip3860 size limits
- **Location**: test/minimal_evm_gas_accounting_test.zig:962
- **Error Type**: TestUnexpectedResult
- **Description**: Test expects false but got unexpected result

### 8. minimal evm gas - selfdestruct hardfork gas and refund
- **Location**: test/minimal_evm_gas_accounting_test.zig:1051
- **Expected gas_left**: 99997
- **Actual gas_left**: 100000
- **Difference**: +3

### 9. minimal evm gas - copy operations gas costs
- **Location**: test/minimal_evm_gas_accounting_test.zig:1262
- **Error Type**: TestUnexpectedResult
- **Description**: Test expects result.success to be true but failed

### 10. minimal evm gas - sstore eip2200 state transitions
- **Location**: test/minimal_evm_gas_accounting_test.zig:1402
- **Expected gas_used**: 38412
- **Actual gas_used**: 34570
- **Difference**: -3842

### 11. minimal evm gas - sstore refunds with gas limit
- **Location**: test/minimal_evm_gas_accounting_test.zig:1551
- **Expected gas_used**: 32624
- **Actual gas_used**: 31312
- **Difference**: -1312

### 12. Gas refund calculation differential
- **Location**: test/minimal_evm_gas_accounting_test.zig:1697
- **Expected istanbul_gas_used**: 26812
- **Actual istanbul_gas_used**: 21000
- **Difference**: -5812

### 13. minimal evm gas - call hardfork transitions
- **Location**: test/minimal_evm_gas_accounting_test.zig:1803
- **Expected gas_left**: 65278
- **Actual gas_left**: 65279
- **Difference**: +1

### 14. minimal evm gas - call eip150 gas limit calculations
- **Location**: test/minimal_evm_gas_accounting_test.zig:1969
- **Expected gas_left**: 165998
- **Actual gas_left**: 65279
- **Difference**: -100719

### 15. minimal evm gas - call memory expansion costs
- **Location**: test/minimal_evm_gas_accounting_test.zig:2093
- **Expected gas_left**: 96610
- **Actual gas_left**: 97322
- **Difference**: +712

### 16. minimal evm gas - call eip150 maximum gas regression
- **Location**: test/minimal_evm_gas_accounting_test.zig:2183
- **Error Type**: TestUnexpectedResult
- **Description**: Test expects max_to_forward <= max_child_could_take but condition failed

### 17. minimal evm gas - call stipend with zero requested gas
- **Location**: test/minimal_evm_gas_accounting_test.zig:2231
- **Expected gas_left**: 67576
- **Actual gas_left**: 65279
- **Difference**: -2297

### 18. minimal evm gas - call precompile short circuit
- **Location**: test/minimal_evm_gas_accounting_test.zig:2283
- **Error Type**: TestUnexpectedResult
- **Description**: Test expects result.gas_left < exec_gas - total_pre but condition failed

### 19. minimal evm gas - call insufficient gas scenarios
- **Location**: test/minimal_evm_gas_accounting_test.zig:2377
- **Error Type**: TestUnexpectedResult
- **Description**: Test expects !result.success but result was successful

### 20. Hardfork transition differential
- **Location**: test/minimal_evm_gas_accounting_test.zig:2492
- **Expected gas_consumed**: 66
- **Actual gas_consumed**: 21061
- **Difference**: +20995

### 21. differential: memory offset edge cases
- **Note**: This test logged errors but appears to be from differential tests involving minimal_evm

## Categories of Failures

### SSTORE-related (4 tests)
- sstore warm restore original
- sstore eip2200 state transitions
- sstore refunds with gas limit
- Gas refund calculation differential

### CALL-related (6 tests)
- call hardfork transitions
- call eip150 gas limit calculations
- call memory expansion costs
- call eip150 maximum gas regression
- call stipend with zero requested gas
- call precompile short circuit
- call insufficient gas scenarios

### CREATE-related (2 tests)
- create2 base and hash cost
- create eip3860 size limits

### SELFDESTRUCT-related (2 tests)
- selfdestruct cold beneficiary
- selfdestruct hardfork gas and refund

### Memory Operations (2 tests)
- mcopy base copy and memory expansion
- copy operations gas costs

### Hardfork Transitions (2 tests)
- extcodecopy hardfork transitions
- Hardfork transition differential

### Other (2 tests)
- auth and authcall gas accounting
- differential: memory offset edge cases

## Severity Analysis

### Critical (Large Discrepancies)
- **call eip150 gas limit calculations**: -100719 gas difference
- **selfdestruct cold beneficiary**: +27600 gas difference
- **Hardfork transition differential**: +20995 gas difference

### Medium (Moderate Discrepancies)
- **Gas refund calculation differential**: -5812 gas difference
- **sstore eip2200 state transitions**: -3842 gas difference
- **auth and authcall gas accounting**: +2500 gas difference
- **call stipend with zero requested gas**: -2297 gas difference
- **sstore refunds with gas limit**: -1312 gas difference

### Minor (Small Discrepancies)
- Most other tests have differences under 1000 gas units