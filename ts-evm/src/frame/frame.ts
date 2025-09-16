import { createStack, Stack } from '../stack/stack';
import { createMemory, Memory } from '../memory/memory';
import type { Schedule } from '../preprocessor/dispatch';
import type { Address } from '../types_blockchain';
import type { Word } from '../types';
import type { LogEntry } from '../instructions/handlers_log';

export interface Evm {
  // Block context
  getBlockHash?(blockNumber: Word): Word;
  getBlockNumber?(): Word;
  getBlockTimestamp?(): Word;
  getBlockGasLimit?(): Word;
  getBlockDifficulty?(): Word;
  getBlockBaseFee?(): Word;
  getBlockCoinbase?(): Address;
  getBlobBaseFee?(): Word;
  getBlobHash?(index: number): Word;
  
  // Transaction context  
  getTxOrigin?(): Address;
  getGasPrice?(): Word;
  
  // Chain context
  getChainId?(): Word;
  
  // Account state
  getBalance?(address: Address): Word;
  getCode?(address: Address): Uint8Array;
  getCodeHash?(address: Address): Word;
  
  // Storage operations
  getStorageAt?(address: Address, slot: Word): Word;
  setStorageAt?(address: Address, slot: Word, value: Word): void;
}

export interface Frame {
  evm: Evm;
  stack: Stack;
  memory: Memory;
  schedule: Schedule;
  safetyLimit: number;
  
  // Contract context
  contractAddress: Address;
  caller: Address;
  value: Word;
  
  // Data
  calldata: Uint8Array;
  code: Uint8Array;
  returnData: Uint8Array;
  
  // Gas (simplified for now)
  gasRemaining: bigint;
  
  // Logs
  logs?: LogEntry[];
}

export function createFrame(
  evm: Evm, 
  schedule: Schedule, 
  contractAddress: Address,
  caller: Address,
  value: Word = 0n,
  calldata: Uint8Array = new Uint8Array(),
  code: Uint8Array = new Uint8Array(),
  gasLimit: bigint = 30_000_000n,
  safetyLimit = 300_000_000
): Frame {
  return {
    evm,
    stack: createStack(),
    memory: createMemory(),
    schedule,
    safetyLimit,
    contractAddress,
    caller,
    value,
    calldata,
    code,
    returnData: new Uint8Array(),
    gasRemaining: gasLimit
  };
}
