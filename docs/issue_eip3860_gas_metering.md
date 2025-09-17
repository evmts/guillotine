# Missing EIP-3860 Init Code Gas Metering in Production EVM

## Issue Summary

The production EVM (`src/evm.zig`) fails to charge gas for init code size as required by EIP-3860 (Shanghai hardfork). It should charge 2 gas per 32-byte word of init code, but currently only charges the base CREATE gas cost.

## The Bug

### Production EVM (INCORRECT) ❌

**CREATE** (`src/evm.zig:810-815`):
```zig
const create_overhead = GasConstants.CreateGas;  // Only 32,000 base gas
if (params.gas < create_overhead) {
    self.journal.revert_to_snapshot(snapshot_id);
    return CallResult.failure(0);
}
const remaining_gas: u64 = params.gas - create_overhead;  // ← MISSING: word cost!
```

**CREATE2** (`src/evm.zig:876-884`):
```zig
const create_overhead = GasConstants.CreateGas;
const hash_cost = @as(u64, @intCast(params.init_code.len)) * GasConstants.Keccak256WordGas / 32;
const total_overhead = create_overhead + hash_cost;  // ← MISSING: word cost!
```

### MinimalEVM Reference (CORRECT) ✅

**CREATE** (`src/tracer/minimal_frame.zig:254-263`):
```zig
fn createGasCost(self: *const Self, init_code_size: u32) u64 {
    var gas_cost: u64 = GasConstants.CreateGas;
    
    if (self.hardfork.isAtLeast(.SHANGHAI)) {
        const word_count = wordCount(@as(u64, init_code_size));
        gas_cost += word_count * GasConstants.InitcodeWordGas;  // ← 2 gas per word
    }
    
    return gas_cost;
}
```

## Impact

Post-Shanghai, deploying a 1KB contract should cost:
- **Expected**: 32,000 + (1024/32 * 2) = 32,064 gas
- **Actual**: 32,000 gas
- **Missing**: 64 gas

This allows cheaper contract deployments than protocol specifications require, creating:
1. **Consensus risk** - Other nodes will reject transactions this EVM accepts
2. **DoS vector** - Attackers can deploy large contracts for less gas than intended

## Fix

Add init code word cost calculation to both CREATE and CREATE2:

```zig
// CREATE fix
const create_overhead = GasConstants.CreateGas;
var total_gas = create_overhead;

// Add EIP-3860 init code gas (Shanghai+)
const eips_instance = eips.Eips{ .hardfork = self.hardfork_config };
if (eips_instance.eip_3860_initcode_word_cost() > 0) {
    const word_count = (params.init_code.len + 31) / 32;
    total_gas += word_count * eips_instance.eip_3860_initcode_word_cost();
}

if (params.gas < total_gas) {
    self.journal.revert_to_snapshot(snapshot_id);
    return CallResult.failure(0);
}
const remaining_gas: u64 = params.gas - total_gas;
```

## References

- [EIP-3860: Limit and meter initcode](https://eips.ethereum.org/EIPS/eip-3860)
- `GasConstants.InitcodeWordGas = 2` (defined in `src/primitives/gas_constants.zig:205`)
- `eips.eip_3860_initcode_word_cost()` (available in `src/eips_and_hardforks/eips.zig:190-193`)

## Priority

**HIGH** - Protocol compliance issue affecting gas accounting post-Shanghai.