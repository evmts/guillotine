# Arbitrum Implementation (Saved for Future PR)

## Overview
This document preserves the Arbitrum L2 implementation that was removed from the main Optimism PR. This implementation will be restored in a separate PR dedicated to Arbitrum support.

## Files to Restore

### 1. Chain Type Support
In `src/evm/chain_type.zig`, add back:
```zig
/// Arbitrum Layer 2
ARBITRUM,

// In fromChainId function:
// Arbitrum chains
42161 => .ARBITRUM, // Arbitrum One
421614 => .ARBITRUM, // Arbitrum Sepolia
42170 => .ARBITRUM, // Arbitrum Nova
```

### 2. L2 Precompile Addresses
In `src/evm/precompiles/l2_precompile_addresses.zig`, add back:
```zig
/// Arbitrum L2 precompile addresses
pub const ARBITRUM = struct {
    /// ArbSys - System configuration and chain info
    pub const ARB_SYS = primitives.Address.from_hex("0x0000000000000000000000000000000000000064") catch unreachable;
    
    /// ArbInfo - Chain metadata  
    pub const ARB_INFO = primitives.Address.from_hex("0x0000000000000000000000000000000000000065") catch unreachable;
    
    /// ArbAddressTable - Address aliasing for L1->L2 messages
    pub const ARB_ADDRESS_TABLE = primitives.Address.from_hex("0x0000000000000000000000000000000000000066") catch unreachable;
    
    /// ArbosTest - Testing utilities
    pub const ARB_OS_TEST = primitives.Address.from_hex("0x0000000000000000000000000000000000000069") catch unreachable;
    
    /// ArbRetryableTx - Retryable transaction management
    pub const ARB_RETRYABLE_TX = primitives.Address.from_hex("0x000000000000000000000000000000000000006e") catch unreachable;
    
    /// ArbGasInfo - Gas pricing information
    pub const ARB_GAS_INFO = primitives.Address.from_hex("0x000000000000000000000000000000000000006c") catch unreachable;
    
    /// ArbAggregator - Batch and data availability info
    pub const ARB_AGGREGATOR = primitives.Address.from_hex("0x000000000000000000000000000000000000006d") catch unreachable;
    
    /// ArbStatistics - Chain statistics
    pub const ARB_STATISTICS = primitives.Address.from_hex("0x000000000000000000000000000000000000006f") catch unreachable;
};
```

### 3. Arbitrum Precompiles
Create `src/evm/precompiles/arbitrum/` directory with:

#### `arb_sys.zig`:
```zig
const std = @import("std");
const PrecompileOutput = @import("../precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("../precompile_result.zig").PrecompileError;

/// ArbSys precompile (0x64)
/// Provides Arbitrum system information
pub fn execute(input: []const u8, output: []u8, gas_limit: u64) PrecompileOutput {
    const gas_cost = 100;
    
    if (gas_cost > gas_limit) {
        return PrecompileOutput.failure_result(PrecompileError.OutOfGas);
    }
    
    if (input.len < 4) {
        return PrecompileOutput.failure_result(PrecompileError.InvalidInput);
    }
    
    const selector = std.mem.readInt(u32, input[0..4], .big);
    
    const result: usize = switch (selector) {
        // arbBlockNumber()
        0xa3b1b31d => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            @memset(output[0..32], 0);
            output[31] = 42; // Mock block number
            break :blk 32;
        },
        // arbChainID()
        0x6c94c87b => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            @memset(output[0..32], 0);
            output[29] = 0xa4;
            output[30] = 0xb1; // 42161 (Arbitrum One)
            break :blk 32;
        },
        else => return PrecompileOutput.failure_result(PrecompileError.InvalidInput),
    };
    
    return PrecompileOutput.success_result(gas_cost, result);
}
```

#### `arb_info.zig`:
```zig
const std = @import("std");
const PrecompileOutput = @import("../precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("../precompile_result.zig").PrecompileError;

/// ArbInfo precompile (0x65)
/// Provides Arbitrum chain information
pub fn execute(input: []const u8, output: []u8, gas_limit: u64) PrecompileOutput {
    const gas_cost = 100;
    
    if (gas_cost > gas_limit) {
        return PrecompileOutput.failure_result(PrecompileError.OutOfGas);
    }
    
    if (input.len < 4) {
        return PrecompileOutput.failure_result(PrecompileError.InvalidInput);
    }
    
    const selector = std.mem.readInt(u32, input[0..4], .big);
    
    const result: usize = switch (selector) {
        // getChainId()
        0x3408e470 => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            @memset(output[0..32], 0);
            output[29] = 0xa4;
            output[30] = 0xb1; // 42161
            break :blk 32;
        },
        else => return PrecompileOutput.failure_result(PrecompileError.InvalidInput),
    };
    
    return PrecompileOutput.success_result(gas_cost, result);
}
```

### 4. Precompile Dispatcher Updates
In `src/evm/precompiles/precompiles.zig`:

Add imports:
```zig
const arb_sys = @import("arbitrum/arb_sys.zig");
const arb_info = @import("arbitrum/arb_info.zig");
```

Update `is_l2_precompile`:
```zig
.ARBITRUM => std.mem.eql(u8, &address, &l2_addresses.ARBITRUM.ARB_SYS) or
            std.mem.eql(u8, &address, &l2_addresses.ARBITRUM.ARB_INFO) or
            std.mem.eql(u8, &address, &l2_addresses.ARBITRUM.ARB_ADDRESS_TABLE) or
            std.mem.eql(u8, &address, &l2_addresses.ARBITRUM.ARB_OS_TEST) or
            std.mem.eql(u8, &address, &l2_addresses.ARBITRUM.ARB_RETRYABLE_TX) or
            std.mem.eql(u8, &address, &l2_addresses.ARBITRUM.ARB_GAS_INFO) or
            std.mem.eql(u8, &address, &l2_addresses.ARBITRUM.ARB_AGGREGATOR) or
            std.mem.eql(u8, &address, &l2_addresses.ARBITRUM.ARB_STATISTICS),
```

Update `execute_precompile`:
```zig
.ARBITRUM => {
    if (std.mem.eql(u8, &address, &l2_addresses.ARBITRUM.ARB_SYS)) {
        return arb_sys.execute(input, output, gas_limit);
    } else if (std.mem.eql(u8, &address, &l2_addresses.ARBITRUM.ARB_INFO)) {
        return arb_info.execute(input, output, gas_limit);
    }
    return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
},
```

### 5. Test Updates
Add back Arbitrum tests in `test/evm/l2_integration_test.zig` and `test/evm/l2_vm_integration_test.zig`.

## Implementation Notes
- All Arbitrum precompiles currently return mock values
- Full implementation would require:
  - ArbOS state access
  - L1/L2 messaging
  - Arbitrum-specific gas model
  - Retryable transaction support
  - Additional precompiles

## Future Work
1. Complete all Arbitrum precompiles
2. Implement Arbitrum-specific opcodes
3. Add Arbitrum gas pricing model
4. Support retryable transactions
5. L1/L2 cross-chain messaging