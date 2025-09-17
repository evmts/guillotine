# SSTORE Refund Logic - Complete Analysis

## Three Key Values
- **original**: Value at transaction start
- **current**: Current value in storage  
- **new**: Value being set

## All Possible Cases - Exhaustive List

### Level 1: No-op Check
**If new == current → No refund, minimal gas**

### Level 2: First Modification (original == current)
1. **Zero to non-zero** (original=0, current=0, new!=0)
   - No refund
   
2. **Non-zero to zero** (original!=0, current!=0, new=0)
   - Refund: SSTORE_CLEARS_SCHEDULE
   
3. **Non-zero to different non-zero** (original!=0, current!=0, new!=0, new!=original)
   - No refund

### Level 3: Subsequent Modifications (original != current)

#### 3A: Restoring to Original (new == original)
1. **Restore to 0** (original=0, current!=0, new=0)
   - This is BOTH restore + clear
   - Refund: SSTORE_CLEARS_SCHEDULE (clearing takes precedence per EIP-2200)
   
2. **Restore to non-zero** (original!=0, current!=original, new=original)
   - Refund: SSTORE_RESET - SLOAD_GAS

#### 3B: Not Restoring (new != original)
1. **Clear to 0** (original!=0, current!=0, new=0)
   - Standard clear
   - Refund: SSTORE_CLEARS_SCHEDULE
   
2. **Re-set from 0** (original!=0, current=0, new!=0)
   - MUST remove previous clearing refund
   - Why certain: If original!=0 and current=0 and original!=current, 
     then current MUST be 0 due to a clear in this tx
   - Action: Remove SSTORE_CLEARS_SCHEDULE refund
   
3. **Other changes** (all other combinations)
   - No refund

## Precedence Rules

Check in this EXACT order:
1. No-op check (new == current)
2. First vs subsequent (original == current vs !=)
3. Within subsequent: restore check FIRST (new == original)
4. Then handle non-restore cases

## Edge Cases Covered

1. **Double refund prevention**: Restore to 0 only gets clearing refund, not both
2. **Refund removal certainty**: If original!=0, current=0, new!=0, the zero MUST be from this tx's clear
3. **No ambiguity**: Every combination maps to exactly one case

## Hardfork Values

**Istanbul/Berlin**:
- SSTORE_CLEARS_SCHEDULE = 15000
- SSTORE_RESET = 5000  
- SLOAD_GAS = 800

**London+** (EIP-3529):
- SSTORE_CLEARS_SCHEDULE = 4800
- SSTORE_RESET = 5000 (but warm = 2900)
- SLOAD_GAS = 100

**Berlin+ cold/warm**:
- Cold penalty adds 2100 to base costs
- Warm costs are lower (100 for SLOAD)