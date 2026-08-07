# CLAUDE.md - Layer2 Module

## MISSION CRITICAL: L2 Fee Accuracy
**L2 fee calculation errors cause fund loss or transaction failures.**

Every fee formula must match the L2 specification exactly. Cross-reference all implementations against official L2 client code (op-geth, op-reth).

## Module Purpose

This module provides Layer 2 blockchain support as a **zero-cost abstraction**. When `layer2_config = .none` (default), all L2 code is eliminated at compile time through comptime branching.

### Zero-Cost Abstraction Principle

```zig
// In EVM handler code:
if (comptime config.layer2_config == .optimism) {
    // This entire block is eliminated when layer2_config = .none
    const l1_cost = calculateL1Cost(...);
    deductL1Fee(l1_cost);
}
```

When compiled with default config (`layer2_config = .none`):
- No L2 code in binary
- No runtime branches
- No performance impact
- Identical binary size to pre-L2 builds

## Supported L2s

### Optimism (and OP Stack chains)
- **Base** - Coinbase's L2
- **Zora** - NFT-focused L2
- **OP Mainnet** - Original Optimism chain
- **Any OP Stack chain** - All use same OpSpecId hardforks

See `optimism/CLAUDE.md` for Optimism-specific details.

## Architecture: Comptime Branching

### Configuration Structure

```zig
// In src/evm_config.zig
pub const EvmConfig = struct {
    /// Layer 2 configuration (default: none = mainnet)
    layer2_config: Layer2Config = .none,
    // ... other fields
};

// In src/layer2/layer2_config.zig
pub const Layer2Config = union(enum) {
    none,                    // Mainnet (default) - all L2 code eliminated
    optimism: OptimismConfig,
    // Future: arbitrum, base, etc.
};
```

### Handler Integration Pattern

All EVM handlers use comptime branching to conditionally include L2 logic:

```zig
// Example: Transaction validation
fn validateTransaction(comptime config: EvmConfig, tx: Transaction) !void {
    // Mainnet validation (always runs)
    try validateBasic(tx);

    // L2-specific validation (compiles away when not needed)
    if (comptime config.layer2_config == .optimism) {
        if (tx.isDeposit()) {
            // Deposit transactions skip signature validation
            try validateDeposit(tx);
            return;
        }
    }

    // Continue with normal validation...
    try validateSignature(tx);
}
```

### Type Elimination

Optional L2 fields become `void` when not in use:

```zig
pub const CallParams = struct {
    // ... existing fields ...

    // Only present when Optimism is enabled
    // Becomes `void` (0 bytes) when layer2_config = .none
    op_tx_data: if (config.layer2_config == .optimism) OpTransactionData else void,
};
```

## Key Concepts

### L1 Data Availability Cost

L2 transactions are batched and posted to L1 for data availability. Users pay:
1. **L2 execution gas** - Normal EVM gas cost
2. **L1 data cost** - Cost to post transaction data to L1
3. **Operator fee** - (Isthmus+) Sequencer compensation

The L1 data cost calculation varies by hardfork (Bedrock, Ecotone, Fjord).

### Deposit Transactions

Special transactions (type 0x7E) that originate from L1:
- **No signature** - Authenticated by L1 origin, not ECDSA
- **Mint** - Can create ETH on L2 from L1 deposits
- **System transactions** - Automated contract updates
- **Failed deposits** - Still apply side effects (nonce, mint)

### Hardfork Progression

Optimism hardforks map to Ethereum base hardforks:
- BEDROCK/REGOLITH → MERGE
- CANYON → SHANGHAI
- ECOTONE/FJORD/GRANITE/HOLOCENE → CANCUN
- ISTHMUS/INTEROP → PRAGUE
- OSAKA → OSAKA

## File Organization

```
src/layer2/
├── CLAUDE.md                    # This file
├── layer2_config.zig            # Layer2Config union type
├── optimism/
│   ├── CLAUDE.md                # Optimism-specific documentation
│   ├── spec.zig                 # OpSpecId enum (BEDROCK → OSAKA)
│   ├── constants.zig            # L1 Block contract addresses, storage slots
│   ├── l1_block_info.zig        # L1BlockInfo struct + fee calculation
│   ├── transaction.zig          # DepositTransaction types
│   ├── precompiles.zig          # Optimism precompile overrides
│   └── fast_lz.zig              # FastLZ compression for Fjord
```

## Integration Points

L2 logic integrates into the EVM at these points:

### 1. Transaction Validation
- Skip signature validation for deposits
- Validate deposit-specific constraints
- Check system transaction restrictions (Regolith+)

### 2. Balance Deduction
- Calculate L1 data cost
- Calculate operator fee (Isthmus+)
- Validate balance covers L2 gas + L1 cost + operator fee
- Handle deposit mint (free ETH)

### 3. Fee Distribution
- Send L1 cost to L1_FEE_RECIPIENT
- Send base fee to BASE_FEE_RECIPIENT
- Send operator fee to OPERATOR_FEE_RECIPIENT (Isthmus+)

### 4. Error Handling
- Failed deposits still apply side effects (nonce increment, mint)
- Return special FailedDeposit status

### 5. Precompiles
- P256verify at address 0x100 (Fjord+)
- BN128 pairing with input size limit (Granite+)

## Testing

### Unit Tests
```bash
# Test layer2 fee calculations
zig build test-unit -Dtest-filter='layer2'

# Test optimism-specific logic
zig build test-unit -Dtest-filter='optimism'
```

### Integration Tests
```bash
# Full EVM integration with L2 features
zig build test-integration -Dtest-filter='layer2'
```

### Differential Tests
Compare against op-geth/op-reth for:
- L1 cost calculations across all hardforks
- Deposit transaction handling
- Fee distribution
- Failed deposit side effects

## Common Pitfalls

### 1. Forgetting Comptime Branching
```zig
// WRONG - runtime branch
if (config.layer2_config == .optimism) {
    // This creates a runtime branch!
}

// CORRECT - comptime branch
if (comptime config.layer2_config == .optimism) {
    // This is eliminated at compile time when not Optimism
}
```

### 2. Deposit Transaction Detection
```zig
// WRONG - checking transaction type
if (tx.tx_type == 0x7E) {
    // Transaction type alone is insufficient
}

// CORRECT - checking deposit source hash
if (tx.op_tx_data.deposit.isDeposit()) {
    // Checks for non-zero source_hash
}
```

### 3. L1 Cost Caching
```zig
// The L1BlockInfo caches the calculated L1 cost to avoid recalculation
// between validation and execution. ALWAYS clear the cache when reusing:

var l1_info = try L1BlockInfo.tryFetch(...);
const cost1 = l1_info.calculateTxL1Cost(tx1_data, spec);
l1_info.clearTxL1Cost(); // REQUIRED before next calculation
const cost2 = l1_info.calculateTxL1Cost(tx2_data, spec);
```

### 4. Formula Precision
All L1 cost formulas use **integer arithmetic with specific scaling factors**:
- Bedrock: `/ 1_000_000` (1e6)
- Ecotone: `/ 16_000_000` (16e6)
- Fjord: `/ 1_000_000_000_000` (1e12)

Never use floating-point arithmetic for fee calculation - consensus critical!

## Reference Implementation

Primary reference: `/Users/williamcory/Guillotine/.scratch/crates/op-revm/` (Rust)

Key files:
- `src/l1block.rs` - L1BlockInfo and fee calculation
- `src/spec.rs` - OpSpecId enum
- `src/constants.rs` - Addresses and storage slots
- `src/transaction/deposit.rs` - Deposit transaction types

Cross-reference all implementations against these files for correctness.

## Zero-Cost Verification

To verify zero-cost abstraction:

```bash
# Build mainnet (default)
zig build -Doptimize=ReleaseFast
size zig-out/lib/libguillotine.a > mainnet.size

# Build with Optimism
zig build -Doptimize=ReleaseFast -Dlayer2=optimism
size zig-out/lib/libguillotine.a > optimism.size

# Compare
diff mainnet.size optimism.size
# Mainnet size should be identical to pre-L2 implementation
```

## Performance Impact

When `layer2_config = .optimism`:
- **No impact on mainnet** - All L2 code eliminated via DCE
- **Optimism execution** - Single comptime branch per handler (no runtime cost)
- **Binary size** - +~10KB for Optimism code (only when enabled)

The comptime branching ensures L2 support has **zero overhead for mainnet users**.
