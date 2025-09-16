import { Word, wordToBytes32 } from '../types';
import { 
  stackPop, 
  stackPush, 
  stackDupN as stackDup, 
  stackSwapN as stackSwap 
} from '../stack/stack';
import { next } from '../interpreter';
import type { Frame } from '../frame/frame';
import type { Tail } from '../types_runtime';
import type { ReturnData } from '../frame/call_result';
import { ScheduleError } from '../errors';

// STOP (0x00) - Stop execution and return empty data
export function STOP(f: Frame, cursor: number): Tail {
  return { data: new Uint8Array() } as ReturnData;
}

export function POP(f: Frame, cursor: number): Tail {
  const val = stackPop(f.stack);
  if (val instanceof Error) return val;
  return next(f, cursor);
}

export function PUSH0(f: Frame, cursor: number): Tail {
  const e = stackPush(f.stack, 0n);
  if (e instanceof Error) return e;
  return next(f, cursor);
}

export function PUSH(f: Frame, cursor: number): Tail {
  // Get inline data from next item
  const metaItem = f.schedule.items[cursor + 1] as any;
  if (!metaItem) return new ScheduleError('Missing metadata for PUSH');
  let value: Word;
  if (metaItem.kind === 'inline') {
    value = metaItem.data.value as Word;
  } else if (metaItem.kind === 'pointer') {
    const idx: number = metaItem.index;
    value = f.schedule.u256Pool[idx] as Word;
  } else {
    return new ScheduleError('Invalid metadata for PUSH');
  }
  const e = stackPush(f.stack, value);
  if (e instanceof Error) return e;
  return next(f, cursor);
}

export function DUP(f: Frame, cursor: number): Tail {
  // Get inline data from next item
  const inlineItem = f.schedule.items[cursor + 1] as any;
  if (!inlineItem || inlineItem.kind !== 'inline') {
    return new ScheduleError('Missing inline data for DUP');
  }
  
  const n = inlineItem.data.n as number;
  const e = stackDup(f.stack, n);
  if (e instanceof Error) return e;
  return next(f, cursor);
}

export function SWAP(f: Frame, cursor: number): Tail {
  // Get inline data from next item
  const inlineItem = f.schedule.items[cursor + 1] as any;
  if (!inlineItem || inlineItem.kind !== 'inline') {
    return new ScheduleError('Missing inline data for SWAP');
  }
  
  const n = inlineItem.data.n as number;
  const e = stackSwap(f.stack, n);
  if (e instanceof Error) return e;
  return next(f, cursor);
}

export function STOP(_f: Frame, _cursor: number): Tail {
  return { data: new Uint8Array(0) } as ReturnData;
}
