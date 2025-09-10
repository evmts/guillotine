/**
 * EVM Precompile Functions
 * 
 * This module exports stub implementations for EVM precompiled contracts.
 * These are placeholder functions that return NOT_IMPLEMENTED status.
 * The actual cryptographic operations are handled by the EVM runtime.
 */

export * from './types';

import { bn254Precompiles } from './bn254';
import { bls12381Precompiles } from './bls12-381';

/**
 * All EVM precompile functions combined
 */
export const precompiles = {
  ...bn254Precompiles,
  ...bls12381Precompiles,
} as const;