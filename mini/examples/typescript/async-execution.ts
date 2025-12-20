/**
 * Example 2: Async Execution with External Storage Backend
 *
 * Demonstrates the async execution protocol for integrating with external state:
 * - Starting async execution with evm_call_ffi
 * - Handling storage/balance/code/nonce requests
 * - Resuming execution with evm_continue_ffi
 * - Processing state change commits
 * - Building a complete async execution loop
 *
 * This pattern is essential for integrating the EVM with:
 * - Database backends (PostgreSQL, LevelDB)
 * - Remote state providers (RPC nodes)
 * - Layer 2 solutions
 * - State channels
 */

import { readFileSync } from 'fs';
import { resolve } from 'path';

// Helper functions (same as basic-usage.ts)
async function loadWasm() {
  const wasmPath = resolve(__dirname, '../../zig-out/bin/guillotine_mini.wasm');
  const wasmBuffer = readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);

  const imports = {
    env: {
      js_opcode_callback: () => 0,
      js_precompile_callback: () => 0,
    }
  };

  const instance = await WebAssembly.instantiate(wasmModule, imports);
  return instance.exports;
}

function hexToAddress(hex: string): Uint8Array {
  const clean = hex.startsWith('0x') ? hex.slice(2) : hex;
  const padded = clean.padStart(40, '0');
  const bytes = new Uint8Array(20);
  for (let i = 0; i < 20; i++) {
    bytes[i] = parseInt(padded.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

function u256ToBytes(value: bigint): Uint8Array {
  const bytes = new Uint8Array(32);
  let v = value;
  for (let i = 31; i >= 0; i--) {
    bytes[i] = Number(v & 0xFFn);
    v >>= 8n;
  }
  return bytes;
}

function bytesToU256(bytes: Uint8Array): bigint {
  let value = 0n;
  for (let i = 0; i < 32; i++) {
    value = (value << 8n) | BigInt(bytes[i]);
  }
  return value;
}

function addressToHex(address: Uint8Array): string {
  return '0x' + Array.from(address).map(b => b.toString(16).padStart(2, '0')).join('');
}

/**
 * Request types from AsyncRequest C struct
 */
enum RequestType {
  RESULT = 0,           // Execution complete
  NEED_STORAGE = 1,     // Need storage value
  NEED_BALANCE = 2,     // Need balance
  NEED_CODE = 3,        // Need code
  NEED_NONCE = 4,       // Need nonce
  READY_TO_COMMIT = 5,  // Ready to commit state changes
  ERROR = 255           // Error occurred
}

/**
 * Mock external state backend
 * In production, this would query a database or RPC node
 */
class ExternalStateBackend {
  private storage = new Map<string, Map<string, bigint>>();
  private balances = new Map<string, bigint>();
  private codes = new Map<string, Uint8Array>();
  private nonces = new Map<string, bigint>();

  private requestCount = 0;

  private storageKey(address: Uint8Array, slot: bigint): string {
    return `${addressToHex(address)}:${slot.toString(16)}`;
  }

  async getStorage(address: Uint8Array, slot: bigint): Promise<bigint> {
    this.requestCount++;
    console.log(`  📡 [Request ${this.requestCount}] Storage read: ${addressToHex(address)} slot ${slot}`);

    // Simulate async database query
    await this.simulateLatency();

    const addrKey = addressToHex(address);
    const slotMap = this.storage.get(addrKey);
    if (!slotMap) {
      console.log(`     ↳ Value: 0 (uninitialized)`);
      return 0n;
    }
    const value = slotMap.get(slot.toString(16)) ?? 0n;
    console.log(`     ↳ Value: ${value}`);
    return value;
  }

  async getBalance(address: Uint8Array): Promise<bigint> {
    this.requestCount++;
    console.log(`  📡 [Request ${this.requestCount}] Balance read: ${addressToHex(address)}`);

    await this.simulateLatency();

    const balance = this.balances.get(addressToHex(address)) ?? 0n;
    console.log(`     ↳ Balance: ${balance} wei`);
    return balance;
  }

  async getCode(address: Uint8Array): Promise<Uint8Array> {
    this.requestCount++;
    console.log(`  📡 [Request ${this.requestCount}] Code read: ${addressToHex(address)}`);

    await this.simulateLatency();

    const code = this.codes.get(addressToHex(address)) ?? new Uint8Array(0);
    console.log(`     ↳ Code length: ${code.length} bytes`);
    return code;
  }

  async getNonce(address: Uint8Array): Promise<bigint> {
    this.requestCount++;
    console.log(`  📡 [Request ${this.requestCount}] Nonce read: ${addressToHex(address)}`);

    await this.simulateLatency();

    const nonce = this.nonces.get(addressToHex(address)) ?? 0n;
    console.log(`     ↳ Nonce: ${nonce}`);
    return nonce;
  }

  async commitStateChanges(changesJson: string): Promise<void> {
    console.log(`\n  💾 Committing state changes...`);
    console.log(`     JSON payload: ${changesJson.substring(0, 100)}${changesJson.length > 100 ? '...' : ''}`);

    await this.simulateLatency();

    // Parse and apply state changes
    try {
      const changes = JSON.parse(changesJson);
      // In production, this would write to database
      console.log(`     ✅ State changes committed`);
    } catch (e) {
      console.log(`     ⚠️  Warning: Could not parse state changes`);
    }
  }

  // Pre-populate state for testing
  setStorage(address: Uint8Array, slot: bigint, value: bigint): void {
    const addrKey = addressToHex(address);
    let slotMap = this.storage.get(addrKey);
    if (!slotMap) {
      slotMap = new Map();
      this.storage.set(addrKey, slotMap);
    }
    slotMap.set(slot.toString(16), value);
  }

  setBalance(address: Uint8Array, balance: bigint): void {
    this.balances.set(addressToHex(address), balance);
  }

  setCode(address: Uint8Array, code: Uint8Array): void {
    this.codes.set(addressToHex(address), code);
  }

  setNonce(address: Uint8Array, nonce: bigint): void {
    this.nonces.set(addressToHex(address), nonce);
  }

  resetRequestCount(): void {
    this.requestCount = 0;
  }

  private async simulateLatency(): Promise<void> {
    // Simulate 10-50ms database/network latency
    const delay = Math.random() * 40 + 10;
    await new Promise(resolve => setTimeout(resolve, delay));
  }
}

/**
 * Example 1: Simple Async Storage Access
 *
 * Bytecode loads a value from storage slot 0
 */
async function example1_asyncStorageLoad() {
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('Example 1: Async Storage Load');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  const wasm = await loadWasm();
  const backend = new ExternalStateBackend();

  // Pre-populate storage
  const contractAddress = hexToAddress('0x2000000000000000000000000000000000000002');
  backend.setStorage(contractAddress, 0n, 42n);

  const hardforkName = 'Cancun';
  const hardforkBytes = new TextEncoder().encode(hardforkName);
  const evmHandle = (wasm as any).evm_create(hardforkBytes, hardforkBytes.length, 0);

  if (!evmHandle) {
    throw new Error('Failed to create EVM instance');
  }

  try {
    // Enable async storage injector
    const injectorEnabled = (wasm as any).evm_enable_storage_injector(evmHandle);
    if (!injectorEnabled) {
      throw new Error('Failed to enable storage injector');
    }

    // Bytecode: SLOAD from slot 0, return result
    const bytecode = new Uint8Array([
      0x60, 0x00,       // PUSH1 0x00 (slot 0)
      0x54,             // SLOAD
      0x60, 0x00,       // PUSH1 0x00 (memory offset)
      0x52,             // MSTORE
      0x60, 0x20,       // PUSH1 0x20 (32 bytes)
      0x60, 0x00,       // PUSH1 0x00 (offset 0)
      0xf3              // RETURN
    ]);

    console.log('Bytecode: SLOAD slot 0, return result\n');
    console.log('Pre-populated storage: slot 0 = 42\n');

    // Set bytecode and context
    (wasm as any).evm_set_bytecode(evmHandle, bytecode, bytecode.length);

    const gas = 100000n;
    const caller = hexToAddress('0x1000000000000000000000000000000000000001');
    const address = contractAddress;
    const value = u256ToBytes(0n);
    const calldata = new Uint8Array(0);

    (wasm as any).evm_set_execution_context(
      evmHandle,
      Number(gas),
      caller,
      address,
      value,
      calldata,
      calldata.length
    );

    const chainId = u256ToBytes(1n);
    const blockNumber = 100n;
    const blockTimestamp = 1700000000n;
    const blockDifficulty = u256ToBytes(0n);
    const blockPrevrandao = u256ToBytes(0n);
    const blockCoinbase = hexToAddress('0x0000000000000000000000000000000000000000');
    const blockGasLimit = 30000000n;
    const blockBaseFee = u256ToBytes(1000000000n);
    const blobBaseFee = u256ToBytes(1n);

    (wasm as any).evm_set_blockchain_context(
      evmHandle,
      chainId,
      Number(blockNumber),
      Number(blockTimestamp),
      blockDifficulty,
      blockPrevrandao,
      blockCoinbase,
      Number(blockGasLimit),
      blockBaseFee,
      blobBaseFee
    );

    console.log('🚀 Starting async execution...\n');

    // Async execution loop
    let iterations = 0;
    const maxIterations = 100;

    // Allocate AsyncRequest struct in WASM memory
    const requestSize = 20 + 32 + 4 + 16384; // address + slot + json_len + json_data
    const requestPtr = (wasm as any).malloc?.(requestSize) ?? 0;

    // Start execution
    let continueExecution = (wasm as any).evm_call_ffi(evmHandle, requestPtr);

    while (continueExecution && iterations < maxIterations) {
      iterations++;

      // Read AsyncRequest struct
      const memory = new Uint8Array((wasm as any).memory.buffer);
      const outputType = memory[requestPtr];

      if (outputType === RequestType.RESULT) {
        console.log('\n✅ Execution complete!\n');
        break;
      }

      if (outputType === RequestType.NEED_STORAGE) {
        // Read address and slot
        const addressBytes = memory.slice(requestPtr + 1, requestPtr + 21);
        const slotBytes = memory.slice(requestPtr + 21, requestPtr + 53);
        const slot = bytesToU256(slotBytes);

        // Query backend
        const value = await backend.getStorage(addressBytes, slot);

        // Build response: address(20) + slot(32) + value(32) = 84 bytes
        const response = new Uint8Array(84);
        response.set(addressBytes, 0);
        response.set(slotBytes, 20);
        response.set(u256ToBytes(value), 52);

        // Continue with storage value
        continueExecution = (wasm as any).evm_continue_ffi(
          evmHandle,
          1, // continue_type: storage
          response,
          response.length,
          requestPtr
        );

      } else if (outputType === RequestType.NEED_BALANCE) {
        const addressBytes = memory.slice(requestPtr + 1, requestPtr + 21);
        const balance = await backend.getBalance(addressBytes);

        // Build response: address(20) + balance(32) = 52 bytes
        const response = new Uint8Array(52);
        response.set(addressBytes, 0);
        response.set(u256ToBytes(balance), 20);

        continueExecution = (wasm as any).evm_continue_ffi(
          evmHandle,
          2, // continue_type: balance
          response,
          response.length,
          requestPtr
        );

      } else if (outputType === RequestType.READY_TO_COMMIT) {
        const jsonLen = new DataView(memory.buffer).getUint32(requestPtr + 53, true);
        const jsonBytes = memory.slice(requestPtr + 57, requestPtr + 57 + jsonLen);
        const jsonStr = new TextDecoder().decode(jsonBytes);

        await backend.commitStateChanges(jsonStr);

        // Continue after commit
        continueExecution = (wasm as any).evm_continue_ffi(
          evmHandle,
          5, // continue_type: after_commit
          new Uint8Array(0),
          0,
          requestPtr
        );

      } else if (outputType === RequestType.ERROR) {
        console.error('❌ Async execution error');
        break;
      } else {
        console.error(`❌ Unknown request type: ${outputType}`);
        break;
      }
    }

    // Get output
    const outputLen = (wasm as any).evm_get_output_len(evmHandle);
    if (outputLen > 0) {
      const outputBuffer = new Uint8Array(outputLen);
      (wasm as any).evm_get_output(evmHandle, outputBuffer, outputLen);

      const result = bytesToU256(outputBuffer);
      console.log('📤 Output:', result.toString());
      console.log('✅ Expected: 42, Got:', result.toString(), result === 42n ? '✅' : '❌');
    }

    const gasUsed = (wasm as any).evm_get_gas_used(evmHandle);
    console.log(`\n⛽ Gas used: ${gasUsed}`);
    console.log(`🔄 Async iterations: ${iterations}\n`);

  } finally {
    (wasm as any).evm_destroy(evmHandle);
  }
}

/**
 * Example 2: Multiple Async Requests
 *
 * Bytecode performs multiple storage reads/writes
 */
async function example2_multipleAsyncRequests() {
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('Example 2: Multiple Async Storage Requests');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  const wasm = await loadWasm();
  const backend = new ExternalStateBackend();

  const contractAddress = hexToAddress('0x2000000000000000000000000000000000000002');

  // Pre-populate multiple storage slots
  backend.setStorage(contractAddress, 0n, 10n);
  backend.setStorage(contractAddress, 1n, 20n);
  backend.setStorage(contractAddress, 2n, 30n);

  const hardforkName = 'Cancun';
  const hardforkBytes = new TextEncoder().encode(hardforkName);
  const evmHandle = (wasm as any).evm_create(hardforkBytes, hardforkBytes.length, 0);

  if (!evmHandle) {
    throw new Error('Failed to create EVM instance');
  }

  try {
    (wasm as any).evm_enable_storage_injector(evmHandle);

    // Bytecode: Load slots 0, 1, 2, sum them, return result
    const bytecode = new Uint8Array([
      0x60, 0x00,       // PUSH1 0x00
      0x54,             // SLOAD (load slot 0 = 10)
      0x60, 0x01,       // PUSH1 0x01
      0x54,             // SLOAD (load slot 1 = 20)
      0x01,             // ADD (10 + 20 = 30)
      0x60, 0x02,       // PUSH1 0x02
      0x54,             // SLOAD (load slot 2 = 30)
      0x01,             // ADD (30 + 30 = 60)
      0x60, 0x00,       // PUSH1 0x00
      0x52,             // MSTORE
      0x60, 0x20,       // PUSH1 0x20
      0x60, 0x00,       // PUSH1 0x00
      0xf3              // RETURN
    ]);

    console.log('Bytecode: Load slots 0, 1, 2, sum them, return result\n');
    console.log('Pre-populated storage:');
    console.log('  - slot 0 = 10');
    console.log('  - slot 1 = 20');
    console.log('  - slot 2 = 30');
    console.log('Expected result: 10 + 20 + 30 = 60\n');

    (wasm as any).evm_set_bytecode(evmHandle, bytecode, bytecode.length);

    const gas = 100000n;
    const caller = hexToAddress('0x1000000000000000000000000000000000000001');
    const address = contractAddress;
    const value = u256ToBytes(0n);
    const calldata = new Uint8Array(0);

    (wasm as any).evm_set_execution_context(
      evmHandle,
      Number(gas),
      caller,
      address,
      value,
      calldata,
      calldata.length
    );

    const chainId = u256ToBytes(1n);
    const blockNumber = 100n;
    const blockTimestamp = 1700000000n;
    const blockDifficulty = u256ToBytes(0n);
    const blockPrevrandao = u256ToBytes(0n);
    const blockCoinbase = hexToAddress('0x0000000000000000000000000000000000000000');
    const blockGasLimit = 30000000n;
    const blockBaseFee = u256ToBytes(1000000000n);
    const blobBaseFee = u256ToBytes(1n);

    (wasm as any).evm_set_blockchain_context(
      evmHandle,
      chainId,
      Number(blockNumber),
      Number(blockTimestamp),
      blockDifficulty,
      blockPrevrandao,
      blockCoinbase,
      Number(blockGasLimit),
      blockBaseFee,
      blobBaseFee
    );

    console.log('🚀 Starting async execution...\n');

    backend.resetRequestCount();
    let iterations = 0;
    const maxIterations = 100;

    const requestSize = 20 + 32 + 4 + 16384;
    const requestPtr = (wasm as any).malloc?.(requestSize) ?? 0;

    let continueExecution = (wasm as any).evm_call_ffi(evmHandle, requestPtr);

    while (continueExecution && iterations < maxIterations) {
      iterations++;

      const memory = new Uint8Array((wasm as any).memory.buffer);
      const outputType = memory[requestPtr];

      if (outputType === RequestType.RESULT) {
        console.log('\n✅ Execution complete!\n');
        break;
      }

      if (outputType === RequestType.NEED_STORAGE) {
        const addressBytes = memory.slice(requestPtr + 1, requestPtr + 21);
        const slotBytes = memory.slice(requestPtr + 21, requestPtr + 53);
        const slot = bytesToU256(slotBytes);

        const value = await backend.getStorage(addressBytes, slot);

        const response = new Uint8Array(84);
        response.set(addressBytes, 0);
        response.set(slotBytes, 20);
        response.set(u256ToBytes(value), 52);

        continueExecution = (wasm as any).evm_continue_ffi(evmHandle, 1, response, response.length, requestPtr);

      } else if (outputType === RequestType.READY_TO_COMMIT) {
        const jsonLen = new DataView(memory.buffer).getUint32(requestPtr + 53, true);
        const jsonBytes = memory.slice(requestPtr + 57, requestPtr + 57 + jsonLen);
        const jsonStr = new TextDecoder().decode(jsonBytes);

        await backend.commitStateChanges(jsonStr);

        continueExecution = (wasm as any).evm_continue_ffi(evmHandle, 5, new Uint8Array(0), 0, requestPtr);

      } else if (outputType === RequestType.ERROR) {
        console.error('❌ Async execution error');
        break;
      }
    }

    const outputLen = (wasm as any).evm_get_output_len(evmHandle);
    if (outputLen > 0) {
      const outputBuffer = new Uint8Array(outputLen);
      (wasm as any).evm_get_output(evmHandle, outputBuffer, outputLen);

      const result = bytesToU256(outputBuffer);
      console.log('📤 Output:', result.toString());
      console.log('✅ Expected: 60, Got:', result.toString(), result === 60n ? '✅' : '❌');
    }

    const gasUsed = (wasm as any).evm_get_gas_used(evmHandle);
    console.log(`\n⛽ Gas used: ${gasUsed}`);
    console.log(`🔄 Async iterations: ${iterations}\n`);

  } finally {
    (wasm as any).evm_destroy(evmHandle);
  }
}

/**
 * Run all examples
 */
async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║     Guillotine Mini - Async Execution Examples           ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  try {
    await example1_asyncStorageLoad();
    await example2_multipleAsyncRequests();

    console.log('✅ All async examples completed successfully!');
  } catch (error) {
    console.error('❌ Error running examples:', error);
    process.exit(1);
  }
}

main();
