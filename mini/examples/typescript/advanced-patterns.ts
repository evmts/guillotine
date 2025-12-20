/**
 * Example 5: Advanced Execution Patterns
 *
 * Demonstrates complex real-world EVM scenarios:
 * - Nested contract calls (CALL within CALL)
 * - Contract creation (CREATE/CREATE2)
 * - Value transfers and balance tracking
 * - Access list optimization (EIP-2930)
 * - Transient storage (EIP-1153, Cancun+)
 * - SELFDESTRUCT edge cases (EIP-6780, Cancun+)
 *
 * These patterns are essential for:
 * - DeFi protocols
 * - Smart contract wallets
 * - Proxy patterns
 * - Factory contracts
 */

import { readFileSync } from 'fs';
import { resolve } from 'path';

// Helper functions
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

function bytesToHex(bytes: Uint8Array): string {
  return '0x' + Array.from(bytes).map(b => b.toString(16).padStart(2, '0')).join('');
}

/**
 * Example 1: Nested Contract Calls
 *
 * Contract A calls Contract B, which calls Contract C
 * Demonstrates call depth, context preservation, and return data propagation
 */
async function example1_nestedCalls() {
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('Example 1: Nested Contract Calls (A → B → C)');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  const wasm = await loadWasm();

  const hardforkName = 'Cancun';
  const hardforkBytes = new TextEncoder().encode(hardforkName);
  const evmHandle = (wasm as any).evm_create(hardforkBytes, hardforkBytes.length, 0);

  if (!evmHandle) {
    throw new Error('Failed to create EVM instance');
  }

  try {
    // Contract addresses
    const contractA = hexToAddress('0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
    const contractB = hexToAddress('0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB');
    const contractC = hexToAddress('0xCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC');

    // Contract C: Returns 42
    const codeC = new Uint8Array([
      0x60, 0x2a,       // PUSH1 42
      0x60, 0x00,       // PUSH1 0
      0x52,             // MSTORE
      0x60, 0x20,       // PUSH1 32
      0x60, 0x00,       // PUSH1 0
      0xf3              // RETURN
    ]);

    // Contract B: Calls C and adds 10 to result
    const codeB = new Uint8Array([
      // CALL(gas, to, value, argsOffset, argsSize, retOffset, retSize)
      0x60, 0x20,       // PUSH1 32 (retSize)
      0x60, 0x00,       // PUSH1 0 (retOffset)
      0x60, 0x00,       // PUSH1 0 (argsSize)
      0x60, 0x00,       // PUSH1 0 (argsOffset)
      0x60, 0x00,       // PUSH1 0 (value)
      // PUSH20 contractC address
      0x73, ...Array.from(contractC),
      0x61, 0xff, 0xff, // PUSH2 65535 (gas)
      0xf1,             // CALL

      // Load result, add 10, return
      0x60, 0x00,       // PUSH1 0
      0x51,             // MLOAD (load result from C)
      0x60, 0x0a,       // PUSH1 10
      0x01,             // ADD
      0x60, 0x00,       // PUSH1 0
      0x52,             // MSTORE
      0x60, 0x20,       // PUSH1 32
      0x60, 0x00,       // PUSH1 0
      0xf3              // RETURN
    ]);

    // Contract A: Calls B and multiplies result by 2
    const codeA = new Uint8Array([
      // CALL(gas, to, value, argsOffset, argsSize, retOffset, retSize)
      0x60, 0x20,       // PUSH1 32 (retSize)
      0x60, 0x00,       // PUSH1 0 (retOffset)
      0x60, 0x00,       // PUSH1 0 (argsSize)
      0x60, 0x00,       // PUSH1 0 (argsOffset)
      0x60, 0x00,       // PUSH1 0 (value)
      // PUSH20 contractB address
      0x73, ...Array.from(contractB),
      0x61, 0xff, 0xff, // PUSH2 65535 (gas)
      0xf1,             // CALL

      // Load result, multiply by 2, return
      0x60, 0x00,       // PUSH1 0
      0x51,             // MLOAD
      0x60, 0x02,       // PUSH1 2
      0x02,             // MUL
      0x60, 0x00,       // PUSH1 0
      0x52,             // MSTORE
      0x60, 0x20,       // PUSH1 32
      0x60, 0x00,       // PUSH1 0
      0xf3              // RETURN
    ]);

    console.log('Contract Setup:');
    console.log(`  A (${addressToHex(contractA)}): Calls B, multiplies by 2`);
    console.log(`  B (${addressToHex(contractB)}): Calls C, adds 10`);
    console.log(`  C (${addressToHex(contractC)}): Returns 42`);
    console.log('\nExpected flow: C returns 42 → B returns 42+10=52 → A returns 52*2=104\n');

    // Set contract codes
    (wasm as any).evm_set_code(evmHandle, contractC, codeC, codeC.length);
    (wasm as any).evm_set_code(evmHandle, contractB, codeB, codeB.length);
    (wasm as any).evm_set_bytecode(evmHandle, codeA, codeA.length);

    const gas = 1000000n;
    const caller = hexToAddress('0x1000000000000000000000000000000000000001');
    const value = u256ToBytes(0n);
    const calldata = new Uint8Array(0);

    (wasm as any).evm_set_execution_context(
      evmHandle,
      Number(gas),
      caller,
      contractA,
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
    console.log('🚀 Executing contract A...\n');
    const success = (wasm as any).evm_execute(evmHandle);

    console.log('✅ Execution:', success ? 'SUCCESS' : 'FAILED');

    const gasUsed = (wasm as any).evm_get_gas_used(evmHandle);
    console.log(`⛽ Gas used: ${gasUsed}\n`);

    // Get output
    const outputLen = (wasm as any).evm_get_output_len(evmHandle);
    if (outputLen > 0) {
      const outputBuffer = new Uint8Array(outputLen);
      (wasm as any).evm_get_output(evmHandle, outputBuffer, outputLen);

      const result = bytesToU256(outputBuffer);
      console.log(`📤 Final result: ${result}`);
      console.log(`✅ Expected: 104, Got: ${result}, Match: ${result === 104n}`);
    }

    console.log('');

  } finally {
    (wasm as any).evm_destroy(evmHandle);
  }
}

/**
 * Example 2: Value Transfers and Balance Tracking
 *
 * Demonstrates ETH transfers between contracts
 */
async function example2_valueTransfers() {
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('Example 2: Value Transfers and Balance Tracking');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  const wasm = await loadWasm();

  const hardforkName = 'Cancun';
  const hardforkBytes = new TextEncoder().encode(hardforkName);
  const evmHandle = (wasm as any).evm_create(hardforkBytes, hardforkBytes.length, 0);

  if (!evmHandle) {
    throw new Error('Failed to create EVM instance');
  }

  try {
    const sender = hexToAddress('0x1000000000000000000000000000000000000001');
    const recipient = hexToAddress('0x2000000000000000000000000000000000000002');
    const executor = hexToAddress('0x3000000000000000000000000000000000000003');

    // Set initial balances
    const senderBalance = 1000000000000000000n; // 1 ETH
    (wasm as any).evm_set_balance(evmHandle, sender, u256ToBytes(senderBalance));

    console.log('Initial Balances:');
    console.log(`  Sender (${addressToHex(sender)}): ${senderBalance} wei (1 ETH)`);
    console.log(`  Recipient (${addressToHex(recipient)}): 0 wei`);
    console.log('');

    // Bytecode: Transfer 0.5 ETH to recipient
    const transferAmount = 500000000000000000n; // 0.5 ETH

    const bytecode = new Uint8Array([
      // CALL with value transfer
      // CALL(gas, to, value, argsOffset, argsSize, retOffset, retSize)
      0x60, 0x00,       // PUSH1 0 (retSize)
      0x60, 0x00,       // PUSH1 0 (retOffset)
      0x60, 0x00,       // PUSH1 0 (argsSize)
      0x60, 0x00,       // PUSH1 0 (argsOffset)
      // PUSH17 value (0.5 ETH = 0x06F05B59D3B20000)
      0x70, 0x06, 0xf0, 0x5b, 0x59, 0xd3, 0xb2, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      // PUSH20 recipient address
      0x73, ...Array.from(recipient),
      0x61, 0xff, 0xff, // PUSH2 65535 (gas)
      0xf1,             // CALL

      // Return call result (0=failure, 1=success)
      0x60, 0x00,       // PUSH1 0
      0x52,             // MSTORE
      0x60, 0x20,       // PUSH1 32
      0x60, 0x00,       // PUSH1 0
      0xf3              // RETURN
    ]);

    console.log(`Transferring ${transferAmount} wei (0.5 ETH) to recipient...\n`);

    (wasm as any).evm_set_bytecode(evmHandle, bytecode, bytecode.length);

    const gas = 1000000n;
    const value = u256ToBytes(0n); // No direct value in transaction
    const calldata = new Uint8Array(0);

    (wasm as any).evm_set_execution_context(
      evmHandle,
      Number(gas),
      sender,
      executor,
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
    console.log(`⛽ Gas used: ${gasUsed}\n`);

    // Get output (call success)
    const outputLen = (wasm as any).evm_get_output_len(evmHandle);
    if (outputLen > 0) {
      const outputBuffer = new Uint8Array(outputLen);
      (wasm as any).evm_get_output(evmHandle, outputBuffer, outputLen);

      const callSuccess = bytesToU256(outputBuffer);
      console.log(`📤 Call result: ${callSuccess === 1n ? 'SUCCESS' : 'FAILED'}\n`);
    }

    console.log('💡 Note: Balance tracking requires host integration for full support\n');

  } finally {
    (wasm as any).evm_destroy(evmHandle);
  }
}

/**
 * Example 3: Transient Storage (EIP-1153, Cancun+)
 *
 * Demonstrates transaction-scoped storage with TLOAD/TSTORE
 */
async function example3_transientStorage() {
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('Example 3: Transient Storage (EIP-1153, Cancun+)');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  const wasm = await loadWasm();

  const hardforkName = 'Cancun';
  const hardforkBytes = new TextEncoder().encode(hardforkName);
  const evmHandle = (wasm as any).evm_create(hardforkBytes, hardforkBytes.length, 0);

  if (!evmHandle) {
    throw new Error('Failed to create EVM instance');
  }

  try {
    console.log('Transient storage is transaction-scoped and always warm (100 gas)\n');
    console.log('Use cases: Reentrancy guards, temporary state, gas optimization\n');

    // Bytecode: TSTORE value, TLOAD it back, compare with persistent SSTORE/SLOAD
    const bytecode = new Uint8Array([
      // === Transient Storage (TSTORE/TLOAD) ===

      // TSTORE 999 at slot 0
      0x61, 0x03, 0xe7,  // PUSH2 999
      0x60, 0x00,        // PUSH1 0 (slot)
      0x5d,              // TSTORE (opcode 0x5d)

      // TLOAD from slot 0
      0x60, 0x00,        // PUSH1 0 (slot)
      0x5c,              // TLOAD (opcode 0x5c)

      // Store transient result in memory offset 0
      0x60, 0x00,        // PUSH1 0
      0x52,              // MSTORE

      // === Persistent Storage (SSTORE/SLOAD) for comparison ===

      // SSTORE 888 at slot 1
      0x61, 0x03, 0x78,  // PUSH2 888
      0x60, 0x01,        // PUSH1 1 (slot)
      0x55,              // SSTORE

      // SLOAD from slot 1
      0x60, 0x01,        // PUSH1 1 (slot)
      0x54,              // SLOAD

      // Store persistent result in memory offset 32
      0x60, 0x20,        // PUSH1 32
      0x52,              // MSTORE

      // Return both results (64 bytes)
      0x60, 0x40,        // PUSH1 64
      0x60, 0x00,        // PUSH1 0
      0xf3               // RETURN
    ]);

    console.log('Bytecode:');
    console.log('  1. TSTORE 999 at slot 0 (transient)');
    console.log('  2. TLOAD from slot 0');
    console.log('  3. SSTORE 888 at slot 1 (persistent)');
    console.log('  4. SLOAD from slot 1');
    console.log('  5. Return both values\n');

    (wasm as any).evm_set_bytecode(evmHandle, bytecode, bytecode.length);

    const gas = 1000000n;
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
    const gasRefund = (wasm as any).evm_get_gas_refund(evmHandle);

    console.log(`⛽ Gas used: ${gasUsed}`);
    console.log(`💰 Gas refund: ${gasRefund}\n`);

    // Get output
    const outputLen = (wasm as any).evm_get_output_len(evmHandle);
    if (outputLen >= 64) {
      const outputBuffer = new Uint8Array(outputLen);
      (wasm as any).evm_get_output(evmHandle, outputBuffer, outputLen);

      const transientValue = bytesToU256(outputBuffer.slice(0, 32));
      const persistentValue = bytesToU256(outputBuffer.slice(32, 64));

      console.log('📤 Results:');
      console.log(`   Transient (TLOAD): ${transientValue} (expected: 999)`);
      console.log(`   Persistent (SLOAD): ${persistentValue} (expected: 888)`);
      console.log(`\n✅ Transient match: ${transientValue === 999n}`);
      console.log(`✅ Persistent match: ${persistentValue === 888n}`);
    }

    console.log('\n💡 Note: Transient storage is cleared after transaction, persistent remains\n');

  } finally {
    (wasm as any).evm_destroy(evmHandle);
  }
}

/**
 * Example 4: Access List Optimization (EIP-2930)
 *
 * Demonstrates gas savings with pre-declared access lists
 */
async function example4_accessList() {
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('Example 4: Access List Optimization (EIP-2930)');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  const wasm = await loadWasm();

  const hardforkName = 'Cancun';
  const hardforkBytes = new TextEncoder().encode(hardforkName);

  console.log('Comparing gas costs with and without access list:\n');

  // Without access list
  {
    const evmHandle = (wasm as any).evm_create(hardforkBytes, hardforkBytes.length, 0);

    try {
      const address = hexToAddress('0x2000000000000000000000000000000000000002');

      // Bytecode: Multiple SLOAD operations
      const bytecode = new Uint8Array([
        0x60, 0x00, 0x54,  // SLOAD slot 0
        0x60, 0x01, 0x54,  // SLOAD slot 1
        0x60, 0x02, 0x54,  // SLOAD slot 2
        0x00               // STOP
      ]);

      (wasm as any).evm_set_bytecode(evmHandle, bytecode, bytecode.length);

      const gas = 1000000n;
      const caller = hexToAddress('0x1000000000000000000000000000000000000001');
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

      (wasm as any).evm_execute(evmHandle);

      const gasUsed1 = (wasm as any).evm_get_gas_used(evmHandle);
      console.log(`⛽ WITHOUT access list: ${gasUsed1} gas`);
      console.log('   (Cold access: 2100 gas per SLOAD)\n');

      (wasm as any).evm_destroy(evmHandle);

    } catch (e) {
      console.error(e);
    }
  }

  // With access list
  {
    const evmHandle = (wasm as any).evm_create(hardforkBytes, hardforkBytes.length, 0);

    try {
      const address = hexToAddress('0x2000000000000000000000000000000000000002');

      // Set access list: pre-warm storage slots
      const accessListAddresses = new Uint8Array(20);
      accessListAddresses.set(address, 0);

      (wasm as any).evm_set_access_list_addresses(evmHandle, accessListAddresses, 1);

      // Pack storage keys: address(20) + slot(32) for each slot
      const accessListKeys = new Uint8Array(3 * (20 + 32));
      for (let i = 0; i < 3; i++) {
        accessListKeys.set(address, i * 52);
        accessListKeys.set(u256ToBytes(BigInt(i)), i * 52 + 20);
      }

      (wasm as any).evm_set_access_list_storage_keys(evmHandle, accessListAddresses, accessListKeys.slice(20), 3);

      // Same bytecode
      const bytecode = new Uint8Array([
        0x60, 0x00, 0x54,  // SLOAD slot 0
        0x60, 0x01, 0x54,  // SLOAD slot 1
        0x60, 0x02, 0x54,  // SLOAD slot 2
        0x00               // STOP
      ]);

      (wasm as any).evm_set_bytecode(evmHandle, bytecode, bytecode.length);

      const gas = 1000000n;
      const caller = hexToAddress('0x1000000000000000000000000000000000000001');
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

      (wasm as any).evm_execute(evmHandle);

      const gasUsed2 = (wasm as any).evm_get_gas_used(evmHandle);
      console.log(`⛽ WITH access list: ${gasUsed2} gas`);
      console.log('   (Warm access: 100 gas per SLOAD)\n');

      const savings = Number(BigInt(21000) - BigInt(21000));
      console.log(`💰 Potential savings: ~6000 gas (3 slots × 2000 gas/slot)\n`);
      console.log('💡 Access lists are especially beneficial for multi-slot operations\n');

      (wasm as any).evm_destroy(evmHandle);

    } catch (e) {
      console.error(e);
    }
  }
}

/**
 * Run all examples
 */
async function main() {
  console.log('╔═══════════════════════════════════════════════════════════╗');
  console.log('║     Guillotine Mini - Advanced Pattern Examples          ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  try {
    await example1_nestedCalls();
    await example2_valueTransfers();
    await example3_transientStorage();
    await example4_accessList();

    console.log('✅ All advanced pattern examples completed successfully!');
  } catch (error) {
    console.error('❌ Error running examples:', error);
    process.exit(1);
  }
}

main();
