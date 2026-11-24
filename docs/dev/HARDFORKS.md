# Hardfork Support

This document covers hardfork handling, EIP support, opcode reference, and feature activation across both EVM implementations.

## Quick Reference

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          HARDFORK TIMELINE                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   FRONTIER ──▶ HOMESTEAD ──▶ TANGERINE ──▶ SPURIOUS ──▶ BYZANTIUM          │
│   (Genesis)    (1.15M)       WHISTLE       DRAGON       (4.37M)             │
│                              (2.46M)       (2.67M)                          │
│                                                                             │
│   ──▶ CONSTANTINOPLE ──▶ PETERSBURG ──▶ ISTANBUL ──▶ BERLIN ──▶ LONDON     │
│       (7.28M)            (7.28M)        (9.07M)      (12.24M)   (12.96M)    │
│                                                                             │
│   ──▶ MERGE ──▶ SHANGHAI ──▶ CANCUN ──▶ PRAGUE ──▶ OSAKA ──▶ AMSTERDAM     │
│       (15.54M)  (17.03M)     (19.43M)   (22.43M)   (23.94M)  (unscheduled)  │
│                                                                             │
│   DEFAULT: OSAKA                                                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Supported Hardforks

Both EVMs use one enum, defined in `lib/voltaire/src/primitives/hardfork.zig` and re-exported by `src/eips_and_hardforks/hardfork.zig`. Block numbers come from `Hardfork.mainnetActivationBlock()`.

```zig
// lib/voltaire/src/primitives/hardfork.zig
pub const Hardfork = enum {
    FRONTIER,          // Block 0
    HOMESTEAD,         // Block 1,150,000
    DAO,               // Block 1,920,000 (no EVM changes)
    TANGERINE_WHISTLE, // Block 2,463,000 (EIP-150)
    SPURIOUS_DRAGON,   // Block 2,675,000 (EIP-155, 160, 161)
    BYZANTIUM,         // Block 4,370,000
    CONSTANTINOPLE,    // Block 7,280,000
    PETERSBURG,        // Block 7,280,000 (removes EIP-1283)
    ISTANBUL,          // Block 9,069,000
    MUIR_GLACIER,      // Block 9,200,000 (no EVM changes)
    BERLIN,            // Block 12,244,000
    LONDON,            // Block 12,965,000
    ARROW_GLACIER,     // Block 13,773,000 (no EVM changes)
    GRAY_GLACIER,      // Block 15,050,000 (no EVM changes)
    MERGE,             // Block 15,537,394 (Paris)
    SHANGHAI,          // Block 17,034,870
    CANCUN,            // Block 19,426,587
    PRAGUE,            // Block 22,431,084
    OSAKA,             // Block 23,935,694
    AMSTERDAM,         // Not scheduled

    pub const DEFAULT = Hardfork.OSAKA;
};
```

## Complete Opcode Reference

### Arithmetic (0x00-0x0B)

| Hex | Name | Stack | Gas | Fork | Description |
|-----|------|-------|-----|------|-------------|
| 0x00 | STOP | 0→0 | 0 | Frontier | Halt execution |
| 0x01 | ADD | 2→1 | 3 | Frontier | a + b (mod 2^256) |
| 0x02 | MUL | 2→1 | 5 | Frontier | a × b (mod 2^256) |
| 0x03 | SUB | 2→1 | 3 | Frontier | a - b (mod 2^256) |
| 0x04 | DIV | 2→1 | 5 | Frontier | a ÷ b (0 if b=0) |
| 0x05 | SDIV | 2→1 | 5 | Frontier | Signed division |
| 0x06 | MOD | 2→1 | 5 | Frontier | a mod b (0 if b=0) |
| 0x07 | SMOD | 2→1 | 5 | Frontier | Signed modulo |
| 0x08 | ADDMOD | 3→1 | 8 | Frontier | (a + b) mod N |
| 0x09 | MULMOD | 3→1 | 8 | Frontier | (a × b) mod N |
| 0x0A | EXP | 2→1 | 10+50×B | Frontier | a^b (B=byte len of exp) |
| 0x0B | SIGNEXTEND | 2→1 | 5 | Frontier | Sign extend |

### Comparison & Bitwise (0x10-0x1E)

| Hex | Name | Stack | Gas | Fork | Description |
|-----|------|-------|-----|------|-------------|
| 0x10 | LT | 2→1 | 3 | Frontier | a < b |
| 0x11 | GT | 2→1 | 3 | Frontier | a > b |
| 0x12 | SLT | 2→1 | 3 | Frontier | Signed less than |
| 0x13 | SGT | 2→1 | 3 | Frontier | Signed greater than |
| 0x14 | EQ | 2→1 | 3 | Frontier | a == b |
| 0x15 | ISZERO | 1→1 | 3 | Frontier | a == 0 |
| 0x16 | AND | 2→1 | 3 | Frontier | Bitwise AND |
| 0x17 | OR | 2→1 | 3 | Frontier | Bitwise OR |
| 0x18 | XOR | 2→1 | 3 | Frontier | Bitwise XOR |
| 0x19 | NOT | 1→1 | 3 | Frontier | Bitwise NOT |
| 0x1A | BYTE | 2→1 | 3 | Frontier | Get byte at index |
| 0x1B | SHL | 2→1 | 3 | Constantinople | Shift left |
| 0x1C | SHR | 2→1 | 3 | Constantinople | Shift right |
| 0x1D | SAR | 2→1 | 3 | Constantinople | Arithmetic shift right |
| 0x1E | CLZ | 1→1 | 5 | Osaka | Count leading zeros (EIP-7939). Performance EVM only; Mini returns `InvalidOpcode` |

### Keccak (0x20)

| Hex | Name | Stack | Gas | Fork | Description |
|-----|------|-------|-----|------|-------------|
| 0x20 | KECCAK256 | 2→1 | 30+6×W | Frontier | Keccak-256 hash (W=word count) |

### Environmental (0x30-0x3F)

| Hex | Name | Stack | Gas | Fork | Description |
|-----|------|-------|-----|------|-------------|
| 0x30 | ADDRESS | 0→1 | 2 | Frontier | Current address |
| 0x31 | BALANCE | 1→1 | 100/2600 | Frontier | Address balance (warm/cold) |
| 0x32 | ORIGIN | 0→1 | 2 | Frontier | Transaction origin |
| 0x33 | CALLER | 0→1 | 2 | Frontier | Direct caller |
| 0x34 | CALLVALUE | 0→1 | 2 | Frontier | Call value (wei) |
| 0x35 | CALLDATALOAD | 1→1 | 3 | Frontier | Load 32 bytes calldata |
| 0x36 | CALLDATASIZE | 0→1 | 2 | Frontier | Calldata size |
| 0x37 | CALLDATACOPY | 3→0 | 3+3×W | Frontier | Copy calldata to memory |
| 0x38 | CODESIZE | 0→1 | 2 | Frontier | Code size |
| 0x39 | CODECOPY | 3→0 | 3+3×W | Frontier | Copy code to memory |
| 0x3A | GASPRICE | 0→1 | 2 | Frontier | Gas price |
| 0x3B | EXTCODESIZE | 1→1 | 100/2600 | Frontier | External code size |
| 0x3C | EXTCODECOPY | 4→0 | 100/2600+3×W | Frontier | Copy external code |
| 0x3D | RETURNDATASIZE | 0→1 | 2 | Byzantium | Return data size |
| 0x3E | RETURNDATACOPY | 3→0 | 3+3×W | Byzantium | Copy return data |
| 0x3F | EXTCODEHASH | 1→1 | 100/2600 | Constantinople | External code hash |

### Block (0x40-0x4A)

| Hex | Name | Stack | Gas | Fork | Description |
|-----|------|-------|-----|------|-------------|
| 0x40 | BLOCKHASH | 1→1 | 20 | Frontier | Block hash (last 256) |
| 0x41 | COINBASE | 0→1 | 2 | Frontier | Block coinbase |
| 0x42 | TIMESTAMP | 0→1 | 2 | Frontier | Block timestamp |
| 0x43 | NUMBER | 0→1 | 2 | Frontier | Block number |
| 0x44 | PREVRANDAO | 0→1 | 2 | Frontier | DIFFICULTY before Merge; previous RANDAO from Merge |
| 0x45 | GASLIMIT | 0→1 | 2 | Frontier | Block gas limit |
| 0x46 | CHAINID | 0→1 | 2 | Istanbul | Chain ID |
| 0x47 | SELFBALANCE | 0→1 | 5 | Istanbul | Self balance |
| 0x48 | BASEFEE | 0→1 | 2 | London | Block base fee |
| 0x49 | BLOBHASH | 1→1 | 3 | Cancun | Blob hash at index |
| 0x4A | BLOBBASEFEE | 0→1 | 2 | Cancun | Blob base fee |

### Stack/Memory/Storage (0x50-0x5F)

| Hex | Name | Stack | Gas | Fork | Description |
|-----|------|-------|-----|------|-------------|
| 0x50 | POP | 1→0 | 2 | Frontier | Pop top of stack |
| 0x51 | MLOAD | 1→1 | 3+M | Frontier | Load word from memory |
| 0x52 | MSTORE | 2→0 | 3+M | Frontier | Store word to memory |
| 0x53 | MSTORE8 | 2→0 | 3+M | Frontier | Store byte to memory |
| 0x54 | SLOAD | 1→1 | 100/2100 | Frontier | Load from storage |
| 0x55 | SSTORE | 2→0 | 100-20000 | Frontier | Store to storage |
| 0x56 | JUMP | 1→0 | 8 | Frontier | Unconditional jump |
| 0x57 | JUMPI | 2→0 | 10 | Frontier | Conditional jump |
| 0x58 | PC | 0→1 | 2 | Frontier | Program counter |
| 0x59 | MSIZE | 0→1 | 2 | Frontier | Memory size |
| 0x5A | GAS | 0→1 | 2 | Frontier | Remaining gas |
| 0x5B | JUMPDEST | 0→0 | 1 | Frontier | Jump destination |
| 0x5C | TLOAD | 1→1 | 100 | Cancun | Load transient storage |
| 0x5D | TSTORE | 2→0 | 100 | Cancun | Store transient storage |
| 0x5E | MCOPY | 3→0 | 3+3×W+M | Cancun | Memory copy |
| 0x5F | PUSH0 | 0→1 | 2 | Shanghai | Push zero |

### PUSH (0x60-0x7F)

| Hex | Name | Stack | Gas | Fork | Description |
|-----|------|-------|-----|------|-------------|
| 0x60 | PUSH1 | 0→1 | 3 | Frontier | Push 1 byte |
| 0x61 | PUSH2 | 0→1 | 3 | Frontier | Push 2 bytes |
| ... | ... | ... | ... | ... | ... |
| 0x7F | PUSH32 | 0→1 | 3 | Frontier | Push 32 bytes |

### DUP (0x80-0x8F)

| Hex | Name | Stack | Gas | Fork | Description |
|-----|------|-------|-----|------|-------------|
| 0x80 | DUP1 | 1→2 | 3 | Frontier | Duplicate 1st item |
| 0x81 | DUP2 | 2→3 | 3 | Frontier | Duplicate 2nd item |
| ... | ... | ... | ... | ... | ... |
| 0x8F | DUP16 | 16→17 | 3 | Frontier | Duplicate 16th item |

### SWAP (0x90-0x9F)

| Hex | Name | Stack | Gas | Fork | Description |
|-----|------|-------|-----|------|-------------|
| 0x90 | SWAP1 | 2→2 | 3 | Frontier | Swap 1st and 2nd |
| 0x91 | SWAP2 | 3→3 | 3 | Frontier | Swap 1st and 3rd |
| ... | ... | ... | ... | ... | ... |
| 0x9F | SWAP16 | 17→17 | 3 | Frontier | Swap 1st and 17th |

### LOG (0xA0-0xA4)

| Hex | Name | Stack | Gas | Fork | Description |
|-----|------|-------|-----|------|-------------|
| 0xA0 | LOG0 | 2→0 | 375+8×S | Frontier | Log with 0 topics |
| 0xA1 | LOG1 | 3→0 | 750+8×S | Frontier | Log with 1 topic |
| 0xA2 | LOG2 | 4→0 | 1125+8×S | Frontier | Log with 2 topics |
| 0xA3 | LOG3 | 5→0 | 1500+8×S | Frontier | Log with 3 topics |
| 0xA4 | LOG4 | 6→0 | 1875+8×S | Frontier | Log with 4 topics |

### System (0xF0-0xFF)

| Hex | Name | Stack | Gas | Fork | Description |
|-----|------|-------|-----|------|-------------|
| 0xF0 | CREATE | 3→1 | 32000+... | Frontier | Create contract |
| 0xF1 | CALL | 7→1 | 100/2600+... | Frontier | Message call |
| 0xF2 | CALLCODE | 7→1 | 100/2600+... | Frontier | Message call (code) |
| 0xF3 | RETURN | 2→0 | 0+M | Frontier | Halt with output |
| 0xF4 | DELEGATECALL | 6→1 | 100/2600+... | Homestead | Delegate call |
| 0xF5 | CREATE2 | 4→1 | 32000+... | Constantinople | Create2 |
| 0xFA | STATICCALL | 6→1 | 100/2600+... | Byzantium | Static call |
| 0xFD | REVERT | 2→0 | 0+M | Byzantium | Halt with output, revert |
| 0xFE | INVALID | - | all | Frontier | Invalid opcode |
| 0xFF | SELFDESTRUCT | 1→0 | 5000+... | Frontier | Self-destruct |

**Legend:**
- Gas: M=memory expansion, W=word count, S=data size, B=byte length
- Stack: inputs→outputs
- 100/2600 = warm/cold access cost (Berlin+)

## EIP Support Matrix

### Berlin (Block 12,244,000)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          BERLIN CHANGES (EIP-2929)                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   Access Lists (EIP-2930):                                                  │
│   ─────────────────────────                                                 │
│   Pre-warm addresses and storage slots in transaction                       │
│   Cost: 2400/address + 1900/slot                                           │
│                                                                             │
│   Gas Cost Changes:                                                         │
│   ─────────────────                                                         │
│   ┌────────────────┬──────────────┬──────────────┐                         │
│   │ Operation      │ Istanbul     │ Berlin+      │                         │
│   ├────────────────┼──────────────┼──────────────┤                         │
│   │ SLOAD          │ 800          │ 100/2100     │                         │
│   │ BALANCE        │ 700          │ 100/2600     │                         │
│   │ EXTCODESIZE    │ 700          │ 100/2600     │                         │
│   │ EXTCODEHASH    │ 700          │ 100/2600     │                         │
│   │ EXTCODECOPY    │ 700          │ 100/2600     │                         │
│   │ CALL/etc       │ 700          │ 100/2600     │                         │
│   └────────────────┴──────────────┴──────────────┘                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### London (Block 12,965,000)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          LONDON CHANGES                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   EIP-1559: Fee Market                                                      │
│   ─────────────────────                                                     │
│   Base fee per gas, dynamic adjustment                                      │
│   New transaction type with maxFeePerGas, maxPriorityFeePerGas             │
│                                                                             │
│   EIP-3198: BASEFEE opcode (0x48)                                          │
│   ─────────────────────────────────                                         │
│   Returns current block's base fee                                          │
│   Gas: 2                                                                    │
│                                                                             │
│   EIP-3529: Reduced refunds                                                 │
│   ──────────────────────────                                                │
│   Refund cap: 50% → 20%                                                    │
│   SELFDESTRUCT refund: 24000 → 0                                           │
│   SSTORE clear refund: 15000 → 4800                                        │
│                                                                             │
│   EIP-3541: 0xEF prefix rejection                                          │
│   ─────────────────────────────                                             │
│   Cannot deploy code starting with 0xEF (reserved for EOF)                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Shanghai (Block 17,034,870)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          SHANGHAI CHANGES                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   EIP-3651: Warm COINBASE                                                   │
│   ─────────────────────────                                                 │
│   Coinbase address pre-warmed at tx start (100 gas instead of 2600)        │
│                                                                             │
│   EIP-3855: PUSH0 (0x5F)                                                   │
│   ──────────────────────                                                    │
│   Push constant 0 onto stack                                                │
│   More efficient than PUSH1 0x00                                           │
│   Gas: 2                                                                    │
│                                                                             │
│   EIP-3860: Initcode size limit                                            │
│   ─────────────────────────────                                             │
│   Max initcode: 2 × MAX_CODE_SIZE = 49152 bytes                            │
│   Initcode gas: INITCODE_WORD_COST (2) × words                             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Cancun (Block 19,426,587)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          CANCUN CHANGES                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   EIP-1153: Transient Storage                                               │
│   ─────────────────────────────                                             │
│   TLOAD (0x5C): Load transient storage     Gas: 100 (always warm)          │
│   TSTORE (0x5D): Store transient storage   Gas: 100 (always warm)          │
│   • Cleared at transaction boundary                                         │
│   • Writes roll back when their call frame reverts                          │
│   • Useful for reentrancy guards, flash loans                              │
│                                                                             │
│   EIP-4844: Shard Blob Transactions                                         │
│   ─────────────────────────────────                                         │
│   BLOBHASH (0x49): Get blob hash at index   Gas: 3                         │
│   BLOBBASEFEE (0x4A): Get blob base fee     Gas: 2                         │
│   New transaction type 0x03 with blob data                                  │
│                                                                             │
│   EIP-5656: MCOPY (0x5E)                                                   │
│   ───────────────────────                                                   │
│   Copy memory within same context                                           │
│   Gas: 3 + 3×words + memory_expansion                                       │
│   Handles overlapping regions correctly                                     │
│                                                                             │
│   EIP-6780: SELFDESTRUCT Changes                                           │
│   ───────────────────────────────                                           │
│   Only destroys if created in same transaction                             │
│   Otherwise just transfers balance                                          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Prague (Block 22,431,084)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          PRAGUE CHANGES                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   EIP-7702: Set Code Transactions                                           │
│   ─────────────────────────────────                                         │
│   Allows EOAs to temporarily have code                                      │
│   New transaction type 0x04 with authorization                              │
│                                                                             │
│   EIP-2537: BLS12-381 Precompiles                                          │
│   ─────────────────────────────────                                         │
│   Addresses 0x0B-0x11:                                                      │
│   • BLS12_G1ADD (0x0B)                                                      │
│   • BLS12_G1MSM (0x0C)                                                      │
│   • BLS12_G2ADD (0x0D)                                                      │
│   • BLS12_G2MSM (0x0E)                                                      │
│   • BLS12_PAIRING_CHECK (0x0F)                                              │
│   • BLS12_MAP_FP_TO_G1 (0x10)                                               │
│   • BLS12_MAP_FP2_TO_G2 (0x11)                                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Osaka (Block 23,935,694, default)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          OSAKA CHANGES                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   EIP-7939: CLZ (0x1E)                                                      │
│   Count leading zeros of the top word. Gas: 5                               │
│                                                                             │
│   EIP-7951: P256VERIFY precompile at 0x100. Gas: 6900                       │
│                                                                             │
│   EIP-7823 / EIP-7883: MODEXP 1024-byte operand bound and repricing         │
│                                                                             │
│   EIP-7825: Transaction gas limit cap of 2^24 (16,777,216)                  │
│                                                                             │
│   EIP-7934: RLP execution block size limit                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Hardfork Detection

### Compile-Time (Performance EVM)

The Performance EVM fixes its fork at compile time in `EvmConfig.eips.hardfork` (`src/evm_config.zig`, default `Hardfork.DEFAULT`). Code branches on it with `comptime`:

```zig
// src/evm.zig, Evm(config).callImpl
// EIP-2929 (Berlin+): exactly the precompiles active in this fork start warm.
if (comptime config.eips.hardfork.isAtLeast(.BERLIN)) {
    const last = comptime precompiles.lastContiguousPrecompile(config.eips.hardfork);
    // warm 0x01..last
}

// src/instructions/handlers_bitwise.zig (FrameConfig carries the same fork)
if (comptime FrameType.config.hardfork.isBefore(.OSAKA)) {
    return error.InvalidOpcode; // CLZ
}
```

Runtime code reads the same value through `evm.is_hardfork_at_least(.LONDON)` and `evm.get_hardfork()`.

### Runtime Checks (Mini EVM)

The Mini EVM stores the fork in the `hardfork` field of `Evm` (`mini/src/evm.zig`), set by `Evm.init`. Each handler checks it:

```zig
// mini/src/instructions/handlers_storage.zig
if (evm.hardfork.isBefore(.CANCUN)) return error.InvalidOpcode; // TLOAD/TSTORE

// mini/src/instructions/handlers_stack.zig
if (evm.hardfork.isBefore(.SHANGHAI)) {
    return error.InvalidOpcode; // PUSH0
}
```

### Hardfork Methods

```zig
// lib/voltaire/src/primitives/hardfork.zig
pub fn isAtLeast(self: Hardfork, target: Hardfork) bool {
    return self.toInt() >= target.toInt();
}

pub fn isBefore(self: Hardfork, target: Hardfork) bool {
    return self.toInt() < target.toInt();
}

/// Case-insensitive. Accepts execution-spec names ("Cancun", "TangerineWhistle"),
/// the aliases "Paris" and "ConstantinopleFix", and a comparison prefix such as ">=".
pub fn fromString(name: []const u8) ?Hardfork { ... }
```

`Hardfork.mainnetActivationBlock()` and `Hardfork.mainnetActivationTimestamp()` return mainnet activation points. `ForkTransition.fromString("ShanghaiToCancunAtTime15000")` parses transition fixtures.

## Feature Guards

### Opcode Availability

The Mini EVM dispatch switch (`Frame.executeOpcode` in `mini/src/frame.zig`) has no fork logic. The guard lives in each handler:

```zig
// mini/src/frame.zig
switch (opcode) {
    0x5c => try StorageHandlers.tload(self),   // guard: isBefore(.CANCUN)
    0x5d => try StorageHandlers.tstore(self),  // guard: isBefore(.CANCUN)
    0x5e => try MemoryHandlers.mcopy(self),    // guard: isBefore(.CANCUN)
    0x5f...0x7f => try StackHandlers.push(self, opcode), // PUSH0 guard: isBefore(.SHANGHAI)
    // ...
    else => return error.InvalidOpcode,
}
```

`src/opcodes/opcode_data.zig` lists the opcodes each fork introduced in `HARDFORK_OPCODES`.

## Build Configuration

`build.zig` defines `-Devm-hardfork=<ENUM_NAME>` (default `OSAKA`) and exports it as `build_options.hardfork`. No code in `src/` reads it, so it does not change the Performance EVM's fork; set `EvmConfig.eips` instead. Only `EvmConfig.fromBuildOptions()` in `mini/src/evm_config.zig` reads the option, and nothing calls that function.

```bash
# Benchmarks take their own fork option (default OSAKA)
zig build bench -Dbench-hardfork=PRAGUE

# Run official EEST state tests for selected forks (execution-spec names)
zig build state-tests -Dspec-fork=Cancun,Prague
```

## Testing Hardfork-Specific Features

The Mini EVM build (`mini/build.zig`) defines one `specs-<fork>` step per fork and finer `specs-<fork>-<feature>` sub-targets. Run them from `mini/`:

```bash
cd mini
zig build specs-cancun                    # all cancun-* sub-targets
zig build specs-cancun-tstore-basic       # EIP-1153
zig build specs-cancun-mcopy              # EIP-5656
zig build specs-cancun-selfdestruct-basic # EIP-6780
zig build specs-shanghai-push0            # EIP-3855
zig build specs-shanghai-warmcoinbase     # EIP-3651
zig build specs-berlin-acl                # EIP-2929/2930
```

## Implementation Checklist

When adding new hardfork support:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    NEW HARDFORK IMPLEMENTATION CHECKLIST                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   □ 1. Add hardfork enum value                                             │
│       // In lib/voltaire/src/primitives/hardfork.zig                       │
│       pub const Hardfork = enum {                                          │
│           // ...existing...                                                 │
│           NEW_FORK,                                                        │
│       };                                                                    │
│       // Also extend mainnetActivationBlock/Timestamp and fromString       │
│                                                                             │
│   □ 2. Add new opcodes (if any)                                            │
│       // In src/opcodes/opcode.zig and src/opcodes/opcode_data.zig         │
│       NEW_OPCODE = 0xXX,                                                   │
│                                                                             │
│   □ 3. Implement handlers                                                   │
│       // In appropriate handlers_*.zig                                     │
│       pub fn new_opcode(frame: *FrameType) EvmError!void {                │
│           // Implementation                                                 │
│       }                                                                     │
│                                                                             │
│   □ 4. Add gas constants                                                    │
│       // In lib/voltaire/src/primitives/gas_constants.zig                  │
│       pub const NEW_OPCODE_GAS = X;                                        │
│                                                                             │
│   □ 5. Add feature guards                                                   │
│       if (!hardfork.isAtLeast(.NEW_FORK)) {                               │
│           return error.InvalidOpcode;                                      │
│       }                                                                     │
│                                                                             │
│   □ 6. Update dispatch                                                      │
│       // Performance: handler table in src/frame/frame_handlers.zig        │
│       // Mini: executeOpcode switch in mini/src/frame.zig                  │
│       0xXX => try NewHandlers.new_opcode(self),                            │
│                                                                             │
│   □ 7. Add tests                                                            │
│       // Add a SubTarget to mini/build.zig, then:                          │
│       cd mini && zig build specs-newfork-feature                           │
│       zig build state-tests -Dspec-fork=NewFork                            │
│                                                                             │
│   □ 8. Update documentation                                                 │
│       - Update HARDFORKS.md                                                │
│       - Update opcode table                                                │
│       - Add EIP description                                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Reference

- [EIP Index](https://eips.ethereum.org/)
- [Ethereum Yellow Paper](https://ethereum.github.io/yellowpaper/paper.pdf)
- [execution-specs](https://github.com/ethereum/execution-specs)
- [EVM.codes](https://www.evm.codes/)
