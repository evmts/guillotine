# Hardfork Support

This document covers hardfork handling, EIP support, and feature activation across both EVM implementations.

## Supported Hardforks

Both implementations support Frontier through Prague:

```zig
// From primitives/Hardfork
pub const Hardfork = enum(u8) {
    FRONTIER,       // Genesis
    HOMESTEAD,      // Block 1,150,000
    TANGERINE,      // Block 2,463,000 (EIP-150)
    SPURIOUS,       // Block 2,675,000 (EIP-155, 158, 160, 161)
    BYZANTIUM,      // Block 4,370,000
    CONSTANTINOPLE, // Block 7,280,000
    ISTANBUL,       // Block 9,069,000
    BERLIN,         // Block 12,244,000
    LONDON,         // Block 12,965,000
    MERGE,          // Block 15,537,394 (Paris)
    SHANGHAI,       // Block 17,034,870
    CANCUN,         // Block 19,426,587
    PRAGUE,         // Upcoming

    pub const DEFAULT = Hardfork.CANCUN;
};
```

## EIP Support Matrix

### Berlin (Block 12,244,000)

| EIP | Feature | Opcodes | Status |
|-----|---------|---------|--------|
| EIP-2929 | Gas cost increases for state access | - | Complete |
| EIP-2930 | Access lists | - | Complete |

**Key Changes:**
```zig
// Warm/cold access costs
COLD_ACCOUNT_ACCESS = 2600  // First access
WARM_ACCOUNT_ACCESS = 100   // Subsequent access
COLD_SLOAD = 2100           // First storage read
WARM_SLOAD = 100            // Subsequent storage read
```

### London (Block 12,965,000)

| EIP | Feature | Opcodes | Status |
|-----|---------|---------|--------|
| EIP-1559 | Fee market change | - | Complete |
| EIP-3198 | BASEFEE opcode | BASEFEE (0x48) | Complete |
| EIP-3529 | Reduced refunds | - | Complete |
| EIP-3541 | Reject 0xEF prefix | - | Complete |

**Key Changes:**
```zig
// Refund cap reduced
Pre-London: gas_used / 2  // 50%
London+: gas_used / 5     // 20% (EIP-3529)

// SELFDESTRUCT refund removed
Pre-London: 24000 refund
London+: 0 refund
```

### Shanghai (Block 17,034,870)

| EIP | Feature | Opcodes | Status |
|-----|---------|---------|--------|
| EIP-3651 | Warm coinbase | - | Complete |
| EIP-3855 | PUSH0 instruction | PUSH0 (0x5F) | Complete |
| EIP-3860 | Limit initcode size | - | Complete |

**Key Changes:**
```zig
// PUSH0: Push zero onto stack
pub fn push0(frame: *FrameType) EvmError!void {
    try frame.consumeGas(2);  // Base cost
    try frame.pushStack(0);
    frame.pc += 1;
}

// Initcode size limit: 2 * MAX_CODE_SIZE = 49152 bytes
```

### Cancun (Block 19,426,587)

| EIP | Feature | Opcodes | Status |
|-----|---------|---------|--------|
| EIP-1153 | Transient storage | TLOAD (0x5C), TSTORE (0x5D) | Complete |
| EIP-4844 | Shard blob transactions | BLOBHASH (0x49), BLOBBASEFEE (0x4A) | Complete |
| EIP-5656 | MCOPY instruction | MCOPY (0x5E) | Complete |
| EIP-6780 | SELFDESTRUCT changes | SELFDESTRUCT (0xFF) | Complete |
| EIP-7516 | BLOBBASEFEE opcode | BLOBBASEFEE (0x4A) | Complete |

**Key Changes:**
```zig
// Transient storage: cleared at transaction boundary
pub fn tstore(frame: *FrameType) EvmError!void {
    if (frame.is_static) return error.WriteInStaticContext;
    try frame.consumeGas(100);  // Always warm
    const slot = try frame.popStack();
    const value = try frame.popStack();
    try frame.getEvm().storage.setTransient(frame.address, slot, value);
    frame.pc += 1;
}

// MCOPY: Memory copy within same context
pub fn mcopy(frame: *FrameType) EvmError!void {
    const dest = try frame.popStack();
    const src = try frame.popStack();
    const size = try frame.popStack();
    // Memory expansion + copy cost
    try frame.expandMemory(dest + size);
    try frame.expandMemory(src + size);
    try frame.consumeGas(3 + 3 * ((size + 31) / 32));
    // Perform copy (handles overlapping regions)
    frame.memory.copy(dest, src, size);
    frame.pc += 1;
}

// SELFDESTRUCT: Only destroys if created in same tx
pub fn selfdestruct(frame: *FrameType) EvmError!void {
    if (frame.getEvm().created_this_tx.contains(frame.address)) {
        // Actually destroy
    } else {
        // Just transfer balance, don't destroy
    }
}
```

### Prague (Upcoming)

| EIP | Feature | Opcodes | Status |
|-----|---------|---------|--------|
| EIP-7702 | Set code transactions | AUTH, AUTHCALL | Complete |
| EIP-2537 | BLS12-381 precompiles | Precompile 0x0B-0x12 | Complete |

**Key Changes:**
```zig
// EIP-7702: Authorization for EOA code execution
// Allows EOAs to temporarily have code via signed authorization
```

## Hardfork Detection

### Compile-Time (Zig Pattern)

```zig
// Configuration at compile time
pub fn Evm(comptime config: EvmConfig) type {
    const hardfork = config.hardfork;

    return struct {
        // Conditional compilation
        pub fn sstore(self: *Self, ...) !void {
            if (comptime hardfork.isAtLeast(.BERLIN)) {
                // Warm/cold access tracking
            }
            if (comptime hardfork.isAtLeast(.LONDON)) {
                // Reduced refund cap
            }
        }
    };
}
```

### Runtime (Both Implementations)

```zig
// Runtime hardfork checks
if (self.hardfork.isAtLeast(.CANCUN)) {
    // TLOAD/TSTORE available
}

if (self.hardfork.isBefore(.SHANGHAI)) {
    // PUSH0 not available
    return error.InvalidOpcode;
}
```

### Hardfork Methods

```zig
pub fn isAtLeast(self: Hardfork, target: Hardfork) bool {
    return @intFromEnum(self) >= @intFromEnum(target);
}

pub fn isBefore(self: Hardfork, target: Hardfork) bool {
    return @intFromEnum(self) < @intFromEnum(target);
}

pub fn fromString(name: []const u8) ?Hardfork {
    return std.meta.stringToEnum(Hardfork, name);
}
```

## Gas Cost Changes by Hardfork

### Pre-Berlin

```zig
SLOAD: 200
BALANCE: 400
EXTCODESIZE: 700
EXTCODEHASH: 400
CALL: 700
```

### Berlin+ (EIP-2929)

```zig
// Cold access
SLOAD cold: 2100
BALANCE cold: 2600
EXTCODESIZE cold: 2600
EXTCODEHASH cold: 2600
CALL cold: 2600

// Warm access (after first)
All warm: 100
```

### London+ (EIP-3529)

```zig
// Reduced refunds
SSTORE clear refund: 4800  // Was 15000
Refund cap: 20%            // Was 50%
SELFDESTRUCT refund: 0     // Was 24000
```

## Feature Guards

### Opcode Availability

```zig
// In handler dispatch
fn dispatchOpcode(frame: *Frame, opcode: u8) EvmError!void {
    switch (opcode) {
        0x5F => {  // PUSH0
            if (!frame.hardfork.isAtLeast(.SHANGHAI)) {
                return error.InvalidOpcode;
            }
            return StackHandlers.push0(frame);
        },
        0x5C => {  // TLOAD
            if (!frame.hardfork.isAtLeast(.CANCUN)) {
                return error.InvalidOpcode;
            }
            return StorageHandlers.tload(frame);
        },
        // ...
    }
}
```

### Behavior Changes

```zig
pub fn selfdestruct(frame: *Frame) EvmError!void {
    if (frame.hardfork.isAtLeast(.CANCUN)) {
        // EIP-6780: Only destroy if created same tx
        if (!frame.getEvm().created_this_tx.contains(frame.address)) {
            // Just transfer balance
            return transferBalanceOnly(frame);
        }
    }
    // Actually destroy contract
    return destroyContract(frame);
}
```

## Build Configuration

```bash
# Specify hardfork at build time
zig build -Devm-hardfork=CANCUN
zig build -Devm-hardfork=SHANGHAI
zig build -Devm-hardfork=BERLIN

# Run tests for specific hardfork
zig build specs -Devm-hardfork=CANCUN
```

## Testing Hardfork-Specific Features

```bash
# Mini EVM granular targets
zig build specs-cancun-tstore-basic      # EIP-1153
zig build specs-cancun-mcopy             # EIP-5656
zig build specs-cancun-selfdestruct      # EIP-6780
zig build specs-shanghai-push0           # EIP-3855
zig build specs-shanghai-warmcoinbase    # EIP-3651
zig build specs-berlin-acl               # EIP-2929/2930
```

## Implementation Checklist

When adding new hardfork support:

1. **Add hardfork enum value**
   ```zig
   pub const Hardfork = enum(u8) {
       // ...existing...
       NEW_FORK,
   };
   ```

2. **Add new opcodes (if any)**
   ```zig
   // In opcode.zig
   NEW_OPCODE = 0xXX,
   ```

3. **Implement handlers**
   ```zig
   // In appropriate handlers_*.zig
   pub fn new_opcode(frame: *FrameType) EvmError!void {
       // Implementation
   }
   ```

4. **Add gas constants**
   ```zig
   // In gas_constants.zig
   pub const NEW_OPCODE_GAS = X;
   ```

5. **Add feature guards**
   ```zig
   if (!hardfork.isAtLeast(.NEW_FORK)) {
       return error.InvalidOpcode;
   }
   ```

6. **Update dispatch**
   ```zig
   // In dispatch handling
   0xXX => return new_opcode(frame),
   ```

7. **Add tests**
   ```bash
   zig build specs-newfork-feature
   ```

## Reference

- [EIP Index](https://eips.ethereum.org/)
- [Ethereum Yellow Paper](https://ethereum.github.io/yellowpaper/paper.pdf)
- [execution-specs](https://github.com/ethereum/execution-specs)
