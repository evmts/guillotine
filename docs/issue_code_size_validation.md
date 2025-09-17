# Missing Contract Code Size Validation in Production EVM Implementation

## Issue Summary

The production EVM implementation (`src/evm.zig`) is missing critical validation for deployed contract code size limits (EIP-170) and has incomplete implementation of init code size validation (EIP-3860). This allows contracts to be deployed that violate Ethereum protocol rules, potentially causing consensus issues.

## Problems Identified

### 1. Missing EIP-170 Validation (Contract Code Size Limit)

**Location**: `/Users/polarzero/code/tevm/guillotine/src/evm.zig:942-955` in `executeCreateInternal`

The production EVM **does not validate** that deployed contract code respects the size limits defined by EIP-170:
- Pre-Spurious Dragon: No limit
- Spurious Dragon onwards: 24KB (0x6000 bytes)
- Future Osaka hardfork: 49KB (0xC000 bytes)

**Current Code**:
```zig
if (result.output.len > 0) {
    // EIP-3541: Reject new contract code starting with the 0xEF byte
    const eips_instance = eips.Eips{ .hardfork = self.hardfork_config };
    if (eips_instance.should_reject_create_with_ef_bytecode(result.output)) {
        self.journal.revert_to_snapshot(args.snapshot_id);
        return CallResult.failure(0);
    }
    const stored_hash = self.database.set_code(result.output) catch {
        self.journal.revert_to_snapshot(args.snapshot_id);
        return CallResult.failure(0);
    };
    // ... rest of code storage logic
}
```

**Missing Validation**:
```zig
// MISSING: Check deployed contract code size limit
if (result.output.len > eips_instance.max_code_size()) {
    self.journal.revert_to_snapshot(args.snapshot_id);
    return CallResult.failure(0);  // Should use specific error
}
```

### 2. Incomplete EIP-3860 Implementation (Init Code Size Limit)

**Location**: `/Users/polarzero/code/tevm/guillotine/src/evm.zig:1155` in `execute_init_code`

The current implementation uses a generic `config.eips.size_limit()` check but:
1. Doesn't properly distinguish between init code and contract code limits
2. Returns generic failure instead of specific error types
3. Doesn't properly meter gas for init code (2 gas per 32-byte word post-Shanghai)

**Current Code**:
```zig
fn execute_init_code(self: *Self, code: []const u8, gas: u64, address: primitives.Address, snapshot_id: Journal.SnapshotIdType) !CallResult {
    if (code.len > config.eips.size_limit()) {
        log.debug("Init code too large: {} > 49152", .{code.len});
        return CallResult.failure(0);
    }
    // ... rest of execution
}
```

### 3. Missing Error Types

The production EVM returns generic `CallResult.failure(0)` for all size limit violations instead of using specific error types that match REVM's behavior:
- `CreateInitCodeSizeLimit` - for EIP-3860 violations
- `CreateContractSizeLimit` - for EIP-170 violations

## Expected Behavior (Per REVM Reference Implementation)

Based on REVM and Ethereum protocol specifications:

1. **Init Code Size Validation** (EIP-3860):
   - Check init code size against hardfork-specific limits
   - Pre-Shanghai: 24KB limit (same as contract code)
   - Shanghai-Prague: 49KB limit (2× contract code)
   - Future Osaka: 73KB limit
   - Return `CreateInitCodeSizeLimit` error on violation

2. **Contract Code Size Validation** (EIP-170):
   - Check deployed code size after init code execution
   - Pre-Spurious Dragon: No limit
   - Spurious Dragon onwards: 24KB limit
   - Future Osaka: 49KB limit
   - Return `CreateContractSizeLimit` error on violation

## Impact

1. **Consensus Risk**: Nodes running this implementation may accept contracts that other nodes reject, causing chain splits
2. **Protocol Violation**: Allows deployment of contracts that violate Ethereum protocol rules
3. **Gas Accounting Issues**: Missing proper gas metering for init code (EIP-3860)
4. **Interoperability Issues**: Contracts deployed with this EVM may not be valid on mainnet Ethereum

## Recommended Fix

### 1. Add Contract Code Size Validation in `executeCreateInternal`:

```zig
if (result.output.len > 0) {
    const eips_instance = eips.Eips{ .hardfork = self.hardfork_config };
    
    // EIP-170: Check contract code size limit
    if (result.output.len > eips_instance.max_code_size()) {
        self.journal.revert_to_snapshot(args.snapshot_id);
        // TODO: Return specific CreateContractSizeLimit error
        return CallResult.failure(0);
    }
    
    // EIP-3541: Reject new contract code starting with the 0xEF byte
    if (eips_instance.should_reject_create_with_ef_bytecode(result.output)) {
        self.journal.revert_to_snapshot(args.snapshot_id);
        return CallResult.failure(0);
    }
    
    // ... rest of code storage logic
}
```

### 2. Improve Init Code Validation in `execute_init_code`:

```zig
fn execute_init_code(self: *Self, code: []const u8, gas: u64, address: primitives.Address, snapshot_id: Journal.SnapshotIdType) !CallResult {
    const eips_instance = eips.Eips{ .hardfork = self.hardfork_config };
    
    // EIP-3860: Check init code size limit
    if (code.len > eips_instance.eip_3860_initcode_size_limit()) {
        log.debug("Init code exceeds size limit: {} > {}", .{code.len, eips_instance.eip_3860_initcode_size_limit()});
        // TODO: Return specific CreateInitCodeSizeLimit error
        return CallResult.failure(0);
    }
    
    // Calculate gas cost for init code (EIP-3860)
    const init_code_gas = eips_instance.eip_3860_initcode_word_cost() * ((code.len + 31) / 32);
    if (gas < init_code_gas) {
        return CallResult.failure(0);
    }
    
    const remaining_gas = gas - init_code_gas;
    
    // ... rest of execution with remaining_gas
}
```

### 3. Add Specific Error Types:

Update the CallResult structure or error handling to distinguish between different failure reasons, matching REVM's error types.

## References

- [EIP-170: Contract code size limit](https://eips.ethereum.org/EIPS/eip-170) (Spurious Dragon)
- [EIP-3860: Limit and meter initcode](https://eips.ethereum.org/EIPS/eip-3860) (Shanghai)
- [REVM Implementation](https://github.com/bluealloy/revm) - Reference implementation with correct error handling
- `src/eips_and_hardforks/eips.zig` - Contains the correct size limit functions that should be used

## Testing Requirements

1. Test CREATE/CREATE2 with init code exceeding limits for each hardfork
2. Test CREATE/CREATE2 with deployed code exceeding limits for each hardfork
3. Verify correct error types are returned
4. Test gas consumption for init code metering (EIP-3860)
5. Test boundary cases (exactly at limit, 1 byte over)

## Priority

**HIGH** - This is a protocol compliance issue that could cause consensus failures.