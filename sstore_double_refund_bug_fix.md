# SSTORE Double Refund Bug Fix

## Bug Identified

In `src/tracer/minimal_frame.zig`, the SSTORE refund logic is **double-counting refunds** when clearing storage back to its original value of 0.

## Scenario

When executing:
```
SSTORE slot[0] = 1  // Set from 0 to 1
SSTORE slot[0] = 0  // Clear back to 0 (original value)
```

## Current Incorrect Behavior

For the second SSTORE (clearing back to original 0):
- **Refund 1**: Lines 533-536 add 15000 (Istanbul) for clearing (1→0)
- **Refund 2**: Lines 540-559 add 19200 for restoring to original (0→0)
- **Total refund**: 34200 (WRONG!)

## Root Cause

The code applies BOTH:
1. Clearing refund (non-zero → zero)
2. Restore-to-original refund (any → original)

But these should be mutually exclusive for the same operation!

## Fix Required

In `minimal_frame.zig`, modify the refund logic to prevent double refunding:

```zig
// Around line 540, add a check to prevent double refund
if (original_value == new_value) {
    // Only apply restore-to-original refund if we haven't already applied a clearing refund
    // If new_value == 0 and we already applied clearing refund, skip this
    const already_refunded_for_clearing = (new_value == 0 and current_value != 0 and original_value == 0);
    
    if (!already_refunded_for_clearing) {
        // ... existing restore-to-original refund logic ...
    }
}
```

## Alternative Fix (Cleaner)

Restructure the refund logic to be mutually exclusive:

```zig
if (new_value == current_value) {
    // No-op: no refund
} else if (original_value == new_value) {
    // Restoring to original - apply restore refund
    // ... restore refund logic ...
} else if (new_value == 0 and current_value != 0) {
    // Clearing - apply clear refund
    // ... clear refund logic ...
} else {
    // Other transitions - handle normally
    // ... other logic ...
}
```

## Impact

This bug causes all SSTORE tests to fail because:
- Gas refunds are over-credited
- Tests expect correct EIP-2200 behavior
- The excessive refunds cascade through gas calculations

## Verification

After fix, these values should match:
- Istanbul: Set then clear should use 26812 gas (not 20906)
- Berlin: Set then clear should use 38412 gas (not 34570)