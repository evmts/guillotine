# Block Context

Execution-time block and transaction context for the EVM.

## Overview

This module does not implement blockchain consensus or block validation. It provides the data structures the EVM reads via environment opcodes (e.g., NUMBER, TIMESTAMP, COINBASE, GASLIMIT, CHAINID, PREVRANDAO) and EIPs such as 1559, 4844, and 4788.

## Files

- `block_info.zig` — Compile-time configurable BlockInfo type exposed to the EVM.
- `transaction_context.zig` — Per-transaction context (gas limit, coinbase, chain id, blob fields).
- `../frame/block_info_config.zig` — Configuration types for BlockInfo field types and validation.

## BlockInfo

`BlockInfo` is a generic factory that produces a struct with the correct field types for the current hardfork. The factory takes a `BlockInfoConfig` parameter to customize field types. Two presets are exposed:
- `DefaultBlockInfo` — Spec-compliant (u256 for difficulty/prevrandao and base_fee).
- `CompactBlockInfo` — Practical u64 types for performance-sensitive usage.

### Key Fields

All BlockInfo instances contain these fields:
- `chain_id: u64` — Chain ID for EIP-155 replay protection (default: 1 for mainnet)
- `number: u64` — Block number
- `parent_hash: [32]u8` — Parent block hash (for EIP-2935 historical block hashes)
- `timestamp: u64` — Block timestamp
- `difficulty: {u64|u128|u256}` — Block difficulty (pre-merge) or prevrandao (post-merge, configurable)
- `gas_limit: u64` — Block gas limit
- `coinbase: Address` — Coinbase (miner/validator) address
- `base_fee: {u64|u96|u256}` — Base fee per gas (EIP-1559, configurable)
- `prev_randao: [32]u8` — Block hash of previous block (post-merge: prevrandao value)
- `blob_base_fee: {u64|u96|u256}` — Blob base fee for EIP-4844 (configurable, default: 0)
- `blob_versioned_hashes: []const [32]u8` — Blob versioned hashes for EIP-4844 blob transactions (default: empty)
- `beacon_root: ?[32]u8` — Beacon block root for EIP-4788 (Dencun, default: null)

### Methods

- `init()` — Initialize with zero/neutral defaults and mainnet chain_id=1
- `hasBaseFee()` — Convenience check for EIP-1559 base fee support (true if base_fee > 0 or number > 0)
- `validate()` — Basic sanity checks (timestamp ≥ Ethereum genesis, gas limit bounds 1-100M)

### Examples

Basic usage:
```zig
const std = @import("std");
const primitives = @import("primitives");
const Block = @import("block_info.zig").DefaultBlockInfo;

test "basic block info" {
    const block = Block{
        .chain_id = 1,
        .number = 18_000_000,
        .timestamp = 1700000000,
        .difficulty = 0, // Post-merge
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 20_000_000_000, // 20 gwei
        .prev_randao = [_]u8{0xAB} ** 32,
    };
    try std.testing.expect(block.validate());
    try std.testing.expect(block.hasBaseFee());
}
```

Custom configuration:
```zig
const BlockInfoConfig = @import("../frame/block_info_config.zig").BlockInfoConfig;
const BlockInfo = @import("block_info.zig").BlockInfo;

// Mixed precision types
const MixedConfig = BlockInfoConfig{
    .DifficultyType = u128,
    .BaseFeeType = u96,
};
const MixedBlockInfo = BlockInfo(MixedConfig);

// Compact types for performance
const CompactBlock = @import("block_info.zig").CompactBlockInfo; // Uses u64 for fees
```

EIP-4844 blob transaction support:
```zig
test "blob transaction block" {
    const blob_hashes = [_][32]u8{
        [_]u8{0x01} ** 32,
        [_]u8{0x02} ** 32,
    };
    
    const block = DefaultBlockInfo{
        .chain_id = 1,
        .number = 18_000_000,
        .timestamp = 1700000000,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 20_000_000_000,
        .blob_base_fee = 1_000_000_000, // 1 gwei
        .blob_versioned_hashes = &blob_hashes,
        .beacon_root = [_]u8{0xCD} ** 32, // EIP-4788
        // ... other fields
    };
    try std.testing.expectEqual(@as(usize, 2), block.blob_versioned_hashes.len);
}
```

## BlockInfoConfig

`BlockInfoConfig` provides compile-time configuration for `BlockInfo` field types:

### Fields
- `DifficultyType: type` — Type for difficulty field (default: u256)
- `BaseFeeType: type` — Type for base_fee and blob_base_fee fields (default: u256)  
- `use_compact_types: bool` — When true, overrides types to u64 for efficiency (default: false)

### Methods
- `getDifficultyType()` — Returns configured difficulty type (u64 if compact, otherwise DifficultyType)
- `getBaseFeeType()` — Returns configured base fee type (u64 if compact, otherwise BaseFeeType)
- `validate()` — Compile-time validation of configuration (ensures integer types ≥ u64)

### Examples
```zig
// Default: spec-compliant u256 types
const DefaultConfig = BlockInfoConfig{};

// Compact: u64 types for performance  
const CompactConfig = BlockInfoConfig{ .use_compact_types = true };

// Custom: mixed precision
const CustomConfig = BlockInfoConfig{
    .DifficultyType = u128,
    .BaseFeeType = u96,
};
```

## TransactionContext

`TransactionContext` holds immutable, per-transaction parameters used during execution:

### Fields
- `gas_limit: u64` — Transaction gas limit
- `coinbase: Address` — Coinbase address (miner/validator) 
- `chain_id: u16` — Chain ID (supports chain IDs up to 65535, used by CHAINID opcode)
- `blob_versioned_hashes: []const [32]u8` — Blob versioned hashes for EIP-4844 (default: empty)
- `blob_base_fee: u256` — Blob base fee for EIP-4844 (default: 0)

### Examples

Basic transaction:
```zig
const TransactionContext = @import("transaction_context.zig").TransactionContext;
const coinbase_addr = Address{ .bytes = [_]u8{0x01} ++ [_]u8{0x00} ** 19 };

const tx_ctx = TransactionContext{
    .gas_limit = 21_000,
    .coinbase = coinbase_addr,
    .chain_id = 1,
};
```

Blob transaction (EIP-4844):
```zig
test "blob transaction context" {
    const blob_hashes = [_][32]u8{
        [_]u8{0x01} ** 32,
        [_]u8{0x02} ** 32,
    };
    
    const blob_ctx = TransactionContext{
        .gas_limit = 30_000_000,
        .coinbase = coinbase_addr,
        .chain_id = 1,
        .blob_versioned_hashes = &blob_hashes,
        .blob_base_fee = 1_000_000_000, // 1 gwei
    };
    
    try std.testing.expectEqual(@as(usize, 2), blob_ctx.blob_versioned_hashes.len);
}
```

## EIP Support

This module provides comprehensive support for:

- **EIP-155**: Replay protection via `chain_id` field
- **EIP-1559**: Base fee mechanism via `base_fee` field and `hasBaseFee()` helper
- **EIP-2935**: Historical block hashes via `parent_hash` field
- **EIP-4844**: Blob transactions via `blob_base_fee` and `blob_versioned_hashes` fields
- **EIP-4788**: Beacon block root access via `beacon_root` field (Dencun hardfork)

## Validation

Both `BlockInfo` and `TransactionContext` include comprehensive validation:

### BlockInfo Validation
- Gas limit: 1 ≤ gas_limit ≤ 100,000,000
- Timestamp: ≥ Ethereum genesis timestamp (1438269973) or 0 for genesis
- Type safety: Compile-time validation of numeric field types

### Test Coverage
- Boundary value testing for all numeric fields
- Edge case handling (zero values, maximum values)  
- EIP-specific functionality validation
- Type system verification for custom configurations
- Memory layout and field ordering verification

## Notes

- This module is intentionally decoupled from block validation/consensus. It focuses solely on the EVM's view of the block and transaction.
- Extensive tests live next to the implementations to validate type choices, boundary conditions, and EIP-specific fields.
- The configuration system allows optimization for different use cases: spec compliance vs. performance vs. custom precision requirements.
- All EIP-related fields have sensible defaults for pre-fork compatibility.
