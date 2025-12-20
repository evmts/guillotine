# Instruction Handlers Architecture

Comprehensive documentation for EVM instruction handlers in guillotine-mini.

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Handler Categories](#handler-categories)
4. [Gas Metering](#gas-metering)
5. [Hardfork-Specific Features](#hardfork-specific-features)
6. [Testing Approach](#testing-approach)
7. [Common Patterns](#common-patterns)
8. [Opcode Reference Table](#opcode-reference-table)
9. [Adding New Instructions](#adding-new-instructions)
10. [Resources](#resources)

---

## Overview

The instruction handlers implement all EVM opcodes (0x00-0xFF) in a modular, type-safe manner. Each handler is responsible for:

1. **Gas consumption** - Charge correct gas before execution
2. **Stack manipulation** - Pop inputs, push outputs
3. **Memory/storage access** - Read/write with proper bounds checking
4. **Program counter update** - Advance PC after successful execution
5. **Error handling** - Return appropriate errors for invalid operations

### Design Principles

- **Modularity**: Handlers grouped by category (arithmetic, storage, system, etc.)
- **Type Safety**: Compile-time generic `Handlers(FrameType)` pattern
- **Hardfork Awareness**: Runtime checks for feature availability
- **Python Reference Compliance**: Matches `execution-specs` behavior exactly

---

## Architecture

### Handler Module Pattern

Each handler module exports a generic `Handlers` function that returns a struct of handler methods:

```zig
pub fn Handlers(FrameType: type) type {
    return struct {
        pub fn opcode_name(frame: *FrameType) FrameType.EvmError!void {
            // 1. Consume gas
            try frame.consumeGas(cost);

            // 2. Pop inputs
            const input = try frame.popStack();

            // 3. Perform operation
            const result = compute(input);

            // 4. Push outputs
            try frame.pushStack(result);

            // 5. Update PC
            frame.pc += 1;
        }
    };
}
```

### Integration with Frame

Handlers are instantiated in `src/frame.zig`:

```zig
const ArithmeticHandlers = handlers_arithmetic.Handlers(Self);
const StorageHandlers = handlers_storage.Handlers(Self);
// ... etc

pub fn executeOpcode(self: *Self, opcode: u8) EvmError!void {
    switch (opcode) {
        0x01 => try ArithmeticHandlers.add(self),
        0x54 => try StorageHandlers.sload(self),
        // ... etc
    }
}
```

### Required Frame Methods

Handlers require these methods on `FrameType`:

| Method | Purpose | Return Type |
|--------|---------|-------------|
| `consumeGas(amount)` | Deduct gas | `EvmError!void` |
| `popStack()` | Pop stack value | `EvmError!u256` |
| `pushStack(value)` | Push stack value | `EvmError!void` |
| `peekStack(index)` | Peek at stack | `EvmError!u256` |
| `readMemory(offset)` | Read memory byte | `u8` |
| `writeMemory(offset, value)` | Write memory byte | `EvmError!void` |
| `getEvm()` | Get parent EVM | `*EvmType` |
| `memoryExpansionCost(size)` | Calculate memory gas | `u64` |

### Required Frame Fields

| Field | Type | Purpose |
|-------|------|---------|
| `pc` | `u32` | Program counter |
| `gas_remaining` | `i64` | Remaining gas (signed for refunds) |
| `address` | `Address` | Contract address |
| `caller` | `Address` | Caller address |
| `value` | `u256` | Call value |
| `calldata` | `[]const u8` | Input data |
| `memory` | `AutoHashMap(u32, u8)` | Memory storage |
| `memory_size` | `u32` | Logical memory size |
| `return_data` | `[]const u8` | Return data buffer |
| `is_static` | `bool` | Static call flag |
| `hardfork` | `Hardfork` | Active hardfork |

---

## Handler Categories

### 1. Arithmetic Operations (`handlers_arithmetic.zig`)

**Opcodes**: `0x01-0x0b` (ADD, MUL, SUB, DIV, SDIV, MOD, SMOD, ADDMOD, MULMOD, EXP, SIGNEXTEND)

**Key Features**:
- Wrapping overflow/underflow (`+%`, `*%`, `-%`)
- Division by zero returns 0
- EXP dynamic gas based on exponent byte length
- Signed operations use `@bitCast` for i256

**Gas Costs**:
- Fast operations (ADD, SUB): 3 gas
- Standard operations (MUL, DIV, MOD): 5 gas
- Medium operations (ADDMOD, MULMOD): 8 gas
- EXP: 10 + 50 per byte of exponent

**Python Reference**: `execution-specs/.../vm/instructions/arithmetic.py`

---

### 2. Comparison Operations (`handlers_comparison.zig`)

**Opcodes**: `0x10-0x15` (LT, GT, SLT, SGT, EQ, ISZERO)

**Key Features**:
- Boolean results (0 or 1)
- Signed comparisons (SLT, SGT) use `@bitCast` for i256
- All operations cost 3 gas (GasFastestStep)

**Python Reference**: `execution-specs/.../vm/instructions/comparison.py`

---

### 3. Bitwise Operations (`handlers_bitwise.zig`)

**Opcodes**: `0x16-0x1d` (AND, OR, XOR, NOT, BYTE, SHL, SHR, SAR)

**Key Features**:
- BYTE extracts specific byte (big-endian indexing)
- Shift operations (SHL/SHR/SAR) introduced in Constantinople
- SAR preserves sign bit (arithmetic right shift)

**Gas Costs**:
- Most operations: 3 gas
- Shift operations: 3 gas

**Python Reference**: `execution-specs/.../vm/instructions/bitwise.py`

---

### 4. Keccak256 Hashing (`handlers_keccak.zig`)

**Opcodes**: `0x20` (SHA3/KECCAK256)

**Key Features**:
- Uses `std.crypto.hash.sha3.Keccak256`
- Dynamic gas cost based on data size
- Memory expansion cost included

**Gas Cost**: 30 + 6 per word (32 bytes)

**Python Reference**: `execution-specs/.../vm/instructions/keccak.py`

---

### 5. Context Information (`handlers_context.zig`)

**Opcodes**: `0x30-0x3f` (ADDRESS, BALANCE, ORIGIN, CALLER, CALLVALUE, CALLDATALOAD, CALLDATASIZE, CALLDATACOPY, CODESIZE, CODECOPY, GASPRICE, EXTCODESIZE, EXTCODECOPY, RETURNDATASIZE, RETURNDATACOPY, EXTCODEHASH)

**Key Features**:
- **EIP-2929** (Berlin): Warm/cold address access costs
- **BALANCE**: Cold = 2600 gas, Warm = 100 gas (Berlin+)
- **EXTCODEHASH**: Empty accounts return 0, not keccak256("")
- **RETURNDATACOPY**: Introduced in Byzantium

**Gas Costs** (Berlin+):
- BALANCE: Cold 2600, Warm 100
- EXTCODESIZE/EXTCODECOPY: Cold 2600, Warm 100
- EXTCODEHASH: Cold 2600, Warm 100

**Python Reference**: `execution-specs/.../vm/instructions/environment.py`

---

### 6. Block Information (`handlers_block.zig`)

**Opcodes**: `0x40-0x4a` (BLOCKHASH, COINBASE, TIMESTAMP, NUMBER, DIFFICULTY/PREVRANDAO, GASLIMIT, CHAINID, SELFBALANCE, BASEFEE, BLOBHASH, BLOBBASEFEE)

**Key Features**:
- **DIFFICULTY/PREVRANDAO**: Returns `block_prevrandao` post-Merge
- **BASEFEE**: Introduced in London (EIP-3198)
- **BLOBHASH/BLOBBASEFEE**: Introduced in Cancun (EIP-4844)
- **BLOCKHASH**: Returns hash of recent blocks (last 256)

**Hardfork Timeline**:
- CHAINID: Istanbul (EIP-1344)
- SELFBALANCE: Istanbul (EIP-1884)
- BASEFEE: London (EIP-3198)
- BLOBHASH/BLOBBASEFEE: Cancun (EIP-4844)

**Python Reference**: `execution-specs/.../vm/instructions/block.py`

---

### 7. Stack Operations (`handlers_stack.zig`)

**Opcodes**: `0x50, 0x5f-0x9f` (POP, PUSH0-PUSH32, DUP1-DUP16, SWAP1-SWAP16)

**Key Features**:
- **PUSH0**: Introduced in Shanghai (EIP-3855), costs 2 gas
- **PUSH1-PUSH32**: Read immediate data from bytecode
- **DUP**: Duplicate stack item at depth 1-16
- **SWAP**: Swap top with item at depth 1-16

**Gas Costs**:
- POP: 2 gas
- PUSH0: 2 gas
- PUSH1-PUSH32: 3 gas
- DUP/SWAP: 3 gas

**Python Reference**: `execution-specs/.../vm/instructions/stack.py`

---

### 8. Memory Operations (`handlers_memory.zig`)

**Opcodes**: `0x51-0x53, 0x59, 0x5e` (MLOAD, MSTORE, MSTORE8, MSIZE, MCOPY)

**Key Features**:
- **Memory expansion**: Quadratic cost formula `3n + n²/512`
- **Word-aligned**: Memory size rounds up to 32-byte boundaries
- **MCOPY**: Introduced in Cancun (EIP-5656), efficient memory copy
- **MSIZE**: Returns current memory size in bytes

**Gas Costs**:
- MLOAD/MSTORE: 3 + expansion
- MSTORE8: 3 + expansion
- MCOPY: 3 + 3 per word + expansion
- MSIZE: 2 gas

**Python Reference**: `execution-specs/.../vm/instructions/memory.py`

---

### 9. Storage Operations (`handlers_storage.zig`)

**Opcodes**: `0x54-0x55, 0x5c-0x5d` (SLOAD, SSTORE, TLOAD, TSTORE)

**Key Features**:
- **EIP-2200** (Istanbul): Net gas metering for SSTORE
- **EIP-2929** (Berlin): Warm/cold storage slot costs
- **EIP-3529** (London): Reduced refunds (4800 instead of 15000)
- **EIP-1153** (Cancun): Transient storage (TLOAD/TSTORE)

**Gas Costs**:

| Operation | Pre-Berlin | Berlin+ (Cold) | Berlin+ (Warm) |
|-----------|------------|----------------|----------------|
| SLOAD | 800 (Istanbul) | 2100 | 100 |
| SSTORE (set) | 20000 | 20000 + 2100 | 20000 + 100 |
| SSTORE (update) | 5000 | 5000 + 2100 | 5000 + 100 |
| TLOAD/TSTORE | - | - | 100 (always warm) |

**Refunds** (London+):
- Clear storage: 4800 gas refund
- Restore to original: Variable (depends on operation)

**Critical Rules**:
1. SSTORE requires 2300 gas remaining (sentry check)
2. SSTORE/TSTORE forbidden in static context
3. Transient storage cleared at transaction boundaries
4. Refunds capped at 1/5 of gas used (London+)

**Python Reference**: `execution-specs/.../vm/instructions/storage.py`

---

### 10. Control Flow (`handlers_control_flow.zig`)

**Opcodes**: `0x00, 0x56-0x58, 0x5b, 0xf3, 0xfd` (STOP, JUMP, JUMPI, PC, JUMPDEST, RETURN, REVERT)

**Key Features**:
- **JUMPDEST**: Valid jump destinations pre-analyzed in bytecode
- **JUMP/JUMPI**: Must land on JUMPDEST, else InvalidJumpDestination
- **RETURN**: Copy memory to output, halt execution
- **REVERT**: Copy memory to output, halt with revert flag (Byzantium+)

**Gas Costs**:
- STOP: 0 gas
- JUMP/JUMPI: 8 gas
- PC: 2 gas
- JUMPDEST: 1 gas
- RETURN/REVERT: 0 + memory expansion

**Python Reference**: `execution-specs/.../vm/instructions/control_flow.py`

---

### 11. Log Operations (`handlers_log.zig`)

**Opcodes**: `0xa0-0xa4` (LOG0, LOG1, LOG2, LOG3, LOG4)

**Key Features**:
- **LOG0-LOG4**: Emit event with 0-4 indexed topics
- Forbidden in static context
- Topics are 32-byte values, data is arbitrary bytes
- Logs accumulated in EVM, included in transaction receipt

**Gas Cost**: 375 + 375 per topic + 8 per data byte + memory expansion

**Python Reference**: `execution-specs/.../vm/instructions/log.py`

---

### 12. System Operations (`handlers_system.zig`)

**Opcodes**: `0xf0-0xf2, 0xf4-0xf5, 0xfa, 0xff` (CREATE, CALL, CALLCODE, DELEGATECALL, CREATE2, STATICCALL, SELFDESTRUCT)

**Key Features**:

#### CREATE (0xf0) / CREATE2 (0xf5)
- **CREATE**: Address = keccak256(rlp([sender, nonce]))[12:]
- **CREATE2**: Address = keccak256(0xff ++ sender ++ salt ++ keccak256(init_code))[12:]
- **EIP-3860** (Shanghai): Init code size limit (49152 bytes)
- **EIP-170**: Code size limit (24576 bytes)
- **EIP-684**: Collision detection (code or nonce exists)

#### CALL (0xf1) / CALLCODE (0xf2) / DELEGATECALL (0xf4) / STATICCALL (0xfa)
- **CALL**: Normal call with value transfer
- **CALLCODE**: Deprecated, like DELEGATECALL but preserves msg.value
- **DELEGATECALL**: Execute code in current context
- **STATICCALL**: Read-only call, no state changes
- **EIP-150** (Tangerine Whistle): 63/64 rule for gas forwarding
- **EIP-2929** (Berlin): Warm/cold address access

#### SELFDESTRUCT (0xff)
- **EIP-6780** (Cancun): Only deletes in same transaction as creation
- **EIP-3529** (London): No refund
- Pre-Cancun: Transfers balance and marks account for deletion
- Post-Cancun: Only transfers balance, deletion only if created in same tx

**Gas Costs**:

| Operation | Base | Value Transfer | Account Creation | Cold Access (Berlin+) |
|-----------|------|----------------|------------------|-----------------------|
| CREATE | 32000 | - | - | - |
| CREATE2 | 32000 + hash | - | - | - |
| CALL | 700 (EIP-150) | 9000 | 25000 | 2600 |
| DELEGATECALL | 700 | - | - | 2600 |
| STATICCALL | 700 | - | - | 2600 |
| SELFDESTRUCT | 5000 | - | 25000 (if new) | 2600 |

**Python Reference**: `execution-specs/.../vm/instructions/system.py`

---

## Gas Metering

### Gas Calculation Order

**CRITICAL**: Gas must be charged in the exact order specified by Python reference:

1. **Base opcode cost** - Fixed cost for instruction
2. **Memory expansion** - If accessing memory beyond current size
3. **Cold access** - If first access to address/slot (EIP-2929)
4. **Dynamic costs** - Variable costs (e.g., SSTORE logic, EXP byte cost)

### Gas Constants (from primitives library)

```zig
const GasConstants = primitives.GasConstants;

// Base costs
GasFastestStep = 3;      // ADD, SUB, LT, GT, EQ, NOT, etc.
GasFastStep = 5;         // MUL, DIV, MOD, etc.
GasMidStep = 8;          // ADDMOD, MULMOD
GasSlowStep = 10;        // EXP base cost

// Memory
MemoryGas = 3;           // Per word cost
QuadCoeffDiv = 512;      // Quadratic divisor

// Storage (EIP-2929 Berlin+)
WarmStorageReadCost = 100;
ColdSloadCost = 2100;
ColdAccountAccessCost = 2600;

// SSTORE costs
SstoreSetGas = 20000;           // 0 -> non-zero
SstoreResetGas = 5000;          // non-zero -> different non-zero
SstoreRefundGas = 4800;         // London+ clear refund
SstoreSentryGas = 2300;         // Minimum gas required

// Call costs
CallGas = 700;                  // EIP-150 base
CallValueTransferGas = 9000;    // Value transfer cost
CallStipend = 2300;             // Stipend for value calls
CallNewAccountGas = 25000;      // New account creation

// Create costs
CreateGas = 32000;              // Base CREATE cost
CreateDataGas = 200;            // Per byte of deployed code
InitcodeWordGas = 2;            // EIP-3860 per word of init code
MaxInitcodeSize = 49152;        // EIP-3860 max init code size

// Other
Keccak256Gas = 30;              // Base keccak256 cost
Keccak256WordGas = 6;           // Per word
CopyGas = 3;                    // Per word for copy ops
LogGas = 375;                   // Base LOG cost
LogDataGas = 8;                 // Per byte
LogTopicGas = 375;              // Per topic
SelfdestructGas = 5000;         // EIP-150
```

### Memory Expansion Formula

```zig
// Total memory cost for n words: 3n + n²/512
fn memoryExpansionCost(current_size: u64, new_size: u64) u64 {
    if (new_size <= current_size) return 0;

    const current_words = (current_size + 31) / 32;
    const new_words = (new_size + 31) / 32;

    const current_cost = 3 * current_words + (current_words * current_words) / 512;
    const new_cost = 3 * new_words + (new_words * new_words) / 512;

    return new_cost - current_cost;
}
```

### Gas Refunds

**Pre-London**:
- SSTORE clear: 15,000 refund
- SELFDESTRUCT: 24,000 refund
- Capped at 1/2 of gas used

**London+ (EIP-3529)**:
- SSTORE clear: 4,800 refund
- SELFDESTRUCT: No refund
- Capped at 1/5 of gas used

**Refund Application**:
- Refunds accumulated during execution
- Applied AFTER transaction completes
- Never increase gas available during execution

---

## Hardfork-Specific Features

### Feature Activation by Hardfork

| Feature | Hardfork | EIP | Opcodes Affected |
|---------|----------|-----|------------------|
| DELEGATECALL | Homestead | - | 0xf4 |
| REVERT | Byzantium | EIP-140 | 0xfd |
| RETURNDATASIZE/COPY | Byzantium | EIP-211 | 0x3d, 0x3e |
| SHL/SHR/SAR | Constantinople | EIP-145 | 0x1b, 0x1c, 0x1d |
| CREATE2 | Constantinople | EIP-1014 | 0xf5 |
| EXTCODEHASH | Constantinople | EIP-1052 | 0x3f |
| CHAINID | Istanbul | EIP-1344 | 0x46 |
| SELFBALANCE | Istanbul | EIP-1884 | 0x47 |
| SSTORE net metering | Istanbul | EIP-2200 | 0x55 |
| Warm/cold access | Berlin | EIP-2929 | All address/storage ops |
| BASEFEE | London | EIP-3198 | 0x48 |
| Reduced refunds | London | EIP-3529 | 0x55, 0xff |
| PUSH0 | Shanghai | EIP-3855 | 0x5f |
| Init code limit | Shanghai | EIP-3860 | 0xf0, 0xf5 |
| Transient storage | Cancun | EIP-1153 | 0x5c, 0x5d |
| MCOPY | Cancun | EIP-5656 | 0x5e |
| BLOBHASH/BLOBBASEFEE | Cancun | EIP-4844 | 0x49, 0x4a |
| SELFDESTRUCT change | Cancun | EIP-6780 | 0xff |

### Hardfork Guards

```zig
// Check if feature is available
if (frame.hardfork.isAtLeast(.SHANGHAI)) {
    // PUSH0 available
}

// Check if feature is NOT available
if (frame.hardfork.isBefore(.CANCUN)) {
    // No transient storage
    return error.InvalidOpcode;
}

// Gas cost changes
const gas_cost = if (evm.hardfork.isAtLeast(.BERLIN))
    ColdAccountAccessCost  // 2600 (Berlin+)
else if (evm.hardfork.isAtLeast(.ISTANBUL))
    800  // Istanbul-Berlin
else
    200; // Pre-Istanbul
```

---

## Testing Approach

### Test Levels

1. **Unit Tests**: Inline tests in handler files
2. **Spec Tests**: `ethereum/tests` GeneralStateTests
3. **Trace Tests**: EIP-3155 trace comparison

### Running Tests

```bash
# All tests
zig build test

# Spec tests only
zig build specs

# Filter by hardfork
TEST_FILTER="Cancun" zig build specs

# Filter by opcode
TEST_FILTER="MCOPY" zig build specs

# Specific test
bun scripts/isolate-test.ts "test_name"
```

### Debugging Workflow

```bash
# 1. Isolate failing test with detailed output
bun scripts/isolate-test.ts "transStorageReset"

# 2. Review trace divergence
# - Shows exact PC where behavior differs
# - Compares opcode, gas, stack state

# 3. Find Python reference
cd execution-specs/src/ethereum/forks/cancun/vm/instructions/
grep -r "def tstore" .

# 4. Compare implementations
# - Match gas calculation order
# - Verify stack/memory operations
# - Check error conditions

# 5. Fix and verify
# Edit src/instructions/handlers_*.zig
zig build specs
```

### Common Test Failures

| Failure Type | Likely Cause | Fix |
|--------------|--------------|-----|
| Gas mismatch | Wrong gas calculation order | Match Python reference exactly |
| Stack error | Incorrect pop/push order | Verify stack operations |
| Memory error | Missing expansion cost | Charge expansion before access |
| Revert behavior | Wrong error condition | Check static context, gas limits |
| Refund incorrect | Wrong refund logic | Match EIP-2200/3529 exactly |

---

## Common Patterns

### 1. Basic Arithmetic Pattern

```zig
pub fn add(frame: *FrameType) FrameType.EvmError!void {
    try frame.consumeGas(GasConstants.GasFastestStep);
    const a = try frame.popStack();
    const b = try frame.popStack();
    try frame.pushStack(a +% b);  // Wrapping add
    frame.pc += 1;
}
```

### 2. Memory Access Pattern

```zig
pub fn mload(frame: *FrameType) FrameType.EvmError!void {
    try frame.consumeGas(GasConstants.GasFastestStep);
    const offset = try frame.popStack();

    // Check bounds and charge expansion
    const off_u32 = std.math.cast(u32, offset) orelse return error.OutOfBounds;
    const end_bytes = @as(u64, off_u32) + 32;
    const mem_cost = frame.memoryExpansionCost(end_bytes);
    try frame.consumeGas(mem_cost);

    // Update memory size
    const aligned = wordAlignedSize(end_bytes);
    if (aligned > frame.memory_size) frame.memory_size = aligned;

    // Read 32 bytes
    var value: u256 = 0;
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        const byte = frame.readMemory(off_u32 + i);
        value = (value << 8) | byte;
    }

    try frame.pushStack(value);
    frame.pc += 1;
}
```

### 3. Storage Access Pattern (EIP-2929)

```zig
pub fn sload(frame: *FrameType) FrameType.EvmError!void {
    const evm = frame.getEvm();
    const key = try frame.popStack();

    // Charge warm/cold access (also warms the slot)
    const access_cost = try evm.accessStorageSlot(frame.address, key);
    try frame.consumeGas(access_cost);

    const value = try evm.storage.get(frame.address, key);
    try frame.pushStack(value);
    frame.pc += 1;
}
```

### 4. External Account Access Pattern

```zig
pub fn balance(frame: *FrameType) FrameType.EvmError!void {
    const evm = frame.getEvm();
    const address_u256 = try frame.popStack();
    const address = addressFromU256(address_u256);

    // Charge warm/cold access (Berlin+) or flat cost (pre-Berlin)
    if (evm.hardfork.isAtLeast(.BERLIN)) {
        const access_cost = try evm.accessAddress(address);
        try frame.consumeGas(access_cost);
    } else if (evm.hardfork.isAtLeast(.ISTANBUL)) {
        try frame.consumeGas(700);
    } else {
        try frame.consumeGas(400);
    }

    const balance = evm.get_balance(address);
    try frame.pushStack(balance);
    frame.pc += 1;
}
```

### 5. Static Context Check

```zig
pub fn sstore(frame: *FrameType) FrameType.EvmError!void {
    // EIP-214: Cannot modify state in static context
    if (frame.is_static) return error.StaticCallViolation;

    // ... rest of SSTORE logic
}
```

### 6. Call Pattern (63/64 Rule)

```zig
pub fn call(frame: *FrameType) FrameType.EvmError!void {
    // ... pop arguments, calculate base gas cost

    const evm = frame.getEvm();
    const remaining_gas = @as(u64, @intCast(@max(frame.gas_remaining, 0)));

    // EIP-150: Forward at most 63/64 of remaining gas
    const max_gas = if (evm.hardfork.isAtLeast(.TANGERINE_WHISTLE))
        remaining_gas - (remaining_gas / 64)
    else
        remaining_gas;

    const gas_to_send = @min(requested_gas, max_gas);

    // Execute call
    const result = evm.inner_call(params);

    // Deduct gas used
    const gas_used = gas_to_send - result.gas_left;
    frame.gas_remaining -= @intCast(gas_used);

    // ... push result, update return_data
}
```

---

## Opcode Reference Table

### Complete Opcode List with Gas Costs

| Opcode | Name | Stack Input | Stack Output | Gas Cost | Handler File |
|--------|------|-------------|--------------|----------|--------------|
| **0x00-0x0f: Arithmetic** |
| 0x00 | STOP | - | - | 0 | handlers_control_flow.zig |
| 0x01 | ADD | a, b | a + b | 3 | handlers_arithmetic.zig |
| 0x02 | MUL | a, b | a * b | 5 | handlers_arithmetic.zig |
| 0x03 | SUB | a, b | a - b | 3 | handlers_arithmetic.zig |
| 0x04 | DIV | a, b | a / b | 5 | handlers_arithmetic.zig |
| 0x05 | SDIV | a, b | a / b (signed) | 5 | handlers_arithmetic.zig |
| 0x06 | MOD | a, b | a % b | 5 | handlers_arithmetic.zig |
| 0x07 | SMOD | a, b | a % b (signed) | 5 | handlers_arithmetic.zig |
| 0x08 | ADDMOD | a, b, n | (a + b) % n | 8 | handlers_arithmetic.zig |
| 0x09 | MULMOD | a, b, n | (a * b) % n | 8 | handlers_arithmetic.zig |
| 0x0a | EXP | a, b | a ** b | 10 + 50/byte | handlers_arithmetic.zig |
| 0x0b | SIGNEXTEND | b, x | sign_extend(x, b) | 5 | handlers_arithmetic.zig |
| **0x10-0x1f: Comparison & Bitwise** |
| 0x10 | LT | a, b | a < b | 3 | handlers_comparison.zig |
| 0x11 | GT | a, b | a > b | 3 | handlers_comparison.zig |
| 0x12 | SLT | a, b | a < b (signed) | 3 | handlers_comparison.zig |
| 0x13 | SGT | a, b | a > b (signed) | 3 | handlers_comparison.zig |
| 0x14 | EQ | a, b | a == b | 3 | handlers_comparison.zig |
| 0x15 | ISZERO | a | a == 0 | 3 | handlers_comparison.zig |
| 0x16 | AND | a, b | a & b | 3 | handlers_bitwise.zig |
| 0x17 | OR | a, b | a \| b | 3 | handlers_bitwise.zig |
| 0x18 | XOR | a, b | a ^ b | 3 | handlers_bitwise.zig |
| 0x19 | NOT | a | ~a | 3 | handlers_bitwise.zig |
| 0x1a | BYTE | i, x | byte_at(x, i) | 3 | handlers_bitwise.zig |
| 0x1b | SHL | shift, value | value << shift | 3 | handlers_bitwise.zig |
| 0x1c | SHR | shift, value | value >> shift | 3 | handlers_bitwise.zig |
| 0x1d | SAR | shift, value | value >> shift (signed) | 3 | handlers_bitwise.zig |
| **0x20: Hash** |
| 0x20 | KECCAK256 | offset, length | keccak256(memory[offset:offset+length]) | 30 + 6/word | handlers_keccak.zig |
| **0x30-0x3f: Context** |
| 0x30 | ADDRESS | - | address | 2 | handlers_context.zig |
| 0x31 | BALANCE | address | balance | 100-2600* | handlers_context.zig |
| 0x32 | ORIGIN | - | tx.origin | 2 | handlers_context.zig |
| 0x33 | CALLER | - | msg.sender | 2 | handlers_context.zig |
| 0x34 | CALLVALUE | - | msg.value | 2 | handlers_context.zig |
| 0x35 | CALLDATALOAD | offset | calldata[offset:offset+32] | 3 | handlers_context.zig |
| 0x36 | CALLDATASIZE | - | len(calldata) | 2 | handlers_context.zig |
| 0x37 | CALLDATACOPY | destOffset, offset, length | - | 3 + 3/word | handlers_context.zig |
| 0x38 | CODESIZE | - | len(code) | 2 | handlers_context.zig |
| 0x39 | CODECOPY | destOffset, offset, length | - | 3 + 3/word | handlers_context.zig |
| 0x3a | GASPRICE | - | tx.gasprice | 2 | handlers_context.zig |
| 0x3b | EXTCODESIZE | address | len(code) | 100-2600* | handlers_context.zig |
| 0x3c | EXTCODECOPY | address, destOffset, offset, length | - | 100-2600* + 3/word | handlers_context.zig |
| 0x3d | RETURNDATASIZE | - | len(returndata) | 2 | handlers_context.zig |
| 0x3e | RETURNDATACOPY | destOffset, offset, length | - | 3 + 3/word | handlers_context.zig |
| 0x3f | EXTCODEHASH | address | hash | 100-2600* | handlers_context.zig |
| **0x40-0x4f: Block** |
| 0x40 | BLOCKHASH | blockNumber | hash | 20 | handlers_block.zig |
| 0x41 | COINBASE | - | block.coinbase | 2 | handlers_block.zig |
| 0x42 | TIMESTAMP | - | block.timestamp | 2 | handlers_block.zig |
| 0x43 | NUMBER | - | block.number | 2 | handlers_block.zig |
| 0x44 | DIFFICULTY | - | block.difficulty | 2 | handlers_block.zig |
| 0x45 | GASLIMIT | - | block.gaslimit | 2 | handlers_block.zig |
| 0x46 | CHAINID | - | chain_id | 2 | handlers_block.zig |
| 0x47 | SELFBALANCE | - | balance(this) | 5 | handlers_block.zig |
| 0x48 | BASEFEE | - | block.basefee | 2 | handlers_block.zig |
| 0x49 | BLOBHASH | index | tx.blob_versioned_hashes[index] | 3 | handlers_block.zig |
| 0x4a | BLOBBASEFEE | - | block.blob_basefee | 2 | handlers_block.zig |
| **0x50-0x5f: Stack & Memory** |
| 0x50 | POP | a | - | 2 | handlers_stack.zig |
| 0x51 | MLOAD | offset | memory[offset:offset+32] | 3 + expansion | handlers_memory.zig |
| 0x52 | MSTORE | offset, value | - | 3 + expansion | handlers_memory.zig |
| 0x53 | MSTORE8 | offset, value | - | 3 + expansion | handlers_memory.zig |
| 0x54 | SLOAD | key | storage[key] | 100-2100* | handlers_storage.zig |
| 0x55 | SSTORE | key, value | - | Complex** | handlers_storage.zig |
| 0x56 | JUMP | dest | - | 8 | handlers_control_flow.zig |
| 0x57 | JUMPI | dest, cond | - | 10 | handlers_control_flow.zig |
| 0x58 | PC | - | pc | 2 | handlers_control_flow.zig |
| 0x59 | MSIZE | - | memory_size | 2 | handlers_memory.zig |
| 0x5a | GAS | - | gas_remaining | 2 | handlers_context.zig |
| 0x5b | JUMPDEST | - | - | 1 | handlers_control_flow.zig |
| 0x5c | TLOAD | key | transient[key] | 100 | handlers_storage.zig |
| 0x5d | TSTORE | key, value | - | 100 | handlers_storage.zig |
| 0x5e | MCOPY | dest, src, length | - | 3 + 3/word | handlers_memory.zig |
| 0x5f | PUSH0 | - | 0 | 2 | handlers_stack.zig |
| **0x60-0x7f: PUSH** |
| 0x60-0x7f | PUSH1-PUSH32 | - | immediate | 3 | handlers_stack.zig |
| **0x80-0x8f: DUP** |
| 0x80-0x8f | DUP1-DUP16 | ..., a | ..., a, a | 3 | handlers_stack.zig |
| **0x90-0x9f: SWAP** |
| 0x90-0x9f | SWAP1-SWAP16 | ..., a, b | ..., b, a | 3 | handlers_stack.zig |
| **0xa0-0xa4: Log** |
| 0xa0 | LOG0 | offset, length | - | 375 + 8/byte | handlers_log.zig |
| 0xa1 | LOG1 | offset, length, topic1 | - | 375*2 + 8/byte | handlers_log.zig |
| 0xa2 | LOG2 | offset, length, topic1, topic2 | - | 375*3 + 8/byte | handlers_log.zig |
| 0xa3 | LOG3 | offset, length, topic1-3 | - | 375*4 + 8/byte | handlers_log.zig |
| 0xa4 | LOG4 | offset, length, topic1-4 | - | 375*5 + 8/byte | handlers_log.zig |
| **0xf0-0xff: System** |
| 0xf0 | CREATE | value, offset, length | address | 32000 + costs | handlers_system.zig |
| 0xf1 | CALL | gas, address, value, inOffset, inLength, outOffset, outLength | success | Complex*** | handlers_system.zig |
| 0xf2 | CALLCODE | gas, address, value, inOffset, inLength, outOffset, outLength | success | Complex*** | handlers_system.zig |
| 0xf3 | RETURN | offset, length | - | 0 + expansion | handlers_control_flow.zig |
| 0xf4 | DELEGATECALL | gas, address, inOffset, inLength, outOffset, outLength | success | Complex*** | handlers_system.zig |
| 0xf5 | CREATE2 | value, offset, length, salt | address | 32000 + hash + costs | handlers_system.zig |
| 0xfa | STATICCALL | gas, address, inOffset, inLength, outOffset, outLength | success | Complex*** | handlers_system.zig |
| 0xfd | REVERT | offset, length | - | 0 + expansion | handlers_control_flow.zig |
| 0xff | SELFDESTRUCT | address | - | 5000 + 25000**** | handlers_system.zig |

**Gas Cost Notes**:

\* **Warm/Cold Costs** (EIP-2929, Berlin+):
- Cold access: 2600 gas (first access to address/slot)
- Warm access: 100 gas (subsequent accesses)

\*\* **SSTORE Costs** (EIP-2200/3529, Istanbul+):
- Set (0 → non-zero): 20000 + cold/warm
- Update (non-zero → different): 5000 + cold/warm
- Delete (non-zero → 0): 5000 + cold/warm (refund 4800 in London+)
- No-op (same value): 100 (warm) or 2100 (cold)

\*\*\* **CALL Costs**:
- Base: 700 (EIP-150) + cold/warm access
- Value transfer: +9000
- New account: +25000
- Stipend: 2300 (added if value > 0)

\*\*\*\* **SELFDESTRUCT Costs**:
- Base: 5000
- New account (pre-London): +25000
- Cold access (Berlin+): +2600
- Refund (pre-London): 24000

---

## Adding New Instructions

### Step-by-Step Guide

1. **Research the EIP**
   - Read the EIP specification
   - Find Python reference in `execution-specs/.../instructions/`
   - Note hardfork activation
   - Identify gas costs

2. **Choose Handler Module**
   - Arithmetic: `handlers_arithmetic.zig`
   - Storage: `handlers_storage.zig`
   - System: `handlers_system.zig`
   - Create new module if needed

3. **Implement Handler**
   ```zig
   pub fn new_opcode(frame: *FrameType) FrameType.EvmError!void {
       // 1. Check hardfork availability
       if (frame.hardfork.isBefore(.TARGET_FORK)) {
           return error.InvalidOpcode;
       }

       // 2. Consume gas (match Python order exactly)
       try frame.consumeGas(base_cost);

       // 3. Pop inputs
       const input = try frame.popStack();

       // 4. Perform operation
       const result = compute(input);

       // 5. Push outputs
       try frame.pushStack(result);

       // 6. Update PC
       frame.pc += 1;
   }
   ```

4. **Register in Dispatcher**
   - Edit `src/frame.zig::executeOpcode()`
   - Add case to switch statement
   - Link to handler module

5. **Add Gas Constants**
   - If new constants needed, add to primitives library
   - Document source (EIP number)

6. **Write Tests**
   - Add unit tests in handler file
   - Run relevant spec tests
   - Compare traces with reference

7. **Document**
   - Update this README
   - Add to opcode reference table
   - Note hardfork requirements

---

## Resources

### Official Specifications

- **Ethereum Yellow Paper**: https://ethereum.github.io/yellowpaper/paper.pdf
- **EIP Index**: https://eips.ethereum.org/
- **execution-specs (Python reference)**: https://github.com/ethereum/execution-specs

### Key EIPs by Category

**Gas Metering**:
- EIP-150: Gas cost changes (Tangerine Whistle)
- EIP-1884: Repricing for trie-access opcodes (Istanbul)
- EIP-2200: Net gas metering for SSTORE (Istanbul)
- EIP-2929: Gas cost increases for state access opcodes (Berlin)
- EIP-3529: Reduction in refunds (London)

**New Opcodes**:
- EIP-145: Bitwise shifting instructions (Constantinople)
- EIP-1014: CREATE2 opcode (Constantinople)
- EIP-1052: EXTCODEHASH opcode (Constantinople)
- EIP-1344: CHAINID opcode (Istanbul)
- EIP-3198: BASEFEE opcode (London)
- EIP-3855: PUSH0 instruction (Shanghai)
- EIP-5656: MCOPY instruction (Cancun)
- EIP-1153: Transient storage opcodes (Cancun)
- EIP-4844: Blob transaction opcodes (Cancun)

**Behavior Changes**:
- EIP-140: REVERT instruction (Byzantium)
- EIP-211: RETURNDATASIZE and RETURNDATACOPY (Byzantium)
- EIP-214: Static calls (Byzantium)
- EIP-3541: Reject contracts starting with 0xEF (London)
- EIP-3860: Limit and meter init code (Shanghai)
- EIP-6780: SELFDESTRUCT only in same transaction (Cancun)
- EIP-7702: Set EOA account code (Prague)

### Python Reference File Locations

```
execution-specs/src/ethereum/forks/<hardfork>/vm/instructions/
├── arithmetic.py       # ADD, MUL, SUB, DIV, EXP, etc.
├── bitwise.py          # AND, OR, XOR, NOT, SHL, SHR, SAR
├── block.py            # BLOCKHASH, COINBASE, TIMESTAMP, etc.
├── comparison.py       # LT, GT, EQ, ISZERO
├── control_flow.py     # JUMP, JUMPI, RETURN, REVERT
├── environment.py      # ADDRESS, BALANCE, CALLER, etc.
├── keccak.py           # SHA3/KECCAK256
├── log.py              # LOG0-LOG4
├── memory.py           # MLOAD, MSTORE, MCOPY
├── stack.py            # POP, PUSH, DUP, SWAP
├── storage.py          # SLOAD, SSTORE, TLOAD, TSTORE
└── system.py           # CALL, CREATE, SELFDESTRUCT
```

### Debugging Tools

- **isolate-test.ts**: Run single test with max debug output
- **test-subset.ts**: Filter tests by hardfork/opcode
- **Trace comparison**: EIP-3155 format, shows divergence point

### Related Documentation

- `/Users/williamcory/guillotine-mini/CLAUDE.md` - Project overview
- `/Users/williamcory/guillotine-mini/src/frame.zig` - Frame implementation
- `/Users/williamcory/guillotine-mini/src/evm.zig` - EVM orchestrator
- `/Users/williamcory/guillotine-mini/test/specs/runner.zig` - Test execution

---

## Summary

This instruction handler architecture provides:

1. **Type-safe, modular design** - Generic handlers instantiated per Frame type
2. **Hardfork compliance** - Runtime checks for feature availability
3. **Python reference alignment** - Exact behavior matching for all opcodes
4. **Comprehensive gas metering** - All costs accounted for (base, memory, cold access)
5. **Clear error handling** - Proper propagation of all EVM errors
6. **Testability** - Spec tests validate against ethereum/tests

When implementing or debugging handlers:
- Always consult Python reference first
- Match gas calculation order exactly
- Test with spec tests for the relevant hardfork
- Use trace comparison to identify divergence points
- Follow existing patterns for consistency

For questions or issues, refer to test output, trace analysis, and Python reference implementations.
