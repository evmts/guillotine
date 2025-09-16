import { Word, u256 } from '../types';
import { stackPeek, stackSetTop, stackPop, stackPush } from '../stack/stack';
import { next } from '../interpreter';
import type { Frame } from '../frame/frame';
import type { Tail } from '../types_runtime';
import { ScheduleError } from '../errors';
import { getU256Evm, setU256, setByte } from '../memory/memory';
import { InvalidJumpError } from '../errors';

// Helper to fetch inline metadata value from schedule
function getInlineValue(f: Frame, cursor: number): Word | ScheduleError {
  const inlineItem = f.schedule.items[cursor + 1] as any;
  if (!inlineItem || inlineItem.kind !== 'inline') {
    return new ScheduleError('missing inline metadata');
  }
  return inlineItem.data.value as Word;
}

// PUSH_ADD_INLINE: Replace TOS with TOS + value
export function PUSH_ADD_INLINE(f: Frame, cursor: number): Tail {
  const value = getInlineValue(f, cursor);
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
  const value = getInlineValue(f, cursor);
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
  const value = getInlineValue(f, cursor);
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
  const value = getInlineValue(f, cursor);
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
  const value = getInlineValue(f, cursor);
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
  const value = getInlineValue(f, cursor);
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
  const value = getInlineValue(f, cursor);
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
  const offset = getInlineValue(f, cursor);
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
  const offset = getInlineValue(f, cursor);
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
  const offset = getInlineValue(f, cursor);
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
  const dest = getInlineValue(f, cursor);
  if (dest instanceof Error) return dest;
  const d = Number(dest as Word);
  if (!isValidJumpDestTS(f, d)) return new InvalidJumpError(d);
  return findCursorForPc(f, d);
}

// PUSH_JUMPI_INLINE: conditional jump to a constant destination
export function PUSH_JUMPI_INLINE(f: Frame, cursor: number): Tail {
  const dest = getInlineValue(f, cursor);
  if (dest instanceof Error) return dest;
  const cond = stackPop(f.stack);
  if (cond instanceof Error) return cond;
  if ((cond as Word) === 0n) return next(f, cursor);
  const d = Number(dest as Word);
  if (!isValidJumpDestTS(f, d)) return new InvalidJumpError(d);
  return findCursorForPc(f, d);
}
