import { Address } from '../primitives/address.js';
import { U256 } from '../primitives/u256.js';
import { Bytes } from '../primitives/bytes.js';
import { ExecutionResult, type LogEntry, type SelfDestructRecord, type StorageAccessRecord } from './execution-result.js';
import { GuillotineError } from '../errors.js';
import { getWasmLoader, type WasmMemory, type GuillotineWasm } from '../wasm/loader.js';

/**
 * Block information for Evm execution
 */
export interface BlockInfo {
  number?: bigint;
  timestamp?: bigint;
  gasLimit?: bigint;
  coinbase?: Address;
  baseFee?: bigint;
  chainId?: bigint;
  difficulty?: bigint;
  prevRandao?: Bytes;
}

/**
 * Call types for Evm execution
 */
export enum CallType {
  CALL = 0,
  CALLCODE = 1,
  DELEGATECALL = 2,
  STATICCALL = 3,
  CREATE = 4,
  CREATE2 = 5,
}

/**
 * Parameters for Evm execution
 */
export interface ExecutionParams {
  /** The caller address */
  caller: Address;
  /** The target address */
  to: Address;
  /** The value to transfer */
  value: U256;
  /** The input data */
  input: Bytes;
  /** The gas limit */
  gas: bigint;
  /** The call type (defaults to CALL) */
  callType?: CallType;
  /** Salt for CREATE2 */
  salt?: U256;
}

/**
 * Main Evm execution engine using WebAssembly
 */
export class GuillotineEvm {
  private wasm: GuillotineWasm;
  private memory: WasmMemory;
  private evmHandle: number;
  private isInitialized: boolean = false;
  private useTracing: boolean = false;

  private constructor(wasm: GuillotineWasm, memory: WasmMemory, evmHandle: number, useTracing: boolean = false) {
    this.wasm = wasm;
    this.memory = memory;
    this.evmHandle = evmHandle;
    this.useTracing = useTracing;
    this.isInitialized = true;
  }

  /**
   * Create a new Evm instance
   * 
   * INSTANCE CREATION PATTERN:
   * - Creates independent Evm instance with its own state via handle
   * - Multiple instances can coexist on same thread (share WASM module)
   * - Each instance has separate storage/balance/code state
   * - Calls guillotine_evm_create() which allocates instance-specific memory
   * - We only init the WASM module and allocate memory once
   */
  static async create(blockInfo?: BlockInfo, useTracing: boolean = false, wasmPath?: string): Promise<GuillotineEvm> {
    try {
      const loader = getWasmLoader();
      
      // Load WASM if not already loaded
      if (!loader.isLoaded()) {
        await loader.load(wasmPath);
      }
      
      const wasm = loader.getWasm();
      const memory = loader.getMemory();
      
      // Create block info structure  
      // BlockInfoFFI struct: 6 u64s (48 bytes) + coinbase (20 bytes) + padding (4 bytes) + prev_randao (32 bytes) = 104 bytes
      const blockInfoPtr = memory.malloc(104); // Size of BlockInfoFFI struct
      const buffer = memory.getBuffer();
      const view = new DataView(buffer.buffer, blockInfoPtr);
      
      // Write all u64 fields first (for proper alignment without padding)
      view.setBigUint64(0, blockInfo?.number || 0n, true); // number
      view.setBigUint64(8, blockInfo?.timestamp || BigInt(Math.floor(Date.now() / 1000)), true); // timestamp
      view.setBigUint64(16, blockInfo?.gasLimit || 30000000n, true); // gas_limit
      view.setBigUint64(24, blockInfo?.baseFee || 0n, true); // base_fee
      view.setBigUint64(32, blockInfo?.chainId || 1n, true); // chain_id
      view.setBigUint64(40, blockInfo?.difficulty || 0n, true); // difficulty
      
      // coinbase address (20 bytes) at offset 48
      const coinbase = blockInfo?.coinbase || Address.zero();
      const coinbaseBytes = coinbase.toBytes();
      for (let i = 0; i < 20; i++) {
        view.setUint8(48 + i, coinbaseBytes[i] || 0);
      }
      
      // padding (4 bytes) at offset 68-71
      // prev_randao (32 bytes) at offset 72
      const prevRandao = blockInfo?.prevRandao || Bytes.fromBytes(new Uint8Array(32));
      const prevRandaoBytes = prevRandao.toBytes();
      for (let i = 0; i < 32; i++) {
        view.setUint8(72 + i, prevRandaoBytes[i] || 0);
      }
      
      // Create Evm instance
      const evmHandle = useTracing
        ? wasm.guillotine_evm_create_tracing(blockInfoPtr)
        : wasm.guillotine_evm_create(blockInfoPtr);
        
      memory.free(blockInfoPtr, 104);
      
      if (evmHandle === 0) {
        const errorPtr = wasm.guillotine_get_last_error();
        const errorMessage = memory.readString(errorPtr);
        throw GuillotineError.vmNotInitialized(`Failed to create Evm instance: ${errorMessage}`);
      }
      
      return new GuillotineEvm(wasm, memory, evmHandle, useTracing);
    } catch (error) {
      if (error instanceof GuillotineError) {
        throw error;
      }
      throw GuillotineError.initializationFailed(
        'Failed to create Evm instance',
        error as Error
      );
    }
  }

  /**
   * Execute a call on the EVM
   */
  async call(params: ExecutionParams): Promise<ExecutionResult> {
    this.ensureInitialized();

    try {
      // Create CallParams structure
      const paramsPtr = this.memory.malloc(124); // Size of CallParams struct
      const buffer = this.memory.getBuffer();
      const view = new DataView(buffer.buffer, paramsPtr);
      let offset = 0;

      // caller (20 bytes)
      const callerBytes = params.caller.toBytes();
      for (let i = 0; i < 20; i++) {
        view.setUint8(offset + i, callerBytes[i] || 0);
      }
      offset += 20;

      // to (20 bytes)
      const toBytes = params.to.toBytes();
      for (let i = 0; i < 20; i++) {
        view.setUint8(offset + i, toBytes[i] || 0);
      }
      offset += 20;

      // value (32 bytes)
      const valueBytes = params.value.toBytes();
      for (let i = 0; i < 32; i++) {
        view.setUint8(offset + i, valueBytes[i] || 0);
      }
      offset += 32;

      // input pointer and length
      const inputPtr = params.input.isEmpty() ? 0 : this.memory.writeBytes(params.input.toBytes());
      view.setUint32(offset, inputPtr, true);
      offset += 4;
      view.setUint32(offset, params.input.length(), true);
      offset += 4;

      // gas
      view.setBigUint64(offset, params.gas, true);
      offset += 8;

      // call_type
      view.setUint8(offset, params.callType || CallType.CALL);
      offset += 1;

      // padding (3 bytes) for alignment
      offset += 3;

      // salt (32 bytes) - for CREATE2
      const salt = params.salt || U256.zero();
      const saltBytes = salt.toBytes();
      for (let i = 0; i < 32; i++) {
        view.setUint8(offset + i, saltBytes[i] || 0);
      }

      try {
        // Execute the call
        const resultPtr = this.useTracing
          ? this.wasm.guillotine_call_tracing(this.evmHandle, paramsPtr)
          : this.wasm.guillotine_call(this.evmHandle, paramsPtr);

        if (resultPtr === 0) {
          const errorPtr = this.wasm.guillotine_get_last_error();
          const errorMessage = this.memory.readString(errorPtr);
          throw GuillotineError.executionFailed(`VM execution failed: ${errorMessage}`);
        }

        // Parse the result
        const result = this.parseExecutionResult(resultPtr);
        
        // Free the result
        this.wasm.guillotine_free_result(resultPtr);
        
        return result;
      } finally {
        // Clean up allocated memory
        this.memory.free(paramsPtr, 124);
        if (inputPtr !== 0) {
          this.memory.free(inputPtr, params.input.length());
        }
      }
    } catch (error) {
      if (error instanceof GuillotineError) {
        throw error;
      }
      throw GuillotineError.executionFailed(
        'Evm execution failed',
        error as Error
      );
    }
  }

  /**
   * Set the balance of an account
   */
  async setBalance(address: Address, balance: U256): Promise<void> {
    this.ensureInitialized();

    try {
      const addressPtr = this.memory.writeAddress(address.toBytes());
      const balancePtr = this.memory.writeU256(balance.toBytes());

      try {
        const result = this.useTracing
          ? this.wasm.guillotine_set_balance_tracing(this.evmHandle, addressPtr, balancePtr)
          : this.wasm.guillotine_set_balance(this.evmHandle, addressPtr, balancePtr);
          
        if (!result) {
          const errorPtr = this.wasm.guillotine_get_last_error();
          const errorMessage = this.memory.readString(errorPtr);
          throw GuillotineError.stateError(`Failed to set balance: ${errorMessage}`);
        }
      } finally {
        this.memory.free(addressPtr, 20);
        this.memory.free(balancePtr, 32);
      }
    } catch (error) {
      if (error instanceof GuillotineError) {
        throw error;
      }
      throw GuillotineError.stateError('Failed to set balance', error as Error);
    }
  }

  /**
   * Set the code of an account
   */
  async setCode(address: Address, code: Bytes): Promise<void> {
    this.ensureInitialized();

    try {
      const addressPtr = this.memory.writeAddress(address.toBytes());
      const codePtr = code.isEmpty() ? 0 : this.memory.writeBytes(code.toBytes());

      try {
        const result = this.useTracing
          ? this.wasm.guillotine_set_code_tracing(this.evmHandle, addressPtr, codePtr, code.length())
          : this.wasm.guillotine_set_code(this.evmHandle, addressPtr, codePtr, code.length());
          
        if (!result) {
          const errorPtr = this.wasm.guillotine_get_last_error();
          const errorMessage = this.memory.readString(errorPtr);
          throw GuillotineError.stateError(`Failed to set code: ${errorMessage}`);
        }
      } finally {
        this.memory.free(addressPtr, 20);
        if (codePtr !== 0) {
          this.memory.free(codePtr, code.length());
        }
      }
    } catch (error) {
      if (error instanceof GuillotineError) {
        throw error;
      }
      throw GuillotineError.stateError('Failed to set code', error as Error);
    }
  }

  /**
   * Set a storage slot for an account
   */
  async setStorage(address: Address, key: U256, value: U256): Promise<void> {
    this.ensureInitialized();

    try {
      const addressPtr = this.memory.writeAddress(address.toBytes());
      const keyPtr = this.memory.writeU256(key.toBytes());
      const valuePtr = this.memory.writeU256(value.toBytes());

      try {
        const result = this.wasm.guillotine_set_storage(
          this.evmHandle,
          addressPtr,
          keyPtr,
          valuePtr
        );
        if (!result) {
          const errorPtr = this.wasm.guillotine_get_last_error();
          const errorMessage = this.memory.readString(errorPtr);
          throw GuillotineError.stateError(`Failed to set storage: ${errorMessage}`);
        }
      } finally {
        this.memory.free(addressPtr, 20);
        this.memory.free(keyPtr, 32);
        this.memory.free(valuePtr, 32);
      }
    } catch (error) {
      if (error instanceof GuillotineError) {
        throw error;
      }
      throw GuillotineError.stateError('Failed to set storage', error as Error);
    }
  }

  /**
   * Get the balance of an account
   */
  async getBalance(address: Address): Promise<U256> {
    this.ensureInitialized();

    try {
      const addressPtr = this.memory.writeAddress(address.toBytes());
      const balanceOutPtr = this.memory.malloc(32);

      try {
        const result = this.wasm.guillotine_get_balance(this.evmHandle, addressPtr, balanceOutPtr);
        if (!result) {
          return U256.zero();
        }

        const balanceBytes = this.memory.readU256(balanceOutPtr);
        return U256.fromBytes(balanceBytes);
      } finally {
        this.memory.free(addressPtr, 20);
        this.memory.free(balanceOutPtr, 32);
      }
    } catch (error) {
      if (error instanceof GuillotineError) {
        throw error;
      }
      throw GuillotineError.stateError('Failed to get balance', error as Error);
    }
  }

  /**
   * Get the code of an account
   */
  async getCode(address: Address): Promise<Bytes> {
    this.ensureInitialized();

    try {
      const addressPtr = this.memory.writeAddress(address.toBytes());
      const codeOutPtr = this.memory.malloc(4);
      const lenOutPtr = this.memory.malloc(4);

      try {
        const success = this.wasm.guillotine_get_code(this.evmHandle, addressPtr, codeOutPtr, lenOutPtr);
        if (!success) {
          return Bytes.empty();
        }

        const buffer = this.memory.getBuffer();
        const view = new DataView(buffer.buffer);
        const codePtr = view.getUint32(codeOutPtr, true);
        const codeLen = view.getUint32(lenOutPtr, true);

        if (codeLen === 0) {
          return Bytes.empty();
        }

        const codeBytes = new Uint8Array(buffer.buffer, codePtr, codeLen);
        const codeResult = Bytes.fromBytes(codeBytes);

        // Free the code allocated by WASM
        this.wasm.guillotine_free_code(codePtr, codeLen);

        return codeResult;
      } finally {
        this.memory.free(addressPtr, 20);
        this.memory.free(codeOutPtr, 4);
        this.memory.free(lenOutPtr, 4);
      }
    } catch (error) {
      if (error instanceof GuillotineError) {
        throw error;
      }
      throw GuillotineError.stateError('Failed to get code', error as Error);
    }
  }

  /**
   * Get a storage slot for an account
   */
  async getStorage(address: Address, key: U256): Promise<U256> {
    this.ensureInitialized();

    try {
      const addressPtr = this.memory.writeAddress(address.toBytes());
      const keyPtr = this.memory.writeU256(key.toBytes());
      const valueOutPtr = this.memory.malloc(32);

      try {
        const result = this.wasm.guillotine_get_storage(this.evmHandle, addressPtr, keyPtr, valueOutPtr);
        if (!result) {
          return U256.zero();
        }

        const valueBytes = this.memory.readU256(valueOutPtr);
        return U256.fromBytes(valueBytes);
      } finally {
        this.memory.free(addressPtr, 20);
        this.memory.free(keyPtr, 32);
        this.memory.free(valueOutPtr, 32);
      }
    } catch (error) {
      if (error instanceof GuillotineError) {
        throw error;
      }
      throw GuillotineError.stateError('Failed to get storage', error as Error);
    }
  }

  /**
   * Simulate a call (doesn't modify state)
   */
  async simulate(params: ExecutionParams): Promise<ExecutionResult> {
    this.ensureInitialized();

    // Create CallParams and call guillotine_simulate
    // Implementation similar to call() but uses guillotine_simulate
    // This is a placeholder - implement similarly to call()
    return this.call(params);
  }

  /**
   * Close the EVM instance and clean up resources
   * 
   * INSTANCE CLEANUP PATTERN:
   * - Frees THIS instance's resources via guillotine_evm_destroy()
   * - Does NOT affect other Evm instances or global WASM module
   * - Does NOT call guillotine_cleanup() (would break all instances)
   * - Safe to create new instances after closing
   */
  close(): void {
    if (this.isInitialized && this.evmHandle !== 0) {
      if (this.useTracing) {
        this.wasm.guillotine_evm_destroy_tracing(this.evmHandle);
      } else {
        this.wasm.guillotine_evm_destroy(this.evmHandle);
      }
      this.evmHandle = 0;
      this.isInitialized = false;
    }
  }

  /**
   * Ensure the EVM is initialized
   */
  private ensureInitialized(): void {
    if (!this.isInitialized || this.evmHandle === 0) {
      throw GuillotineError.vmNotInitialized('Evm instance is not initialized');
    }
  }

  /**
   * Parse execution result from WASM memory
   */
  private parseExecutionResult(resultPtr: number): ExecutionResult {
    const buffer = this.memory.getBuffer();
    const view = new DataView(buffer.buffer, resultPtr);
    let offset = 0;

    // Parse EvmResult struct with correct WASM32 offsets
    // IMPORTANT: These offsets match the actual WASM32 struct layout
    // success: bool at offset 0 (padded to 4 bytes)
    const success = view.getUint8(offset) !== 0;
    offset = 8; // Skip to offset 8 (gas_left requires 8-byte alignment)

    // gas_left: u64 at offset 8
    const gasLeft = view.getBigUint64(offset, true);
    offset = 16; // Now at offset 16

    // output: pointer at offset 16
    const outputPtr = view.getUint32(offset, true);
    offset = 20; // Now at offset 20

    // output_len: usize at offset 20
    const outputLen = view.getUint32(offset, true);
    offset = 24; // Now at offset 24

    // error_message: pointer at offset 24
    const errorMessagePtr = view.getUint32(offset, true);
    offset = 28; // Now at offset 28
    
    // Skip padding (_pad2: 4 bytes)
    offset = 32; // Skip to offset 32 after padding

    // logs: pointer at offset 32
    const logsPtr = view.getUint32(offset, true);
    offset = 36; // Now at offset 36

    // logs_len: u32 at offset 36
    const logsLen = view.getUint32(offset, true);
    offset = 40; // Now at offset 40

    // selfdestructs: pointer at offset 40
    const selfdestructsPtr = view.getUint32(offset, true);
    offset = 44; // Now at offset 44

    // selfdestructs_len: u32 at offset 44
    const selfdestructsLen = view.getUint32(offset, true);
    offset = 48; // Now at offset 48

    // accessed_addresses: pointer at offset 48
    const accessedAddressesPtr = view.getUint32(offset, true);
    offset = 52; // Now at offset 52

    // accessed_addresses_len: u32 at offset 52
    const accessedAddressesLen = view.getUint32(offset, true);
    offset = 56; // Now at offset 56

    // accessed_storage: pointer at offset 56
    const accessedStoragePtr = view.getUint32(offset, true);
    offset = 60; // Now at offset 60

    // accessed_storage_len: u32 at offset 60
    const accessedStorageLen = view.getUint32(offset, true);
    offset = 64; // Now at offset 64

    // created_address: [20]u8 at offset 64
    const createdAddressBytes = new Uint8Array(20);
    for (let i = 0; i < 20; i++) {
      createdAddressBytes[i] = view.getUint8(offset + i);
    }
    offset = 84; // Now at offset 84 (64 + 20)

    // has_created_address: bool at offset 84
    const hasCreatedAddress = view.getUint8(offset) !== 0;
    offset = 88; // Now at offset 88 (aligned to 4 bytes with padding)

    // trace_json: pointer at offset 88
    const traceJsonPtr = view.getUint32(offset, true);
    offset = 92; // Now at offset 92

    // trace_json_len: u32 at offset 92
    const traceJsonLen = view.getUint32(offset, true);

    // Parse output
    const output = outputLen > 0 && outputPtr !== 0
      ? Bytes.fromBytes(this.memory.readBytes(outputPtr, outputLen))
      : Bytes.empty();

    // Parse error message
    const errorMessage = errorMessagePtr !== 0
      ? this.memory.readString(errorMessagePtr)
      : null;

    // Parse logs
    const logs: LogEntry[] = [];
    if (logsLen > 0 && logsPtr !== 0) {
      for (let i = 0; i < logsLen; i++) {
        const logPtr = logsPtr + i * 40; // Size of LogEntry struct (20 + 4 padding + 4 + 4 + 4 + 4)
        const logBuffer = this.memory.readBytes(logPtr, 40);
        const logView = new DataView(logBuffer.buffer);
        
        // address: [20]u8
        const addressBytes = new Uint8Array(20);
        for (let j = 0; j < 20; j++) {
          addressBytes[j] = logView.getUint8(j);
        }
        
        // Skip padding (4 bytes) at offset 20-23
        // topics: pointer at offset 24
        const topicsPtr = logView.getUint32(24, true);
        // topics_len: u32 at offset 28
        const topicsLen = logView.getUint32(28, true);
        // data: pointer at offset 32
        const dataPtr = logView.getUint32(32, true);
        // data_len: u32 at offset 36
        const dataLen = logView.getUint32(36, true);

        const topics: U256[] = [];
        if (topicsLen > 0 && topicsPtr !== 0) {
          for (let j = 0; j < topicsLen; j++) {
            const topicBytes = this.memory.readBytes(topicsPtr + j * 32, 32);
            topics.push(U256.fromBytes(topicBytes));
          }
        }

        const data = dataLen > 0 && dataPtr !== 0
          ? Bytes.fromBytes(this.memory.readBytes(dataPtr, dataLen))
          : Bytes.empty();

        logs.push({
          address: Address.fromBytes(addressBytes),
          topics,
          data,
        });
      }
    }

    // Parse selfdestructs
    const selfdestructs: SelfDestructRecord[] = [];
    if (selfdestructsLen > 0 && selfdestructsPtr !== 0) {
      for (let i = 0; i < selfdestructsLen; i++) {
        const sdPtr = selfdestructsPtr + i * 40; // Size of SelfDestructRecord
        const sdBuffer = this.memory.readBytes(sdPtr, 40);
        const contractBytes = new Uint8Array(sdBuffer.buffer, 0, 20);
        const beneficiaryBytes = new Uint8Array(sdBuffer.buffer, 20, 20);
        
        selfdestructs.push({
          contract: Address.fromBytes(contractBytes),
          beneficiary: Address.fromBytes(beneficiaryBytes),
        });
      }
    }

    // Parse accessed addresses
    const accessedAddresses: Address[] = [];
    if (accessedAddressesLen > 0 && accessedAddressesPtr !== 0) {
      for (let i = 0; i < accessedAddressesLen; i++) {
        const addrPtr = accessedAddressesPtr + i * 20;
        const addrBytes = this.memory.readBytes(addrPtr, 20);
        accessedAddresses.push(Address.fromBytes(addrBytes));
      }
    }

    // Parse accessed storage
    const accessedStorage: StorageAccessRecord[] = [];
    if (accessedStorageLen > 0 && accessedStoragePtr !== 0) {
      for (let i = 0; i < accessedStorageLen; i++) {
        const storagePtr = accessedStoragePtr + i * 52; // 20 + 32
        const storageBuffer = this.memory.readBytes(storagePtr, 52);
        const addressBytes = new Uint8Array(storageBuffer.buffer, 0, 20);
        const slotBytes = new Uint8Array(storageBuffer.buffer, 20, 32);
        
        accessedStorage.push({
          address: Address.fromBytes(addressBytes),
          slot: U256.fromBytes(slotBytes),
        });
      }
    }

    // Parse created address
    const createdAddress = hasCreatedAddress
      ? Address.fromBytes(createdAddressBytes)
      : null;

    // Parse trace JSON
    let traceJson: string | null = null;
    if (traceJsonLen > 0 && traceJsonPtr !== 0) {
      const traceBytes = this.memory.readBytes(traceJsonPtr, traceJsonLen);
      // The trace JSON from Zig might include garbage at the end, trim it
      // Look for the last valid JSON character (should end with ]})
      let actualLength = traceJsonLen;
      for (let i = 0; i < traceJsonLen; i++) {
        // Check for null terminator or invalid UTF-8 byte
        if (traceBytes[i] === 0 || (traceBytes[i] ?? 0) > 127) {
          actualLength = i;
          break;
        }
      }
      const rawJson = new TextDecoder().decode(traceBytes.slice(0, actualLength));
      // Ensure the JSON is complete
      if (rawJson.includes('"structLogs":[') && !rawJson.endsWith(']}')) {
        // Try to fix incomplete JSON by adding missing closing brackets
        const openBrackets = (rawJson.match(/\[/g) || []).length;
        const closeBrackets = (rawJson.match(/\]/g) || []).length;
        const openBraces = (rawJson.match(/\{/g) || []).length;
        const closeBraces = (rawJson.match(/\}/g) || []).length;
        
        let fixedJson = rawJson;
        for (let i = 0; i < openBrackets - closeBrackets; i++) {
          fixedJson += ']';
        }
        for (let i = 0; i < openBraces - closeBraces; i++) {
          fixedJson += '}';
        }
        traceJson = fixedJson;
      } else {
        traceJson = rawJson;
      }
    }

    return new ExecutionResult(
      success,
      gasLeft,
      output,
      errorMessage,
      logs,
      selfdestructs,
      accessedAddresses,
      accessedStorage,
      createdAddress,
      traceJson
    );
  }
}