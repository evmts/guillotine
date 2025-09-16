import type { Handler } from '../types_runtime';
import { InvalidOpcodeError } from '../errors';
import { OPCODES, isPush, getPushSize, isDup, getDupN, isSwap, getSwapN } from '../opcodes/opcodes';
import { bytesToWord } from '../types';
import * as arith from '../instructions/handlers_arithmetic';
import * as bitwise from '../instructions/handlers_bitwise';
import * as comparison from '../instructions/handlers_comparison';
import * as stack from '../instructions/handlers_stack';
import * as memory from '../instructions/handlers_memory';
import * as context from '../instructions/handlers_context';
import * as jump from '../instructions/handlers_jump';
import * as crypto from '../instructions/handlers_crypto';
import * as storage from '../instructions/handlers_storage';
import * as log from '../instructions/handlers_log';
import * as synth from '../instructions/handlers_synthetic';
import * as meta from '../instructions/handlers_meta';
import * as system from '../instructions/handlers_system';
import { analyzeBytecode } from '../bytecode/bytecode_analyze';

export type Item =
  | { kind: 'meta'; gas?: number }
  | { kind: 'handler'; handler: Handler; nextCursor: number; opcode?: number; pc?: number }
  | { kind: 'inline'; data: any }
  | { kind: 'pointer'; index: number };

export interface Schedule {
  items: Item[];
  entry: { handler: Handler; cursor: number };
  pcToCursor: Map<number, number>;
  u256Pool: bigint[];
}

function getHandler(opcode: number): Handler | null {
  switch (opcode) {
    // System
    case OPCODES.STOP: return stack.STOP;
    
    // Arithmetic
    case OPCODES.ADD: return arith.ADD;
    case OPCODES.MUL: return arith.MUL;
    case OPCODES.SUB: return arith.SUB;
    case OPCODES.DIV: return arith.DIV;
    case OPCODES.SDIV: return arith.SDIV;
    case OPCODES.MOD: return arith.MOD;
    case OPCODES.SMOD: return arith.SMOD;
    case OPCODES.ADDMOD: return arith.ADDMOD;
    case OPCODES.MULMOD: return arith.MULMOD;
    case OPCODES.EXP: return arith.EXP;
    case OPCODES.SIGNEXTEND: return arith.SIGNEXTEND;
    
    // Crypto
    case OPCODES.KECCAK256: return crypto.KECCAK256;
    
    // Comparison
    case OPCODES.LT: return comparison.LT;
    case OPCODES.GT: return comparison.GT;
    case OPCODES.SLT: return comparison.SLT;
    case OPCODES.SGT: return comparison.SGT;
    case OPCODES.EQ: return comparison.EQ;
    case OPCODES.ISZERO: return comparison.ISZERO;
    
    // Bitwise
    case OPCODES.AND: return bitwise.AND;
    case OPCODES.OR: return bitwise.OR;
    case OPCODES.XOR: return bitwise.XOR;
    case OPCODES.NOT: return bitwise.NOT;
    case OPCODES.BYTE: return bitwise.BYTE;
    case OPCODES.SHL: return bitwise.SHL;
    case OPCODES.SHR: return bitwise.SHR;
    case OPCODES.SAR: return bitwise.SAR;
    
    // Context
    case OPCODES.ADDRESS: return context.ADDRESS;
    case OPCODES.BALANCE: return context.BALANCE;
    case OPCODES.ORIGIN: return context.ORIGIN;
    case OPCODES.CALLER: return context.CALLER;
    case OPCODES.CALLVALUE: return context.CALLVALUE;
    case OPCODES.CALLDATALOAD: return context.CALLDATALOAD;
    case OPCODES.CALLDATASIZE: return context.CALLDATASIZE;
    case OPCODES.CALLDATACOPY: return memory.CALLDATACOPY;
    case OPCODES.CODESIZE: return context.CODESIZE;
    case OPCODES.CODECOPY: return memory.CODECOPY;
    case OPCODES.GASPRICE: return context.GASPRICE;
    case OPCODES.EXTCODESIZE: return context.EXTCODESIZE;
    case OPCODES.EXTCODECOPY: return context.EXTCODECOPY;
    case OPCODES.RETURNDATASIZE: return context.RETURNDATASIZE;
    case OPCODES.RETURNDATACOPY: return memory.RETURNDATACOPY;
    case OPCODES.EXTCODEHASH: return context.EXTCODEHASH;
    case OPCODES.BLOCKHASH: return context.BLOCKHASH;
    case OPCODES.COINBASE: return context.COINBASE;
    case OPCODES.TIMESTAMP: return context.TIMESTAMP;
    case OPCODES.NUMBER: return context.NUMBER;
    case OPCODES.DIFFICULTY: return context.DIFFICULTY;
    case OPCODES.GASLIMIT: return context.GASLIMIT;
    case OPCODES.CHAINID: return context.CHAINID;
    case OPCODES.SELFBALANCE: return context.SELFBALANCE;
    case OPCODES.BASEFEE: return context.BASEFEE;
    case OPCODES.BLOBHASH: return context.BLOBHASH;
    case OPCODES.BLOBBASEFEE: return context.BLOBBASEFEE;
    
    // Stack
    case OPCODES.POP: return stack.POP;
    case OPCODES.PUSH0: return stack.PUSH0;
    
    // Memory
    case OPCODES.MLOAD: return memory.MLOAD;
    case OPCODES.MSTORE: return memory.MSTORE;
    case OPCODES.MSTORE8: return memory.MSTORE8;
    case OPCODES.MSIZE: return memory.MSIZE;
    case OPCODES.MCOPY: return memory.MCOPY;
    
    // Storage
    case OPCODES.SLOAD: return storage.SLOAD;
    case OPCODES.SSTORE: return storage.SSTORE;
    
    // Jump
    case OPCODES.JUMP: return jump.JUMP;
    case OPCODES.JUMPI: return jump.JUMPI;
    case OPCODES.JUMPDEST: return jump.JUMPDEST;
    
    // PC/GAS
    case OPCODES.PC: return context.PC;
    case OPCODES.GAS: return context.GAS;
    
    // Logs
    case OPCODES.LOG0: return log.LOG0;
    case OPCODES.LOG1: return log.LOG1;
    case OPCODES.LOG2: return log.LOG2;
    case OPCODES.LOG3: return log.LOG3;
    case OPCODES.LOG4: return log.LOG4;
    
    // System
    case OPCODES.RETURN: return system.RETURN;
    
    default:
      if (isPush(opcode)) return stack.PUSH;
      if (isDup(opcode)) return stack.DUP;
      if (isSwap(opcode)) return stack.SWAP;
      return null;
  }
}

export function compile(bytecode: Uint8Array): Schedule | InvalidOpcodeError {
  const items: Item[] = [];
  const handlerIndices: number[] = [];
  const pcToCursor = new Map<number, number>();
  const u256Pool: bigint[] = [];
  const poolIndex = new Map<bigint, number>();

  function poolGetOrAdd(v: bigint): number {
    const found = poolIndex.get(v);
    if (found !== undefined) return found;
    const idx = u256Pool.length;
    u256Pool.push(v);
    poolIndex.set(v, idx);
    return idx;
  }
  
  // Add initial metadata
  items.push({ kind: 'meta', gas: 0 });
  // Analyze bytecode for basic blocks
  const analysis = analyzeBytecode(bytecode);
  const blocks = analysis.basicBlocks;

  let pc = 0;
  const sortedBlocks = blocks.slice().sort((a, b) => a.start - b.start);
  let blockIdx = 0;

  while (pc < bytecode.length) {
    // If at the start of a basic block, insert FIRST_BLOCK_GAS handler
    if (blockIdx < sortedBlocks.length && pc === sortedBlocks[blockIdx].start) {
      const gas = sortedBlocks[blockIdx].gasUsed;
      const handlerIndex = items.length;
      handlerIndices.push(handlerIndex);
      items.push({ kind: 'handler', handler: meta.FIRST_BLOCK_GAS, nextCursor: -1, opcode: undefined, pc: pc });
      items.push({ kind: 'inline', data: { gas } });
      // do not advance pc; meta is schedule-only
      blockIdx++;
    }

    const opcode = bytecode[pc];

    // Prefer longest/most specific patterns first
    // FUNCTION_DISPATCH: PUSH4 <sel> EQ PUSH <dest> JUMPI
    if (opcode === OPCODES.PUSH0 + 4 && pc + 1 + 4 < bytecode.length) { // 0x60 + 4 = 0x64
      const selStart = pc + 1;
      const selEnd = selStart + 4;
      const afterSel = selEnd;
      if (bytecode[afterSel] === OPCODES.EQ) {
        const pushAt = afterSel + 1;
        if (pushAt < bytecode.length && isPush(bytecode[pushAt])) {
          const ps = getPushSize(bytecode[pushAt]);
          const dataStart = pushAt + 1;
          const dataEnd = Math.min(dataStart + ps, bytecode.length);
          if (dataEnd <= bytecode.length && dataEnd < bytecode.length && bytecode[dataEnd] === OPCODES.JUMPI) {
            const selectorBytes = bytecode.slice(selStart, selEnd);
            const selector = bytesToWord(selectorBytes) & 0xffffffffn;
            const destVal = bytesToWord(bytecode.slice(dataStart, dataEnd));
            const handlerIndex = items.length;
            handlerIndices.push(handlerIndex);
            items.push({ kind: 'handler', handler: (synth as any).FUNCTION_DISPATCH, nextCursor: -1, opcode, pc });
            items.push({ kind: 'inline', data: { value: selector, n: 4 } });
            if (ps <= 8) items.push({ kind: 'inline', data: { value: destVal, n: ps } });
            else items.push({ kind: 'pointer', index: poolGetOrAdd(destVal) });
            pc = dataEnd + 1; // consume PUSH4, EQ, PUSH, JUMPI
            continue;
          }
        }
      }
    }

    // ISZERO_JUMPI: ISZERO; PUSHk <target>; JUMPI
    if (opcode === OPCODES.ISZERO) {
      const pushAt = pc + 1;
      if (pushAt < bytecode.length && isPush(bytecode[pushAt])) {
        const ps = getPushSize(bytecode[pushAt]);
        const dataStart = pushAt + 1;
        const dataEnd = Math.min(dataStart + ps, bytecode.length);
        if (dataEnd <= bytecode.length && dataEnd < bytecode.length && bytecode[dataEnd] === OPCODES.JUMPI) {
          const targetVal = bytesToWord(bytecode.slice(dataStart, dataEnd));
          const handlerIndex = items.length;
          handlerIndices.push(handlerIndex);
          items.push({ kind: 'handler', handler: (synth as any).ISZERO_JUMPI, nextCursor: -1, opcode, pc });
          if (ps <= 8) items.push({ kind: 'inline', data: { value: targetVal, n: ps } });
          else items.push({ kind: 'pointer', index: poolGetOrAdd(targetVal) });
          pc = dataEnd + 1; // consume ISZERO, PUSHk, JUMPI
          continue;
        }
      }
    }

    // CALLVALUE_CHECK: CALLVALUE; DUP1; ISZERO
    if (opcode === OPCODES.CALLVALUE && pc + 2 < bytecode.length && bytecode[pc + 1] === OPCODES.POP - 0x30 /* DUP1 0x80 */ && bytecode[pc + 2] === OPCODES.ISZERO) {
      const handlerIndex = items.length;
      handlerIndices.push(handlerIndex);
      items.push({ kind: 'handler', handler: (synth as any).CALLVALUE_CHECK, nextCursor: -1, opcode, pc });
      pc += 3;
      continue;
    }

    // PUSH0_REVERT: PUSH0; PUSH0; REVERT
    if (opcode === OPCODES.PUSH0 && pc + 2 < bytecode.length && bytecode[pc + 1] === OPCODES.PUSH0 && bytecode[pc + 2] === 0xfd) {
      const handlerIndex = items.length;
      handlerIndices.push(handlerIndex);
      items.push({ kind: 'handler', handler: (synth as any).PUSH0_REVERT, nextCursor: -1, opcode, pc });
      pc += 3;
      continue;
    }

    // MLOAD_SWAP1_DUP2: MLOAD; SWAP1; DUP2
    if (opcode === OPCODES.MLOAD && pc + 2 < bytecode.length && bytecode[pc + 1] === 0x90 && bytecode[pc + 2] === 0x81) {
      const handlerIndex = items.length;
      handlerIndices.push(handlerIndex);
      items.push({ kind: 'handler', handler: (synth as any).MLOAD_SWAP1_DUP2, nextCursor: -1, opcode, pc });
      pc += 3;
      continue;
    }

    // DUP3_ADD_MSTORE: DUP3; ADD; MSTORE
    if (opcode === 0x82 && pc + 2 < bytecode.length && bytecode[pc + 1] === OPCODES.ADD && bytecode[pc + 2] === OPCODES.MSTORE) {
      const handlerIndex = items.length;
      handlerIndices.push(handlerIndex);
      items.push({ kind: 'handler', handler: (synth as any).DUP3_ADD_MSTORE, nextCursor: -1, opcode, pc });
      pc += 3;
      continue;
    }

    // SWAP1_DUP2_ADD: SWAP1; DUP2; ADD
    if (opcode === 0x90 && pc + 2 < bytecode.length && bytecode[pc + 1] === 0x81 && bytecode[pc + 2] === OPCODES.ADD) {
      const handlerIndex = items.length;
      handlerIndices.push(handlerIndex);
      items.push({ kind: 'handler', handler: (synth as any).SWAP1_DUP2_ADD, nextCursor: -1, opcode, pc });
      pc += 3;
      continue;
    }

    // DUP2_MSTORE_PUSH: DUP2; MSTORE; PUSHk
    if (opcode === 0x81 && pc + 2 < bytecode.length && bytecode[pc + 1] === OPCODES.MSTORE && isPush(bytecode[pc + 2])) {
      const ps = getPushSize(bytecode[pc + 2]);
      const ds = pc + 3;
      const de = Math.min(ds + ps, bytecode.length);
      const val = bytesToWord(bytecode.slice(ds, de));
      const handlerIndex = items.length;
      handlerIndices.push(handlerIndex);
      items.push({ kind: 'handler', handler: (synth as any).DUP2_MSTORE_PUSH, nextCursor: -1, opcode, pc });
      if (ps <= 8) items.push({ kind: 'inline', data: { value: val, n: ps } });
      else items.push({ kind: 'pointer', index: poolGetOrAdd(val) });
      pc = de;
      continue;
    }

    // PUSH_DUP3_ADD: PUSHk; DUP3; ADD
    if (isPush(opcode)) {
      const ps = getPushSize(opcode);
      const ds = pc + 1;
      const de = Math.min(ds + ps, bytecode.length);
      const after = de;
      if (after + 1 < bytecode.length && bytecode[after] === 0x82 && bytecode[after + 1] === OPCODES.ADD) {
        const val = bytesToWord(bytecode.slice(ds, de));
        const handlerIndex = items.length;
        handlerIndices.push(handlerIndex);
        items.push({ kind: 'handler', handler: (synth as any).PUSH_DUP3_ADD, nextCursor: -1, opcode, pc });
        if (ps <= 8) items.push({ kind: 'inline', data: { value: val, n: ps } });
        else items.push({ kind: 'pointer', index: poolGetOrAdd(val) });
        pc = after + 2;
        continue;
      }
    }

    // MULTI_PUSH fusion: try for 3, then 2
    if (isPush(opcode)) {
      const startPc = pc;
      const values: { value: bigint; size: number }[] = [];
      let lookPc = pc;
      for (let k = 0; k < 3; k++) {
        if (!isPush(bytecode[lookPc])) break;
        const sz = getPushSize(bytecode[lookPc]);
        const ds = lookPc + 1;
        const de = Math.min(ds + sz, bytecode.length);
        const imm = bytesToWord(bytecode.slice(ds, de));
        values.push({ value: imm, size: sz });
        lookPc = de;
      }
      if (values.length === 3) {
        const handlerIndex = items.length;
        handlerIndices.push(handlerIndex);
        items.push({ kind: 'handler', handler: synth.MULTI_PUSH_3, nextCursor: -1, opcode, pc: startPc });
        for (const v of values) {
          if (v.size <= 8) items.push({ kind: 'inline', data: { value: v.value, n: v.size } });
          else items.push({ kind: 'pointer', index: poolGetOrAdd(v.value) });
        }
        pc = lookPc; // consumed 3 pushes
        continue;
      } else if (values.length === 2) {
        const handlerIndex = items.length;
        handlerIndices.push(handlerIndex);
        items.push({ kind: 'handler', handler: synth.MULTI_PUSH_2, nextCursor: -1, opcode, pc: startPc });
        for (const v of values) {
          if (v.size <= 8) items.push({ kind: 'inline', data: { value: v.value, n: v.size } });
          else items.push({ kind: 'pointer', index: poolGetOrAdd(v.value) });
        }
        pc = lookPc; // consumed 2 pushes
        continue;
      }
    }

    // FUSION: ISZERO + PUSH <dest> + JUMPI
    if (opcode === OPCODES.ISZERO) {
      const op1 = bytecode[pc + 1];
      if (op1 !== undefined && isPush(op1)) {
        const pushSize = getPushSize(op1);
        const dataStart = pc + 2;
        const dataEnd = Math.min(dataStart + pushSize, bytecode.length);
        if (dataEnd <= bytecode.length) {
          const nextPc = pc + 2 + pushSize;
          const op2 = bytecode[nextPc];
          if (op2 === OPCODES.JUMPI) {
            const immediateBytes = bytecode.slice(dataStart, dataEnd);
            const paddedBytes = new Uint8Array(pushSize);
            paddedBytes.set(immediateBytes);
            const value = bytesToWord(paddedBytes);
            const handlerIndex = items.length;
            handlerIndices.push(handlerIndex);
            items.push({ kind: 'handler', handler: (synth as any).ISZERO_JUMPI, nextCursor: -1, opcode: OPCODES.JUMPI, pc: nextPc });
            if (pushSize <= 8) {
              items.push({ kind: 'inline', data: { value, n: pushSize } });
            } else {
              const idx = poolGetOrAdd(value);
              items.push({ kind: 'pointer', index: idx });
            }
            pc = nextPc + 1;
            continue;
          }
        }
      }
    }

    // FUSION: PUSH <imm> + (ADD|SUB|MUL|DIV|AND|OR|XOR)
    if (isPush(opcode)) {
      const pushSize = getPushSize(opcode);
      const dataStart = pc + 1;
      const dataEnd = Math.min(dataStart + pushSize, bytecode.length);
      const immediateBytes = bytecode.slice(dataStart, dataEnd);
      const paddedBytes = new Uint8Array(pushSize);
      paddedBytes.set(immediateBytes);
      const value = bytesToWord(paddedBytes);

      const nextPc = pc + 1 + pushSize;
      const nextOpcode = nextPc < bytecode.length ? bytecode[nextPc] : undefined;

      if (
        nextOpcode === OPCODES.ADD ||
        nextOpcode === OPCODES.SUB ||
        nextOpcode === OPCODES.MUL ||
        nextOpcode === OPCODES.DIV ||
        nextOpcode === OPCODES.AND ||
        nextOpcode === OPCODES.OR  ||
        nextOpcode === OPCODES.XOR
      ) {
        const handlerIndex = items.length;
        handlerIndices.push(handlerIndex);
        const fusedHandler =
          nextOpcode === OPCODES.ADD ? synth.PUSH_ADD_INLINE :
          nextOpcode === OPCODES.SUB ? synth.PUSH_SUB_INLINE :
          nextOpcode === OPCODES.MUL ? synth.PUSH_MUL_INLINE :
          nextOpcode === OPCODES.DIV ? synth.PUSH_DIV_INLINE :
          nextOpcode === OPCODES.AND ? (synth as any).PUSH_AND_INLINE :
          nextOpcode === OPCODES.OR  ? (synth as any).PUSH_OR_INLINE :
          (synth as any).PUSH_XOR_INLINE;
        items.push({ kind: 'handler', handler: fusedHandler, nextCursor: -1, opcode: nextOpcode, pc: nextPc });
        if (pushSize <= 8) {
          items.push({ kind: 'inline', data: { value, n: pushSize } });
        } else {
          const idx = poolGetOrAdd(value);
          items.push({ kind: 'pointer', index: idx });
        }
        pc = nextPc + 1;
        continue;
      }

      // FUSION: PUSH <imm> + (JUMP|JUMPI)
      if (nextOpcode === OPCODES.JUMP || nextOpcode === OPCODES.JUMPI) {
        const handlerIndex = items.length;
        handlerIndices.push(handlerIndex);
        const fusedHandler = nextOpcode === OPCODES.JUMP ? synth.PUSH_JUMP_INLINE : synth.PUSH_JUMPI_INLINE;
        items.push({ kind: 'handler', handler: fusedHandler, nextCursor: -1, opcode: nextOpcode, pc: nextPc });
        if (pushSize <= 8) {
          items.push({ kind: 'inline', data: { value, n: pushSize } });
        } else {
          const idx = poolGetOrAdd(value);
          items.push({ kind: 'pointer', index: idx });
        }
        pc = nextPc + 1;
        continue;
      }

      // FUSION: PUSH <imm> + (MLOAD|MSTORE|MSTORE8)
      if (
        nextOpcode === OPCODES.MLOAD ||
        nextOpcode === OPCODES.MSTORE ||
        nextOpcode === OPCODES.MSTORE8
      ) {
        const handlerIndex = items.length;
        handlerIndices.push(handlerIndex);
        const fusedHandler =
          nextOpcode === OPCODES.MLOAD ? synth.PUSH_MLOAD_INLINE :
          nextOpcode === OPCODES.MSTORE ? synth.PUSH_MSTORE_INLINE :
          synth.PUSH_MSTORE8_INLINE;
        items.push({ kind: 'handler', handler: fusedHandler, nextCursor: -1, opcode: nextOpcode, pc });
        if (pushSize <= 8) {
          items.push({ kind: 'inline', data: { value, n: pushSize } });
        } else {
          const idx = poolGetOrAdd(value);
          items.push({ kind: 'pointer', index: idx });
        }
        pc = nextPc + 1;
        continue;
      }

      // Plain PUSH case
      const pushHandler = getHandler(opcode);
      if (!pushHandler) return new InvalidOpcodeError(opcode);
      const handlerIndex = items.length;
      handlerIndices.push(handlerIndex);
      items.push({ kind: 'handler', handler: pushHandler, nextCursor: -1, opcode, pc });
      if (pushSize <= 8) {
        items.push({ kind: 'inline', data: { value, n: pushSize } });
      } else {
        const idx = poolGetOrAdd(value);
        items.push({ kind: 'pointer', index: idx });
      }
      pc += pushSize + 1;
      continue;
    }

    // Non-PUSH path
    // FUSION: DUP2 + MSTORE + PUSH <imm>
    if (opcode === 0x81 /* DUP2 */) {
      const op1 = bytecode[pc + 1];
      if (op1 === OPCODES.MSTORE) {
        const op2 = bytecode[pc + 2];
        if (op2 !== undefined && isPush(op2)) {
          const pushSize = getPushSize(op2);
          const dataStart = pc + 3;
          const dataEnd = Math.min(dataStart + pushSize, bytecode.length);
          if (dataEnd <= bytecode.length) {
            const immediateBytes = bytecode.slice(dataStart, dataEnd);
            const paddedBytes = new Uint8Array(pushSize);
            paddedBytes.set(immediateBytes);
            const value = bytesToWord(paddedBytes);
            const handlerIndex = items.length;
            handlerIndices.push(handlerIndex);
            items.push({ kind: 'handler', handler: (synth as any).DUP2_MSTORE_PUSH, nextCursor: -1, opcode: OPCODES.MSTORE, pc: pc + 1 });
            if (pushSize <= 8) {
              items.push({ kind: 'inline', data: { value, n: pushSize } });
            } else {
              const idx = poolGetOrAdd(value);
              items.push({ kind: 'pointer', index: idx });
            }
            pc = dataStart + pushSize;
            continue;
          }
        }
      }
    }

    const handler = getHandler(opcode);
    if (!handler) return new InvalidOpcodeError(opcode);
    const handlerIndex = items.length;
    handlerIndices.push(handlerIndex);
    items.push({ kind: 'handler', handler, nextCursor: -1, opcode, pc });

    // Record jumpdest pc to cursor mapping for fast JUMP/JUMPI
    if (opcode === OPCODES.JUMPDEST) {
      pcToCursor.set(pc, handlerIndex);
    }

    if (isDup(opcode)) {
      const n = getDupN(opcode);
      items.push({ kind: 'inline', data: { n } });
    } else if (isSwap(opcode)) {
      const n = getSwapN(opcode);
      items.push({ kind: 'inline', data: { n } });
    }
    pc++;
  }
  
  // Add two terminal STOP handlers for parity with Zig
  for (let k = 0; k < 2; k++) {
    const terminalIndex = items.length;
    handlerIndices.push(terminalIndex);
    items.push({
      kind: 'handler',
      handler: stack.STOP,
      nextCursor: -1,
      opcode: OPCODES.STOP
    });
  }
  
  // Update nextCursor for each handler
  for (let i = 0; i < handlerIndices.length - 1; i++) {
    const currentIdx = handlerIndices[i];
    const nextIdx = handlerIndices[i + 1];
    const item = items[currentIdx];
    if (item.kind === 'handler') {
      item.nextCursor = nextIdx;
    }
  }
  
  // Find first handler
  const firstHandlerIdx = handlerIndices[0];
  const firstHandler = items[firstHandlerIdx] as { kind: 'handler'; handler: Handler };
  
  return {
    items,
    entry: {
      handler: firstHandler.handler,
      cursor: firstHandlerIdx
    },
    pcToCursor,
    u256Pool
  };
}
