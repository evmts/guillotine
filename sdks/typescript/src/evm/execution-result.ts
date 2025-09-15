import { Bytes } from '../primitives/bytes.js';
import { Address } from '../primitives/address.js';
import { U256 } from '../primitives/u256.js';
import type { Jsonified } from '../utils/json-types.js';

/**
 * Log entry from Evm execution
 */
export interface LogEntry {
  address: Address;
  topics: U256[];
  data: Bytes;
}

/**
 * Self-destruct record from Evm execution
 */
export interface SelfDestructRecord {
  contract: Address;
  beneficiary: Address;
}

/**
 * Storage access record from Evm execution
 */
export interface StorageAccessRecord {
  address: Address;
  slot: U256;
}

/**
 * Result of Evm execution
 */
export class ExecutionResult {
  public readonly success: boolean;
  public readonly gasLeft: bigint;
  public readonly output: Bytes;
  public readonly errorMessage: string | null;
  public readonly logs: LogEntry[];
  public readonly selfdestructs: SelfDestructRecord[];
  public readonly accessedAddresses: Address[];
  public readonly accessedStorage: StorageAccessRecord[];
  public readonly createdAddress: Address | null;
  public readonly traceJson: string | null;

  constructor(
    success: boolean,
    gasLeft: bigint,
    output: Bytes,
    errorMessage: string | null = null,
    logs: LogEntry[] = [],
    selfdestructs: SelfDestructRecord[] = [],
    accessedAddresses: Address[] = [],
    accessedStorage: StorageAccessRecord[] = [],
    createdAddress: Address | null = null,
    traceJson: string | null = null
  ) {
    this.success = success;
    this.gasLeft = gasLeft;
    this.output = output;
    this.errorMessage = errorMessage;
    this.logs = logs;
    this.selfdestructs = selfdestructs;
    this.accessedAddresses = accessedAddresses;
    this.accessedStorage = accessedStorage;
    this.createdAddress = createdAddress;
    this.traceJson = traceJson;
  }

  /**
   * Creates a successful execution result
   */
  static success(gasLeft: bigint, output: Bytes = Bytes.empty()): ExecutionResult {
    return new ExecutionResult(true, gasLeft, output);
  }

  /**
   * Creates a failed execution result
   */
  static failure(gasLeft: bigint, errorMessage: string): ExecutionResult {
    return new ExecutionResult(false, gasLeft, Bytes.empty(), errorMessage);
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
   * Returns true if there is output data
   */
  hasOutput(): boolean {
    return !this.output.isEmpty();
  }

  /**
   * Returns true if there is an error message
   */
  hasErrorMessage(): boolean {
    return this.errorMessage !== null;
  }

  /**
   * Returns true if there are logs
   */
  hasLogs(): boolean {
    return this.logs.length > 0;
  }

  /**
   * Returns true if there are self-destructs
   */
  hasSelfDestructs(): boolean {
    return this.selfdestructs.length > 0;
  }

  /**
   * Returns true if a contract was created
   */
  hasCreatedAddress(): boolean {
    return this.createdAddress !== null;
  }

  /**
   * Returns true if there is a trace
   */
  hasTrace(): boolean {
    return this.traceJson !== null;
  }

  /**
   * Returns the gas used
   */
  getGasUsed(gasLimit: bigint): bigint {
    return gasLimit - this.gasLeft;
  }

  /**
   * Returns the output as a string (if it's UTF-8 encoded)
   */
  getOutputString(): string | null {
    if (!this.hasOutput()) {
      return null;
    }
    
    try {
      return this.output.toString();
    } catch {
      return null;
    }
  }

  /**
   * JSON serialization
   */
  toJSON() {
    return {
      success: this.success,
      gasLeft: this.gasLeft.toString(),
      output: this.output.toHex(),
      errorMessage: this.errorMessage,
      logs: this.logs.map(log => ({
        address: log.address.toHex(),
        topics: log.topics.map(t => t.toHex()),
        data: log.data.toHex(),
      })),
      selfdestructs: this.selfdestructs.map(sd => ({
        contract: sd.contract.toHex(),
        beneficiary: sd.beneficiary.toHex(),
      })),
      accessedAddresses: this.accessedAddresses.map(a => a.toHex()),
      accessedStorage: this.accessedStorage.map(s => ({
        address: s.address.toHex(),
        slot: s.slot.toHex(),
      })),
      createdAddress: this.createdAddress?.toHex() ?? null,
      traceJson: this.traceJson,
    };
  }

  /**
   * Create from JSON
   */
  static fromJSON(json: Jsonified<ExecutionResult>): ExecutionResult {
    const logs = (json.logs ?? []).map(log => ({
      address: Address.fromHex(log.address),
      topics: (log.topics ?? []).map(t => U256.fromHex(t)),
      data: Bytes.fromHex(log.data),
    }));

    const selfdestructs = (json.selfdestructs ?? []).map(sd => ({
      contract: Address.fromHex(sd.contract),
      beneficiary: Address.fromHex(sd.beneficiary),
    }));

    const accessedAddresses = (json.accessedAddresses ?? []).map(a => Address.fromHex(a));

    const accessedStorage = (json.accessedStorage ?? []).map(s => ({
      address: Address.fromHex(s.address),
      slot: U256.fromHex(s.slot),
    }));

    return new ExecutionResult(
      json.success,
      BigInt(json.gasLeft),
      Bytes.fromHex(json.output),
      json.errorMessage,
      logs,
      selfdestructs,
      accessedAddresses,
      accessedStorage,
      json.createdAddress ? Address.fromHex(json.createdAddress) : null,
      json.traceJson
    );
  }
}