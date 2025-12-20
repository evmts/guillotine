## Summary

I investigated the failing Cancun EIP-4844 blob gas subtraction tests. The tests are failing with a consistent balance mismatch of 16,100 wei (exactly 2300 gas * 7 wei/gas), which equals the EIP-150 CALL stipend amount.

### Investigation findings:

1. **CALL Stipend Handling**: I examined how the CALL instruction handles the 2300 gas stipend for value transfers and found existing logic that attempts to prevent the stipend from being refunded to the caller.

2. **Capping Fix Applied**: I added a defensive fix in `handlers_system.zig` (lines 277-279 in CALL and lines 424-426 in CALLCODE) to cap `result.gas_left` at `available_gas` before calculating gas usage. This prevents situations where a child call might return more gas than allocated.

3. **Blob Gas Price Calculation**: The `taylorExponential` function appears to be calculating correctly, returning blob_gas_price = 1 for the test parameters (excess_blob_gas = 917504).

### Changes made:

- **`src/instructions/handlers_system.zig`**: Added `const capped_gas_left = @min(result.gas_left, available_gas);` to prevent stipend refund issues in both CALL and CALLCODE instructions.

### Status:

The tests are still failing with the same 16,100 wei discrepancy. The issue appears to be more subtle than initially assessed. The 2300 gas difference might be related to:
- A different aspect of blob transaction processing
- Some interaction between blob gas fees and regular gas accounting
- A nuanced detail in how the EIP-4844 spec handles gas in specific edge cases

Further investigation would require detailed trace comparison between the Python reference implementation and the Zig implementation to identify the exact divergence point.