/**
 * Evm Precompile Functions
 * 
 * This module exports stub implementations for Evm precompiled contracts.
 * These are placeholder functions that return NOT_IMPLEMENTED status.
 * The actual cryptographic operations are handled by the Evm runtime.
 */

export * from './types';

import { bn254Precompiles } from './bn254';
import { bls12381Precompiles } from './bls12-381';

/**
 * All Evm precompile functions combined
 */
export const precompiles = {
  ...bn254Precompiles,
  ...bls12381Precompiles,
} as const;