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

Fixed cost per opcode. Both EVMs import the constants from the vendored Voltaire library as `GasConstants` (`@import("voltaire").GasConstants` in `src/`, `@import("primitives").GasConstants` in `mini/src/`):

```zig
// lib/voltaire/src/primitives/gas_constants.zig
// Zero tier (STOP, RETURN, REVERT) has no named constant.
pub const GasQuickStep: u64 = 2;    // Base: ADDRESS, ORIGIN, CALLER, CALLVALUE, ...
pub const GasFastestStep: u64 = 3;  // VeryLow: ADD, SUB, NOT, LT, GT, ...
pub const GasFastStep: u64 = 5;     // Low: MUL, DIV, SDIV, MOD, SMOD
pub const GasMidStep: u64 = 8;      // Mid: ADDMOD, MULMOD, JUMP
pub const GasSlowStep: u64 = 10;    // High: JUMPI
pub const GasExtStep: u64 = 20;     // BLOCKHASH

// EIP-2929 access costs
pub const WarmStorageReadCost: u64 = 100;
pub const ColdSloadCost: u64 = 2100;
pub const ColdAccountAccessCost: u64 = 2600;
```

### Dynamic Gas Costs

Calculated at runtime from operation parameters. Each opcode handler computes its own dynamic cost:

| Cost | Mini (`mini/src/`) | Performance (`src/`) |
|------|--------------------|----------------------|
| Memory expansion | `Frame.memoryExpansionCost(end_bytes)` in `frame.zig` | `Memory.get_expansion_cost(new_size)` in `memory/memory.zig` |
| SSTORE | `GasConstants.sstoreGasCostWithHardfork(...)` plus refunds in `instructions/handlers_storage.zig` | `sstore` in `instructions/handlers_storage.zig` |
| EXP | `exp` in `instructions/handlers_arithmetic.zig` | `exp` in `instructions/handlers_arithmetic.zig` |
| KECCAK256 | `instructions/handlers_keccak.zig` | `instructions/handlers_keccak.zig` |
| CALL family | `instructions/handlers_system.zig` | `instructions/handlers_system.zig` |

`gas_constants.zig` also exports helpers such as `memoryGasCost`, `keccak256GasCost`, `copyGasCost`, `logGasCost` and `createGasCost`, but neither EVM calls them from its handlers.

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
// lib/voltaire/src/primitives/gas_constants.zig (MemoryGas = 3, QuadCoeffDiv = 512)
pub fn memoryGasCost(current_size: u64, new_size: u64) u64 {
    if (new_size <= current_size) return 0;

    const current_words = wordCount(current_size);
    const new_words = wordCount(new_size);

    const current_cost = MemoryGas * current_words + (current_words * current_words) / QuadCoeffDiv;
    const new_cost = MemoryGas * new_words + (new_words * new_words) / QuadCoeffDiv;

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
| X | 0 | X | 100 | -2000 (-4800 +2800) | Restore: cleared → original |
| X | 0 | Y | 100 | -4800 | Re-set: cleared → different |
| X | Y | X | 100 | +2800 | Restore: modified → original |
| X | Y | 0 | 100 | +4800 | Clear: modified → empty |
| 0 | X | 0 | 100 | +19900 | Clear new: set → empty |

**Note:** Add 2100 gas if slot is COLD (first access in transaction).

### Code Implementation

The Performance EVM computes SSTORE gas and refunds inline in the handler (condensed; Istanbul+ gas and London+ refund paths only):

```zig
// src/instructions/handlers_storage.zig, sstore()
const warm_cost: u64 = if (evm.is_hardfork_at_least(.BERLIN))
    GasConstants.WarmStorageReadCost // 100
else
    800; // EIP-2200 Istanbul SLOAD_GAS
const base_gas_cost: u64 = if (current_value == value) warm_cost
    else if (original_value == current_value)
        (if (original_value == 0) GasConstants.SstoreSetGas // 20000
         else GasConstants.SstoreResetGas - GasConstants.ColdSloadCost) // 2900 (Berlin+)
    else warm_cost;
const total_gas_cost: u64 = base_gas_cost +
    (if (is_cold and evm.is_hardfork_at_least(.BERLIN)) GasConstants.ColdSloadCost else 0);

// Refunds (London+): three independent checks
if (current_value != value) {
    if (original_value != 0 and current_value != 0 and value == 0)
        evm.add_gas_refund(GasConstants.SstoreRefundGas); // +4800
    if (original_value != 0 and current_value == 0)
        evm.gas_refund_counter -|= GasConstants.SstoreRefundGas; // -4800
    if (original_value == value) {
        if (original_value == 0)
            evm.add_gas_refund(GasConstants.SstoreSetGas - GasConstants.WarmStorageReadCost) // +19900
        else
            evm.add_gas_refund(GasConstants.SstoreResetGas - GasConstants.ColdSloadCost - GasConstants.WarmStorageReadCost); // +2800
    }
}
```

The Mini EVM gets the gas cost from `GasConstants.sstoreGasCostWithHardfork(current, original, new, is_cold, is_berlin_or_later, is_istanbul_or_later)` and applies refunds inline in `mini/src/instructions/handlers_storage.zig`.

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
│   │ 2^32 to 2^40-1       │ 5         │ 260                                 ││
│   │ 2^256-1 (max)        │ 32        │ 1610                                ││
│   └──────────────────────┴───────────┴─────────────────────────────────────┘│
│                                                                             │
│   Why? EXP operation is O(log n) where n is exponent bit length.            │
│   Charging per byte approximates actual computational cost.                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// Illustrative. Neither EVM has an expGasCost function: the Performance EVM
// charges the 10 gas base with the basic block and the 50 * bytes part inside
// exp() in src/instructions/handlers_arithmetic.zig.
// Gas = 10 + 50 * byte_length(exponent)
fn expGasCost(exponent: u256) u64 {
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
// lib/voltaire/src/primitives/gas_constants.zig
// Gas = 30 + 6 * word_count (Keccak256Gas = 30, Keccak256WordGas = 6)
pub inline fn keccak256GasCost(data_size: usize) u64 {
    const word_count = wordCount(data_size);
    return Keccak256Gas + (word_count * Keccak256WordGas);
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
// Illustrative spec logic. The CALL-family handlers in
// src/instructions/handlers_system.zig compute these costs inline.
fn callGasCost(
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
fn gasToForward(available: u64, requested: u64) u64 {
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
│   │          +2 per 32-byte word of initcode (EIP-3860, Shanghai+)          │
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
│   Prague+ (EIP-7623): the transaction pays at least                         │
│   21000 + 10 * calldata_tokens (tokens = zero bytes + 4 * non-zero bytes)   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```zig
// src/eips_and_hardforks/eips.zig: methods on `Eips` (EvmConfig.eips); src/evm.zig calls them
pub fn intrinsic_gas_cost(_: Self, is_create: bool) u64;      // 21000, or 53000 for CREATE
pub fn tokens_in_calldata(self: Self, input: []const u8) u64; // zero bytes + 4 * non-zero bytes (Istanbul+)
pub fn calldata_gas_cost(self: Self, calldata_tokens: u64, is_create: bool, input_len: usize) u64; // 4 * tokens + EIP-3860 initcode words
pub fn floor_gas_cost(self: Self, calldata_tokens: u64) u64;  // EIP-7623 floor, 0 before Prague
```

## Gas Refunds

### Tracking

Both EVMs keep the refund counter as an unsigned integer on the EVM struct:

```zig
// src/evm.zig (Performance)
gas_refund_counter: u64,

pub fn add_gas_refund(self: *Self, amount: u64) void {
    self.gas_refund_counter += amount;
}
// SSTORE reverses an earlier clear refund with a saturating subtract:
// evm.gas_refund_counter -|= GasConstants.SstoreRefundGas;

// mini/src/evm.zig (Mini)
gas_refund: u64,

pub fn add_refund(self: *Self, amount: u64) void {
    self.gas_refund += amount;
}

pub fn sub_refund(self: *Self, amount: u64) void {
    self.gas_refund -= amount;
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
// src/eips_and_hardforks/eips.zig, applied at transaction end by src/evm.zig
pub fn eip_3529_gas_refund_cap(self: Self, gas_used: u64, refund_counter: u64) u64 {
    if (!self.hardfork.isAtLeast(.LONDON)) return @min(refund_counter, gas_used / 2);
    return @min(refund_counter, gas_used / 5);
}

pub fn eip_3529_apply_gas_refund(self: Self, initial_gas: u64, gas_left: u64, gas_refund_counter: u64) u64 {
    const gas_used = initial_gas - gas_left;
    const capped_refund = self.eip_3529_gas_refund_cap(gas_used, gas_refund_counter);
    return @min(initial_gas, gas_left + capped_refund);
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
│   ISTANBUL (flat costs, EIP-1884):     BERLIN+ (warm/cold):                 │
│   ─────────────────────────────        ──────────────────────               │
│                                                                             │
│   SLOAD:       800                     Cold: 2100, Warm: 100                │
│   BALANCE:     700                     Cold: 2600, Warm: 100                │
│   EXTCODESIZE: 700                     Cold: 2600, Warm: 100                │
│   EXTCODEHASH: 700                     Cold: 2600, Warm: 100                │
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
│   Coinbase address pre-warmed at transaction start.                         │
│                                                                             │
│   Before Shanghai:                                                          │
│   BALANCE(coinbase) or CALL to coinbase → cold access → 2600 gas            │
│                                                                             │
│   Shanghai+:                                                                │
│   BALANCE(coinbase) or CALL to coinbase → warm access → 100 gas             │
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
| G_sreset | 2900 | SSTORE non-zero→non-zero (Berlin+; 5000 before) |
| G_sclear | 4800 | SSTORE clear refund (London+; 15000 before) |
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
