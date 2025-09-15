// File system imports are loaded dynamically in Node.js environment
import { GuillotineError } from '../errors';
import { precompiles } from './precompiles';

/**
 * C-compatible types used by the WASM interface
 * 
 * EvmResult struct (returned by guillotine_call):
 * - success: bool (1 byte, padded to 4 bytes for alignment)
 * - gas_left: u64 (8 bytes)
 * - output: pointer (4 bytes in wasm32)
 * - output_len: usize (4 bytes in wasm32)
 * - error_message: pointer to null-terminated string (4 bytes in wasm32)
 * - logs: pointer to LogEntry array (4 bytes in wasm32)
 * - logs_len: usize (4 bytes in wasm32)
 * - selfdestructs: pointer to SelfDestructRecord array (4 bytes in wasm32)
 * - selfdestructs_len: usize (4 bytes in wasm32)
 * - accessed_addresses: pointer to address array (4 bytes in wasm32)
 * - accessed_addresses_len: usize (4 bytes in wasm32)
 * - accessed_storage: pointer to StorageAccessRecord array (4 bytes in wasm32)
 * - accessed_storage_len: usize (4 bytes in wasm32)
 * - created_address: [20]u8 (20 bytes)
 * - has_created_address: bool (1 byte)
 * - trace_json: pointer to JSON string (4 bytes in wasm32)
 * - trace_json_len: usize (4 bytes in wasm32)
 * 
 * LogEntry struct:
 * - address: [20]u8
 * - topics: pointer to [32]u8 array
 * - topics_len: usize
 * - data: pointer to u8 array
 * - data_len: usize
 * 
 * SelfDestructRecord struct:
 * - contract: [20]u8
 * - beneficiary: [20]u8
 * 
 * StorageAccessRecord struct:
 * - address: [20]u8
 * - slot: [32]u8
 * 
 * CallParams struct:
 * - caller: [20]u8
 * - to: [20]u8
 * - value: [32]u8 (u256 as bytes)
 * - input: pointer to u8 array
 * - input_len: usize
 * - gas: u64
 * - call_type: u8 (0=CALL, 1=CALLCODE, 2=DELEGATECALL, 3=STATICCALL, 4=CREATE, 5=CREATE2)
 * - salt: [32]u8 (for CREATE2)
 */

/**
 * WASM module interface - represents the exported functions from Zig
 */
export interface GuillotineWasm {
  // Memory management
  memory: WebAssembly.Memory;
  
  // Initialization
  guillotine_init(): void;
  guillotine_cleanup(): void;
  
  // Evm instance management
  guillotine_evm_create(block_info_ptr: number): number; // Returns EvmHandle pointer or null
  guillotine_evm_create_tracing(block_info_ptr: number): number; // Returns EvmHandle pointer or null
  guillotine_evm_destroy(handle: number): void;
  guillotine_evm_destroy_tracing(handle: number): void;
  
  // State management
  guillotine_set_balance(handle: number, address_ptr: number, balance_ptr: number): boolean;
  guillotine_set_balance_tracing(handle: number, address_ptr: number, balance_ptr: number): boolean;
  guillotine_set_code(handle: number, address_ptr: number, code_ptr: number, code_len: number): boolean;
  guillotine_set_code_tracing(handle: number, address_ptr: number, code_ptr: number, code_len: number): boolean;
  guillotine_set_storage(handle: number, address_ptr: number, key_ptr: number, value_ptr: number): boolean;
  guillotine_get_balance(handle: number, address_ptr: number, balance_out: number): boolean;
  guillotine_get_code(handle: number, address_ptr: number, code_out_ptr: number, len_out_ptr: number): boolean;
  guillotine_get_storage(handle: number, address_ptr: number, key_ptr: number, value_out: number): boolean;
  
  // Execution
  guillotine_call(handle: number, params_ptr: number): number; // Returns EvmResult pointer or null
  guillotine_call_tracing(handle: number, params_ptr: number): number; // Returns EvmResult pointer or null
  guillotine_simulate(handle: number, params_ptr: number): number; // Returns EvmResult pointer or null
  
  // Memory cleanup
  guillotine_free_output(output: number, len: number): void;
  guillotine_free_code(code: number, len: number): void;
  guillotine_free_result(result: number): void;
  
  // Error handling
  guillotine_get_last_error(): number; // Returns pointer to null-terminated error string
}

/**
 * WASM memory helper for reading/writing data
 */
export class WasmMemory {
  private memory: WebAssembly.Memory;

  constructor(memory: WebAssembly.Memory, _wasm: GuillotineWasm) {
    this.memory = memory;
    // wasm parameter kept for API compatibility but not used internally
  }

  /**
   * Get a view of the memory buffer
   */
  getBuffer(): Uint8Array {
    return new Uint8Array(this.memory.buffer);
  }

  /**
   * Allocate memory in WASM
   */
  malloc(size: number): number {
    // Simple bump allocator for Zig-compiled WASM
    // Zig uses page_allocator for freestanding WASM
    if (!this.allocOffset) {
      this.allocOffset = 1024 * 1024; // Start at 1MB
    }
    const ptr = this.allocOffset;
    this.allocOffset += size;
    // Ensure we have enough memory
    const needed = Math.ceil(this.allocOffset / 65536);
    if (this.memory.buffer.byteLength < needed * 65536) {
      this.memory.grow(needed - this.memory.buffer.byteLength / 65536);
    }
    return ptr;
  }

  private allocOffset?: number;

  /**
   * Free memory in WASM
   */
  free(_ptr: number, _size: number): void {
    // No-op for simple bump allocator
    // Zig's page_allocator doesn't expose free to WASM
  }

  /**
   * Write bytes to WASM memory
   */
  writeBytes(data: Uint8Array): number {
    const ptr = this.malloc(data.length);
    const buffer = this.getBuffer();
    buffer.set(data, ptr);
    return ptr;
  }

  /**
   * Read bytes from WASM memory
   */
  readBytes(ptr: number, len: number): Uint8Array {
    const buffer = this.getBuffer();
    return buffer.slice(ptr, ptr + len);
  }

  /**
   * Write a null-terminated string to WASM memory
   */
  writeString(str: string): number {
    const encoder = new TextEncoder();
    const bytes = encoder.encode(str + '\\0');
    return this.writeBytes(bytes);
  }

  /**
   * Read a null-terminated string from WASM memory
   */
  readString(ptr: number): string {
    const buffer = this.getBuffer();
    let len = 0;
    while (buffer[ptr + len] !== 0 && ptr + len < buffer.length) {
      len++;
    }
    const decoder = new TextDecoder();
    return decoder.decode(buffer.slice(ptr, ptr + len));
  }

  /**
   * Write an address (20 bytes) to WASM memory
   */
  writeAddress(address: Uint8Array): number {
    if (address.length !== 20) {
      throw new Error('Address must be 20 bytes');
    }
    return this.writeBytes(address);
  }

  /**
   * Read an address (20 bytes) from WASM memory
   */
  readAddress(ptr: number): Uint8Array {
    return this.readBytes(ptr, 20);
  }

  /**
   * Write a U256 (32 bytes) to WASM memory
   */
  writeU256(value: Uint8Array): number {
    if (value.length !== 32) {
      throw new Error('U256 must be 32 bytes');
    }
    return this.writeBytes(value);
  }

  /**
   * Read a U256 (32 bytes) from WASM memory
   */
  readU256(ptr: number): Uint8Array {
    return this.readBytes(ptr, 32);
  }

  /**
   * Write a hash (32 bytes) to WASM memory
   */
  writeHash(hash: Uint8Array): number {
    if (hash.length !== 32) {
      throw new Error('Hash must be 32 bytes');
    }
    return this.writeBytes(hash);
  }

  /**
   * Read a hash (32 bytes) from WASM memory
   */
  readHash(ptr: number): Uint8Array {
    return this.readBytes(ptr, 32);
  }
}

/**
 * WASM loader with support for Node.js and browser environments
 */
export class WasmLoader {
  private wasmModule: GuillotineWasm | null = null;
  private memory: WasmMemory | null = null;
  public exports: GuillotineWasm | null = null;
  public memoryViews = {
    getUint8: () => new Uint8Array(0),
    getUint32: () => new Uint32Array(0),
  };

  /**
   * Load the WASM module
   * 
   * INITIALIZATION PATTERN:
   * - Called ONCE per application lifetime (singleton pattern)
   * - Initializes global FFI allocator via guillotine_init()
   * - Shared by ALL Evm instances on the same thread
   * - Do NOT call per Evm instance - use GuillotineEvm.create() instead
   */
  async load(wasmPath?: string): Promise<void> {
    let wasmBinary: Uint8Array;

    if (typeof window !== 'undefined') {
      // Browser environment
      const wasmUrl = wasmPath || '/wasm/guillotine.wasm';
      const response = await fetch(wasmUrl);
      wasmBinary = new Uint8Array(await response.arrayBuffer());
    } else {
      // Node.js environment
      const fs = await import('fs');
      const path = await import('path');
      // Try multiple paths to find the WASM file
      const possiblePaths = [
        wasmPath,
        path.join(__dirname, '../wasm/guillotine.wasm'),
        path.join(__dirname, '../../../../zig-out/bin/guillotine.wasm'),
        path.join(process.cwd(), 'zig-out/bin/guillotine.wasm'),
      ].filter(Boolean);
      
      let finalPath: string | undefined;
      for (const p of possiblePaths) {
        if (!p) continue;
        if (fs.existsSync(p)) {
          finalPath = p;
          break;
        }
      }
      
      if (!finalPath) {
        throw GuillotineError.wasmLoadFailed('Could not find guillotine.wasm file');
      }
      
      wasmBinary = new Uint8Array(fs.readFileSync(finalPath));
    }

    // Compile and instantiate the WASM module
    const wasmModule = await WebAssembly.instantiate(wasmBinary, {
      env: {
        // Provide any environment functions needed by WASM
        console_log: this.consoleLog.bind(this),
        console_warn: this.consoleWarn.bind(this),
        console_error: this.consoleError.bind(this),
        // Evm precompile functions (organized in separate modules)
        ...precompiles,
      },
      wasi_snapshot_preview1: {
        // Provide minimal WASI imports if needed
        proc_exit: (code: number) => { throw new Error(`Process exited with code ${code}`); },
        fd_write: () => 0,
        fd_close: () => 0,
        fd_seek: () => 0,
      },
    });

    const exports = wasmModule.instance.exports as unknown as GuillotineWasm;
    this.wasmModule = exports;
    this.exports = exports;
    
    // Debug: Log available exports
    // console.log('WASM exports:', Object.keys(exports));
    // console.log('WASM export types:', Object.entries(exports).map(([k, v]) => [k, typeof v]));
    
    this.memory = new WasmMemory(exports.memory || new WebAssembly.Memory({ initial: 256 }), exports);
    
    // Update memory views
    this.memoryViews = {
      getUint8: () => {
        if (!this.wasmModule) {
          throw GuillotineError.wasmNotLoaded('WASM module not loaded. Call load() first.');
        }
        return new Uint8Array(this.wasmModule.memory.buffer);
      },
      getUint32: () => {
        if (!this.wasmModule) {
          throw GuillotineError.wasmNotLoaded('WASM module not loaded. Call load() first.');
        }
        return new Uint32Array(this.wasmModule.memory.buffer);
      },
    };

    // Initialize the Evm
    if (this.wasmModule?.guillotine_init) {
      this.wasmModule.guillotine_init();
    } else if (this.wasmModule) {
      throw GuillotineError.initializationFailed('guillotine_init function not found in WASM exports');
    }
  }

  /**
   * Get the WASM module
   */
  getWasm(): GuillotineWasm {
    if (!this.wasmModule) {
      throw GuillotineError.wasmNotLoaded('WASM module not loaded. Call load() first.');
    }
    return this.wasmModule;
  }

  /**
   * Get the memory helper
   */
  getMemory(): WasmMemory {
    if (!this.memory) {
      throw GuillotineError.wasmNotLoaded('WASM module not loaded. Call load() first.');
    }
    return this.memory;
  }

  /**
   * Check if the module is loaded
   */
  isLoaded(): boolean {
    return this.wasmModule !== null;
  }

  /**
   * Allocate bytes in WASM memory
   */
  allocateBytes(bytes: Uint8Array): number {
    if (!this.memory) {
      throw GuillotineError.wasmNotLoaded('WASM module not loaded');
    }
    return this.memory.writeBytes(bytes);
  }

  /**
   * Free bytes in WASM memory
   */
  freeBytes(_ptr: number): void {
    if (!this.memory) {
      throw GuillotineError.wasmNotLoaded('WASM module not loaded');
    }
    // In our case, we don't track size, so we'll just no-op for now
    // Real implementation would track allocations
  }

  /**
   * Read bytes from WASM memory
   */
  readBytes(ptr: number, length: number): Uint8Array {
    if (!this.memory) {
      throw GuillotineError.wasmNotLoaded('WASM module not loaded');
    }
    return this.memory.readBytes(ptr, length);
  }

  /**
   * Write bytes to WASM memory
   */
  writeBytes(ptr: number, bytes: Uint8Array): void {
    if (!this.memory) {
      throw GuillotineError.wasmNotLoaded('WASM module not loaded');
    }
    const buffer = this.memory.getBuffer();
    buffer.set(bytes, ptr);
  }

  /**
   * Read string from WASM memory
   */
  readString(ptr: number): string {
    if (!this.memory) {
      throw GuillotineError.wasmNotLoaded('WASM module not loaded');
    }
    return this.memory.readString(ptr);
  }

  /**
   * Cleanup the WASM module
   * 
   * CLEANUP PATTERN:
   * - Called ONCE when unloading entire WASM module (application shutdown)
   * - Destroys global FFI allocator via guillotine_cleanup()
   * - Will break ALL existing Evm instances
   * - Do NOT call when closing individual Evms - use evm.close() instead
   * - Only call if you need to fully unload and reload the WASM module
   */
  cleanup(): void {
    if (this.wasmModule?.guillotine_cleanup) {
      this.wasmModule.guillotine_cleanup();
    } else {
      throw GuillotineError.cleanupFailed('guillotine_cleanup function not found in WASM exports');
    }
    this.wasmModule = null;
    this.memory = null;
    this.exports = null;
  }

  // Console logging functions for WASM
  private consoleLog(ptr: number, len: number): void {
    if (this.memory) {
      const message = new TextDecoder().decode(this.memory.readBytes(ptr, len));
      console.log(message);
    }
  }

  private consoleWarn(ptr: number, len: number): void {
    if (this.memory) {
      const message = new TextDecoder().decode(this.memory.readBytes(ptr, len));
      console.warn(message);
    }
  }

  private consoleError(ptr: number, len: number): void {
    if (this.memory) {
      const message = new TextDecoder().decode(this.memory.readBytes(ptr, len));
      console.error(message);
    }
  }
}

// Global WASM loader instance
let globalLoader: WasmLoader | null = null;

/**
 * Get or create the global WASM loader instance
 */
export function getWasmLoader(): WasmLoader {
  if (!globalLoader) {
    globalLoader = new WasmLoader();
  }
  return globalLoader;
}

/**
 * Set the global WASM loader instance (for testing)
 */
export function setWasmLoader(loader: WasmLoader): void {
  globalLoader = loader;
}

/**
 * Initialize the global WASM loader
 */
export async function initWasm(wasmPath?: string): Promise<void> {
  const loader = getWasmLoader();
  if (!loader.isLoaded()) {
    await loader.load(wasmPath);
  }
}