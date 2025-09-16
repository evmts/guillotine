import type { Frame } from '../frame/frame';
import { ErrorUnion } from '../errors';
import type { Tail } from '../types_runtime';
import type { Word } from '../types';
import type { Address } from '../types_blockchain';
import { Database } from '../storage/database';
import { AccessList } from '../storage/access_list';
import { Journal } from '../storage/journal';
import { stackPop } from '../stack/stack';
import { getSlice } from '../memory/memory';
import type { ReturnData } from '../frame/call_result';
import { next } from '../interpreter';
import * as crypto from 'crypto';

// System operations for calls, creates, and contract management

// Gas constants
const GAS_CONSTANTS = {
  CALL_GAS: 700,
  CALL_VALUE_TRANSFER_GAS: 9000,
  CALL_NEW_ACCOUNT_GAS: 25000,
  CREATE_GAS: 32000,
  CREATE2_GAS: 32000,
  SELFDESTRUCT_GAS: 5000,
  SELFDESTRUCT_NEW_ACCOUNT_GAS: 25000,
  MAX_CALL_DEPTH: 1024
} as const;

// Extended Frame interface for system operations
export interface FrameWithSystem extends Frame {
  database?: Database;
  accessList?: AccessList;
  journal?: Journal;
  isStatic?: boolean;
  depth?: number;
  createdContracts?: Set<string>;
}

export interface CallParams {
  gas: bigint;
  to: Address;
  value: Word;
  input: Uint8Array;
  caller: Address;
  isStatic: boolean;
}

export interface CallResult {
  success: boolean;
  output: Uint8Array;
  gasUsed: bigint;
}

// RETURN (0xf3) - Return output from memory
export function RETURN(frame: Frame, cursor: number): Tail {
  const offset = stackPop(frame.stack);
  if (offset instanceof Error) return offset;
  const size = stackPop(frame.stack);
  if (size instanceof Error) return size;
  
  if ((offset as Word) > BigInt(Number.MAX_SAFE_INTEGER) || 
      (size as Word) > BigInt(Number.MAX_SAFE_INTEGER)) {
    return { data: new Uint8Array() } as ReturnData;
  }
  
  const data = getSlice(frame.memory, Number(offset as Word), Number(size as Word));
  if (data instanceof Error) return data;
  
  return { data: data as Uint8Array } as ReturnData;
}

// CALL (0xf1) - Message call to another contract
export function call(frame: FrameWithSystem, _cursor: DispatchItem[]): ErrorUnion | null {
  if (frame.stack.size() < 7) {
    return createError('StackUnderflow', 'CALL requires 7 stack items');
  }
  
  const gas = frame.stack.pop();
  const to = frame.stack.pop();
  const value = frame.stack.pop();
  const inputOffset = frame.stack.pop();
  const inputSize = frame.stack.pop();
  const outputOffset = frame.stack.pop();
  const outputSize = frame.stack.pop();
  
  // Check for static call violation
  if (frame.isStatic && value !== 0n) {
    return createError('StaticCallViolation', 'Cannot transfer value in static call');
  }
  
  // Check call depth
  if ((frame.depth || 0) >= GAS_CONSTANTS.MAX_CALL_DEPTH) {
    // Call fails but doesn't error - push 0 for failure
    frame.stack.push(0n);
    return null;
  }
  
  // Calculate gas cost
  let gasCost = BigInt(GAS_CONSTANTS.CALL_GAS);
  if (value !== 0n) {
    gasCost += BigInt(GAS_CONSTANTS.CALL_VALUE_TRANSFER_GAS);
    // Check if account exists
    if (frame.database && !frame.database.accountExists(to)) {
      gasCost += BigInt(GAS_CONSTANTS.CALL_NEW_ACCOUNT_GAS);
    }
  }
  
  // Access list gas (EIP-2929)
  if (frame.accessList) {
    gasCost += BigInt(frame.accessList.accessAccount(to));
  }
  
  // Check gas
  if (frame.gasRemaining < gasCost) {
    return createError('OutOfGas', `CALL requires ${gasCost} gas`);
  }
  
  // Get input data from memory
  const input = frame.memory.readSlice(Number(inputOffset), Number(inputSize));
  if (input instanceof Error) {
    return createError('MemoryError', input.message);
  }
  
  // Calculate gas to forward (63/64 rule)
  const gasToForward = calculateForwardGas(frame.gasRemaining - gasCost, gas);
  frame.gasRemaining -= gasCost + gasToForward;
  
  // This would normally make a nested call to the EVM
  // For now, we'll simulate a successful empty call
  const output = new Uint8Array();
  const success = true;
  
  // Write output to memory
  if (outputSize > 0n) {
    const writeResult = frame.memory.writeSlice(Number(outputOffset), output);
    if (writeResult instanceof Error) {
      return createError('MemoryError', writeResult.message);
    }
  }
  
  // Store return data
  frame.returnData = output;
  
  // Push success (1) or failure (0)
  frame.stack.push(success ? 1n : 0n);
  
  return null;
}

// CALLCODE (0xf2) - Message call with code of another contract
export function callcode(frame: FrameWithSystem, _cursor: DispatchItem[]): ErrorUnion | null {
  if (frame.stack.size() < 7) {
    return createError('StackUnderflow', 'CALLCODE requires 7 stack items');
  }
  
  // Similar to CALL but executes in current context
  const gas = frame.stack.pop();
  const to = frame.stack.pop();
  const value = frame.stack.pop();
  const inputOffset = frame.stack.pop();
  const inputSize = frame.stack.pop();
  const outputOffset = frame.stack.pop();
  const outputSize = frame.stack.pop();
  
  // Implementation similar to CALL but with different context
  // For now, push success
  frame.stack.push(1n);
  
  return null;
}

// DELEGATECALL (0xf4) - Message call preserving caller and value
export function delegatecall(frame: FrameWithSystem, _cursor: DispatchItem[]): ErrorUnion | null {
  if (frame.stack.size() < 6) {
    return createError('StackUnderflow', 'DELEGATECALL requires 6 stack items');
  }
  
  const gas = frame.stack.pop();
  const to = frame.stack.pop();
  const inputOffset = frame.stack.pop();
  const inputSize = frame.stack.pop();
  const outputOffset = frame.stack.pop();
  const outputSize = frame.stack.pop();
  
  // DELEGATECALL preserves msg.sender and msg.value from current context
  // For now, push success
  frame.stack.push(1n);
  
  return null;
}

// STATICCALL (0xfa) - Static message call
export function staticcall(frame: FrameWithSystem, _cursor: DispatchItem[]): ErrorUnion | null {
  if (frame.stack.size() < 6) {
    return createError('StackUnderflow', 'STATICCALL requires 6 stack items');
  }
  
  const gas = frame.stack.pop();
  const to = frame.stack.pop();
  const inputOffset = frame.stack.pop();
  const inputSize = frame.stack.pop();
  const outputOffset = frame.stack.pop();
  const outputSize = frame.stack.pop();
  
  // STATICCALL enforces no state changes in called contract
  // For now, push success
  frame.stack.push(1n);
  
  return null;
}

// CREATE (0xf0) - Create a new contract
export function create(frame: FrameWithSystem, _cursor: DispatchItem[]): ErrorUnion | null {
  if (frame.stack.size() < 3) {
    return createError('StackUnderflow', 'CREATE requires 3 stack items');
  }
  
  const value = frame.stack.pop();
  const offset = frame.stack.pop();
  const size = frame.stack.pop();
  
  // Check for static call violation
  if (frame.isStatic) {
    return createError('StaticCallViolation', 'CREATE not allowed in static call');
  }
  
  // Check call depth
  if ((frame.depth || 0) >= GAS_CONSTANTS.MAX_CALL_DEPTH) {
    // Creation fails - push 0 address
    frame.stack.push(0n);
    return null;
  }
  
  // Calculate gas cost
  const gasCost = BigInt(GAS_CONSTANTS.CREATE_GAS);
  if (frame.gasRemaining < gasCost) {
    return createError('OutOfGas', `CREATE requires ${gasCost} gas`);
  }
  frame.gasRemaining -= gasCost;
  
  // Get init code from memory
  const initCode = frame.memory.readSlice(Number(offset), Number(size));
  if (initCode instanceof Error) {
    return createError('MemoryError', initCode.message);
  }
  
  // Calculate contract address
  const nonce = frame.database ? frame.database.getNonce(frame.contractAddress) : 0n;
  const newAddress = calculateCreateAddress(frame.contractAddress, nonce);
  
  // Record contract creation
  if (frame.createdContracts) {
    frame.createdContracts.add(newAddress.toString());
  }
  if (frame.journal) {
    frame.journal.recordContractCreation(newAddress, new Uint8Array());
  }
  
  // Push new contract address
  frame.stack.push(newAddress);
  
  return null;
}

// CREATE2 (0xf5) - Create a new contract with deterministic address
export function create2(frame: FrameWithSystem, _cursor: DispatchItem[]): ErrorUnion | null {
  if (frame.stack.size() < 4) {
    return createError('StackUnderflow', 'CREATE2 requires 4 stack items');
  }
  
  const value = frame.stack.pop();
  const offset = frame.stack.pop();
  const size = frame.stack.pop();
  const salt = frame.stack.pop();
  
  // Check for static call violation
  if (frame.isStatic) {
    return createError('StaticCallViolation', 'CREATE2 not allowed in static call');
  }
  
  // Check call depth
  if ((frame.depth || 0) >= GAS_CONSTANTS.MAX_CALL_DEPTH) {
    // Creation fails - push 0 address
    frame.stack.push(0n);
    return null;
  }
  
  // Calculate gas cost (includes hashing cost)
  const gasCost = BigInt(GAS_CONSTANTS.CREATE2_GAS) + (BigInt(size) * 6n) / 32n;
  if (frame.gasRemaining < gasCost) {
    return createError('OutOfGas', `CREATE2 requires ${gasCost} gas`);
  }
  frame.gasRemaining -= gasCost;
  
  // Get init code from memory
  const initCode = frame.memory.readSlice(Number(offset), Number(size));
  if (initCode instanceof Error) {
    return createError('MemoryError', initCode.message);
  }
  
  // Calculate contract address
  const newAddress = calculateCreate2Address(frame.contractAddress, salt, initCode);
  
  // Record contract creation
  if (frame.createdContracts) {
    frame.createdContracts.add(newAddress.toString());
  }
  if (frame.journal) {
    frame.journal.recordContractCreation(newAddress, new Uint8Array());
  }
  
  // Push new contract address
  frame.stack.push(newAddress);
  
  return null;
}

// SELFDESTRUCT (0xff) - Destroy contract and send funds
export function selfdestruct(frame: FrameWithSystem, _cursor: DispatchItem[]): ErrorUnion | null {
  if (frame.stack.size() < 1) {
    return createError('StackUnderflow', 'SELFDESTRUCT requires 1 stack item');
  }
  
  const beneficiary = frame.stack.pop();
  
  // Check for static call violation
  if (frame.isStatic) {
    return createError('StaticCallViolation', 'SELFDESTRUCT not allowed in static call');
  }
  
  // Calculate gas cost
  let gasCost = BigInt(GAS_CONSTANTS.SELFDESTRUCT_GAS);
  if (frame.database && !frame.database.accountExists(beneficiary)) {
    gasCost += BigInt(GAS_CONSTANTS.SELFDESTRUCT_NEW_ACCOUNT_GAS);
  }
  
  // Access list gas (EIP-2929)
  if (frame.accessList) {
    gasCost += BigInt(frame.accessList.accessAccount(beneficiary));
  }
  
  // Check gas
  if (frame.gasRemaining < gasCost) {
    return createError('OutOfGas', `SELFDESTRUCT requires ${gasCost} gas`);
  }
  frame.gasRemaining -= gasCost;
  
  // Get balance to transfer
  const balance = frame.database ? frame.database.getBalance(frame.contractAddress) : 0n;
  
  // Record self-destruct
  if (frame.journal) {
    frame.journal.recordSelfDestruct(frame.contractAddress, beneficiary, balance);
  }
  
  // Transfer balance
  if (frame.database && balance > 0n) {
    frame.database.transferBalance(frame.contractAddress, beneficiary, balance);
  }
  
  // EIP-6780: Only delete if created in same transaction
  if (frame.createdContracts?.has(frame.contractAddress.toString())) {
    // Actually delete the account
    if (frame.database) {
      frame.database.setCode(frame.contractAddress, new Uint8Array());
      frame.database.setNonce(frame.contractAddress, 0n);
    }
  }
  
  return null;
}

// RETURN (0xf3) - Halt and return output
export function return_(frame: Frame, _cursor: DispatchItem[]): ErrorUnion | null {
  if (frame.stack.size() < 2) {
    return createError('StackUnderflow', 'RETURN requires 2 stack items');
  }
  
  const offset = frame.stack.pop();
  const size = frame.stack.pop();
  
  // Get return data from memory
  const returnData = frame.memory.readSlice(Number(offset), Number(size));
  if (returnData instanceof Error) {
    return createError('MemoryError', returnData.message);
  }
  
  frame.returnData = returnData;
  
  // Return indicates successful completion
  return null;
}

// REVERT (0xfd) - Halt and revert state changes
export function revert(frame: Frame, _cursor: DispatchItem[]): ErrorUnion | null {
  if (frame.stack.size() < 2) {
    return createError('StackUnderflow', 'REVERT requires 2 stack items');
  }
  
  const offset = frame.stack.pop();
  const size = frame.stack.pop();
  
  // Get revert data from memory
  const revertData = frame.memory.readSlice(Number(offset), Number(size));
  if (revertData instanceof Error) {
    return createError('MemoryError', revertData.message);
  }
  
  frame.returnData = revertData;
  
  // Return revert error
  return createError('RevertExecution', 'Execution reverted');
}

// STOP (0x00) - Halt execution
export function stop(_frame: Frame, _cursor: DispatchItem[]): ErrorUnion | null {
  // STOP indicates successful completion with empty output
  return null;
}

// INVALID (0xfe) - Invalid opcode
export function invalid(_frame: Frame, _cursor: DispatchItem[]): ErrorUnion | null {
  return createError('InvalidOpcode', 'Invalid opcode executed');
}

// Helper functions

function calculateForwardGas(availableGas: bigint, requestedGas: bigint): bigint {
  // EIP-150: 63/64 rule for gas forwarding
  const maxForward = availableGas - (availableGas / 64n);
  return requestedGas < maxForward ? requestedGas : maxForward;
}

function calculateCreateAddress(deployer: Address, nonce: bigint): Address {
  // RLP encode [deployer, nonce] and hash
  // Simplified implementation using SHA256 as placeholder
  const hash = crypto.createHash('sha256');
  hash.update(deployer.toString());
  hash.update(nonce.toString());
  const bytes = hash.digest();
  
  // Take last 20 bytes for address
  let address = 0n;
  for (let i = 12; i < 32; i++) {
    address = (address << 8n) | BigInt(bytes[i]);
  }
  return address;
}

function calculateCreate2Address(deployer: Address, salt: Word, initCode: Uint8Array): Address {
  // keccak256(0xff ++ deployer ++ salt ++ keccak256(init_code))
  // Simplified implementation using SHA256 as placeholder
  const hash = crypto.createHash('sha256');
  hash.update(new Uint8Array([0xff]));
  hash.update(deployer.toString());
  hash.update(salt.toString());
  hash.update(initCode);
  const bytes = hash.digest();
  
  // Take last 20 bytes for address
  let address = 0n;
  for (let i = 12; i < 32; i++) {
    address = (address << 8n) | BigInt(bytes[i]);
  }
  return address;
}
