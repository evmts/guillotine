# Gas Metering

This document covers gas calculation, costs, and metering patterns across both EVM implementations.

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

### Example Memory Costs

| Size (bytes) | Words | Cost |
|--------------|-------|------|
| 32 | 1 | 3 |
| 64 | 2 | 6 |
| 128 | 4 | 12 |
| 1024 | 32 | 98 |
| 32768 | 1024 | 5120 |

## SSTORE Gas (EIP-2200/3529)

Complex gas based on value transitions:

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

### SSTORE Gas Table

| original | current | new | Gas | Refund |
|----------|---------|-----|-----|--------|
| 0 | 0 | 0 | 100 | 0 |
| 0 | 0 | X | 20000 | 0 |
| X | X | X | 100 | 0 |
| X | X | 0 | 2900 | 4800 |
| X | X | Y | 2900 | 0 |
| X | Y | X | 100 | 2800 |
| X | Y | 0 | 100 | 4800 |

## EXP Gas

Dynamic cost based on exponent size:

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

| Exponent | Bytes | Gas |
|----------|-------|-----|
| 0 | 0 | 10 |
| 1-255 | 1 | 60 |
| 256-65535 | 2 | 110 |
| 2^24 | 3 | 160 |
| 2^256-1 | 32 | 1610 |

## KECCAK256 Gas

Dynamic cost based on data size:

```zig
// Gas = 30 + 6 * word_count
pub fn keccakGasCost(size: u64) u64 {
    const words = (size + 31) / 32;
    return 30 + 6 * words;
}
```

## CALL Gas (EIP-150)

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

// Gas forwarding (63/64 rule)
pub fn gasToForward(available: u64, requested: u64) u64 {
    const max_forward = available - available / 64;
    return @min(requested, max_forward);
}
```

## Intrinsic Gas

Transaction base cost:

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
// Refunds tracked as signed integer (can go negative)
gas_refund: i64 = 0,

pub fn addRefund(self: *Self, amount: u64) void {
    self.gas_refund += @intCast(amount);
}

pub fn subRefund(self: *Self, amount: u64) void {
    self.gas_refund -= @intCast(amount);
}
```

### Refund Cap (EIP-3529)

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

```zig
// mini/src/frame.zig
pub fn consumeGas(self: *Self, amount: u64) EvmError!void {
    if (self.gas_remaining < @intCast(amount)) {
        return error.OutOfGas;
    }
    self.gas_remaining -= @intCast(amount);
}

// Each handler:
pub fn add(frame: *FrameType) EvmError!void {
    try frame.consumeGas(3);  // Check every operation
    // ...
}
```

### Performance: Per-Basic-Block

```zig
// Gas calculated during preprocessing
first_block_gas: FirstBlockMetadata {
    .gas: 15,  // Sum of all ops in block
    .min_stack: 0,
    .max_stack: 2,
}

// Charged at block entry
if (self.gas_remaining < first_block.gas) {
    return Error.OutOfGas;
}
self.gas_remaining -= first_block.gas;
```

## Hardfork-Specific Costs

### Berlin (EIP-2929)

```zig
// Before Berlin: flat costs
SLOAD: 200
BALANCE: 400
EXTCODESIZE: 700

// Berlin+: warm/cold access
SLOAD cold: 2100, warm: 100
BALANCE cold: 2600, warm: 100
EXTCODESIZE cold: 2600, warm: 100
```

### London (EIP-3529)

```zig
// Reduced refund cap
Pre-London: 50% of gas used
London+: 20% of gas used

// SELFDESTRUCT refund removed
Pre-London: 24000 refund
London+: 0 refund
```

### Shanghai (EIP-3651)

```zig
// Warm coinbase
// Coinbase address pre-warmed at transaction start
warm_addresses.put(block.coinbase, {});
```

## Gas Debugging

### Common Out-of-Gas Causes

1. **Memory expansion**: Quadratic cost surprises
2. **Cold storage**: First SLOAD is 21x more expensive
3. **CREATE/CALL**: Initcode or nested call costs
4. **Large calldata**: 16 gas per non-zero byte

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

## Gas Constants Reference

| Constant | Value | Usage |
|----------|-------|-------|
| G_zero | 0 | STOP, RETURN |
| G_base | 2 | ADDRESS, ORIGIN |
| G_verylow | 3 | ADD, SUB, LT |
| G_low | 5 | MUL, DIV |
| G_mid | 8 | ADDMOD, MULMOD |
| G_high | 10 | JUMPI |
| G_warmaccess | 100 | Warm account/storage |
| G_coldaccountaccess | 2600 | Cold account |
| G_coldsload | 2100 | Cold SLOAD |
| G_sset | 20000 | SSTORE 0→non-zero |
| G_sreset | 2900 | SSTORE non-zero→non-zero |
| G_callvalue | 9000 | Value transfer |
| G_newaccount | 25000 | Creating account |
| G_selfdestruct | 5000 | SELFDESTRUCT |
| G_create | 32000 | CREATE |
| G_sha3word | 6 | KECCAK256 per word |
| G_copy | 3 | COPY per word |
| G_memory | 3 | Memory per word |
| G_log | 375 | LOG base |
| G_logtopic | 375 | LOG per topic |
| G_logdata | 8 | LOG per byte |
