// File system imports are loaded dynamically in Node.js environment

/**
 * C-compatible types used by the WASM interface
 * 
 * CExecutionResult struct (for evm_execute result_ptr):
 * - success: c_int (4 bytes)
 * - gas_used: c_ulonglong (8 bytes) 
 * - return_data_ptr: pointer (4 bytes in wasm32)
 * - return_data_len: usize (4 bytes in wasm32)
 * - error_code: c_int (4 bytes)
 * 
 * GuillotineExecutionResult struct (returned by guillotine_execute):
 * - success: bool (1 byte)
 * - gas_used: u64 (8 bytes)
 * - output: pointer (4 bytes in wasm32)
 * - output_len: usize (4 bytes in wasm32)
 * - error_message: pointer or null (4 bytes in wasm32)
 * 
 * GuillotineAddress: 20 bytes
 * GuillotineU256: 32 bytes (little-endian)
 * 
 * Error codes (EvmError enum):
 * - EVM_OK = 0
 * - EVM_ERROR_MEMORY = 1
 * - EVM_ERROR_INVALID_PARAM = 2
 * - EVM_ERROR_VM_NOT_INITIALIZED = 3
 * - EVM_ERROR_EXECUTION_FAILED = 4
 * - EVM_ERROR_INVALID_ADDRESS = 5
 * - EVM_ERROR_INVALID_BYTECODE = 6
 * 
 * Frame error codes (FrameError enum):
 * - FRAME_OK = 0
 * - FRAME_ERROR_MEMORY = 1
 * - FRAME_ERROR_INVALID_PARAM = 2
 * - FRAME_ERROR_EXECUTION_FAILED = 3
 * - FRAME_ERROR_STACK_OVERFLOW = 4
 * - FRAME_ERROR_STACK_UNDERFLOW = 5
 * - FRAME_ERROR_OUT_OF_GAS = 6
 */

/**
 * WASM module interface - represents the exported functions from Zig
 */
export interface GuillotineWasm {
  // Memory management
  memory: WebAssembly.Memory;
  
  // Core functions
  evm_init(): number; // Returns c_int (0 = success)
  evm_deinit(): void;
  evm_is_initialized(): number; // Returns c_int (1 if initialized, 0 otherwise)
  evm_version(): number; // Returns pointer to null-terminated string
  
  // Legacy EVM execution
  evm_execute(
    bytecode_ptr: number,
    bytecode_len: number,
    caller_ptr: number,
    value: bigint, // c_ulonglong
    gas_limit: bigint, // c_ulonglong
    result_ptr: number // Pointer to CExecutionResult struct
  ): number; // Returns c_int error code
  
  // VM management
  guillotine_vm_create(): number; // Returns pointer to GuillotineVm or null
  guillotine_vm_destroy(vm: number): void;
  
  // State management
  guillotine_set_balance(vm: number, address_ptr: number, balance_ptr: number): boolean;
  guillotine_set_code(vm: number, address_ptr: number, code_ptr: number, code_len: number): boolean;
  guillotine_set_storage(vm: number, address_ptr: number, key_ptr: number, value_ptr: number): number;
  guillotine_get_balance(vm: number, address_ptr: number): number; // Returns pointer to U256
  guillotine_get_code(vm: number, address_ptr: number): number; // Returns pointer to bytes
  guillotine_get_storage(vm: number, address_ptr: number, key_ptr: number): number; // Returns pointer to U256
  
  // VM execution
  guillotine_vm_execute(
    vm: number,
    bytecode_ptr: number,
    bytecode_len: number,
    caller_ptr: number,
    to_ptr: number,
    value_ptr: number,
    input_ptr: number,
    input_len: number,
    gas_limit: bigint
  ): number; // Returns pointer to result
  guillotine_execute(
    vm: number,
    from_ptr: number, // Pointer to GuillotineAddress
    to_ptr: number, // Pointer to GuillotineAddress (nullable)
    value_ptr: number, // Pointer to GuillotineU256 (nullable)
    input_ptr: number, // Pointer to input bytes (nullable)
    input_len: number,
    gas_limit: bigint // u64
  ): number; // Returns GuillotineExecutionResult struct (by value)
  
  // Utility functions
  guillotine_u256_from_u64(value: bigint, out_u256_ptr: number): void;
  guillotine_version(): number; // Returns pointer to version string
  
  // Frame API
  evm_frame_create(bytecode_ptr: number, bytecode_len: number, initial_gas: bigint): number; // Returns pointer or null
  evm_frame_destroy(frame_ptr: number): void;
  evm_frame_reset(frame_ptr: number, new_gas: bigint): number; // Returns c_int error code
  evm_frame_execute(frame_ptr: number): number; // Returns c_int error code
  
  // Frame gas operations
  evm_frame_get_gas_remaining(frame_ptr: number): bigint; // Returns u64
  evm_frame_get_gas_used(frame_ptr: number): bigint; // Returns u64
  
  // Frame state inspection
  evm_frame_get_pc(frame_ptr: number): number; // Returns u32
  evm_frame_stack_size(frame_ptr: number): number; // Returns u32
  evm_frame_is_stopped(frame_ptr: number): number; // Returns c_int (1 if stopped, 0 if running)
  evm_frame_get_memory_size(frame_ptr: number): number; // Returns usize
  evm_frame_get_bytecode_len(frame_ptr: number): number; // Returns u32
  evm_frame_get_current_opcode(frame_ptr: number): number; // Returns u8
  
  // Frame stack operations
  evm_frame_push_u64(frame_ptr: number, value: bigint): number; // Returns c_int error code
  evm_frame_pop_u64(frame_ptr: number, value_out_ptr: number): number; // Returns c_int error code
  
  // Frame memory operations
  evm_frame_get_memory(frame_ptr: number, offset: number, length: number, data_out_ptr: number): number; // Returns c_int error code
  
  // Debug frame API
  evm_debug_frame_create(bytecode_ptr: number, bytecode_len: number, initial_gas: bigint): number; // Returns pointer or null
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
   */
  async load(wasmPath?: string): Promise<void> {
    let wasmBinary: Uint8Array;

    if (typeof window !== 'undefined') {
      // Browser environment
      const wasmUrl = wasmPath || '/wasm/guillotine-evm.wasm';
      const response = await fetch(wasmUrl);
      wasmBinary = new Uint8Array(await response.arrayBuffer());
    } else {
      // Node.js environment
      const fs = await import('fs');
      const path = await import('path');
      // Try multiple paths to find the WASM file
      const possiblePaths = [
        wasmPath,
        path.join(__dirname, '../wasm/guillotine-evm.wasm'),
        path.join(__dirname, '../../../../zig-out/bin/guillotine-evm.wasm'),
        path.join(process.cwd(), 'zig-out/bin/guillotine-evm.wasm'),
      ].filter(Boolean);
      
      let finalPath: string | undefined;
      for (const p of possiblePaths) {
        if (fs.existsSync(p!)) {
          finalPath = p;
          break;
        }
      }
      
      if (!finalPath) {
        throw new Error('Could not find guillotine-evm.wasm file');
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
      },
      wasi_snapshot_preview1: {
        // Provide minimal WASI imports if needed
        proc_exit: (code: number) => { throw new Error(`Process exited with code ${code}`); },
        fd_write: () => 0,
        fd_close: () => 0,
        fd_seek: () => 0,
      },
    });

    const exports = wasmModule.instance.exports as any;
    this.wasmModule = exports;
    this.exports = exports;
    
    // Debug: Log available exports
    console.log('WASM exports:', Object.keys(exports));
    console.log('WASM export types:', Object.entries(exports).map(([k, v]) => [k, typeof v]));
    
    this.memory = new WasmMemory(exports.memory || new WebAssembly.Memory({ initial: 256 }), exports);
    
    // Update memory views
    this.memoryViews = {
      getUint8: () => new Uint8Array(this.wasmModule!.memory.buffer),
      getUint32: () => new Uint32Array(this.wasmModule!.memory.buffer),
    };

    // Initialize the EVM
    if (this.wasmModule && this.wasmModule.evm_init) {
      const result = this.wasmModule.evm_init();
      if (result !== 0) {
        throw new Error('Failed to initialize Guillotine EVM');
      }
    } else if (this.wasmModule) {
      console.warn('evm_init function not found in WASM exports');
    }
  }

  /**
   * Get the WASM module
   */
  getWasm(): any {
    if (!this.wasmModule) {
      throw new Error('WASM module not loaded. Call load() first.');
    }
    return this.wasmModule;
  }

  /**
   * Get the memory helper
   */
  getMemory(): WasmMemory {
    if (!this.memory) {
      throw new Error('WASM module not loaded. Call load() first.');
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
      throw new Error('WASM module not loaded');
    }
    return this.memory.writeBytes(bytes);
  }

  /**
   * Free bytes in WASM memory
   */
  freeBytes(_ptr: number): void {
    if (!this.memory) {
      throw new Error('WASM module not loaded');
    }
    // In our case, we don't track size, so we'll just no-op for now
    // Real implementation would track allocations
  }

  /**
   * Read bytes from WASM memory
   */
  readBytes(ptr: number, length: number): Uint8Array {
    if (!this.memory) {
      throw new Error('WASM module not loaded');
    }
    return this.memory.readBytes(ptr, length);
  }

  /**
   * Write bytes to WASM memory
   */
  writeBytes(ptr: number, bytes: Uint8Array): void {
    if (!this.memory) {
      throw new Error('WASM module not loaded');
    }
    const buffer = this.memory.getBuffer();
    buffer.set(bytes, ptr);
  }

  /**
   * Read string from WASM memory
   */
  readString(ptr: number): string {
    if (!this.memory) {
      throw new Error('WASM module not loaded');
    }
    return this.memory.readString(ptr);
  }

  /**
   * Cleanup the WASM module
   */
  cleanup(): void {
    if (this.wasmModule && this.wasmModule.evm_deinit) {
      this.wasmModule.evm_deinit();
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
export function setWasmLoader(loader: WasmLoader | any): void {
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