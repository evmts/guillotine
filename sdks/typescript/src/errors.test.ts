import { describe, it, expect } from 'bun:test';
import { GuillotineError } from './errors';

describe('GuillotineError', () => {
  describe('creation', () => {
    it('should create error with type and message', () => {
      const error = new GuillotineError('ExecutionFailed', 'Test error');
      expect(error.type).toBe('ExecutionFailed');
      expect(error.message).toBe('Test error');
      expect(error.name).toBe('GuillotineError');
    });

    it('should create error with cause', () => {
      const cause = new Error('Original error');
      const error = new GuillotineError('ExecutionFailed', 'Test error', cause);
      expect(error.cause).toBe(cause);
    });

    it('should have proper prototype chain', () => {
      const error = new GuillotineError('ExecutionFailed', 'Test error');
      expect(error instanceof GuillotineError).toBe(true);
      expect(error instanceof Error).toBe(true);
    });
  });

  describe('static factory methods', () => {
    it('should create initialization error', () => {
      const error = GuillotineError.initializationFailed('Init failed');
      expect(error.type).toBe('InitializationFailed');
      expect(error.message).toBe('Init failed');
    });

    it('should create WASM load error', () => {
      const error = GuillotineError.wasmLoadFailed('WASM load failed');
      expect(error.type).toBe('WasmLoadFailed');
      expect(error.message).toBe('WASM load failed');
    });

    it('should create WASM not loaded error', () => {
      const error = GuillotineError.wasmNotLoaded();
      expect(error.type).toBe('WasmNotLoaded');
      expect(error.message).toBe('WASM module not loaded');
    });

    it('should create VM creation error', () => {
      const error = GuillotineError.vmCreationFailed('VM creation failed');
      expect(error.type).toBe('VMCreationFailed');
      expect(error.message).toBe('VM creation failed');
    });

    it('should create VM not initialized error', () => {
      const error = GuillotineError.vmNotInitialized();
      expect(error.type).toBe('VMNotInitialized');
      expect(error.message).toBe('VM not initialized');
    });

    it('should create execution error', () => {
      const error = GuillotineError.executionFailed('Execution failed');
      expect(error.type).toBe('ExecutionFailed');
      expect(error.message).toBe('Execution failed');
    });

    it('should create invalid bytecode error', () => {
      const error = GuillotineError.invalidBytecode('Invalid bytecode');
      expect(error.type).toBe('InvalidBytecode');
      expect(error.message).toBe('Invalid bytecode');
    });

    it('should create invalid address error', () => {
      const error = GuillotineError.invalidAddress('Invalid address');
      expect(error.type).toBe('InvalidAddress');
      expect(error.message).toBe('Invalid address');
    });

    it('should create invalid value error', () => {
      const error = GuillotineError.invalidValue('Invalid value');
      expect(error.type).toBe('InvalidValue');
      expect(error.message).toBe('Invalid value');
    });

    it('should create out of gas error', () => {
      const error = GuillotineError.outOfGas('Out of gas');
      expect(error.type).toBe('OutOfGas');
      expect(error.message).toBe('Out of gas');
    });

    it('should create stack overflow error', () => {
      const error = GuillotineError.stackOverflow('Stack overflow');
      expect(error.type).toBe('StackOverflow');
      expect(error.message).toBe('Stack overflow');
    });

    it('should create stack underflow error', () => {
      const error = GuillotineError.stackUnderflow('Stack underflow');
      expect(error.type).toBe('StackUnderflow');
      expect(error.message).toBe('Stack underflow');
    });

    it('should create invalid jump error', () => {
      const error = GuillotineError.invalidJump('Invalid jump');
      expect(error.type).toBe('InvalidJump');
      expect(error.message).toBe('Invalid jump');
    });

    it('should create invalid opcode error', () => {
      const error = GuillotineError.invalidOpcode('Invalid opcode');
      expect(error.type).toBe('InvalidOpcode');
      expect(error.message).toBe('Invalid opcode');
    });

    it('should create memory error', () => {
      const error = GuillotineError.memoryError('Memory error');
      expect(error.type).toBe('MemoryError');
      expect(error.message).toBe('Memory error');
    });

    it('should create state error', () => {
      const error = GuillotineError.stateError('State error');
      expect(error.type).toBe('StateError');
      expect(error.message).toBe('State error');
    });

    it('should create unknown error', () => {
      const error = GuillotineError.unknown('Unknown error');
      expect(error.type).toBe('UnknownError');
      expect(error.message).toBe('Unknown error');
    });
  });

  describe('fromErrorCode', () => {
    it('should convert error codes correctly', () => {
      const cases = [
        { code: 0, type: 'UnknownError' },
        { code: 1, type: 'MemoryError' },
        { code: 2, type: 'InvalidValue' },
        { code: 3, type: 'VMNotInitialized' },
        { code: 4, type: 'ExecutionFailed' },
        { code: 5, type: 'InvalidAddress' },
        { code: 6, type: 'InvalidBytecode' },
        { code: 999, type: 'UnknownError' },
      ] as const;

      cases.forEach(({ code, type }) => {
        const error = GuillotineError.fromErrorCode(code);
        expect(error.type).toBe(type);
        expect(error.message).toContain(`Error code: ${code}`);
      });
    });

    it('should use custom message when provided', () => {
      const error = GuillotineError.fromErrorCode(1, 'Custom message');
      expect(error.type).toBe('MemoryError');
      expect(error.message).toBe('Custom message');
    });
  });

  describe('JSON serialization', () => {
    it('should serialize to JSON correctly', () => {
      const cause = new Error('Original error');
      const error = new GuillotineError('ExecutionFailed', 'Test error', cause);
      
      const json = error.toJSON();
      
      expect(json.name).toBe('GuillotineError');
      expect(json.type).toBe('ExecutionFailed');
      expect(json.message).toBe('Test error');
      expect(json.cause).toBe('Original error');
      expect(json.stack).toBeDefined();
    });

    it('should serialize without cause', () => {
      const error = new GuillotineError('ExecutionFailed', 'Test error');
      
      const json = error.toJSON();
      
      expect(json.cause).toBeUndefined();
    });
  });
});