import { Word, u256 } from '../types';
import { stackPeek, stackSetTop, stackPop, stackPush } from '../stack/stack';
import { next } from '../interpreter';
import type { Frame } from '../frame/frame';
import type { Tail } from '../types_runtime';
import { ScheduleError } from '../errors';
import { getU256Evm, setU256, setByte } from '../memory/memory';
import { InvalidJumpError } from '../errors';

// Helper to fetch inline metadata value from schedule
function getConstValue(f: Frame, cursor: number): Word | ScheduleError {
  const meta = f.schedule.items[cursor + 1] as any;
  if (!meta) return new ScheduleError('missing metadata');
  if (meta.kind === 'inline') return meta.data.value as Word;
  if (meta.kind === 'pointer') {
    const idx: number = meta.index;
    return f.schedule.u256Pool[idx] as Word;
  }
  return new ScheduleError('invalid metadata kind');
}

// PUSH_ADD_INLINE: Replace TOS with TOS + value
export function PUSH_ADD_INLINE(f: Frame, cursor: number): Tail {
  const value = getConstValue(f, cursor);
  if (value instanceof Error) return value;
  const top = stackPeek(f.stack);
  if (top instanceof Error) return top;
  const r = u256((top as Word) + (value as Word));
  const e = stackSetTop(f.stack, r);
  if (e instanceof Error) return e;
  return next(f, cursor);
}

// PUSH_SUB_INLINE: Replace TOS with TOS - value
export function PUSH_SUB_INLINE(f: Frame, cursor: number): Tail {
  const value = getConstValue(f, cursor);
  if (value instanceof Error) return value;
  const top = stackPeek(f.stack);
  if (top instanceof Error) return top;
  const r = u256((top as Word) - (value as Word));
  const e = stackSetTop(f.stack, r);
  if (e instanceof Error) return e;
  return next(f, cursor);
}

// PUSH_MUL_INLINE: Replace TOS with TOS * value
export function PUSH_MUL_INLINE(f: Frame, cursor: number): Tail {
  const value = getConstValue(f, cursor);
  if (value instanceof Error) return value;
  const top = stackPeek(f.stack);
  if (top instanceof Error) return top;
  const r = u256((top as Word) * (value as Word));
  const e = stackSetTop(f.stack, r);
  if (e instanceof Error) return e;
  return next(f, cursor);
}

// PUSH_DIV_INLINE: Replace TOS with TOS / value (0 ⇒ 0)
export function PUSH_DIV_INLINE(f: Frame, cursor: number): Tail {
  const value = getConstValue(f, cursor);
  if (value instanceof Error) return value;
  const top = stackPeek(f.stack);
  if (top instanceof Error) return top;
  const denom = value as Word;
  const r = denom === 0n ? 0n : u256((top as Word) / denom);
  const e = stackSetTop(f.stack, r);
  if (e instanceof Error) return e;
  return next(f, cursor);
}

// PUSH_AND_INLINE: Replace TOS with TOS & value
export function PUSH_AND_INLINE(f: Frame, cursor: number): Tail {
  const value = getConstValue(f, cursor);
  if (value instanceof Error) return value;
  const top = stackPeek(f.stack);
  if (top instanceof Error) return top;
  const r = u256((top as Word) & (value as Word));
  const e = stackSetTop(f.stack, r);
  if (e instanceof Error) return e;
  return next(f, cursor);
}

// PUSH_OR_INLINE: Replace TOS with TOS | value
export function PUSH_OR_INLINE(f: Frame, cursor: number): Tail {
  const value = getConstValue(f, cursor);
  if (value instanceof Error) return value;
  const top = stackPeek(f.stack);
  if (top instanceof Error) return top;
  const r = u256((top as Word) | (value as Word));
  const e = stackSetTop(f.stack, r);
  if (e instanceof Error) return e;
  return next(f, cursor);
}

// PUSH_XOR_INLINE: Replace TOS with TOS ^ value
export function PUSH_XOR_INLINE(f: Frame, cursor: number): Tail {
  const value = getConstValue(f, cursor);
  if (value instanceof Error) return value;
  const top = stackPeek(f.stack);
  if (top instanceof Error) return top;
  const r = u256((top as Word) ^ (value as Word));
  const e = stackSetTop(f.stack, r);
  if (e instanceof Error) return e;
  return next(f, cursor);
}

// PUSH_MLOAD_INLINE: Push memory word at constant offset
export function PUSH_MLOAD_INLINE(f: Frame, cursor: number): Tail {
  const offset = getConstValue(f, cursor);
  if (offset instanceof Error) return offset;
  if ((offset as Word) > BigInt(Number.MAX_SAFE_INTEGER)) {
    return new ScheduleError('mload offset too large');
  }
  const v = getU256Evm(f.memory, Number(offset));
  if (v instanceof Error) return v;
  const e = stackPush(f.stack, v as Word);
  if (e instanceof Error) return e;
  return next(f, cursor);
}

// PUSH_MSTORE_INLINE: Store TOS to memory at constant offset
export function PUSH_MSTORE_INLINE(f: Frame, cursor: number): Tail {
  const offset = getConstValue(f, cursor);
  if (offset instanceof Error) return offset;
  const value = stackPop(f.stack);
  if (value instanceof Error) return value;
  if ((offset as Word) > BigInt(Number.MAX_SAFE_INTEGER)) {
    return new ScheduleError('mstore offset too large');
  }
  const err = setU256(f.memory, Number(offset), value as Word);
  if (err instanceof Error) return err;
  return next(f, cursor);
}

// PUSH_MSTORE8_INLINE: Store TOS byte to memory at constant offset
export function PUSH_MSTORE8_INLINE(f: Frame, cursor: number): Tail {
  const offset = getConstValue(f, cursor);
  if (offset instanceof Error) return offset;
  const value = stackPop(f.stack);
  if (value instanceof Error) return value;
  if ((offset as Word) > BigInt(Number.MAX_SAFE_INTEGER)) {
    return new ScheduleError('mstore8 offset too large');
  }
  const byteValue = Number((value as Word) & 0xFFn);
  const err = setByte(f.memory, Number(offset), byteValue);
  if (err instanceof Error) return err;
  return next(f, cursor);
}


// --- Static jump fusions ---

function findCursorForPc(f: Frame, pc: number): { next: any; cursor: number } | InvalidJumpError {
  const target = f.schedule.pcToCursor.get(pc);
  if (target !== undefined) {
    const it = f.schedule.items[target] as any;
    return { next: it.handler, cursor: target };
  }
  return new InvalidJumpError(pc);
}

function isValidJumpDestTS(f: Frame, dest: number): boolean {
  if (dest < 0 || dest >= f.code.length) return false;
  return f.code[dest] === 0x5b; // JUMPDEST
}

// PUSH_JUMP_INLINE: jump to a constant destination (no stack read)
export function PUSH_JUMP_INLINE(f: Frame, cursor: number): Tail {
  const dest = getConstValue(f, cursor);
  if (dest instanceof Error) return dest;
  const d = Number(dest as Word);
  if (!isValidJumpDestTS(f, d)) return new InvalidJumpError(d);
  return findCursorForPc(f, d);
}

// PUSH_JUMPI_INLINE: conditional jump to a constant destination
export function PUSH_JUMPI_INLINE(f: Frame, cursor: number): Tail {
  const dest = getConstValue(f, cursor);
  if (dest instanceof Error) return dest;
  const cond = stackPop(f.stack);
  if (cond instanceof Error) return cond;
  if ((cond as Word) === 0n) return next(f, cursor);
  const d = Number(dest as Word);
  if (!isValidJumpDestTS(f, d)) return new InvalidJumpError(d);
  return findCursorForPc(f, d);
}

// ISZERO_JUMPI: pop value, if zero then jump to constant destination
export function ISZERO_JUMPI(f: Frame, cursor: number): Tail {
  const dest = getConstValue(f, cursor);
  if (dest instanceof Error) return dest;
  const v = stackPop(f.stack);
  if (v instanceof Error) return v;
  if ((v as Word) !== 0n) {
    return next(f, cursor);
  }
  const d = Number(dest as Word);
  if (!isValidJumpDestTS(f, d)) return new InvalidJumpError(d);
  return findCursorForPc(f, d);
}

// DUP2_MSTORE_PUSH: emulate DUP2;MSTORE;PUSHk X in one
// Stack before: [..., a, b]
// After:        [..., X] and memory[a] = b
export function DUP2_MSTORE_PUSH(f: Frame, cursor: number): Tail {
  const pushVal = getConstValue(f, cursor);
  if (pushVal instanceof Error) return pushVal;
  const value = stackPop(f.stack);
  if (value instanceof Error) return value;
  const offset = stackPop(f.stack);
  if (offset instanceof Error) return offset;
  if ((offset as Word) > BigInt(Number.MAX_SAFE_INTEGER)) {
    return new ScheduleError('mstore offset too large');
  }
  const err = setU256(f.memory, Number(offset as Word), value as Word);
  if (err instanceof Error) return err;
  const pe = stackPush(f.stack, pushVal as Word);
  if (pe instanceof Error) return pe;
  return next(f, cursor);
}

// MULTI_PUSH_2: push two constants (inline or pointer)
export function MULTI_PUSH_2(f: Frame, cursor: number): Tail {
  const meta1 = f.schedule.items[cursor + 1] as any;
  const meta2 = f.schedule.items[cursor + 2] as any;
  if (!meta1 || !meta2) return new ScheduleError('missing metadata for MULTI_PUSH_2');
  const v1 = meta1.kind === 'inline' ? (meta1.data.value as Word) : meta1.kind === 'pointer' ? (f.schedule.u256Pool[meta1.index] as Word) : undefined;
  const v2 = meta2.kind === 'inline' ? (meta2.data.value as Word) : meta2.kind === 'pointer' ? (f.schedule.u256Pool[meta2.index] as Word) : undefined;
  if (v1 === undefined || v2 === undefined) return new ScheduleError('invalid metadata for MULTI_PUSH_2');
  let e = stackPush(f.stack, v1);
  if (e instanceof Error) return e;
  e = stackPush(f.stack, v2);
  if (e instanceof Error) return e;
  return next(f, cursor);
}

// MULTI_PUSH_3: push three constants (inline or pointer)
export function MULTI_PUSH_3(f: Frame, cursor: number): Tail {
  const meta1 = f.schedule.items[cursor + 1] as any;
  const meta2 = f.schedule.items[cursor + 2] as any;
  const meta3 = f.schedule.items[cursor + 3] as any;
  if (!meta1 || !meta2 || !meta3) return new ScheduleError('missing metadata for MULTI_PUSH_3');
  const vals: (Word | undefined)[] = [meta1, meta2, meta3].map((m: any) => m.kind === 'inline' ? (m.data.value as Word) : m.kind === 'pointer' ? (f.schedule.u256Pool[m.index] as Word) : undefined);
  if (vals.some(v => v === undefined)) return new ScheduleError('invalid metadata for MULTI_PUSH_3');
  for (const v of vals as Word[]) {
    const e = stackPush(f.stack, v);
    if (e instanceof Error) return e;
  }
  return next(f, cursor);
}

// MULTI_POP_2: pop two values in a single operation
export function MULTI_POP_2(f: Frame, cursor: number): Tail {
  let e = stackPop(f.stack);
  if (e instanceof Error) return e;
  e = stackPop(f.stack);
  if (e instanceof Error) return e;
  return next(f, cursor);
}

// MULTI_POP_3: pop three values in a single operation
export function MULTI_POP_3(f: Frame, cursor: number): Tail {
  let e = stackPop(f.stack);
  if (e instanceof Error) return e;
  e = stackPop(f.stack);
  if (e instanceof Error) return e;
  e = stackPop(f.stack);
  if (e instanceof Error) return e;
  return next(f, cursor);
}

// ISZERO_JUMPI: Combined ISZERO + JUMPI pattern (inverted logic)
export function ISZERO_JUMPI(f: Frame, cursor: number): Tail {
  const dest = getConstValue(f, cursor);
  if (dest instanceof Error) return dest;
  const value = stackPop(f.stack);
  if (value instanceof Error) return value;
  // Note: ISZERO inverts the condition
  if ((value as Word) !== 0n) return next(f, cursor); // If value != 0, ISZERO gives 0, so don't jump
  const d = Number(dest as Word);
  if (!isValidJumpDestTS(f, d)) return new InvalidJumpError(d);
  return findCursorForPc(f, d);
}

// DUP2_MSTORE_PUSH: DUP2 + MSTORE + PUSH pattern
export function DUP2_MSTORE_PUSH(f: Frame, cursor: number): Tail {
  // DUP2 - duplicate stack element at depth 2
  const stack = f.stack as any;
  if (stack.top < 2) return new ScheduleError('stack underflow in DUP2');
  const val = stack.items[stack.top - 2];
  let e = stackPush(f.stack, val as Word);
  if (e instanceof Error) return e;
  
  // MSTORE
  const value = stackPop(f.stack);
  if (value instanceof Error) return value;
  const offset = stackPop(f.stack);
  if (offset instanceof Error) return offset;
  if ((offset as Word) > BigInt(Number.MAX_SAFE_INTEGER)) {
    return new ScheduleError('mstore offset too large');
  }
  const err = setU256(f.memory, Number(offset as Word), value as Word);
  if (err instanceof Error) return err;
  
  // PUSH
  const pushValue = getConstValue(f, cursor);
  if (pushValue instanceof Error) return pushValue;
  e = stackPush(f.stack, pushValue as Word);
  if (e instanceof Error) return e;
  
  return next(f, cursor);
}
