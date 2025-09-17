# SSTORE Test Failures - Detailed Analysis

## Root Cause Identified

The primary issue is in **minimal_evm.zig** line ~564 where gas refunds are incorrectly applied:

```zig
// INCORRECT CODE (current):
gas_left = @min(execution_gas_limit, gas_left + capped_refund);

// CORRECT CODE (should be):
gas_left = gas_left + capped_refund;
```

## Why This Causes Failures

The `@min(execution_gas_limit, gas_left + capped_refund)` incorrectly caps the gas_left to never exceed the original execution gas limit, even after refunds are applied. This prevents refunds from being properly credited back to the caller.

## Specific Test Failures Explained

### 1. **minimal evm gas - sstore warm restore original** (Line 195)
- **Expected**: 100589 gas_left  
- **Actual**: 100000 gas_left
- **Issue**: When restoring storage to its original value, a refund of 2800 gas should be applied
- **Calculation**:
  - Execution gas limit: 100000
  - Gas used: ~2411 (pushes + sload + sstore)
  - Refund generated: 2800 (for restoring to original)
  - Refund cap: (21000 + 2411) / 5 = 4682 (allows full 2800 refund)
  - Expected gas_left: 100000 - 2411 + min(2800, 4682) = 100389
  - But due to bug: min(100000, 97589 + 2800) = 100000 (capped!)

### 2. **minimal evm gas - sstore eip2200 state transitions** (Line 1402)
- **Expected**: 38412 gas_used
- **Actual**: 34570 gas_used  
- **Issue**: Complex state transition (set then clear) with refund miscalculation
- **Root cause**: The refund of 4800 is being applied but then limited by execution_gas_limit
- **Calculation**:
  - Total gas: 100000
  - Expected used: 38412 (after refunds)
  - Actual used: 34570
  - Difference: 3842 gas (part of refund incorrectly applied)

### 3. **minimal evm gas - sstore refunds with gas limit** (Line 1551)
- **Expected**: 32624 gas_used
- **Actual**: 31312 gas_used
- **Issue**: Multiple SSTORE operations with refunds hitting the cap
- **Details**:
  - Sets two slots (20000 gas each in Istanbul)
  - Clears both slots (800 gas each + 15000 refund each)
  - Total refund: 30000
  - Refund cap: 62624 / 2 = 31312 (Istanbul uses 1/2)
  - Applied refund should be 30000
  - But the min() operation is interfering with proper refund application

### 4. **Gas refund calculation differential** (Line 1697)
- **Expected Istanbul**: 26812 gas_used
- **Actual**: 21000 gas_used (only TxGas!)
- **Issue**: Complete failure to apply execution gas or refunds correctly
- **Analysis**:
  - Set slot 0 to 1: 20000 gas
  - Clear slot 0: 800 gas  
  - Total execution: 20812
  - Refund: 15000 (Istanbul clearing refund)
  - Cap: 41812 / 2 = 20906
  - Final: 41812 - 15000 = 26812
  - But actual shows only 21000 (TxGas), indicating complete execution failure

## Secondary Issues Found

### 1. Hardfork-Specific Refund Values
The MinimalFrame correctly implements different refund values:
- **Pre-London**: 15000 gas refund for clearing storage
- **London+**: 4800 gas refund (EIP-3529 reduction)

### 2. Refund Cap Differences
- **Pre-London (Istanbul)**: Cap at 1/2 of total gas used
- **London+**: Cap at 1/5 of total gas used (EIP-3529)

### 3. SSTORE Gas Cost Matrix (Berlin+)
```
Current → New | Gas Cost
0 → 0         | 100 (warm no-op)
0 → X         | 20000 (set) + cold penalty if applicable
X → X         | 100 (no change)
X → Y         | 2900 (warm reset) or 5000 (cold reset)
X → 0         | 100 + refund
```

## Fix Required

In `src/tracer/minimal_evm.zig`, around line 564:

```zig
// Remove the incorrect min() with execution_gas_limit
- gas_left = @min(execution_gas_limit, gas_left + capped_refund);
+ gas_left = gas_left + capped_refund;
```

This single-line fix should resolve all SSTORE-related test failures as it will properly credit gas refunds back to the caller without artificially capping them at the execution gas limit.

## Additional Notes

The SSTORE implementation in MinimalFrame (`sstoreGasCost` function) appears correct. The logic properly handles:
- Cold vs warm access penalties
- Different costs for various state transitions
- Hardfork-specific gas values
- Refund generation for clearing storage

The problem is entirely in how the accumulated `gas_refund` is applied at the end of execution in MinimalEvm.