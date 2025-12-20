# Gas Metering

This document covers gas calculation, costs, and metering patterns across both EVM implementations.

## Quick Reference

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           GAS COST QUICK REFERENCE                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   STATIC COSTS (fixed per opcode):                                          │
│   ────────────────────────────────                                          │
│   Zero (0):     STOP, RETURN, REVERT                                        │
│   Base (2):     ADDRESS, ORIGIN, CALLER, CALLVALUE, CODESIZE, ...          │
│   VeryLow (3):  ADD, SUB, NOT, LT, GT, EQ, ISZERO, AND, OR, XOR, ...       │
│   Low (5):      MUL, DIV, SDIV, MOD, SMOD                                   │
│   Mid (8):      ADDMOD, MULMOD, JUMP                                        │
│   High (10):    JUMPI                                                       │
│                                                                             │
│   DYNAMIC COSTS (calculated at runtime):                                    │
│   ─────────────────────────────────────                                     │
│   SLOAD:        100 (warm) / 2100 (cold)                                   │
│   SSTORE:       100-20000 (see decision tree below)                        │
│   CALL:         100 (warm) / 2600 (cold) + value + new account             │
│   MEMORY:       3*words + words²/512                                       │
│   EXP:          10 + 50*byte_length(exponent)                              │
│   KECCAK256:    30 + 6*word_count                                          │
│   LOG:          375 + 375*topics + 8*data_bytes                            │
│   CREATE:       32000 + memory + initcode_cost                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Gas Categories

### Static Gas Costs

Fixed cost per opcode, defined in gas constants:

```zig
// From primitives/GasConstants
pub const GasConstants = struct {
    // Tier: Zero (0 gas)
    pub const GasZero: u64 = 0;

    // Tier: Base (2 gas)
    pub const GasBase: u64 = 2;

    // Tier: VeryLow (3 gas)
    pub const GasVeryLow: u64 = 3;  // ADD, SUB, NOT, LT, GT, etc.

    // Tier: Low (5 gas)
    pub const GasLow: u64 = 5;  // MUL, DIV, SDIV, MOD, SMOD

    // Tier: Mid (8 gas)
    pub const GasMid: u64 = 8;  // ADDMOD, MULMOD

    // Tier: High (10 gas)
    pub const GasHigh: u64 = 10;  // JUMPI

    // Tier: ExtCode (100-2600 gas, EIP-2929)
    pub const WarmStorageReadCost: u64 = 100;
    pub const ColdSloadCost: u64 = 2100;
    pub const ColdAccountAccessCost: u64 = 2600;
};
```

### Dynamic Gas Costs

Calculated based on operation parameters:

```zig
// Memory expansion
fn memoryExpansionCost(current_words: u64, new_words: u64) u64;

// SSTORE (depends on original, current, new values)
fn sstoreGasCost(original: u256, current: u256, new_value: u256) u64;

// EXP (depends on exponent bit length)
fn expGasCost(exponent: u256) u64;

// SHA3/KECCAK256 (depends on data size)
fn keccakGasCost(size: u64) u64;

// CALL family (depends on value transfer, account existence)
fn callGasCost(value: u256, exists: bool) u64;
```

## Memory Expansion

Memory expands in 32-byte words with quadratic cost:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        MEMORY EXPANSION COST                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Formula: cost = 3*words + words²/512                                      │
│                                                                             │
│   ┌───────────────┬───────────┬────────────┬──────────────────────────────┐│
│   │ Size (bytes)  │ Words     │ Cost       │ Notes                        ││
│   ├───────────────┼───────────┼────────────┼──────────────────────────────┤│
│   │ 32            │ 1         │ 3          │ Linear dominates             ││
│   │ 64            │ 2         │ 6          │ Linear dominates             ││
│   │ 128           │ 4         │ 12         │ Linear dominates             ││
│   │ 256           │ 8         │ 24         │ Linear dominates             ││
│   │ 1,024         │ 32        │ 98         │ Quadratic starts to matter   ││
│   │ 4,096         │ 128       │ 416        │ Noticeable quadratic         ││
│   │ 32,768        │ 1,024     │ 5,120      │ Quadratic significant        ││
│   │ 262,144       │ 8,192     │ 155,648    │ Quadratic dominates          ││
│   └───────────────┴───────────┴────────────┴──────────────────────────────┘│
│                                                                             │
│   Why quadratic? Prevents DoS via memory exhaustion.                        │
│   Large memory allocations become prohibitively expensive.                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// Formula: cost = 3*words + words²/512
fn memoryExpansionCost(current_size: u64, new_size: u64) u64 {
    if (new_size <= current_size) return 0;

    const current_words = (current_size + 31) / 32;
    const new_words = (new_size + 31) / 32;

    const current_cost = 3 * current_words + (current_words * current_words) / 512;
    const new_cost = 3 * new_words + (new_words * new_words) / 512;

    return new_cost - current_cost;
}
```

## SSTORE Gas (EIP-2200/3529)

### Decision Tree

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        SSTORE GAS DECISION TREE                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   SSTORE(slot, new_value)                                                   │
│   │                                                                         │
│   ├── Is slot COLD?                                                         │
│   │   │                                                                     │
│   │   YES ──▶ Add 2100 gas (COLD_SLOAD)                                    │
│   │          Mark slot as WARM                                              │
│   │                                                                         │
│   ▼                                                                         │
│   │                                                                         │
│   ├── current == new_value?                                                 │
│   │   │                                                                     │
│   │   YES ──▶ 100 gas (WARM_STORAGE_READ)                                  │
│   │          No state change, done.                                         │
│   │                                                                         │
│   NO ▼                                                                      │
│   │                                                                         │
│   ├── original == current?  (First change in this tx?)                     │
│   │   │                                                                     │
│   │   YES ├── original == 0?                                               │
│   │       │   │                                                             │
│   │       │   YES ──▶ 20000 gas (SSTORE_SET: 0 → non-zero)                 │
│   │       │                                                                 │
│   │       │   NO ───▶ 2900 gas (SSTORE_RESET: non-zero → different)        │
│   │                                                                         │
│   │   NO ─┴──▶ 100 gas (WARM_STORAGE_READ: already modified)               │
│   │                                                                         │
│   ▼                                                                         │
│   Calculate REFUNDS (see refund decision tree below)                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Refund Decision Tree

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       SSTORE REFUND DECISION TREE                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   (After determining gas cost)                                              │
│   │                                                                         │
│   ├── new_value != current?  (State actually changed?)                     │
│   │   │                                                                     │
│   │   NO ───▶ No refund                                                    │
│   │                                                                         │
│   │   YES ▼                                                                 │
│   │   │                                                                     │
│   │   ├── original != 0 AND current != 0 AND new_value == 0?               │
│   │   │   │                                                                 │
│   │   │   YES ──▶ REFUND += 4800 (clearing a slot)                         │
│   │   │                                                                     │
│   │   ├── original != 0 AND current == 0?                                  │
│   │   │   │                                                                 │
│   │   │   YES ──▶ REFUND -= 4800 (re-setting a cleared slot)               │
│   │   │                                                                     │
│   │   ├── original == new_value?  (Resetting to original?)                 │
│   │   │   │                                                                 │
│   │   │   YES ├── original == 0?                                           │
│   │   │       │   │                                                         │
│   │   │       │   YES ──▶ REFUND += 19900 (SSTORE_SET - WARM)              │
│   │   │       │                                                             │
│   │   │       │   NO ───▶ REFUND += 2800 (SSTORE_RESET - COLD - WARM)      │
│   │                                                                         │
│   DONE                                                                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### SSTORE Gas Table (Complete)

| Original | Current | New | Gas Cost | Refund | Scenario |
|----------|---------|-----|----------|--------|----------|
| 0 | 0 | 0 | 100 | 0 | No-op: empty → empty |
| 0 | 0 | X | 20000 | 0 | Set: empty → value |
| X | X | X | 100 | 0 | No-op: same value |
| X | X | 0 | 2900 | +4800 | Clear: value → empty |
| X | X | Y | 2900 | 0 | Modify: value → different |
| X | 0 | X | 100 | +2800 | Restore: cleared → original |
| X | 0 | Y | 100 | -4800 | Re-set: cleared → different |
| X | Y | X | 100 | +2800 | Restore: modified → original |
| X | Y | 0 | 100 | +4800 | Clear: modified → empty |
| 0 | X | 0 | 100 | +19900 | Clear new: set → empty |

**Note:** Add 2100 gas if slot is COLD (first access in transaction).

### Code Implementation

```zig
// mini/src/instructions/handlers_storage.zig
pub fn calculateSstoreGas(
    original: u256,
    current: u256,
    new_value: u256,
    is_cold: bool,
) struct { gas: u64, refund: i64 } {
    var gas: u64 = 0;
    var refund: i64 = 0;

    // Cold access cost
    if (is_cold) {
        gas += 2100;  // COLD_SLOAD
    }

    // No change: warm access only
    if (current == new_value) {
        gas += 100;  // WARM_STORAGE_READ
        return .{ .gas = gas, .refund = 0 };
    }

    // Value changed
    if (original == current) {
        // First change in transaction
        if (original == 0) {
            gas += 20000;  // SSTORE_SET (0 → non-zero)
        } else {
            gas += 2900;   // SSTORE_RESET (non-zero → different non-zero)
        }
    } else {
        gas += 100;  // WARM_STORAGE_READ (already modified)
    }

    // Refund calculations
    if (original != 0) {
        if (current != 0 and new_value == 0) {
            // Clearing a slot
            refund += 4800;  // SSTORE_CLEARS_SCHEDULE (EIP-3529)
        }
        if (current == 0) {
            // Re-setting a cleared slot
            refund -= 4800;
        }
    }

    if (original == new_value) {
        // Resetting to original value
        if (original == 0) {
            refund += 19900;  // SSTORE_SET - WARM
        } else {
            refund += 2800;   // SSTORE_RESET - COLD - WARM
        }
    }

    return .{ .gas = gas, .refund = refund };
}
```

## EXP Gas

Dynamic cost based on exponent size:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            EXP GAS COST                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Formula: 10 + 50 × byte_length(exponent)                                  │
│                                                                             │
│   ┌──────────────────────┬───────────┬─────────────────────────────────────┐│
│   │ Exponent             │ Bytes     │ Gas                                 ││
│   ├──────────────────────┼───────────┼─────────────────────────────────────┤│
│   │ 0                    │ 0         │ 10                                  ││
│   │ 1-255                │ 1         │ 60                                  ││
│   │ 256-65535            │ 2         │ 110                                 ││
│   │ 65536-16777215       │ 3         │ 160                                 ││
│   │ 2^32-2^40            │ 5         │ 260                                 ││
│   │ 2^256-1 (max)        │ 32        │ 1610                                ││
│   └──────────────────────┴───────────┴─────────────────────────────────────┘│
│                                                                             │
│   Why? EXP operation is O(log n) where n is exponent bit length.            │
│   Charging per byte approximates actual computational cost.                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// Gas = 10 + 50 * byte_length(exponent)
pub fn expGasCost(exponent: u256) u64 {
    if (exponent == 0) return 10;

    // Count bytes needed to represent exponent
    var bytes: u64 = 0;
    var e = exponent;
    while (e != 0) : (e >>= 8) {
        bytes += 1;
    }

    return 10 + 50 * bytes;
}
```

## KECCAK256 Gas

Dynamic cost based on data size:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          KECCAK256 GAS COST                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Formula: 30 + 6 × word_count                                              │
│                                                                             │
│   ┌──────────────────────┬───────────┬─────────────────────────────────────┐│
│   │ Data Size            │ Words     │ Gas                                 ││
│   ├──────────────────────┼───────────┼─────────────────────────────────────┤│
│   │ 0-32 bytes           │ 1         │ 36                                  ││
│   │ 33-64 bytes          │ 2         │ 42                                  ││
│   │ 65-96 bytes          │ 3         │ 48                                  ││
│   │ 256 bytes            │ 8         │ 78                                  ││
│   │ 1024 bytes           │ 32        │ 222                                 ││
│   │ 32768 bytes          │ 1024      │ 6174                                ││
│   └──────────────────────┴───────────┴─────────────────────────────────────┘│
│                                                                             │
│   Plus memory expansion cost for reading the data!                          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// Gas = 30 + 6 * word_count
pub fn keccakGasCost(size: u64) u64 {
    const words = (size + 31) / 32;
    return 30 + 6 * words;
}
```

## CALL Gas (EIP-150)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          CALL GAS DECISION TREE                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   CALL(gas, address, value, args_offset, args_size, ret_offset, ret_size)   │
│   │                                                                         │
│   ├── Base cost                                                             │
│   │   │                                                                     │
│   │   ├── Is address COLD?                                                  │
│   │   │   │                                                                 │
│   │   │   YES ──▶ +2600 (COLD_ACCOUNT_ACCESS)                              │
│   │   │                                                                     │
│   │   │   NO ───▶ +100 (WARM_ACCOUNT_ACCESS)                               │
│   │   │                                                                     │
│   │   ▼                                                                     │
│   ├── Value transfer?                                                       │
│   │   │                                                                     │
│   │   ├── value > 0?                                                        │
│   │   │   │                                                                 │
│   │   │   YES ──▶ +9000 (CALL_VALUE_TRANSFER)                              │
│   │   │          │                                                          │
│   │   │          ├── Account exists?                                        │
│   │   │          │   │                                                      │
│   │   │          │   NO ───▶ +25000 (NEW_ACCOUNT)                          │
│   │   │          │                                                          │
│   │   │          └── Stipend: +2300 given to callee                        │
│   │   │                                                                     │
│   ├── Memory expansion                                                      │
│   │   │                                                                     │
│   │   └── Expand for args_offset+args_size and ret_offset+ret_size         │
│   │                                                                         │
│   ├── Gas forwarding (63/64 rule)                                           │
│   │   │                                                                     │
│   │   └── Forward min(requested, available - available/64)                 │
│   │                                                                         │
│   TOTAL = base + value_transfer + new_account + memory                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
pub fn callGasCost(
    value: u256,
    to_exists: bool,
    is_cold: bool,
) struct { base: u64, stipend: u64 } {
    var base: u64 = 0;

    // Account access cost
    if (is_cold) {
        base += 2600;  // COLD_ACCOUNT_ACCESS
    } else {
        base += 100;   // WARM_ACCOUNT_ACCESS
    }

    // Value transfer cost
    if (value > 0) {
        base += 9000;  // CALL_VALUE_TRANSFER
        if (!to_exists) {
            base += 25000;  // NEW_ACCOUNT
        }
    }

    // Stipend (returned to child frame)
    const stipend: u64 = if (value > 0) 2300 else 0;

    return .{ .base = base, .stipend = stipend };
}

// Gas forwarding (63/64 rule - EIP-150)
pub fn gasToForward(available: u64, requested: u64) u64 {
    const max_forward = available - available / 64;
    return @min(requested, max_forward);
}
```

## Intrinsic Gas

Transaction base cost:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        INTRINSIC GAS CALCULATION                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Base transaction cost: 21000                                              │
│   │                                                                         │
│   ├── Is CREATE transaction?                                                │
│   │   │                                                                     │
│   │   YES ──▶ +32000                                                       │
│   │                                                                         │
│   ├── Calldata cost                                                         │
│   │   │                                                                     │
│   │   └── For each byte:                                                   │
│   │       ├── Zero byte: +4                                                │
│   │       └── Non-zero byte: +16                                           │
│   │                                                                         │
│   ├── Access list cost (EIP-2930)                                           │
│   │   │                                                                     │
│   │   └── For each entry:                                                  │
│   │       ├── Address: +2400                                               │
│   │       └── Storage key: +1900 (per key)                                 │
│   │                                                                         │
│   TOTAL = 21000 + create + calldata + access_list                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
pub fn intrinsicGas(
    data: []const u8,
    is_create: bool,
    access_list: []const AccessListItem,
) u64 {
    var gas: u64 = 21000;  // Base transaction cost

    // Create cost
    if (is_create) {
        gas += 32000;
    }

    // Data cost
    for (data) |byte| {
        if (byte == 0) {
            gas += 4;   // Zero byte
        } else {
            gas += 16;  // Non-zero byte
        }
    }

    // Access list cost (EIP-2930)
    for (access_list) |item| {
        gas += 2400;  // Address cost
        gas += item.storage_keys.len * 1900;  // Storage key cost
    }

    return gas;
}
```

## Gas Refunds

### Tracking

```zig
// Refunds tracked as signed integer (can go negative temporarily)
gas_refund: i64 = 0,

pub fn addRefund(self: *Self, amount: u64) void {
    self.gas_refund += @intCast(amount);
}

pub fn subRefund(self: *Self, amount: u64) void {
    self.gas_refund -= @intCast(amount);
}
```

### Refund Cap (EIP-3529)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          REFUND CAP (EIP-3529)                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Pre-London:  max_refund = gas_used / 2  (50%)                            │
│   London+:     max_refund = gas_used / 5  (20%)                            │
│                                                                             │
│   Example (London):                                                         │
│   ─────────────────                                                         │
│   Gas used: 100,000                                                         │
│   Accumulated refund: 50,000                                                │
│   Max refund: 100,000 / 5 = 20,000                                         │
│   Actual refund: min(50,000, 20,000) = 20,000                              │
│                                                                             │
│   Why reduced? Pre-London refunds were exploited for gas token attacks.    │
│   EIP-3529 reduced the cap and removed SELFDESTRUCT refunds entirely.      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// Applied at transaction end
pub fn applyRefundCap(gas_used: u64, gas_refund: i64, hardfork: Hardfork) u64 {
    if (gas_refund <= 0) return 0;

    const max_refund = if (hardfork.isAtLeast(.LONDON))
        gas_used / 5   // EIP-3529: 20% cap
    else
        gas_used / 2;  // Pre-London: 50% cap

    return @min(@intCast(gas_refund), max_refund);
}
```

## Gas Metering Patterns

### Mini: Per-Operation

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      MINI GAS METERING PATTERN                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Every opcode handler:                                                     │
│                                                                             │
│   pub fn add(frame: *FrameType) EvmError!void {                            │
│       try frame.consumeGas(3);  // ← Check EVERY operation                 │
│       // ... operation logic                                                │
│   }                                                                         │
│                                                                             │
│   pub fn consumeGas(self: *Self, amount: u64) EvmError!void {              │
│       if (self.gas_remaining < amount) {                                   │
│           return error.OutOfGas;  // ← Branch on every op                  │
│       }                                                                     │
│       self.gas_remaining -= amount;                                        │
│   }                                                                         │
│                                                                             │
│   Cost: 1 comparison + 1 subtraction + 1 branch per opcode                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Performance: Per-Basic-Block

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                   PERFORMANCE GAS METERING PATTERN                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Preprocessing calculates total gas per basic block:                       │
│                                                                             │
│   Basic Block: PUSH1 + PUSH1 + ADD + JUMP                                  │
│                 3    +   3   +  3  +   8  = 17 gas                         │
│                                                                             │
│   Schedule:                                                                 │
│   [0] first_block_gas { gas: 17, min_stack: 0, max_stack: 2 }              │
│   [1] &push_handler                                                         │
│   ...                                                                       │
│                                                                             │
│   At block entry (once):                                                    │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ if (gas_remaining < 17) return OutOfGas;                            │  │
│   │ gas_remaining -= 17;                                                │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│   Each opcode in block:                                                     │
│   ┌─────────────────────────────────────────────────────────────────────┐  │
│   │ // NO gas check! Already paid at block entry.                       │  │
│   │ // Just execute and tail-call next.                                 │  │
│   └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│   Cost: 1 comparison + 1 subtraction + 1 branch per BLOCK (not per op)     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Hardfork-Specific Costs

### Berlin (EIP-2929)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      BERLIN GAS CHANGES (EIP-2929)                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   BEFORE BERLIN (flat costs):          BERLIN+ (warm/cold):                │
│   ─────────────────────────────        ──────────────────────               │
│                                                                             │
│   SLOAD:       200                     Cold: 2100, Warm: 100                │
│   BALANCE:     400                     Cold: 2600, Warm: 100                │
│   EXTCODESIZE: 700                     Cold: 2600, Warm: 100                │
│   EXTCODEHASH: 400                     Cold: 2600, Warm: 100                │
│   EXTCODECOPY: 700                     Cold: 2600, Warm: 100                │
│   CALL:        700                     Cold: 2600, Warm: 100                │
│                                                                             │
│   First access = COLD (expensive)                                           │
│   Subsequent = WARM (cheap)                                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### London (EIP-3529)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      LONDON GAS CHANGES (EIP-3529)                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Reduced refund cap:                                                       │
│   Pre-London: 50% of gas used                                              │
│   London+:    20% of gas used                                              │
│                                                                             │
│   SELFDESTRUCT refund removed:                                              │
│   Pre-London: 24000 refund                                                 │
│   London+:    0 refund                                                     │
│                                                                             │
│   Why? Gas token attacks exploited high refunds.                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Shanghai (EIP-3651)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    SHANGHAI GAS CHANGES (EIP-3651)                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Warm COINBASE:                                                            │
│   Coinbase address pre-warmed at transaction start.                        │
│                                                                             │
│   Before Shanghai:                                                          │
│   COINBASE → cold access → 2600 gas                                        │
│                                                                             │
│   Shanghai+:                                                                │
│   COINBASE → warm access → 100 gas                                         │
│                                                                             │
│   Why? Builder/proposer payments commonly access coinbase.                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Gas Debugging

### Common Out-of-Gas Causes

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      COMMON OUT-OF-GAS CAUSES                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   1. MEMORY EXPANSION                                                       │
│      Symptom: OOG on MSTORE/MLOAD/CALLDATACOPY                             │
│      Cause: Quadratic cost surprises                                        │
│      Check: Memory offset + size                                            │
│                                                                             │
│   2. COLD STORAGE ACCESS                                                    │
│      Symptom: OOG on first SLOAD                                           │
│      Cause: Cold access is 21x more expensive than warm                     │
│      Check: Is slot in access list? Was it accessed before?                 │
│                                                                             │
│   3. CREATE/CALL                                                            │
│      Symptom: OOG on CREATE/CALL with sufficient gas                       │
│      Cause: Initcode size (EIP-3860) or nested call depth                  │
│      Check: initcode.len <= 49152, call depth < 1024                       │
│                                                                             │
│   4. LARGE CALLDATA                                                         │
│      Symptom: OOG on transaction submission                                │
│      Cause: 16 gas per non-zero byte in calldata                           │
│      Check: Intrinsic gas calculation                                       │
│                                                                             │
│   5. SSTORE 0→NON-ZERO                                                      │
│      Symptom: OOG on SSTORE                                                │
│      Cause: Setting empty slot costs 20000 gas                             │
│      Check: original value == 0?                                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Tracing Gas

```zig
// Enable gas tracing
log.debug("Op: {} Gas before: {} Cost: {} After: {}", .{
    opcode,
    gas_before,
    gas_cost,
    gas_after,
});
```

## Complete Gas Constants Reference

| Constant | Value | Usage |
|----------|-------|-------|
| G_zero | 0 | STOP, RETURN, REVERT |
| G_base | 2 | ADDRESS, ORIGIN, CALLER, CALLVALUE, ... |
| G_verylow | 3 | ADD, SUB, LT, GT, SLT, SGT, EQ, ISZERO, AND, OR, XOR, NOT, BYTE, SHL, SHR, SAR |
| G_low | 5 | MUL, DIV, SDIV, MOD, SMOD |
| G_mid | 8 | ADDMOD, MULMOD, JUMP |
| G_high | 10 | JUMPI |
| G_warmaccess | 100 | Warm account/storage |
| G_coldaccountaccess | 2600 | Cold account access |
| G_coldsload | 2100 | Cold SLOAD |
| G_sset | 20000 | SSTORE 0→non-zero |
| G_sreset | 2900 | SSTORE non-zero→non-zero |
| G_sclear | 4800 | SSTORE clear refund |
| G_callvalue | 9000 | Value transfer in CALL |
| G_callstipend | 2300 | Stipend for value transfer |
| G_newaccount | 25000 | Creating new account |
| G_selfdestruct | 5000 | SELFDESTRUCT base |
| G_create | 32000 | CREATE base |
| G_codedeposit | 200 | Per byte of deployed code |
| G_sha3 | 30 | KECCAK256 base |
| G_sha3word | 6 | KECCAK256 per word |
| G_copy | 3 | COPY per word (CALLDATACOPY, etc.) |
| G_memory | 3 | Memory per word (linear term) |
| G_txcreate | 32000 | CREATE transaction |
| G_txdatazero | 4 | Zero byte in calldata |
| G_txdatanonzero | 16 | Non-zero byte in calldata |
| G_transaction | 21000 | Base transaction cost |
| G_log | 375 | LOG base |
| G_logtopic | 375 | LOG per topic |
| G_logdata | 8 | LOG per data byte |
| G_exp | 10 | EXP base |
| G_expbyte | 50 | EXP per byte in exponent |
| G_accesslistaddress | 2400 | Per address in access list |
| G_accessliststorage | 1900 | Per storage key in access list |
