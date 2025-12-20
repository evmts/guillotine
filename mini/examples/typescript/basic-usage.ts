/**
 * Example 1: Basic EVM Usage
 *
 * Demonstrates fundamental EVM operations:
 * - Initializing the EVM
 * - Loading bytecode
 * - Executing simple operations
 * - Reading results from the stack
 * - Checking gas consumption
 */

// Import WASM module and wrapper types
import { readFileSync } from 'fs';
import { resolve } from 'path';

/**
 * Helper function to load the WASM module
 * Assumes the WASM file is in zig-out/bin/guillotine_mini.wasm
 */
async function loadWasm() {
  const wasmPath = resolve(__dirname, '../../zig-out/bin/guillotine_mini.wasm');
  const wasmBuffer = readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);

  const imports = {
    env: {
      // Stub implementations for optional JavaScript callbacks
      js_opcode_callback: () => 0,
      js_precompile_callback: () => 0,
    }
  };

  const instance = await WebAssembly.instantiate(wasmModule, imports);
  return instance.exports;
}

/**
 * Helper to convert hex string to address bytes (20 bytes)
 */
function hexToAddress(hex: string): Uint8Array {
  const clean = hex.startsWith('0x') ? hex.slice(2) : hex;
  const padded = clean.padStart(40, '0');
  const bytes = new Uint8Array(20);
  for (let i = 0; i < 20; i++) {
    bytes[i] = parseInt(padded.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

/**
 * Helper to convert u256 to 32-byte array (big-endian)
 */
function u256ToBytes(value: bigint): Uint8Array {
  const bytes = new Uint8Array(32);
  let v = value;
  for (let i = 31; i >= 0; i--) {
    bytes[i] = Number(v & 0xFFn);
    v >>= 8n;
  }
  return bytes;
}

/**
 * Helper to convert 32-byte array to u256 (big-endian)
 */
function bytesToU256(bytes: Uint8Array): bigint {
  let value = 0n;
  for (let i = 0; i < 32; i++) {
    value = (value << 8n) | BigInt(bytes[i]);
  }
  return value;
}

/**
 * Example 1: Simple Arithmetic
 *
 * Bytecode: PUSH1 0x02, PUSH1 0x03, ADD, STOP
 * Stack trace: [] -> [2] -> [2, 3] -> [5] -> []
 * Expected result: 5 (2 + 3)
 */
async function example1_simpleArithmetic() {
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('Example 1: Simple Arithmetic (2 + 3)');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  const wasm = await loadWasm();

  // Create EVM instance (Cancun hardfork, log level 0 = none)
  const hardforkName = 'Cancun';
  const hardforkBytes = new TextEncoder().encode(hardforkName);
  const evmHandle = (wasm as any).evm_create(
    hardforkBytes,
    hardforkBytes.length,
    0 // log level
  );

  if (!evmHandle) {
    throw new Error('Failed to create EVM instance');
  }

  try {
    // Bytecode: PUSH1 0x02, PUSH1 0x03, ADD, STOP
    // Opcodes: 0x60 (PUSH1), 0x01 (ADD), 0x00 (STOP)
    const bytecode = new Uint8Array([
      0x60, 0x02, // PUSH1 0x02
      0x60, 0x03, // PUSH1 0x03
      0x01,       // ADD
      0x00        // STOP
    ]);

    console.log('Bytecode:', Array.from(bytecode).map(b => '0x' + b.toString(16).padStart(2, '0')).join(' '));
    console.log('Operation: 2 + 3\n');

    // Set bytecode
    const bytecodeSet = (wasm as any).evm_set_bytecode(evmHandle, bytecode, bytecode.length);
    if (!bytecodeSet) {
      throw new Error('Failed to set bytecode');
    }

    // Set execution context
    const gas = 100000n;
    const caller = hexToAddress('0x1000000000000000000000000000000000000001');
    const address = hexToAddress('0x2000000000000000000000000000000000000002');
    const value = u256ToBytes(0n);
    const calldata = new Uint8Array(0);

    const contextSet = (wasm as any).evm_set_execution_context(
      evmHandle,
      Number(gas),
      caller,
      address,
      value,
      calldata,
      calldata.length
    );

    if (!contextSet) {
      throw new Error('Failed to set execution context');
    }

    // Set blockchain context
    const chainId = u256ToBytes(1n);
    const blockNumber = 100n;
    const blockTimestamp = 1700000000n;
    const blockDifficulty = u256ToBytes(0n);
    const blockPrevrandao = u256ToBytes(0n);
    const blockCoinbase = hexToAddress('0x0000000000000000000000000000000000000000');
    const blockGasLimit = 30000000n;
    const blockBaseFee = u256ToBytes(1000000000n); // 1 gwei
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

    // Execute
    const success = (wasm as any).evm_execute(evmHandle);

    console.log('✅ Execution:', success ? 'SUCCESS' : 'FAILED');

    // Get gas metrics
    const gasRemaining = (wasm as any).evm_get_gas_remaining(evmHandle);
    const gasUsed = (wasm as any).evm_get_gas_used(evmHandle);

    console.log(`⛽ Gas used: ${gasUsed} / ${gas}`);
    console.log(`⛽ Gas remaining: ${gasRemaining}\n`);

    // Get output (if any)
    const outputLen = (wasm as any).evm_get_output_len(evmHandle);
    if (outputLen > 0) {
      const outputBuffer = new Uint8Array(outputLen);
      (wasm as any).evm_get_output(evmHandle, outputBuffer, outputLen);
      console.log('📤 Output:', Array.from(outputBuffer).map(b => '0x' + b.toString(16).padStart(2, '0')).join(''));
    } else {
      console.log('📤 Output: (empty - result on stack)');
    }

    console.log('\n💡 Note: Result (5) remains on stack. Use RETURN to output it.\n');

  } finally {
    // Clean up
    (wasm as any).evm_destroy(evmHandle);
  }
}

/**
 * Example 2: Return Value
 *
 * Bytecode: PUSH1 0x02, PUSH1 0x03, ADD, PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
 * Stores result in memory and returns it
 */
async function example2_returnValue() {
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('Example 2: Return Value from Execution');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  const wasm = await loadWasm();

  const hardforkName = 'Cancun';
  const hardforkBytes = new TextEncoder().encode(hardforkName);
  const evmHandle = (wasm as any).evm_create(hardforkBytes, hardforkBytes.length, 0);

  if (!evmHandle) {
    throw new Error('Failed to create EVM instance');
  }

  try {
    // Bytecode: Compute 2 + 3, store in memory, return 32 bytes
    const bytecode = new Uint8Array([
      0x60, 0x02,       // PUSH1 0x02
      0x60, 0x03,       // PUSH1 0x03
      0x01,             // ADD (result: 5)
      0x60, 0x00,       // PUSH1 0x00 (memory offset)
      0x52,             // MSTORE (store 5 at memory[0:32])
      0x60, 0x20,       // PUSH1 0x20 (32 bytes)
      0x60, 0x00,       // PUSH1 0x00 (offset 0)
      0xf3              // RETURN (return memory[0:32])
    ]);

    console.log('Bytecode:', Array.from(bytecode).map(b => '0x' + b.toString(16).padStart(2, '0')).join(' '));
    console.log('Operation: Compute 2 + 3, store in memory, return result\n');

    // Set bytecode and context (same as example 1)
    (wasm as any).evm_set_bytecode(evmHandle, bytecode, bytecode.length);

    const gas = 100000n;
    const caller = hexToAddress('0x1000000000000000000000000000000000000001');
    const address = hexToAddress('0x2000000000000000000000000000000000000002');
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

    // Execute
    const success = (wasm as any).evm_execute(evmHandle);

    console.log('✅ Execution:', success ? 'SUCCESS' : 'FAILED');

    const gasUsed = (wasm as any).evm_get_gas_used(evmHandle);
    const gasRemaining = (wasm as any).evm_get_gas_remaining(evmHandle);

    console.log(`⛽ Gas used: ${gasUsed}`);
    console.log(`⛽ Gas remaining: ${gasRemaining}\n`);

    // Get output
    const outputLen = (wasm as any).evm_get_output_len(evmHandle);
    if (outputLen > 0) {
      const outputBuffer = new Uint8Array(outputLen);
      (wasm as any).evm_get_output(evmHandle, outputBuffer, outputLen);

      // Decode as u256
      const result = bytesToU256(outputBuffer);
      console.log('📤 Output (raw):', Array.from(outputBuffer).map(b => '0x' + b.toString(16).padStart(2, '0')).join(''));
      console.log('📤 Output (decoded):', result.toString());
      console.log('\n✅ Expected: 5, Got:', result.toString(), result === 5n ? '✅' : '❌');
    }

    console.log('');

  } finally {
    (wasm as any).evm_destroy(evmHandle);
  }
}

/**
 * Example 3: Storage Operations
 *
 * Demonstrates SSTORE and SLOAD opcodes
 */
async function example3_storageOperations() {
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('Example 3: Storage Operations (SSTORE/SLOAD)');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  const wasm = await loadWasm();

  const hardforkName = 'Cancun';
  const hardforkBytes = new TextEncoder().encode(hardforkName);
  const evmHandle = (wasm as any).evm_create(hardforkBytes, hardforkBytes.length, 0);

  if (!evmHandle) {
    throw new Error('Failed to create EVM instance');
  }

  try {
    // Bytecode: Store 42 at slot 0, then load it back
    const bytecode = new Uint8Array([
      0x60, 0x2a,       // PUSH1 0x2a (42 in decimal)
      0x60, 0x00,       // PUSH1 0x00 (slot 0)
      0x55,             // SSTORE (store 42 at slot 0)
      0x60, 0x00,       // PUSH1 0x00 (slot 0)
      0x54,             // SLOAD (load from slot 0)
      0x60, 0x00,       // PUSH1 0x00 (memory offset)
      0x52,             // MSTORE (store result in memory)
      0x60, 0x20,       // PUSH1 0x20 (32 bytes)
      0x60, 0x00,       // PUSH1 0x00 (offset 0)
      0xf3              // RETURN
    ]);

    console.log('Bytecode: SSTORE 42 at slot 0, SLOAD from slot 0, return result\n');

    (wasm as any).evm_set_bytecode(evmHandle, bytecode, bytecode.length);

    const gas = 100000n;
    const caller = hexToAddress('0x1000000000000000000000000000000000000001');
    const address = hexToAddress('0x2000000000000000000000000000000000000002');
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

    // Execute
    const success = (wasm as any).evm_execute(evmHandle);

    console.log('✅ Execution:', success ? 'SUCCESS' : 'FAILED');

    const gasUsed = (wasm as any).evm_get_gas_used(evmHandle);
    const gasRemaining = (wasm as any).evm_get_gas_remaining(evmHandle);

    console.log(`⛽ Gas used: ${gasUsed}`);
    console.log(`⛽ Gas remaining: ${gasRemaining}`);

    // Get gas refund (SSTORE can generate refunds)
    const gasRefund = (wasm as any).evm_get_gas_refund(evmHandle);
    console.log(`💰 Gas refund: ${gasRefund}\n`);

    // Get output
    const outputLen = (wasm as any).evm_get_output_len(evmHandle);
    if (outputLen > 0) {
      const outputBuffer = new Uint8Array(outputLen);
      (wasm as any).evm_get_output(evmHandle, outputBuffer, outputLen);

      const result = bytesToU256(outputBuffer);
      console.log('📤 Output (decoded):', result.toString());
      console.log('✅ Expected: 42, Got:', result.toString(), result === 42n ? '✅' : '❌');
    }

    // Check storage changes
    const storageChangeCount = (wasm as any).evm_get_storage_change_count(evmHandle);
    console.log(`\n📦 Storage changes: ${storageChangeCount}`);

    for (let i = 0; i < storageChangeCount; i++) {
      const addressOut = new Uint8Array(20);
      const slotOut = new Uint8Array(32);
      const valueOut = new Uint8Array(32);

      const ok = (wasm as any).evm_get_storage_change(evmHandle, i, addressOut, slotOut, valueOut);
      if (ok) {
        const slot = bytesToU256(slotOut);
        const value = bytesToU256(valueOut);
        console.log(`  - Slot ${slot}: ${value}`);
      }
    }

    console.log('');

  } finally {
    (wasm as any).evm_destroy(evmHandle);
  }
}

/**
 * Run all examples
 */
async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║  Guillotine Mini - TypeScript/WASM Basic Usage Examples  ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  try {
    await example1_simpleArithmetic();
    await example2_returnValue();
    await example3_storageOperations();

    console.log('✅ All examples completed successfully!');
  } catch (error) {
    console.error('❌ Error running examples:', error);
    process.exit(1);
  }
}

// Run examples
main();
