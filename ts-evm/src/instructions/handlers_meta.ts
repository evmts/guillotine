import { next } from '../interpreter';
import type { Frame } from '../frame/frame';
import type { Tail } from '../types_runtime';
import { ScheduleError, OutOfGasError } from '../errors';

// FIRST_BLOCK_GAS: charges precomputed gas for the basic block.
export function FIRST_BLOCK_GAS(f: Frame, cursor: number): Tail {
  const inlineItem = f.schedule.items[cursor + 1] as any;
  if (!inlineItem || inlineItem.kind !== 'inline') {
    return new ScheduleError('missing inline gas for FIRST_BLOCK_GAS');
  }
  const gas = BigInt(inlineItem.data.gas ?? 0);
  if (f.gasRemaining < gas) return new OutOfGasError();
  f.gasRemaining -= gas;
  return next(f, cursor);
}

