# CLAUDE.md - EIPs and Hardforks Module

## MISSION CRITICAL: Protocol Evolution and Compatibility
**Protocol errors cause consensus failures and network splits.**

## Hardfork Management
- **Berlin**: EIP-2929 (gas increases), EIP-2930 (access lists)
- **London**: EIP-1559 (fee market), EIP-3198 (BASEFEE)
- **Shanghai**: EIP-3651/3855/3860 optimizations
- **Cancun**: EIP-4844 (proto-danksharding), EIP-1153 (transient storage)

## Key Responsibilities
- **Feature Activation**: Enable opcodes/functionality at correct blocks
- **Gas Updates**: Apply new pricing per hardfork
- **Consensus Rules**: Enforce validation rules
- **Backward Compatibility**: Support historical transactions
- **Configuration**: Handle network-specific activation blocks

## Critical Safety
- Never activate features before designated blocks
- Exact consensus rules per hardfork
- Handle chain reorganizations across boundaries
- Validate EIP compliance
- Prevent feature regression

## Implementation Pattern
```zig
pub fn is_london_active(block_number: u64, config: *const ChainConfig) bool {
    return block_number >= config.london_block;
}

pub fn calculate_gas_fee(base_fee: u64, max_fee: u64, priority_fee: u64) u64 {
    return @min(max_fee, base_fee + priority_fee);
}
```

## Testing & Emergency
- Test hardfork transitions
- Validate historical replay
- Cross-reference official vectors
- Emergency deployment procedures
- Rollback mechanisms

**Protocol upgrades affect entire network. Exact EIP compliance prevents network splits.**