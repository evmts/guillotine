import { Bytes } from '../primitives/bytes.js';

/**
 * Result of EVM execution
 */
export class ExecutionResult {
  public readonly success: boolean;
  public readonly gasUsed: bigint;
  public readonly returnData: Bytes;
  public readonly revertReason: Bytes;

  constructor(success: boolean, gasUsed: bigint, returnData: Bytes, revertReason: Bytes) {
    this.success = success;
    this.gasUsed = gasUsed;
    this.returnData = returnData;
    this.revertReason = revertReason;
  }

  /**
   * Creates a successful execution result
   * TODO: we probably don't want these exposed as exported ExecutionResult so probably need a better type for this
  */
  static success(gasUsed: bigint, returnData: Bytes = Bytes.empty()): ExecutionResult {
    return new ExecutionResult(true, gasUsed, returnData, Bytes.empty());
  }

  /**
   * Creates a failed execution result
   */
  static failure(gasUsed: bigint, revertReason: Bytes = Bytes.empty()): ExecutionResult {
    return new ExecutionResult(false, gasUsed, Bytes.empty(), revertReason);
  }

  /**
   * Returns true if execution was successful
   */
  isSuccess(): boolean {
    return this.success;
  }

  /**
   * Returns true if execution failed
   */
  isFailure(): boolean {
    return !this.success;
  }

  /**
   * Returns true if there is return data
   */
  hasReturnData(): boolean {
    return !this.returnData.isEmpty();
  }

  /**
   * Returns true if there is a revert reason
   */
  hasRevertReason(): boolean {
    return !this.revertReason.isEmpty();
  }

  /**
   * Returns the revert reason as a string (if it's UTF-8 encoded)
   */
  getRevertReasonString(): string | null {
    if (!this.hasRevertReason()) {
      return null;
    }
    
    try {
      return this.revertReason.toString();
    } catch {
      return null;
    }
  }

  /**
   * Returns the return data as a string (if it's UTF-8 encoded)
   */
  getReturnDataString(): string | null {
    if (!this.hasReturnData()) {
      return null;
    }
    
    try {
      return this.returnData.toString();
    } catch {
      return null;
    }
  }

  /**
   * JSON serialization
   */
  toJSON(): Record<string, unknown> {
    return {
      success: this.success,
      gasUsed: this.gasUsed.toString(),
      returnData: this.returnData.toHex(),
      revertReason: this.revertReason.toHex(),
    };
  }

  /**
   * Create from JSON
   */
  static fromJSON(json: Record<string, unknown>): ExecutionResult {
    return new ExecutionResult(
      json.success as boolean,
      BigInt(json.gasUsed as string),
      Bytes.fromHex(json.returnData as string),
      Bytes.fromHex(json.revertReason as string)
    );
  }
}