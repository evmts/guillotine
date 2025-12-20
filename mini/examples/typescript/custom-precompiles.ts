/**
 * Example 4: Custom Precompiles
 *
 * Demonstrates extending the EVM with custom precompiled contracts:
 * - Registering custom precompile handlers via JavaScript callbacks
 * - Calling precompiles from bytecode
 * - Handling gas metering for custom operations
 * - Building domain-specific EVM extensions
 *
 * This pattern enables:
 * - Layer 2 solutions with custom opcodes
 * - Rollups with specialized cryptography
 * - Private chains with custom functionality
 * - Testing and development environments
 */

import { readFileSync } from 'fs';
import { resolve } from 'path';

// Helper functions
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
 * Custom Precompile Registry
 * Maps addresses to handler functions
 */
interface PrecompileHandler {
  (input: Uint8Array, gasLimit: bigint): {
    success: boolean;
    output: Uint8Array;
    gasUsed: bigint;
  };
}

class PrecompileRegistry {
  private handlers = new Map<string, PrecompileHandler>();

  register(address: string, handler: PrecompileHandler): void {
    this.handlers.set(address.toLowerCase(), handler);
    console.log(`✅ Registered custom precompile at ${address}`);
  }

  handle(address: Uint8Array, input: Uint8Array, gasLimit: bigint): {
    success: boolean;
    output: Uint8Array;
    gasUsed: bigint;
  } | null {
    const addrHex = addressToHex(address).toLowerCase();
    const handler = this.handlers.get(addrHex);

    if (!handler) {
      return null; // Not handled by custom precompiles
    }

    console.log(`\n🔧 Custom precompile invoked: ${addrHex}`);
    console.log(`   Input: ${bytesToHex(input)}`);
    console.log(`   Gas limit: ${gasLimit}`);

    const result = handler(input, gasLimit);

    console.log(`   Output: ${bytesToHex(result.output)}`);
    console.log(`   Gas used: ${result.gasUsed}`);
    console.log(`   Success: ${result.success}`);

    return result;
  }
}

/**
 * Load WASM with custom precompile callback
 */
async function loadWasmWithPrecompiles(registry: PrecompileRegistry) {
  const wasmPath = resolve(__dirname, '../../zig-out/bin/guillotine_mini.wasm');
  const wasmBuffer = readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);

  const imports = {
    env: {
      js_opcode_callback: () => 0,

      /**
       * JavaScript precompile callback
       * Called by WASM when a CALL targets a precompile address
       *
       * Parameters:
       * - address_ptr: pointer to 20-byte address
       * - input_ptr: pointer to input data
       * - input_len: length of input data
       * - gas_limit: available gas
       * - output_len: pointer to write output length
       * - output_ptr: pointer to write output data pointer
       * - gas_used: pointer to write gas used
       *
       * Returns: 1 if handled, 0 if not handled (use default)
       */
      js_precompile_callback: (
        address_ptr: number,
        input_ptr: number,
        input_len: number,
        gas_limit: number,
        output_len_ptr: number,
        output_ptr_ptr: number,
        gas_used_ptr: number
      ): number => {
        try {
          const memory = new Uint8Array((instance.exports as any).memory.buffer);

          // Read address
          const address = memory.slice(address_ptr, address_ptr + 20);

          // Read input
          const input = memory.slice(input_ptr, input_ptr + input_len);

          // Try to handle
          const result = registry.handle(address, input, BigInt(gas_limit));

          if (!result) {
            return 0; // Not handled, use default precompiles
          }

          if (!result.success) {
            return 0; // Failed, let EVM handle error
          }

          // Allocate output buffer in WASM memory
          const outputPtr = (instance.exports as any).malloc?.(result.output.length) ?? 0;
          if (outputPtr === 0 && result.output.length > 0) {
            console.error('Failed to allocate output buffer');
            return 0;
          }

          // Write output data
          const outputMemory = new Uint8Array((instance.exports as any).memory.buffer);
          outputMemory.set(result.output, outputPtr);

          // Write output metadata
          const metadata = new DataView((instance.exports as any).memory.buffer);
          metadata.setUint32(output_len_ptr, result.output.length, true);
          metadata.setUint32(output_ptr_ptr, outputPtr, true);
          metadata.setBigUint64(gas_used_ptr, result.gasUsed, true);

          return 1; // Handled successfully
        } catch (e) {
          console.error('Error in precompile callback:', e);
          return 0;
        }
      },
    }
  };

  const instance = await WebAssembly.instantiate(wasmModule, imports);
  return instance.exports;
}

/**
 * Example 1: Simple Custom Precompile (String Reverser)
 *
 * Address: 0x0000000000000000000000000000000000001000
 * Input: UTF-8 string bytes
 * Output: Reversed UTF-8 string bytes
 * Gas: 100 + 10 per byte
 */
async function example1_stringReverser() {
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('Example 1: Custom Precompile - String Reverser');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  const registry = new PrecompileRegistry();

  // Register string reverser at address 0x1000
  registry.register('0x0000000000000000000000000000000000001000', (input, gasLimit) => {
    const gasCost = 100n + BigInt(input.length) * 10n;

    if (gasCost > gasLimit) {
      return {
        success: false,
        output: new Uint8Array(0),
        gasUsed: gasLimit, // Consume all gas on failure
      };
    }

    // Reverse the bytes
    const output = new Uint8Array(input.length);
    for (let i = 0; i < input.length; i++) {
      output[i] = input[input.length - 1 - i];
    }

    return {
      success: true,
      output,
      gasUsed: gasCost,
    };
  });

  const wasm = await loadWasmWithPrecompiles(registry);

  const hardforkName = 'Cancun';
  const hardforkBytes = new TextEncoder().encode(hardforkName);
  const evmHandle = (wasm as any).evm_create(hardforkBytes, hardforkBytes.length, 0);

  if (!evmHandle) {
    throw new Error('Failed to create EVM instance');
  }

  try {
    // Store "Hello World!" in memory and call precompile
    const inputText = "Hello World!";
    const inputBytes = new TextEncoder().encode(inputText);

    // Bytecode:
    // 1. Store input in memory
    // 2. CALL precompile at 0x1000
    // 3. Return output
    const bytecode = new Uint8Array([
      // Store "Hello World!" in memory at offset 0
      // PUSH32 "Hello World!" (padded)
      0x7f, ...Array.from(inputBytes), ...new Array(32 - inputBytes.length).fill(0),
      0x60, 0x00,       // PUSH1 0 (offset)
      0x52,             // MSTORE

      // CALL(gas, to, value, argsOffset, argsSize, retOffset, retSize)
      0x60, 0x20,       // PUSH1 32 (retSize - max output)
      0x60, 0x20,       // PUSH1 32 (retOffset)
      0x60, 0x0c,       // PUSH1 12 (argsSize - "Hello World!" length)
      0x60, 0x00,       // PUSH1 0 (argsOffset)
      0x60, 0x00,       // PUSH1 0 (value)
      0x61, 0x10, 0x00, // PUSH2 0x1000 (precompile address)
      0x61, 0xff, 0xff, // PUSH2 65535 (gas for call)
      0xf1,             // CALL

      // Return the output (32 bytes from offset 32)
      0x60, 0x20,       // PUSH1 32 (length)
      0x60, 0x20,       // PUSH1 32 (offset)
      0xf3              // RETURN
    ]);

    console.log(`Input: "${inputText}"`);
    console.log(`Expected output: "${inputText.split('').reverse().join('')}"\n`);

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
    console.log('🚀 Executing bytecode...\n');
    const success = (wasm as any).evm_execute(evmHandle);

    console.log('\n✅ Execution:', success ? 'SUCCESS' : 'FAILED');

    const gasUsed = (wasm as any).evm_get_gas_used(evmHandle);
    console.log(`⛽ Gas used: ${gasUsed}\n`);

    // Get output
    const outputLen = (wasm as any).evm_get_output_len(evmHandle);
    if (outputLen > 0) {
      const outputBuffer = new Uint8Array(outputLen);
      (wasm as any).evm_get_output(evmHandle, outputBuffer, outputLen);

      // Decode as string (remove padding)
      const decoder = new TextDecoder();
      let text = '';
      for (let i = 0; i < outputBuffer.length; i++) {
        if (outputBuffer[i] === 0) break; // Stop at null terminator/padding
        text += String.fromCharCode(outputBuffer[i]);
      }

      console.log('📤 Output (raw):', bytesToHex(outputBuffer));
      console.log(`📤 Output (string): "${text}"`);
      console.log(`✅ Match: ${text === inputText.split('').reverse().join('')}`);
    }

    console.log('');

  } finally {
    (wasm as any).evm_destroy(evmHandle);
  }
}

/**
 * Example 2: Mathematical Precompile (Fibonacci)
 *
 * Address: 0x0000000000000000000000000000000000002000
 * Input: 32-byte u256 (n)
 * Output: 32-byte u256 (fibonacci(n))
 * Gas: 50 + 20 * n
 */
async function example2_fibonacci() {
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('Example 2: Custom Precompile - Fibonacci Calculator');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

  const registry = new PrecompileRegistry();

  // Register fibonacci calculator at address 0x2000
  registry.register('0x0000000000000000000000000000000000002000', (input, gasLimit) => {
    if (input.length < 32) {
      return {
        success: false,
        output: new Uint8Array(0),
        gasUsed: 0n,
      };
    }

    const n = bytesToU256(input.slice(0, 32));

    // Gas cost: 50 base + 20 per iteration
    const gasCost = 50n + 20n * n;

    if (gasCost > gasLimit) {
      return {
        success: false,
        output: new Uint8Array(0),
        gasUsed: gasLimit,
      };
    }

    // Limit n to prevent overflow (fibonacci grows exponentially)
    if (n > 93n) {
      return {
        success: false,
        output: new Uint8Array(0),
        gasUsed: gasCost,
      };
    }

    // Calculate fibonacci
    let a = 0n;
    let b = 1n;
    for (let i = 0n; i < n; i++) {
      [a, b] = [b, a + b];
    }

    const result = a;
    const output = u256ToBytes(result);

    return {
      success: true,
      output,
      gasUsed: gasCost,
    };
  });

  const wasm = await loadWasmWithPrecompiles(registry);

  const hardforkName = 'Cancun';
  const hardforkBytes = new TextEncoder().encode(hardforkName);
  const evmHandle = (wasm as any).evm_create(hardforkBytes, hardforkBytes.length, 0);

  if (!evmHandle) {
    throw new Error('Failed to create EVM instance');
  }

  try {
    const n = 10n;
    console.log(`Computing fibonacci(${n})...\n`);

    // Bytecode: Call fibonacci precompile with n=10
    const bytecode = new Uint8Array([
      // PUSH32 n (input)
      0x7f, ...Array.from(u256ToBytes(n)),

      // Store n in memory
      0x60, 0x00,       // PUSH1 0 (offset)
      0x52,             // MSTORE

      // CALL(gas, to, value, argsOffset, argsSize, retOffset, retSize)
      0x60, 0x20,       // PUSH1 32 (retSize)
      0x60, 0x20,       // PUSH1 32 (retOffset)
      0x60, 0x20,       // PUSH1 32 (argsSize)
      0x60, 0x00,       // PUSH1 0 (argsOffset)
      0x60, 0x00,       // PUSH1 0 (value)
      0x61, 0x20, 0x00, // PUSH2 0x2000 (precompile address)
      0x62, 0x0f, 0xff, 0xff, // PUSH3 65535 (gas)
      0xf1,             // CALL

      // Return result
      0x60, 0x20,       // PUSH1 32
      0x60, 0x20,       // PUSH1 32
      0xf3              // RETURN
    ]);

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
    console.log('🚀 Executing bytecode...\n');
    const success = (wasm as any).evm_execute(evmHandle);

    console.log('\n✅ Execution:', success ? 'SUCCESS' : 'FAILED');

    const gasUsed = (wasm as any).evm_get_gas_used(evmHandle);
    console.log(`⛽ Gas used: ${gasUsed}\n`);

    // Get output
    const outputLen = (wasm as any).evm_get_output_len(evmHandle);
    if (outputLen > 0) {
      const outputBuffer = new Uint8Array(outputLen);
      (wasm as any).evm_get_output(evmHandle, outputBuffer, outputLen);

      const result = bytesToU256(outputBuffer);
      console.log(`📤 fibonacci(${n}) = ${result}`);

      // Verify (fibonacci(10) = 55)
      const expected = 55n;
      console.log(`✅ Expected: ${expected}, Got: ${result}, Match: ${result === expected}`);
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
  console.log('║     Guillotine Mini - Custom Precompile Examples         ║');
  console.log('╚═══════════════════════════════════════════════════════════╝\n');

  try {
    await example1_stringReverser();
    await example2_fibonacci();

    console.log('✅ All custom precompile examples completed successfully!');
  } catch (error) {
    console.error('❌ Error running examples:', error);
    process.exit(1);
  }
}

main();
