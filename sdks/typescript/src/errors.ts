/**
 * Error types for Guillotine operations
 */
export type GuillotineErrorType =
  | 'InitializationFailed'
  | 'WasmLoadFailed'
  | 'WasmNotLoaded'
  | 'VMCreationFailed'
  | 'VMNotInitialized'
  | 'ExecutionFailed'
  | 'InvalidBytecode'
  | 'InvalidAddress'
  | 'InvalidValue'
  | 'OutOfGas'
  | 'StackOverflow'
  | 'StackUnderflow'
  | 'InvalidJump'
  | 'InvalidOpcode'
  | 'MemoryError'
  | 'StateError'
  | 'UnknownError';

/**
 * Typed error class for Guillotine operations
 */
export class GuillotineError extends Error {
  public readonly type: GuillotineErrorType;
  public override readonly cause?: Error | undefined;

  constructor(type: GuillotineErrorType, message: string, cause?: Error) {
    super(message);
    this.name = 'GuillotineError';
    this.type = type;
    this.cause = cause;

    // Ensure proper prototype chain
    Object.setPrototypeOf(this, GuillotineError.prototype);
  }

  /**
   * Create an initialization error
   */
  static initializationFailed(message: string, cause?: Error): GuillotineError {
    return new GuillotineError('InitializationFailed', message, cause);
  }

  /**
   * Create a WASM load error
   */
  static wasmLoadFailed(message: string, cause?: Error): GuillotineError {
    return new GuillotineError('WasmLoadFailed', message, cause);
  }

  /**
   * Create a WASM not loaded error
   */
  static wasmNotLoaded(message: string = 'WASM module not loaded'): GuillotineError {
    return new GuillotineError('WasmNotLoaded', message);
  }

  /**
   * Create a VM creation error
   */
  static vmCreationFailed(message: string, cause?: Error): GuillotineError {
    return new GuillotineError('VMCreationFailed', message, cause);
  }

  /**
   * Create a VM not initialized error
   */
  static vmNotInitialized(message: string = 'VM not initialized'): GuillotineError {
    return new GuillotineError('VMNotInitialized', message);
  }

  /**
   * Create an execution error
   */
  static executionFailed(message: string, cause?: Error): GuillotineError {
    return new GuillotineError('ExecutionFailed', message, cause);
  }

  /**
   * Create an invalid bytecode error
   */
  static invalidBytecode(message: string): GuillotineError {
    return new GuillotineError('InvalidBytecode', message);
  }

  /**
   * Create an invalid address error
   */
  static invalidAddress(message: string): GuillotineError {
    return new GuillotineError('InvalidAddress', message);
  }

  /**
   * Create an invalid value error
   */
  static invalidValue(message: string): GuillotineError {
    return new GuillotineError('InvalidValue', message);
  }

  /**
   * Create an out of gas error
   */
  static outOfGas(message: string): GuillotineError {
    return new GuillotineError('OutOfGas', message);
  }

  /**
   * Create a stack overflow error
   */
  static stackOverflow(message: string): GuillotineError {
    return new GuillotineError('StackOverflow', message);
  }

  /**
   * Create a stack underflow error
   */
  static stackUnderflow(message: string): GuillotineError {
    return new GuillotineError('StackUnderflow', message);
  }

  /**
   * Create an invalid jump error
   */
  static invalidJump(message: string): GuillotineError {
    return new GuillotineError('InvalidJump', message);
  }

  /**
   * Create an invalid opcode error
   */
  static invalidOpcode(message: string): GuillotineError {
    return new GuillotineError('InvalidOpcode', message);
  }

  /**
   * Create a memory error
   */
  static memoryError(message: string, cause?: Error): GuillotineError {
    return new GuillotineError('MemoryError', message, cause);
  }

  /**
   * Create a state error
   */
  static stateError(message: string, cause?: Error): GuillotineError {
    return new GuillotineError('StateError', message, cause);
  }

  /**
   * Create an unknown error
   */
  static unknown(message: string, cause?: Error): GuillotineError {
    return new GuillotineError('UnknownError', message, cause);
  }

  /**
   * Convert from error code returned by WASM
   */
  static fromErrorCode(code: number, message?: string): GuillotineError {
    const msg = message || `Error code: ${code}`;
    
    switch (code) {
      case 0:
        return GuillotineError.unknown(msg);
      case 1:
        return GuillotineError.memoryError(msg);
      case 2:
        return GuillotineError.invalidValue(msg);
      case 3:
        return GuillotineError.vmNotInitialized(msg);
      case 4:
        return GuillotineError.executionFailed(msg);
      case 5:
        return GuillotineError.invalidAddress(msg);
      case 6:
        return GuillotineError.invalidBytecode(msg);
      default:
        return GuillotineError.unknown(msg);
    }
  }

  /**
   * JSON serialization
   */
  toJSON(): Record<string, unknown> {
    return {
      name: this.name,
      type: this.type,
      message: this.message,
      stack: this.stack,
      cause: this.cause?.message,
    };
  }
}