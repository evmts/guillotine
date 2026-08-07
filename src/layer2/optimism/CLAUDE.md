# CLAUDE.md - Optimism Module

## MISSION CRITICAL: Consensus-Critical Fee Calculations

**Every formula in this module is consensus-critical.** Errors cause:
- Transaction rejections (insufficient balance)
- Fund loss (overcharging users)
- Chain halts (divergence from canonical chain)

Cross-reference all implementations against op-geth and op-reth.

## OpSpecId Hardforks

Optimism hardforks are **supersets** of Ethereum hardforks with additional features:

```zig
pub const OpSpecId = enum(u8) {
    BEDROCK = 100,   // Base OP hardfork (maps to MERGE)
    REGOLITH,        // Removes 68-byte L1 cost overhead
    CANYON,          // Maps to SHANGHAI
    ECOTONE,         // New L1 fee model with blob support (maps to CANCUN)
    FJORD,           // FastLZ compression for L1 cost (maps to CANCUN)
    GRANITE,         // BN128 precompile input limits (maps to CANCUN)
    HOLOCENE,        // Future features (maps to CANCUN)
    ISTHMUS,         // Operator fees (maps to PRAGUE)
    INTEROP,         // Cross-chain interoperability (maps to PRAGUE)
    OSAKA,           // Maps to OSAKA
};
```

### Ethereum Hardfork Mapping

```zig
pub fn toEthHardfork(spec: OpSpecId) Hardfork {
    return switch (spec) {
        .BEDROCK, .REGOLITH => .MERGE,
        .CANYON => .SHANGHAI,
        .ECOTONE, .FJORD, .GRANITE, .HOLOCENE => .CANCUN,
        .ISTHMUS, .INTEROP => .PRAGUE,
        .OSAKA => .OSAKA,
    };
}
```

### Hardfork Comparison

```zig
pub fn isAtLeast(self: OpSpecId, other: OpSpecId) bool {
    return @intFromEnum(self) >= @intFromEnum(other);
}

// Usage:
if (spec.isAtLeast(.FJORD)) {
    // Use Fjord L1 cost calculation
}
```

## L1Block Contract

The L1Block predeploy contract stores L1 block information at address `0x4200000000000000000000000000000000000015`.

### Storage Layout

| Slot | Field | Type | Hardfork | Description |
|------|-------|------|----------|-------------|
| 1 | l1_base_fee | u256 | All | L1's current base fee per gas |
| 5 | l1_fee_overhead | u256 | Bedrock/Regolith | Fixed L1 gas overhead (deprecated in Ecotone) |
| 6 | l1_base_fee_scalar | u256 | Bedrock/Regolith | Scalar for L1 base fee (deprecated in Ecotone) |
| 3 | fee_scalars | bytes32 | Ecotone+ | Packed scalars (baseFeeScalar at offset 16, blobBaseFeeScalar at offset 20) |
| 7 | l1_blob_base_fee | u256 | Ecotone+ | L1's blob base fee |
| 8 | operator_fee_scalars | bytes32 | Isthmus+ | Packed operator fees (scalar at offset 20, constant at offset 24) |

### Reading L1 Block Info

```zig
pub fn tryFetch(db: anytype, block_number: u256, spec: OpSpecId) !L1BlockInfo {
    // Load L1Block contract account (required post-Cancun for EIP-4788)
    if (spec.toEthHardfork().isAtLeast(.CANCUN)) {
        _ = try db.basic(L1_BLOCK_ADDRESS);
    }

    const l1_base_fee = try db.storage(L1_BLOCK_ADDRESS, L1_BASE_FEE_SLOT);

    if (!spec.isAtLeast(.ECOTONE)) {
        // Bedrock/Regolith format
        const l1_fee_overhead = try db.storage(L1_BLOCK_ADDRESS, L1_OVERHEAD_SLOT);
        const l1_fee_scalar = try db.storage(L1_BLOCK_ADDRESS, L1_SCALAR_SLOT);
        return L1BlockInfo{
            .l1_base_fee = l1_base_fee,
            .l1_fee_overhead = l1_fee_overhead,
            .l1_base_fee_scalar = l1_fee_scalar,
            // ... other fields
        };
    } else {
        // Ecotone+ format
        const l1_blob_base_fee = try db.storage(L1_BLOCK_ADDRESS, ECOTONE_L1_BLOB_BASE_FEE_SLOT);
        const fee_scalars = try db.storage(L1_BLOCK_ADDRESS, ECOTONE_L1_FEE_SCALARS_SLOT);

        // Extract packed scalars
        const scalars_bytes = fee_scalars.to_be_bytes();
        const l1_base_fee_scalar = u256.from_be_slice(scalars_bytes[16..20]);
        const l1_blob_base_fee_scalar = u256.from_be_slice(scalars_bytes[20..24]);

        // Check for empty scalars edge case (first Ecotone block)
        const empty_ecotone_scalars = l1_blob_base_fee == 0 and
            std.mem.eql(u8, scalars_bytes[16..24], &EMPTY_SCALARS);

        // ... rest of initialization
    }
}
```

## L1 Fee Calculation Formulas

### CRITICAL: All formulas use integer arithmetic with specific scaling factors

### Bedrock Formula (Pre-Ecotone)

**Used in**: BEDROCK, REGOLITH

```zig
fn calculateL1CostBedrock(self: L1BlockInfo, tx_data: []const u8, spec: OpSpecId) u256 {
    // Step 1: Count calldata gas
    var data_gas: u256 = 0;
    for (tx_data) |byte| {
        data_gas += if (byte == 0) ZERO_BYTE_GAS else NON_ZERO_BYTE_GAS;
    }
    // data_gas = (zeros * 4) + (non_zeros * 16)

    // Step 2: Add 68-byte overhead for empty signature (pre-Regolith only)
    if (!spec.isAtLeast(.REGOLITH)) {
        data_gas += 68 * NON_ZERO_BYTE_GAS;  // +1088 gas
    }

    // Step 3: Apply L1 fee formula
    // L1 cost = (data_gas + overhead) * l1_base_fee * l1_scalar / 1e6
    const overhead = self.l1_fee_overhead orelse 0;
    return (data_gas + overhead)
        .saturating_mul(self.l1_base_fee)
        .saturating_mul(self.l1_base_fee_scalar)
        .wrapping_div(u256.from(1_000_000));
}
```

**Constants**:
- ZERO_BYTE_GAS = 4
- NON_ZERO_BYTE_GAS = 16
- Scaling factor: 1e6 (1,000,000)

**Example** (REGOLITH, tx_data = "FACADE" = 3 bytes):
```
data_gas = 3 * 16 = 48
l1_base_fee = 1000 (1 gwei)
l1_base_fee_scalar = 1_000_000
l1_fee_overhead = 1000

L1 cost = (48 + 1000) * 1000 * 1_000_000 / 1_000_000
        = 1048 * 1000
        = 1,048,000 wei
```

### Ecotone Formula

**Used in**: ECOTONE, GRANITE, HOLOCENE (not FJORD - see below)

```zig
fn calculateL1CostEcotone(self: L1BlockInfo, tx_data: []const u8, spec: OpSpecId) u256 {
    // Edge case: empty scalars on first Ecotone block -> use Bedrock formula
    if (self.empty_ecotone_scalars) {
        return self.calculateL1CostBedrock(tx_data, spec);
    }

    // Step 1: Count calldata gas (same as Bedrock, no overhead)
    var data_gas: u256 = 0;
    for (tx_data) |byte| {
        data_gas += if (byte == 0) ZERO_BYTE_GAS else NON_ZERO_BYTE_GAS;
    }

    // Step 2: Calculate weighted fee
    // l1_fee_scaled = (l1_base_fee * 16 * base_fee_scalar) + (l1_blob_base_fee * blob_base_fee_scalar)
    const calldata_cost_per_byte = self.l1_base_fee
        .saturating_mul(u256.from(16))
        .saturating_mul(self.l1_base_fee_scalar);

    const blob_cost_per_byte = self.l1_blob_base_fee
        .saturating_mul(self.l1_blob_base_fee_scalar);

    const l1_fee_scaled = calldata_cost_per_byte.saturating_add(blob_cost_per_byte);

    // Step 3: Apply formula
    // L1 cost = data_gas * l1_fee_scaled / (16 * 1e6)
    return l1_fee_scaled
        .saturating_mul(data_gas)
        .wrapping_div(u256.from(16_000_000));  // 16e6
}
```

**Scaling factor**: 16e6 (16,000,000)

**Formula breakdown**:
```
compressedTxSize = data_gas / 16
L1 cost = compressedTxSize * (l1_base_fee*16*l1_base_fee_scalar + l1_blob_base_fee*l1_blob_base_fee_scalar) / 1e6

Rearranged for integer arithmetic:
L1 cost = data_gas * (l1_base_fee*16*l1_base_fee_scalar + l1_blob_base_fee*l1_blob_base_fee_scalar) / (16e6)
```

**Example** (ECOTONE, tx_data = "FACADE" = 3 bytes):
```
data_gas = 3 * 16 = 48
l1_base_fee = 1000
l1_base_fee_scalar = 1000
l1_blob_base_fee = 1000
l1_blob_base_fee_scalar = 1000

calldata_cost = 1000 * 16 * 1000 = 16_000_000
blob_cost = 1000 * 1000 = 1_000_000
l1_fee_scaled = 17_000_000

L1 cost = 48 * 17_000_000 / 16_000_000
        = 816_000_000 / 16_000_000
        = 51 wei
```

### Fjord Formula (FastLZ Compression)

**Used in**: FJORD, ISTHMUS, INTEROP

```zig
fn calculateL1CostFjord(self: L1BlockInfo, tx_data: []const u8) u256 {
    // Step 1: Estimate compressed size using FastLZ
    const compressed_size = fastLzCompressedSize(tx_data);

    // Step 2: Apply compression model
    // estimated_size = max(100e6, intercept + fastlz_coef * compressed_size)
    const estimated_raw = FASTLZ_INTERCEPT
        .saturating_add(FASTLZ_COEF.saturating_mul(compressed_size));
    const estimated_size = @max(MIN_COMPRESSED_SIZE, estimated_raw);

    // Step 3: Calculate weighted fee (same as Ecotone)
    const l1_fee_scaled = self.l1_base_fee
        .saturating_mul(u256.from(16))
        .saturating_mul(self.l1_base_fee_scalar)
        .saturating_add(
            self.l1_blob_base_fee.saturating_mul(self.l1_blob_base_fee_scalar)
        );

    // Step 4: Apply formula
    // L1 cost = estimated_size * l1_fee_scaled / 1e12
    return estimated_size
        .saturating_mul(l1_fee_scaled)
        .wrapping_div(u256.from(1_000_000_000_000));  // 1e12
}
```

**Constants** (all scaled by 1e6):
- FASTLZ_COEF = 836,500 (0.8365 scaled)
- FASTLZ_INTERCEPT = 42,585,600 (42.5856 scaled)
- MIN_COMPRESSED_SIZE = 100,000,000 (100 bytes scaled)
- Scaling factor: 1e12 (1,000,000,000,000)

**Example** (FJORD, tx_data = "FACADE" = 3 bytes):
```
compressed_size = 4 (from FastLZ)
estimated_raw = 42_585_600 + (836_500 * 4) = 46_931_600
estimated_size = max(100_000_000, 46_931_600) = 100_000_000

l1_fee_scaled = 17_000_000 (same as Ecotone example)

L1 cost = 100_000_000 * 17_000_000 / 1_000_000_000_000
        = 1,700,000,000,000 / 1_000_000_000_000
        = 1700 wei
```

### FastLZ Compression Estimation

```zig
pub fn fastLzCompressedSize(input: []const u8) u64 {
    // Uses fast_lz.zig implementation
    // Estimates compressed size without actually compressing
    // Returns size as if compressed with FastLZ algorithm
    return flz_compress_len(input);
}
```

**CRITICAL**: The Fjord formula uses a **compression model** to estimate L1 cost based on compressibility, not actual byte count. This significantly reduces fees for compressible data.

## Operator Fee (Isthmus+)

**Used in**: ISTHMUS, INTEROP, OSAKA

```zig
fn operatorFeeCharge(self: L1BlockInfo, tx_data: []const u8, gas_limit: u256) u256 {
    // Deposit transactions (0x7E) have zero operator fee
    if (tx_data.len > 0 and tx_data[0] == 0x7E) {
        return u256.ZERO;
    }

    // operator_fee = (gas_limit * operator_fee_scalar / 1e6) + operator_fee_constant
    const product = gas_limit
        .saturating_mul(self.operator_fee_scalar)
        .wrapping_div(u256.from(OPERATOR_FEE_SCALAR_DECIMAL));  // 1e6

    return product.saturating_add(self.operator_fee_constant);
}

fn operatorFeeRefund(self: L1BlockInfo, gas: *Gas, spec: OpSpecId) u256 {
    if (!spec.isAtLeast(.ISTHMUS)) {
        return u256.ZERO;
    }

    // Refund based on unused gas
    const limit_fee = self.operatorFeeCharge(&.{}, u256.from(gas.limit()));
    const used_fee = self.operatorFeeCharge(&.{}, u256.from(gas.spent()));

    return limit_fee.saturating_sub(used_fee);
}
```

**Constants**:
- OPERATOR_FEE_SCALAR_DECIMAL = 1,000,000 (6 decimal places of precision)

## Deposit Transactions

### Transaction Type 0x7E

Deposit transactions have special properties:

```zig
pub const DepositTransactionParts = struct {
    source_hash: [32]u8,         // L1 origin hash (non-zero = deposit)
    mint: ?u128,                 // Free ETH minted on L2
    is_system_transaction: bool, // Automated system update (Bedrock only)

    pub fn isDeposit(self: DepositTransactionParts) bool {
        // Non-zero source_hash indicates deposit
        for (self.source_hash) |byte| {
            if (byte != 0) return true;
        }
        return false;
    }
};
```

### Special Handling

1. **No signature validation** - Deposits are authenticated by L1 origin, not ECDSA
2. **Free mint** - Can create ETH from thin air (backed by L1 deposit)
3. **Zero L1 cost** - Deposits don't pay L1 data fees
4. **Zero operator fee** - Deposits exempt from operator fees
5. **Failed deposits** - Still apply side effects (nonce increment, mint)

### System Transactions (Bedrock Only)

```zig
if (tx.isDeposit() and tx.is_system_transaction) {
    // System transactions allowed in Bedrock only
    if (spec.isAtLeast(.REGOLITH)) {
        return error.SystemTransactionPostRegolith;
    }
    // No gas cost, no sender balance check
}
```

## Fee Recipients

### L1 Fee Recipient
**Address**: `0x420000000000000000000000000000000000001A`
**Receives**: All L1 data availability fees

### Base Fee Recipient
**Address**: `0x4200000000000000000000000000000000000019`
**Receives**: L2 base fees (EIP-1559)

### Operator Fee Recipient (Isthmus+)
**Address**: `0x420000000000000000000000000000000000001B`
**Receives**: Operator fees for sequencer compensation

### Fee Distribution

```zig
fn distributeFees(evm: *Evm, gas_used: u64) !void {
    // L1 fee to L1 recipient
    try evm.journal.addBalance(L1_FEE_RECIPIENT, evm.context.l1_cost);

    // Base fee to base recipient
    const base_fee_amount = gas_used * evm.block.base_fee;
    try evm.journal.addBalance(BASE_FEE_RECIPIENT, base_fee_amount);

    // Operator fee to operator recipient (Isthmus+)
    if (config.layer2_config.optimism.spec.isAtLeast(.ISTHMUS)) {
        try evm.journal.addBalance(OPERATOR_FEE_RECIPIENT, evm.context.operator_fee);
    }
}
```

## Precompile Modifications

### P256verify (Fjord+, RIP-7212)
**Address**: `0x0000000000000000000000000000000000000100`
**Gas cost**: 3450
**Description**: secp256r1 curve signature verification

```zig
if (spec.isAtLeast(.FJORD)) {
    // Add P256verify precompile
    precompiles.add(.{
        .address = P256_VERIFY_ADDRESS,
        .execute = &p256Verify,
    });
}
```

### BN128 Pairing Input Limit (Granite+)
**Address**: `0x0000000000000000000000000000000000000008`
**Modification**: Maximum 64 pairs (2048 bytes input)

```zig
if (spec.isAtLeast(.GRANITE)) {
    // Override BN128 pairing with input size limit
    precompiles.override(.{
        .address = BN128_PAIRING_ADDRESS,
        .execute = &bn128PairingWithLimit,
    });
}

fn bn128PairingWithLimit(input: []const u8, gas: u64) !PrecompileResult {
    // Granite enforces max 64 pairs (64 * 32 = 2048 bytes)
    if (input.len > 2048) {
        return error.InputTooLarge;
    }
    return bn128Pairing(input, gas);
}
```

## Testing Strategy

### Unit Tests

Test fee calculations against known values:

```zig
test "L1 cost - Bedrock with overhead" {
    const info = L1BlockInfo{
        .l1_base_fee = 1_000_000_000, // 1 gwei
        .l1_base_fee_scalar = 1_000_000,
        .l1_fee_overhead = 2100,
    };

    const tx_data = &[_]u8{0x00, 0x01, 0x02};  // 1 zero, 2 non-zero = 36 gas
    const cost = info.calculateL1CostBedrock(tx_data, .BEDROCK);

    // Expected: (36 + 1088 + 2100) * 1e9 * 1e6 / 1e6 = 3,224,000,000,000 wei
    try testing.expectEqual(u256.from(3_224_000_000_000), cost);
}

test "L1 cost - Ecotone with blob fees" {
    const info = L1BlockInfo{
        .l1_base_fee = 47_036_678_951,
        .l1_base_fee_scalar = 1368,
        .l1_blob_base_fee = 57_422_457_042,
        .l1_blob_base_fee_scalar = 810_949,
    };

    // Real transaction from OP mainnet block 118024092
    const tx = hex!("02f8b30a832253fc8402d11f39842c8a4639...");
    const cost = info.calculateL1CostEcotone(tx, .ECOTONE);

    // Expected from block scanner: 7,306,020,222,001 wei
    try testing.expectEqual(u256.from(7_306_020_222_001), cost);
}
```

### Differential Tests

Compare against op-reth reference implementation:

```bash
# Run differential tests
zig build test-layer2-differential
```

Test vectors from:
- OP Mainnet block 118024092 (Ecotone)
- OP Mainnet block 124665056 (Fjord)

## Common Errors

### 1. Using Floating-Point Arithmetic
```zig
// WRONG - floating point
const cost = @as(f64, data_gas) * 1.5 * l1_base_fee;

// CORRECT - integer arithmetic with scaling
const cost = data_gas * 1_500_000 * l1_base_fee / 1_000_000;
```

### 2. Incorrect Scaling Factors
```zig
// WRONG - Bedrock uses 1e6, not 1e12
const cost = (data_gas + overhead) * l1_base_fee * scalar / 1_000_000_000_000;

// CORRECT - Bedrock scaling
const cost = (data_gas + overhead) * l1_base_fee * scalar / 1_000_000;
```

### 3. Forgetting Empty Scalars Edge Case
```zig
// WRONG - doesn't handle first Ecotone block
fn calculateL1CostEcotone(self: L1BlockInfo, tx_data: []const u8) u256 {
    const data_gas = countDataGas(tx_data);
    return data_gas * self.l1_fee_scaled / 16_000_000;
}

// CORRECT - handle edge case
fn calculateL1CostEcotone(self: L1BlockInfo, tx_data: []const u8, spec: OpSpecId) u256 {
    if (self.empty_ecotone_scalars) {
        return self.calculateL1CostBedrock(tx_data, spec);
    }
    // ... rest of calculation
}
```

### 4. Not Checking for Deposit Transactions
```zig
// WRONG - charges L1 fee for deposits
const l1_cost = info.calculateTxL1Cost(tx.enveloped_data, spec);

// CORRECT - deposits have zero L1 cost
const l1_cost = if (tx.isDeposit())
    u256.ZERO
else
    info.calculateTxL1Cost(tx.enveloped_data, spec);
```

## Reference Implementation

Primary reference: `/Users/williamcory/Guillotine/.scratch/crates/op-revm/src/l1block.rs`

All formulas, constants, and edge cases are taken from this implementation. When in doubt, defer to the Rust code.

## Key Invariants

1. **Deposit transactions ALWAYS have zero L1 cost**
2. **Deposit transactions ALWAYS have zero operator fee**
3. **Failed deposits ALWAYS increment nonce and apply mint**
4. **Empty scalars on first Ecotone block → use Bedrock formula**
5. **Fjord uses compression model, not byte count**
6. **All fee calculations use integer arithmetic with specific scaling factors**
7. **System transactions only allowed in Bedrock (pre-Regolith)**
8. **Operator fees only apply post-Isthmus**
