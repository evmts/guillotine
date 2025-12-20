# Guillotine Mini - TypeScript/WASM Examples

Comprehensive examples demonstrating how to use the Guillotine Mini EVM via the WASM interface from TypeScript/JavaScript.

## Prerequisites

1. **Build the WASM module** (required):
   ```bash
   cd ../..
   zig build wasm
   ```
   This generates `zig-out/bin/guillotine_mini.wasm`

2. **Install dependencies** (for running examples):
   ```bash
   npm install
   # or
   bun install
   ```

3. **TypeScript/Bun** (recommended):
   ```bash
   brew install bun  # Fast TypeScript runtime
   ```

## Examples Overview

| Example | Description | Key Concepts |
|---------|-------------|--------------|
| [`basic-usage.ts`](#1-basic-usage) | Fundamental EVM operations | Initialization, bytecode execution, gas metering, return values |
| [`async-execution.ts`](#2-async-execution) | External state integration | Storage requests, async protocol, state backends |
| [`tracing.ts`](#3-tracing) | Execution introspection | Storage changes, event logs, gas refunds |
| [`custom-precompiles.ts`](#4-custom-precompiles) | EVM extensions | JavaScript callbacks, custom opcodes, domain-specific logic |
| [`advanced-patterns.ts`](#5-advanced-patterns) | Real-world scenarios | Nested calls, value transfers, transient storage, access lists |

## Running Examples

```bash
# Run individual examples
bun examples/typescript/basic-usage.ts
bun examples/typescript/async-execution.ts
bun examples/typescript/tracing.ts
bun examples/typescript/custom-precompiles.ts
bun examples/typescript/advanced-patterns.ts

# Or with Node.js (requires ts-node)
npx ts-node examples/typescript/basic-usage.ts
```

---

## 1. Basic Usage

**File:** `basic-usage.ts`

Learn the fundamentals of EVM execution:

- **Example 1: Simple Arithmetic**
  - Execute basic operations (2 + 3)
  - Read gas metrics
  - Understand stack-based execution

- **Example 2: Return Value**
  - Store result in memory
  - Return data from execution
  - Parse output as u256

- **Example 3: Storage Operations**
  - SSTORE/SLOAD operations
  - Inspect storage changes
  - Track gas refunds

### Key API Functions

```typescript
// Create EVM instance
const evmHandle = wasm.evm_create(hardforkBytes, hardforkBytes.length, logLevel);

// Set bytecode
wasm.evm_set_bytecode(evmHandle, bytecode, bytecode.length);

// Set execution context
wasm.evm_set_execution_context(
  evmHandle,
  gas,
  caller,
  address,
  value,
  calldata,
  calldata.length
);

// Set blockchain context
wasm.evm_set_blockchain_context(
  evmHandle,
  chainId,
  blockNumber,
  blockTimestamp,
  blockDifficulty,
  blockPrevrandao,
  blockCoinbase,
  blockGasLimit,
  blockBaseFee,
  blobBaseFee
);

// Execute
const success = wasm.evm_execute(evmHandle);

// Get results
const gasUsed = wasm.evm_get_gas_used(evmHandle);
const outputLen = wasm.evm_get_output_len(evmHandle);
wasm.evm_get_output(evmHandle, outputBuffer, outputLen);

// Clean up
wasm.evm_destroy(evmHandle);
```

### Output Example

```
Example 1: Simple Arithmetic (2 + 3)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Bytecode: 0x60 0x02 0x60 0x03 0x01 0x00
Operation: 2 + 3

✅ Execution: SUCCESS
⛽ Gas used: 9 / 100000
⛽ Gas remaining: 99991

📤 Output: (empty - result on stack)

💡 Note: Result (5) remains on stack. Use RETURN to output it.
```

---

## 2. Async Execution

**File:** `async-execution.ts`

Integrate the EVM with external state backends:

- **Example 1: Simple Async Storage Load**
  - Start async execution
  - Handle storage requests
  - Resume execution with data
  - Complete async protocol flow

- **Example 2: Multiple Async Requests**
  - Complex bytecode with multiple SLOADs
  - Async iteration loop
  - Request/response pattern

### Async Protocol Flow

```typescript
// 1. Enable storage injector
wasm.evm_enable_storage_injector(evmHandle);

// 2. Start execution (returns first request)
let continueExecution = wasm.evm_call_ffi(evmHandle, requestPtr);

// 3. Async loop
while (continueExecution) {
  const requestType = memory[requestPtr];

  if (requestType === RequestType.NEED_STORAGE) {
    // Query backend
    const value = await backend.getStorage(address, slot);

    // Build response
    const response = new Uint8Array(84); // address(20) + slot(32) + value(32)
    // ... pack data

    // Continue execution
    continueExecution = wasm.evm_continue_ffi(evmHandle, 1, response, 84, requestPtr);
  }
  else if (requestType === RequestType.RESULT) {
    break; // Done
  }
}
```

### Request Types

| Type | Value | Description | Response Format |
|------|-------|-------------|-----------------|
| `RESULT` | 0 | Execution complete | N/A |
| `NEED_STORAGE` | 1 | Storage value needed | `address(20) + slot(32) + value(32)` |
| `NEED_BALANCE` | 2 | Balance needed | `address(20) + balance(32)` |
| `NEED_CODE` | 3 | Contract code needed | `address(20) + code(...)` |
| `NEED_NONCE` | 4 | Account nonce needed | `address(20) + nonce(8)` |
| `READY_TO_COMMIT` | 5 | State changes ready | Acknowledge with `continue_type=5` |
| `ERROR` | 255 | Execution error | N/A |

### Use Cases

- **Database Backends**: PostgreSQL, LevelDB, RocksDB
- **Remote State**: RPC nodes, distributed databases
- **Layer 2 Solutions**: Rollups with off-chain state
- **State Channels**: Ephemeral state management

---

## 3. Tracing

**File:** `tracing.ts`

Debug and analyze EVM execution:

- **Example 1: Storage Changes**
  - Track modified slots
  - Inspect addresses
  - Analyze state transitions

- **Example 2: Event Logs**
  - Parse LOG0-LOG4 events
  - Extract topics and data
  - Decode event parameters

- **Example 3: Gas Refund Analysis**
  - Track SSTORE refunds
  - Understand refund caps (EIP-3529)
  - Optimize gas consumption

### Inspection APIs

```typescript
// Storage changes
const count = wasm.evm_get_storage_change_count(evmHandle);
for (let i = 0; i < count; i++) {
  const addressOut = new Uint8Array(20);
  const slotOut = new Uint8Array(32);
  const valueOut = new Uint8Array(32);

  wasm.evm_get_storage_change(evmHandle, i, addressOut, slotOut, valueOut);

  const slot = bytesToU256(slotOut);
  const value = bytesToU256(valueOut);
  console.log(`Slot ${slot}: ${value}`);
}

// Event logs
const logCount = wasm.evm_get_log_count(evmHandle);
for (let i = 0; i < logCount; i++) {
  const addressOut = new Uint8Array(20);
  const topicsCountOut = new Uint32Array(1);
  const topicsOut = new Uint8Array(4 * 32);
  const dataLenOut = new Uint32Array(1);
  const dataOut = new Uint8Array(1024);

  wasm.evm_get_log(
    evmHandle, i,
    addressOut, topicsCountOut, topicsOut,
    dataLenOut, dataOut, dataOut.length
  );

  console.log(`Log ${i}: ${topicsCountOut[0]} topics`);
}

// Gas refunds
const refund = wasm.evm_get_gas_refund(evmHandle);
console.log(`Gas refund: ${refund}`);
```

### Output Example

```
Example 1: Inspecting Storage Changes
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✅ Execution: SUCCESS
⛽ Gas used: 60000
⛽ Gas remaining: 40000
💰 Gas refund: 0

📦 Storage Changes (3 slots modified):

  Slot 0: 100
  Slot 1: 200
  Slot 5: 300
```

---

## 4. Custom Precompiles

**File:** `custom-precompiles.ts`

Extend the EVM with custom functionality:

- **Example 1: String Reverser**
  - Custom precompile at 0x1000
  - Input: UTF-8 string
  - Output: Reversed string
  - Gas: 100 + 10 per byte

- **Example 2: Fibonacci Calculator**
  - Custom precompile at 0x2000
  - Input: u256 (n)
  - Output: u256 (fibonacci(n))
  - Gas: 50 + 20 * n

### Registering Custom Precompiles

```typescript
// 1. Define handler function
const handler: PrecompileHandler = (input: Uint8Array, gasLimit: bigint) => {
  const gasCost = 100n + BigInt(input.length) * 10n;

  if (gasCost > gasLimit) {
    return { success: false, output: new Uint8Array(0), gasUsed: gasLimit };
  }

  // Custom logic
  const output = processInput(input);

  return { success: true, output, gasUsed: gasCost };
};

// 2. Register in registry
registry.register('0x0000000000000000000000000000000000001000', handler);

// 3. Load WASM with callback
const wasm = await loadWasmWithPrecompiles(registry);

// 4. WASM imports handle routing
const imports = {
  env: {
    js_precompile_callback: (
      address_ptr: number,
      input_ptr: number,
      input_len: number,
      gas_limit: number,
      output_len_ptr: number,
      output_ptr_ptr: number,
      gas_used_ptr: number
    ) => {
      // Read input from WASM memory
      const memory = new Uint8Array(instance.exports.memory.buffer);
      const address = memory.slice(address_ptr, address_ptr + 20);
      const input = memory.slice(input_ptr, input_ptr + input_len);

      // Try to handle
      const result = registry.handle(address, input, BigInt(gas_limit));

      if (!result || !result.success) {
        return 0; // Not handled, use default
      }

      // Allocate output, write metadata
      const outputPtr = wasm.malloc(result.output.length);
      memory.set(result.output, outputPtr);

      // Return success
      return 1;
    }
  }
};
```

### Calling Precompiles from Bytecode

```typescript
// Bytecode to call precompile at 0x1000
const bytecode = new Uint8Array([
  // Store input in memory
  0x7f, ...inputBytes, ...padding,  // PUSH32 input
  0x60, 0x00,                       // PUSH1 0 (offset)
  0x52,                             // MSTORE

  // CALL(gas, to, value, argsOffset, argsSize, retOffset, retSize)
  0x60, 0x20,                       // PUSH1 32 (retSize)
  0x60, 0x20,                       // PUSH1 32 (retOffset)
  0x60, 0x0c,                       // PUSH1 12 (argsSize)
  0x60, 0x00,                       // PUSH1 0 (argsOffset)
  0x60, 0x00,                       // PUSH1 0 (value)
  0x61, 0x10, 0x00,                 // PUSH2 0x1000 (precompile address)
  0x61, 0xff, 0xff,                 // PUSH2 65535 (gas)
  0xf1,                             // CALL

  // Return output
  0x60, 0x20,                       // PUSH1 32
  0x60, 0x20,                       // PUSH1 32
  0xf3                              // RETURN
]);
```

### Use Cases

- **Layer 2 Protocols**: Custom cryptography (BLS, ZK proofs)
- **Rollups**: Optimized state transitions
- **Private Chains**: Domain-specific operations
- **Testing**: Mock external dependencies
- **Development**: Rapid prototyping of new EIPs

---

## 5. Advanced Patterns

**File:** `advanced-patterns.ts`

Real-world contract execution patterns:

- **Example 1: Nested Contract Calls**
  - Contract A → Contract B → Contract C
  - Call depth management
  - Return data propagation
  - Context preservation

- **Example 2: Value Transfers**
  - ETH transfers between contracts
  - Balance tracking
  - CALL with value

- **Example 3: Transient Storage (EIP-1153)**
  - TLOAD/TSTORE opcodes
  - Transaction-scoped state
  - Gas optimization (always warm, 100 gas)
  - Reentrancy guards

- **Example 4: Access List Optimization (EIP-2930)**
  - Pre-warm addresses and slots
  - Gas savings comparison
  - Cold vs warm access costs

### Nested Calls Pattern

```typescript
// Contract C: Returns 42
const codeC = [
  0x60, 0x2a,  // PUSH1 42
  0x60, 0x00,  // PUSH1 0
  0x52,        // MSTORE
  0x60, 0x20,  // PUSH1 32
  0x60, 0x00,  // PUSH1 0
  0xf3         // RETURN
];

// Contract B: Calls C, adds 10
const codeB = [
  // CALL C
  0x60, 0x20,       // retSize
  0x60, 0x00,       // retOffset
  0x60, 0x00,       // argsSize
  0x60, 0x00,       // argsOffset
  0x60, 0x00,       // value
  0x73, ...addressC,  // to
  0x61, 0xff, 0xff, // gas
  0xf1,             // CALL

  // Add 10 to result
  0x60, 0x00,  // PUSH1 0
  0x51,        // MLOAD
  0x60, 0x0a,  // PUSH1 10
  0x01,        // ADD

  // Return
  0x60, 0x00,  // PUSH1 0
  0x52,        // MSTORE
  0x60, 0x20,  // PUSH1 32
  0x60, 0x00,  // PUSH1 0
  0xf3         // RETURN
];

// Contract A: Calls B, multiplies by 2
// ... similar pattern

// Result: C returns 42 → B returns 52 → A returns 104
```

### Transient Storage (EIP-1153)

```typescript
// Transient storage is transaction-scoped
const bytecode = [
  // TSTORE 999 at slot 0
  0x61, 0x03, 0xe7,  // PUSH2 999
  0x60, 0x00,        // PUSH1 0
  0x5d,              // TSTORE (0x5d)

  // TLOAD from slot 0
  0x60, 0x00,        // PUSH1 0
  0x5c,              // TLOAD (0x5c)

  // Return result
  0x60, 0x00,  // PUSH1 0
  0x52,        // MSTORE
  0x60, 0x20,  // PUSH1 32
  0x60, 0x00,  // PUSH1 0
  0xf3         // RETURN
];

// Benefits:
// - Always warm (100 gas vs 2100 cold SLOAD)
// - Cleared after transaction
// - Perfect for reentrancy guards
// - No refund complexity
```

### Access List Optimization

```typescript
// Without access list: Cold SLOAD = 2100 gas
// With access list: Warm SLOAD = 100 gas
// Savings: 2000 gas per slot

// Set access list before execution
const accessListAddresses = new Uint8Array(20);
accessListAddresses.set(contractAddress, 0);

wasm.evm_set_access_list_addresses(evmHandle, accessListAddresses, 1);

// Pre-warm storage slots
const accessListKeys = new Uint8Array(numSlots * 52); // address(20) + slot(32)
for (let i = 0; i < numSlots; i++) {
  accessListKeys.set(contractAddress, i * 52);
  accessListKeys.set(u256ToBytes(BigInt(i)), i * 52 + 20);
}

wasm.evm_set_access_list_storage_keys(
  evmHandle,
  accessListAddresses,
  accessListKeys.slice(20),
  numSlots
);
```

---

## API Reference

### Core Functions

| Function | Description | Returns |
|----------|-------------|---------|
| `evm_create(hardfork, hardfork_len, log_level)` | Create EVM instance | Handle |
| `evm_destroy(handle)` | Destroy EVM instance | void |
| `evm_set_bytecode(handle, bytecode, len)` | Set bytecode | bool |
| `evm_set_execution_context(handle, gas, caller, address, value, calldata, calldata_len)` | Set execution context | bool |
| `evm_set_blockchain_context(handle, ...)` | Set block context | void |
| `evm_execute(handle)` | Execute bytecode | bool |
| `evm_get_gas_used(handle)` | Get gas used | i64 |
| `evm_get_gas_remaining(handle)` | Get gas remaining | i64 |
| `evm_get_output_len(handle)` | Get output length | usize |
| `evm_get_output(handle, buffer, len)` | Copy output data | usize |

### Async Protocol Functions

| Function | Description |
|----------|-------------|
| `evm_enable_storage_injector(handle)` | Enable async storage |
| `evm_call_ffi(handle, request_out)` | Start async execution |
| `evm_continue_ffi(handle, type, data, len, request_out)` | Continue execution |

### Inspection Functions

| Function | Description |
|----------|-------------|
| `evm_get_gas_refund(handle)` | Get gas refund counter |
| `evm_get_storage_change_count(handle)` | Get number of modified slots |
| `evm_get_storage_change(handle, index, ...)` | Get storage change by index |
| `evm_get_log_count(handle)` | Get number of logs |
| `evm_get_log(handle, index, ...)` | Get log by index |

### State Management Functions

| Function | Description |
|----------|-------------|
| `evm_set_storage(handle, address, slot, value)` | Set storage value |
| `evm_get_storage(handle, address, slot, value_out)` | Get storage value |
| `evm_set_balance(handle, address, balance)` | Set account balance |
| `evm_set_code(handle, address, code, code_len)` | Set contract code |
| `evm_set_nonce(handle, address, nonce)` | Set account nonce |

### Access List Functions (EIP-2930)

| Function | Description |
|----------|-------------|
| `evm_set_access_list_addresses(handle, addresses, count)` | Set pre-warmed addresses |
| `evm_set_access_list_storage_keys(handle, addresses, slots, count)` | Set pre-warmed storage slots |

### Blob Functions (EIP-4844)

| Function | Description |
|----------|-------------|
| `evm_set_blob_hashes(handle, hashes, count)` | Set blob versioned hashes |

---

## Gas Costs Reference

### Opcodes (Cancun)

| Operation | Base Cost | Notes |
|-----------|-----------|-------|
| ADD, SUB, MUL | 3 gas | Arithmetic |
| DIV, MOD | 5 gas | Division |
| SLOAD (cold) | 2100 gas | First access |
| SLOAD (warm) | 100 gas | Subsequent access |
| SSTORE (set) | 20000 gas | Zero → nonzero |
| SSTORE (update) | 5000 gas | Nonzero → nonzero |
| TLOAD | 100 gas | Always warm |
| TSTORE | 100 gas | Always warm |
| CALL (cold) | 2600 gas | + stipend costs |
| CALL (warm) | 100 gas | Pre-warmed |
| LOG0 | 375 + 375/word | Base + data |
| LOG1-LOG4 | +375 per topic | Additional topics |

### Access Lists (EIP-2930)

| Item | Cost |
|------|------|
| Address | 2400 gas |
| Storage key | 1900 gas |

**Benefit**: Pre-paying upfront saves 2000 gas per cold SLOAD/SSTORE

### Refunds (EIP-3529, London+)

- **Cap**: 1/5 of gas used (was 1/2 pre-London)
- **SSTORE clear**: 4800 gas (nonzero → zero)
- **No refunds**: For SELFDESTRUCT (EIP-6780)

---

## Hardforks Supported

| Hardfork | Notable Features |
|----------|------------------|
| **Frontier** | Basic EVM operations |
| **Homestead** | DELEGATECALL |
| **Tangerine** | Gas cost adjustments (EIP-150) |
| **Spurious** | REVERT, STATICCALL |
| **Byzantium** | RETURNDATASIZE, RETURNDATACOPY |
| **Constantinople** | CREATE2, EXTCODEHASH, SHL/SHR/SAR |
| **Istanbul** | ChainID, SELFBALANCE |
| **Berlin** | Warm/cold access (EIP-2929) |
| **London** | Base fee, reduced refunds (EIP-3529) |
| **Merge** | PREVRANDAO (EIP-4399) |
| **Shanghai** | PUSH0, warm coinbase, init code limit |
| **Cancun** | Transient storage, MCOPY, blob transactions |
| **Prague** | TBD (future) |

---

## Common Patterns

### Pattern 1: Execute Simple Bytecode

```typescript
const wasm = await loadWasm();
const evmHandle = wasm.evm_create(hardforkBytes, hardforkBytes.length, 0);

wasm.evm_set_bytecode(evmHandle, bytecode, bytecode.length);
wasm.evm_set_execution_context(evmHandle, gas, caller, address, value, calldata, calldata.length);
wasm.evm_set_blockchain_context(evmHandle, ...);

const success = wasm.evm_execute(evmHandle);
const gasUsed = wasm.evm_get_gas_used(evmHandle);

wasm.evm_destroy(evmHandle);
```

### Pattern 2: Async Execution Loop

```typescript
wasm.evm_enable_storage_injector(evmHandle);
let continueExecution = wasm.evm_call_ffi(evmHandle, requestPtr);

while (continueExecution) {
  const requestType = memory[requestPtr];

  switch (requestType) {
    case RequestType.NEED_STORAGE:
      const value = await backend.getStorage(address, slot);
      continueExecution = wasm.evm_continue_ffi(evmHandle, 1, response, 84, requestPtr);
      break;
    case RequestType.RESULT:
      return; // Done
  }
}
```

### Pattern 3: Inspect Execution Results

```typescript
const success = wasm.evm_execute(evmHandle);

// Storage changes
const storageCount = wasm.evm_get_storage_change_count(evmHandle);
for (let i = 0; i < storageCount; i++) {
  wasm.evm_get_storage_change(evmHandle, i, addrOut, slotOut, valueOut);
}

// Logs
const logCount = wasm.evm_get_log_count(evmHandle);
for (let i = 0; i < logCount; i++) {
  wasm.evm_get_log(evmHandle, i, addrOut, topicsOut, dataOut);
}

// Gas metrics
const gasUsed = wasm.evm_get_gas_used(evmHandle);
const gasRefund = wasm.evm_get_gas_refund(evmHandle);
```

---

## Troubleshooting

### Issue: "Module not found"

**Solution**: Build WASM module first:
```bash
zig build wasm
```

### Issue: "Out of gas"

**Solution**: Increase gas limit or optimize bytecode:
```typescript
const gas = 10000000n; // Increase limit
wasm.evm_set_execution_context(evmHandle, Number(gas), ...);
```

### Issue: "Invalid bytecode"

**Solution**: Verify opcode sequence:
```typescript
// Invalid: JUMP without JUMPDEST
[0x56] // JUMP

// Valid: JUMP to JUMPDEST
[
  0x60, 0x03, // PUSH1 3 (jump target)
  0x56,       // JUMP
  0x5b        // JUMPDEST
]
```

### Issue: "Storage not found"

**Solution**: Enable storage injector for async:
```typescript
wasm.evm_enable_storage_injector(evmHandle);
```

Or pre-populate storage for sync:
```typescript
wasm.evm_set_storage(evmHandle, address, slot, value);
```

---

## Best Practices

1. **Always destroy EVM instances** to prevent memory leaks:
   ```typescript
   try {
     // ... use EVM
   } finally {
     wasm.evm_destroy(evmHandle);
   }
   ```

2. **Use access lists** for multi-slot operations to save gas:
   ```typescript
   wasm.evm_set_access_list_addresses(...);
   wasm.evm_set_access_list_storage_keys(...);
   ```

3. **Enable tracing** during development:
   ```typescript
   const evmHandle = wasm.evm_create(hardforkBytes, hardforkBytes.length, 4); // log_level=4 (debug)
   ```

4. **Validate bytecode** before execution:
   - Ensure JUMP targets are JUMPDEST
   - Check PUSH immediate values are within bounds
   - Verify call gas limits

5. **Handle errors gracefully**:
   ```typescript
   const success = wasm.evm_execute(evmHandle);
   if (!success) {
     const outputLen = wasm.evm_get_output_len(evmHandle);
     if (outputLen > 0) {
       // Get revert data
     }
   }
   ```

---

## Additional Resources

- **Main Documentation**: `../../CLAUDE.md`
- **C API Reference**: `../../src/root_c.zig`
- **Zig Implementation**: `../../src/evm.zig`, `../../src/frame.zig`
- **Ethereum Specs**: https://github.com/ethereum/execution-specs
- **EIPs**: https://eips.ethereum.org/

---

## Contributing

Found a bug or want to add an example? See `../../CONTRIBUTING.md`

---

## License

See `../../LICENSE`
