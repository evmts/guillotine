# TypeScript EVM API Reference

Complete API documentation for the TypeScript EVM implementation.

## Table of Contents

- [Core Classes](#core-classes)
  - [Evm](#evm)
  - [Frame](#frame)
  - [Storage](#storage)
  - [AccessListManager](#accesslistmanager)
  - [Bytecode](#bytecode)
- [Configuration](#configuration)
  - [EvmConfig](#evmconfig)
  - [Hardfork](#hardfork)
- [Types](#types)
  - [BlockContext](#blockcontext)
  - [CallParams](#callparams)
  - [CallResult](#callresult)
  - [Log](#log)
- [Errors](#errors)
- [Host Interface](#host-interface)

---

## Core Classes

### Evm

The main EVM orchestrator that manages state, storage, and nested calls.

#### Constructor

```typescript
constructor(
  host?: HostInterface | null,
  hardfork: Hardfork = Hardfork.CANCUN,
  blockContext?: BlockContext | null
)
```

**Parameters:**
- `host` - Optional host interface for external state backend
- `hardfork` - Hardfork version (default: CANCUN)
- `blockContext` - Optional block context information

**Example:**
```typescript
const evm = new Evm(null, Hardfork.CANCUN, {
  chain_id: 1n,
  block_number: 18_000_000n,
  block_timestamp: 1700000000n,
  block_difficulty: 0n,
  block_prevrandao: 0n,
  block_coinbase: coinbaseAddress,
  block_gas_limit: 30_000_000n,
  block_base_fee: 20_000_000_000n,
  blob_base_fee: 1n,
  block_hashes: [],
});
```

#### Methods

##### `initTransactionState(blobVersionedHashes?: Uint8Array[])`

Initialize transaction state. Must be called before any transaction execution.

**Clears:**
- Storage (persistent + transient)
- Balance/nonce/code caches
- Access lists (warm/cold tracking)
- Frame stack
- Logs
- Account tracking (created, selfdestructed, touched)
- Balance snapshots
- Gas refunds

**Parameters:**
- `blobVersionedHashes` - Optional EIP-4844 blob hashes

**Example:**
```typescript
evm.initTransactionState([blobHash1, blobHash2]);
```

##### `getActiveFork(): Hardfork`

Get the currently active hardfork, accounting for fork transitions.

**Returns:** Current hardfork enum value

**Example:**
```typescript
const fork = evm.getActiveFork();
if (fork >= Hardfork.BERLIN) {
  // EIP-2929 warm/cold tracking active
}
```

##### `accessAddress(address: Address): bigint`

Access an address for EIP-2929 warm/cold tracking.

**Parameters:**
- `address` - Address to access

**Returns:** Gas cost (0 pre-Berlin, 2600 cold, 100 warm)

**Example:**
```typescript
const gasCost = evm.accessAddress(targetAddress);
frame.consumeGas(gasCost);
```

##### `accessStorageSlot(contractAddress: Address, slot: bigint): bigint`

Access a storage slot for EIP-2929 warm/cold tracking.

**Parameters:**
- `contractAddress` - Contract address
- `slot` - Storage slot key (u256)

**Returns:** Gas cost (200/800 pre-Berlin, 2100 cold, 100 warm)

**Example:**
```typescript
const gasCost = evm.accessStorageSlot(address, 0n);
frame.consumeGas(gasCost);
```

##### `getNonce(address: Address): bigint`

Get account nonce.

**Parameters:**
- `address` - Account address

**Returns:** Nonce (0 if not set)

##### `getBalance(address: Address): bigint`

Get account balance.

**Parameters:**
- `address` - Account address

**Returns:** Balance in wei (0 if not set)

##### `getCode(address: Address): Uint8Array`

Get contract bytecode with EIP-7702 delegation support.

**Parameters:**
- `address` - Contract address

**Returns:** Bytecode (empty if no code)

**Example:**
```typescript
const code = evm.getCode(contractAddress);
if (code.length === 0) {
  console.log('EOA or empty contract');
} else if (code[0] === 0xef && code[1] === 0x01) {
  console.log('EIP-7702 delegation designation');
}
```

##### `setBalanceWithSnapshot(address: Address, newBalance: bigint)`

Set balance with copy-on-write snapshot for revert handling.

**Parameters:**
- `address` - Address whose balance to modify
- `newBalance` - New balance value

**Note:** Automatically snapshots balance in all active snapshots on the stack.

##### `preWarmTransaction(target: Address)`

Pre-warm addresses at transaction start (EIP-2929, EIP-3651).

**Pre-warmed addresses:**
- Transaction origin
- Transaction target (if not zero address)
- Coinbase (Shanghai+)
- All precompiles (0x01-0x09 Berlin, 0x01-0x0A Cancun, 0x01-0x12 Prague)

**Parameters:**
- `target` - Transaction target address

**Example:**
```typescript
evm.preWarmTransaction(contractAddress);
```

##### `computeCreateAddress(sender: Address, nonce: bigint): Address`

Compute CREATE address using RLP encoding.

**Formula:** `keccak256(rlp([sender, nonce]))[12:]`

**Parameters:**
- `sender` - Sender address
- `nonce` - Sender nonce

**Returns:** Computed contract address (20 bytes)

**Example:**
```typescript
const newAddress = evm.computeCreateAddress(senderAddress, 5n);
```

##### `computeCreate2Address(sender: Address, salt: bigint, initCode: Uint8Array): Address`

Compute CREATE2 address (EIP-1014).

**Formula:** `keccak256(0xff ++ sender ++ salt ++ keccak256(init_code))[12:]`

**Parameters:**
- `sender` - Sender address
- `salt` - 32-byte salt value
- `initCode` - Initialization code

**Returns:** Computed contract address (20 bytes)

**Example:**
```typescript
const create2Address = evm.computeCreate2Address(
  senderAddress,
  0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdefn,
  initCode
);
```

##### `addRefund(amount: bigint)`

Add gas refund (called by SSTORE).

**Parameters:**
- `amount` - Refund amount to add

##### `subRefund(amount: bigint)`

Subtract gas refund (called by SSTORE).

**Parameters:**
- `amount` - Refund amount to subtract

##### `dispose()`

Clean up EVM resources. Clears all Maps/Sets to help GC.

---

### Frame

Bytecode interpreter for a single execution context.

#### Constructor

```typescript
constructor(params: FrameParams)
```

**FrameParams:**
```typescript
interface FrameParams {
  bytecode: Uint8Array;          // Raw bytecode to execute
  gas: bigint;                   // Initial gas available
  caller: Address;               // Address that initiated this call
  address: Address;              // Address being executed
  value: bigint;                 // Wei value transferred
  calldata: Uint8Array;          // Input data
  evmPtr: unknown;               // Opaque pointer to parent EVM
  hardfork: Hardfork;            // Active hardfork
  isStatic: boolean;             // Whether this is a static call
  authorized?: bigint;           // EIP-7702 authorization
  callDepth?: number;            // Current call depth
}
```

**Example:**
```typescript
const frame = new Frame({
  bytecode: contractCode,
  gas: 1_000_000n,
  caller: msg.sender,
  address: msg.to,
  value: msg.value,
  calldata: msg.data,
  evmPtr: evm,
  hardfork: Hardfork.CANCUN,
  isStatic: false,
});
```

#### Properties

##### `stack: readonly bigint[]`

Stack contents (read-only). Top of stack is at the end of the array.

**Example:**
```typescript
console.log('Stack depth:', frame.stack.length);
console.log('Top of stack:', frame.stack[frame.stack.length - 1]);
```

##### `pc: number`

Program counter (current bytecode position).

##### `gasRemaining: bigint`

Remaining gas (signed to allow negative during calculations).

##### `bytecode: Bytecode`

Analyzed bytecode with jump destination metadata.

##### `output: Uint8Array`

Output data (set by RETURN/REVERT).

##### `returnData: Uint8Array`

Return data from last call/create (for RETURNDATASIZE/RETURNDATACOPY).

##### `stopped: boolean`

Whether execution has stopped (STOP/RETURN).

##### `reverted: boolean`

Whether execution reverted (REVERT).

##### `caller: Address`

Address that initiated this call.

##### `address: Address`

Address being executed (contract address).

##### `value: bigint`

Wei value transferred with this call.

##### `calldata: Uint8Array`

Input data for the call.

##### `hardfork: Hardfork`

Active hardfork.

##### `isStatic: boolean`

Whether this is a static call (no state modifications allowed).

##### `callDepth: number`

Current call depth (for depth limit checks).

#### Methods

##### `execute()`

Main execution loop. Executes bytecode until STOP/RETURN/REVERT or error.

**Iteration limit:** 10,000,000 operations (prevents infinite loops)

**Example:**
```typescript
try {
  frame.execute();
  console.log('Success:', frame.output);
} catch (error) {
  if (error instanceof EvmError) {
    console.error('EVM error:', error.callError);
  }
}
```

##### `step()`

Execute a single step (one opcode). Used for tracing/debugging.

**Example:**
```typescript
while (!frame.stopped && !frame.reverted && frame.pc < frame.bytecode.length) {
  console.log(`PC: ${frame.pc}, Opcode: 0x${frame.getCurrentOpcode()?.toString(16)}`);
  frame.step();
}
```

##### `executeOpcode(opcode: number)`

Execute a specific opcode. Delegates to handler modules.

**Parameters:**
- `opcode` - Opcode byte (0x00-0xFF)

**Throws:** `EvmError` on invalid opcode or execution error

##### Stack Operations

###### `pushStack(value: bigint)`

Push value onto stack.

**Parameters:**
- `value` - Value to push (u256)

**Throws:** `StackOverflow` if stack exceeds 1024 items

###### `popStack(): bigint`

Pop value from stack.

**Returns:** Top stack value

**Throws:** `StackUnderflow` if stack is empty

###### `peekStack(index: number): bigint`

Peek at stack value at given depth (0 = top).

**Parameters:**
- `index` - Stack index (0 = top)

**Returns:** Stack value at index

**Throws:** `StackUnderflow` if index out of bounds

##### Memory Operations

###### `readMemory(offset: number): number`

Read byte from memory (returns 0 for uninitialized).

**Parameters:**
- `offset` - Byte offset

**Returns:** Byte value (0-255)

###### `writeMemory(offset: number, value: number)`

Write byte to memory. Expands memory if needed.

**Parameters:**
- `offset` - Byte offset
- `value` - Byte value (0-255)

###### `getMemorySlice(): Uint8Array`

Get memory contents as a slice (for tracing).

**Returns:** Copy of memory contents

##### Gas Operations

###### `consumeGas(amount: bigint)`

Consume gas.

**Parameters:**
- `amount` - Gas to consume

**Throws:** `OutOfGas` if insufficient gas

**Example:**
```typescript
frame.consumeGas(3n); // Charge 3 gas
```

###### `memoryExpansionCost(endBytes: bigint | number): bigint`

Calculate memory expansion cost.

**Formula:** `3n + n²/512` where n is word count (32-byte words)

**Parameters:**
- `endBytes` - End byte offset

**Returns:** Gas cost for expansion (0 if no expansion needed)

**Example:**
```typescript
const expansionCost = frame.memoryExpansionCost(1024);
frame.consumeGas(expansionCost);
```

##### Gas Cost Helpers

###### `selfdestructGasCost(): bigint`

Calculate SELFDESTRUCT gas cost (EIP-150 aware).

**Returns:**
- 0 (pre-Tangerine Whistle)
- 5000 (Tangerine Whistle+)

###### `selfdestructRefund(): bigint`

Calculate SELFDESTRUCT refund (EIP-3529 aware).

**Returns:**
- 24000 (pre-London)
- 0 (London+)

###### `createGasCost(initCodeSize: number): bigint`

Calculate CREATE gas cost (EIP-3860 aware).

**Formula:**
- Base: 32000
- Shanghai+: +2 per init code word

**Parameters:**
- `initCodeSize` - Init code size in bytes

**Returns:** Total gas cost

###### `create2GasCost(initCodeSize: number): bigint`

Calculate CREATE2 gas cost (EIP-3860 aware).

**Formula:**
- Base: 32000
- Keccak: 6 per init code word
- Shanghai+: +2 per init code word

**Parameters:**
- `initCodeSize` - Init code size in bytes

**Returns:** Total gas cost

##### Bytecode Operations

###### `getCurrentOpcode(): number | null`

Get current opcode at PC.

**Returns:** Opcode byte or null if PC out of bounds

###### `readImmediate(size: number): bigint | null`

Read immediate data for PUSH operations.

**Parameters:**
- `size` - Number of bytes to read (1-32)

**Returns:** Immediate value or null if not enough bytes

---

### Storage

Storage manager for persistent and transient storage.

#### Constructor

```typescript
constructor(
  host?: HostInterface | null,
  injector?: StorageInjector | null
)
```

**Parameters:**
- `host` - Optional host interface for external state
- `injector` - Optional storage injector for async data fetching

#### Methods

##### `get(address: Address, slot: bigint): bigint`

Get persistent storage value.

**Parameters:**
- `address` - Contract address
- `slot` - Storage slot key

**Returns:** Storage value (0 if not set)

##### `set(address: Address, slot: bigint, value: bigint)`

Set persistent storage value.

**Parameters:**
- `address` - Contract address
- `slot` - Storage slot key
- `value` - New value

##### `getOriginal(address: Address, slot: bigint): bigint`

Get original storage value (snapshot at transaction start).

Used for SSTORE gas refund calculations.

**Parameters:**
- `address` - Contract address
- `slot` - Storage slot key

**Returns:** Original value (0 if not set)

##### `getTransient(address: Address, slot: bigint): bigint`

Get transient storage value (EIP-1153).

**Parameters:**
- `address` - Contract address
- `slot` - Storage slot key

**Returns:** Transient value (0 if not set)

##### `setTransient(address: Address, slot: bigint, value: bigint)`

Set transient storage value (EIP-1153).

**Parameters:**
- `address` - Contract address
- `slot` - Storage slot key
- `value` - New value

##### `snapshot(): StorageSnapshot`

Create a storage snapshot for revert handling.

**Returns:** Snapshot object containing storage/original/transient state

##### `restore(snapshot: StorageSnapshot)`

Restore storage from snapshot (on revert).

**Parameters:**
- `snapshot` - Snapshot to restore

---

### AccessListManager

EIP-2929 warm/cold access tracking.

#### Methods

##### `accessAddress(address: Address): number`

Access an address.

**Returns:**
- 2600 (cold access, first time)
- 100 (warm access, subsequent)

##### `accessStorageSlot(address: Address, slot: bigint): number`

Access a storage slot.

**Returns:**
- 2100 (cold access, first time)
- 100 (warm access, subsequent)

##### `preWarmAddresses(addresses: Address[])`

Pre-warm multiple addresses (for transaction initialization).

##### `snapshot(): AccessListSnapshot`

Create snapshot for revert handling.

##### `restore(snapshot: AccessListSnapshot)`

Restore from snapshot.

---

### Bytecode

Bytecode analysis and JUMPDEST tracking.

#### Constructor

```typescript
constructor(bytecode: Uint8Array)
```

**Analyzes bytecode to:**
- Build JUMPDEST bitmap for valid jump destinations
- Enable fast JUMPDEST validation (O(1) lookup)

#### Properties

##### `length: number`

Bytecode length in bytes.

##### `raw: Uint8Array`

Raw bytecode bytes.

#### Methods

##### `getOpcode(pc: number): number | null`

Get opcode at program counter.

**Parameters:**
- `pc` - Program counter

**Returns:** Opcode byte or null if out of bounds

##### `readImmediate(pc: number, size: number): bigint | null`

Read immediate data for PUSH operations.

**Parameters:**
- `pc` - Program counter (points to PUSH opcode)
- `size` - Number of bytes to read (1-32)

**Returns:** Immediate value or null if not enough bytes

##### `isValidJumpDest(pc: number): boolean`

Check if PC points to a valid JUMPDEST.

**Parameters:**
- `pc` - Program counter

**Returns:** true if PC is a valid jump destination

**Example:**
```typescript
const dest = Number(frame.popStack());
if (!frame.bytecode.isValidJumpDest(dest)) {
  throw new EvmError(CallError.InvalidJumpDestination);
}
```

---

## Configuration

### EvmConfig

EVM configuration options.

```typescript
interface EvmConfig {
  hardfork: Hardfork;
  stack_size: number;
  max_bytecode_size: number;
  max_initcode_size: number;
  block_gas_limit: bigint;
  memory_initial_capacity: number;
  memory_limit: bigint;
  max_call_depth: number;
  opcode_overrides: OpcodeOverride[];
  precompile_overrides: PrecompileOverride[];
  loop_quota: number | null;
  enable_beacon_roots: boolean;
  enable_historical_block_hashes: boolean;
  enable_validator_deposits: boolean;
  enable_validator_withdrawals: boolean;
}
```

**Defaults:**
```typescript
const DEFAULT_CONFIG: EvmConfig = {
  hardfork: Hardfork.CANCUN,
  stack_size: 1024,
  max_bytecode_size: 24576,      // 24 KB (EIP-170)
  max_initcode_size: 49152,      // 48 KB (EIP-3860)
  block_gas_limit: 30_000_000n,
  memory_initial_capacity: 4096,
  memory_limit: 0xFFFFFFn,       // ~16.7 MB
  max_call_depth: 1024,
  opcode_overrides: [],
  precompile_overrides: [],
  loop_quota: 1_000_000,
  enable_beacon_roots: true,
  enable_historical_block_hashes: true,
  enable_validator_deposits: true,
  enable_validator_withdrawals: true,
};
```

**Factory Functions:**

```typescript
// Create custom config
const config = createConfig({
  hardfork: Hardfork.BERLIN,
  block_gas_limit: 15_000_000n,
});

// Use preset
const mainnetConfig = ConfigPresets.mainnet();
const testConfig = ConfigPresets.testing();
```

---

### Hardfork

Ethereum hardfork enumeration.

```typescript
enum Hardfork {
  FRONTIER = 'FRONTIER',
  HOMESTEAD = 'HOMESTEAD',
  TANGERINE = 'TANGERINE',
  SPURIOUS = 'SPURIOUS',
  BYZANTIUM = 'BYZANTIUM',
  CONSTANTINOPLE = 'CONSTANTINOPLE',
  ISTANBUL = 'ISTANBUL',
  BERLIN = 'BERLIN',
  LONDON = 'LONDON',
  MERGE = 'MERGE',
  SHANGHAI = 'SHANGHAI',
  CANCUN = 'CANCUN',
  PRAGUE = 'PRAGUE',
}
```

**Utility Functions:**

```typescript
// Parse from string
const fork = parseHardfork('cancun'); // Hardfork.CANCUN

// Version checks
if (isAtLeast(currentFork, Hardfork.BERLIN)) {
  // EIP-2929 active
}

if (isBefore(currentFork, Hardfork.LONDON)) {
  // Pre-London behavior
}
```

---

## Types

### BlockContext

Block-level information for EVM execution.

```typescript
interface BlockContext {
  chain_id: bigint;              // Chain ID (EIP-155)
  block_number: bigint;          // Current block number
  block_timestamp: bigint;       // Block timestamp (seconds)
  block_difficulty: bigint;      // Block difficulty (pre-Merge)
  block_prevrandao: bigint;      // PREVRANDAO (Merge+)
  block_coinbase: Address;       // Coinbase address
  block_gas_limit: bigint;       // Block gas limit
  block_base_fee: bigint;        // Base fee (EIP-1559, London+)
  blob_base_fee: bigint;         // Blob base fee (EIP-4844, Cancun+)
  block_hashes: Uint8Array[];    // Recent block hashes (last 256)
}
```

---

### CallParams

Call parameter types (to be implemented in Part 2).

---

### CallResult

Call result types.

```typescript
interface CallResult {
  success: boolean;              // Execution succeeded
  gas_remaining: bigint;         // Gas remaining after execution
  output: Uint8Array;            // Output data
  logs: Log[];                   // Event logs
  gas_refund: bigint;            // Gas refunds
  created_address?: Address;     // Address of created contract (CREATE/CREATE2)
}
```

---

### Log

Event log structure (LOG0-LOG4 opcodes).

```typescript
interface Log {
  address: Address;              // Contract that emitted the log
  topics: bigint[];              // Indexed topics (0-4)
  data: Uint8Array;              // Non-indexed event data
}
```

**Example:**
```typescript
// LOG1 example: Transfer(address indexed from, address indexed to, uint256 value)
const transferLog: Log = {
  address: tokenAddress,
  topics: [
    keccak256('Transfer(address,address,uint256)'), // Topic 0 (event signature)
    addressToBigInt(fromAddress),                   // Topic 1 (from)
    addressToBigInt(toAddress),                     // Topic 2 (to)
  ],
  data: encodedValue, // Non-indexed value parameter
};
```

---

## Errors

### EvmError

Main error class for EVM execution errors.

```typescript
class EvmError extends Error {
  constructor(
    public callError: CallError,
    message?: string
  )
}
```

### CallError

Error type enumeration.

```typescript
enum CallError {
  // Gas errors
  OutOfGas = 'OutOfGas',

  // Stack errors
  StackOverflow = 'StackOverflow',
  StackUnderflow = 'StackUnderflow',

  // Memory errors
  OutOfBounds = 'OutOfBounds',

  // Control flow errors
  InvalidJumpDestination = 'InvalidJumpDestination',
  InvalidOpcode = 'InvalidOpcode',

  // State modification errors
  WriteInStaticContext = 'WriteInStaticContext',

  // Create errors
  ContractSizeExceeded = 'ContractSizeExceeded',
  InitCodeSizeExceeded = 'InitCodeSizeExceeded',
  CreateCollision = 'CreateCollision',

  // Call errors
  CallDepthExceeded = 'CallDepthExceeded',
  InsufficientBalance = 'InsufficientBalance',

  // Other
  ExecutionTimeout = 'ExecutionTimeout',
  Reverted = 'Reverted',
}
```

**Usage:**
```typescript
try {
  frame.execute();
} catch (error) {
  if (error instanceof EvmError) {
    switch (error.callError) {
      case CallError.OutOfGas:
        console.error('Out of gas');
        break;
      case CallError.StackUnderflow:
        console.error('Stack underflow');
        break;
      default:
        console.error('EVM error:', error.callError);
    }
  }
}
```

---

## Host Interface

Optional interface for external state backends.

```typescript
interface HostInterface {
  getBalance(address: Address): bigint;
  setBalance(address: Address, balance: bigint): void;

  getNonce(address: Address): bigint;
  setNonce(address: Address, nonce: bigint): void;

  getCode(address: Address): Uint8Array;
  setCode(address: Address, code: Uint8Array): void;

  getStorage(address: Address, slot: bigint): bigint;
  setStorage(address: Address, slot: bigint, value: bigint): void;

  // Optional methods for additional functionality
  accountExists?(address: Address): boolean;
  isEmpty?(address: Address): boolean;
  getCodeHash?(address: Address): Uint8Array;
}
```

**Example Implementation:**

```typescript
class MemoryHost implements HostInterface {
  private balances = new Map<string, bigint>();
  private nonces = new Map<string, bigint>();
  private code = new Map<string, Uint8Array>();
  private storage = new Map<string, bigint>();

  private addrKey(address: Address): string {
    return Array.from(address).map(b => b.toString(16).padStart(2, '0')).join('');
  }

  private storageKey(address: Address, slot: bigint): string {
    return `${this.addrKey(address)}:${slot.toString(16)}`;
  }

  getBalance(address: Address): bigint {
    return this.balances.get(this.addrKey(address)) ?? 0n;
  }

  setBalance(address: Address, balance: bigint): void {
    this.balances.set(this.addrKey(address), balance);
  }

  getNonce(address: Address): bigint {
    return this.nonces.get(this.addrKey(address)) ?? 0n;
  }

  setNonce(address: Address, nonce: bigint): void {
    this.nonces.set(this.addrKey(address), nonce);
  }

  getCode(address: Address): Uint8Array {
    return this.code.get(this.addrKey(address)) ?? new Uint8Array(0);
  }

  setCode(address: Address, code: Uint8Array): void {
    this.code.set(this.addrKey(address), code);
  }

  getStorage(address: Address, slot: bigint): bigint {
    return this.storage.get(this.storageKey(address, slot)) ?? 0n;
  }

  setStorage(address: Address, slot: bigint, value: bigint): void {
    this.storage.set(this.storageKey(address, slot), value);
  }
}
```

---

## Complete Example

Putting it all together:

```typescript
import {
  Evm,
  Frame,
  Hardfork,
  EvmError,
  CallError,
  type BlockContext,
  type HostInterface,
} from 'guillotine-mini-ts';

// Set up block context
const blockContext: BlockContext = {
  chain_id: 1n,
  block_number: 18_000_000n,
  block_timestamp: 1700000000n,
  block_difficulty: 0n,
  block_prevrandao: 0n,
  block_coinbase: new Uint8Array(20),
  block_gas_limit: 30_000_000n,
  block_base_fee: 20_000_000_000n,
  blob_base_fee: 1n,
  block_hashes: [],
};

// Initialize EVM
const evm = new Evm(null, Hardfork.CANCUN, blockContext);
evm.initTransactionState();

// Set transaction context
evm.origin = senderAddress;
evm.gasPrice = 20_000_000_000n;

// Pre-warm transaction
evm.preWarmTransaction(contractAddress);

// Create and execute frame
const frame = new Frame({
  bytecode: contractBytecode,
  gas: 1_000_000n,
  caller: senderAddress,
  address: contractAddress,
  value: 0n,
  calldata: encodedCalldata,
  evmPtr: evm,
  hardfork: Hardfork.CANCUN,
  isStatic: false,
});

try {
  frame.execute();

  console.log('Execution succeeded!');
  console.log('Gas used:', 1_000_000n - frame.gasRemaining);
  console.log('Output:', frame.output);
  console.log('Logs:', evm.logs);

} catch (error) {
  if (error instanceof EvmError) {
    console.error('EVM error:', error.callError);
    if (error.callError === CallError.Reverted) {
      console.error('Revert data:', frame.output);
    }
  } else {
    console.error('Unexpected error:', error);
  }
}
```
