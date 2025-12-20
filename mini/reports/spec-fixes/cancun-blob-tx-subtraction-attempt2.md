Perfect! All 256 blob gas subtraction tests are passing. Let me create a summary of the fix:

## Summary

I successfully fixed the failing Cancun EIP-4844 blob gas subtraction tests. All 256 tests are now passing.

### Root Cause

The bug was in the gas accounting for CALL and CALLCODE instructions in `src/instructions/handlers_system.zig`. The Zig implementation was:

1. **Charging only the "extra" costs upfront** (access costs, transfer costs, memory expansion) - missing the forwardable gas charge
2. **Charging for gas used after the call** - instead of refunding unused gas

This was backwards from the Python reference implementation, which:

1. **Charges the total cost upfront** (`gas + extra_gas + memory_cost`)
2. **Refunds unused gas after the call** (via `evm.gas_left += child_evm.gas_left`)

The previous attempt tried to cap the gas refund but kept the incorrect charging model, so it didn't fix the issue.

### The Fix

I updated both CALL and CALLCODE handlers to match Python's approach:

1. **Charge forwardable gas upfront**: Changed `try frame.consumeGas(gas_cost)` to `try frame.consumeGas(gas_cost + available_gas_without_stipend)`

2. **Refund unused gas**: Changed from charging for gas used to refunding unused gas:
   ```zig
   // Before: frame.gas_remaining -= gas_used_by_caller
   // After: frame.gas_remaining += gas_to_refund
   ```

This ensures that when a child call uses less gas than the stipend amount (2300 gas), the parent correctly gets refunded for the unused stipend, which matches the Python reference implementation and fixes the 16,100 wei balance discrepancy (2300 gas × 7 wei/gas).

### Files Modified

- `src/instructions/handlers_system.zig` - Fixed gas accounting in CALL and CALLCODE opcodes

### Test Results

- ✅ All 256 blob gas subtraction tests passing
- ✅ No regressions in the target test suite