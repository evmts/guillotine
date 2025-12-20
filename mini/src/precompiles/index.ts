/**
 * Precompile detection and execution
 *
 * Maps Ethereum precompiled contract addresses to their implementations
 * based on hardfork activation.
 *
 * Precompile address ranges by hardfork:
 * - Frontier-Istanbul: 0x01-0x09
 * - Cancun+: 0x01-0x0A (adds KZG point evaluation)
 * - Prague+: 0x01-0x12 (adds BLS12-381 operations)
 */

import type { Address } from '../host';
import { Hardfork } from '../instructions/handlers_storage';

/**
 * Precompile identifiers
 */
export enum PrecompileType {
  ECRECOVER = 0x01,
  SHA256 = 0x02,
  RIPEMD160 = 0x03,
  IDENTITY = 0x04,
  MODEXP = 0x05,
  EC_ADD = 0x06,
  EC_MUL = 0x07,
  EC_PAIRING = 0x08,
  BLAKE2F = 0x09,
  KZG_POINT_EVAL = 0x0a,
  BLS_G1_ADD = 0x0b,
  BLS_G1_MUL = 0x0c,
  BLS_G1_MULTIEXP = 0x0d,
  BLS_G2_ADD = 0x0e,
  BLS_G2_MUL = 0x0f,
  BLS_G2_MULTIEXP = 0x10,
  BLS_PAIRING = 0x11,
  BLS_MAP_FP_TO_G1 = 0x12,
}

/**
 * Precompile execution result
 */
export interface PrecompileResult {
  /** Success flag */
  success: boolean;
  /** Gas used (0 if failed) */
  gas_used: bigint;
  /** Output data (empty if failed) */
  output: Uint8Array;
}

/**
 * Check if an address is a precompiled contract
 *
 * @param address - Address to check
 * @param hardfork - Current hardfork
 * @returns true if address is a valid precompile for this hardfork
 */
export function isPrecompile(address: Address, hardfork: Hardfork): boolean {
  // Convert address to number (last byte)
  const addr_num = address.bytes[19];

  if (addr_num === 0 || addr_num > 0x12) {
    return false;
  }

  // Check if all other bytes are zero
  for (let i = 0; i < 19; i++) {
    if (address.bytes[i] !== 0) {
      return false;
    }
  }

  // Check hardfork availability
  switch (addr_num) {
    case PrecompileType.ECRECOVER:
    case PrecompileType.SHA256:
    case PrecompileType.RIPEMD160:
    case PrecompileType.IDENTITY:
      return true; // Available since Frontier

    case PrecompileType.MODEXP:
    case PrecompileType.EC_ADD:
    case PrecompileType.EC_MUL:
    case PrecompileType.EC_PAIRING:
      return hardfork >= Hardfork.BYZANTIUM;

    case PrecompileType.BLAKE2F:
      return hardfork >= Hardfork.ISTANBUL;

    case PrecompileType.KZG_POINT_EVAL:
      return hardfork >= Hardfork.CANCUN;

    case PrecompileType.BLS_G1_ADD:
    case PrecompileType.BLS_G1_MUL:
    case PrecompileType.BLS_G1_MULTIEXP:
    case PrecompileType.BLS_G2_ADD:
    case PrecompileType.BLS_G2_MUL:
    case PrecompileType.BLS_G2_MULTIEXP:
    case PrecompileType.BLS_PAIRING:
    case PrecompileType.BLS_MAP_FP_TO_G1:
      return hardfork >= Hardfork.PRAGUE;

    default:
      return false;
  }
}

/**
 * Execute a precompiled contract
 *
 * @param address - Precompile address
 * @param input - Input data
 * @param gas - Gas available for execution
 * @param hardfork - Current hardfork
 * @returns Precompile execution result
 */
export function execute(
  address: Address,
  input: Uint8Array,
  gas: bigint,
  hardfork: Hardfork
): PrecompileResult {
  const addr_num = address.bytes[19];

  // Verify it's a valid precompile for this hardfork
  if (!isPrecompile(address, hardfork)) {
    return {
      success: false,
      gas_used: gas,
      output: new Uint8Array(0),
    };
  }

  // Stub implementations - return error for now
  // TODO: Implement actual precompile logic
  switch (addr_num) {
    case PrecompileType.ECRECOVER:
      return executeEcrecover(input, gas);
    case PrecompileType.SHA256:
      return executeSha256(input, gas);
    case PrecompileType.RIPEMD160:
      return executeRipemd160(input, gas);
    case PrecompileType.IDENTITY:
      return executeIdentity(input, gas);
    case PrecompileType.MODEXP:
      return executeModexp(input, gas, hardfork);
    case PrecompileType.EC_ADD:
      return executeEcAdd(input, gas);
    case PrecompileType.EC_MUL:
      return executeEcMul(input, gas);
    case PrecompileType.EC_PAIRING:
      return executeEcPairing(input, gas);
    case PrecompileType.BLAKE2F:
      return executeBlake2f(input, gas);
    case PrecompileType.KZG_POINT_EVAL:
      return executeKzgPointEval(input, gas);
    case PrecompileType.BLS_G1_ADD:
    case PrecompileType.BLS_G1_MUL:
    case PrecompileType.BLS_G1_MULTIEXP:
    case PrecompileType.BLS_G2_ADD:
    case PrecompileType.BLS_G2_MUL:
    case PrecompileType.BLS_G2_MULTIEXP:
    case PrecompileType.BLS_PAIRING:
    case PrecompileType.BLS_MAP_FP_TO_G1:
      return executeBlsStub(input, gas);
    default:
      return {
        success: false,
        gas_used: gas,
        output: new Uint8Array(0),
      };
  }
}

// Stub implementations - return error for now

function executeEcrecover(input: Uint8Array, gas: bigint): PrecompileResult {
  // TODO: Implement ECRECOVER
  // Gas cost: 3000
  return { success: false, gas_used: gas, output: new Uint8Array(0) };
}

function executeSha256(input: Uint8Array, gas: bigint): PrecompileResult {
  // TODO: Implement SHA256
  // Gas cost: 60 + 12 * ceil(input.length / 32)
  return { success: false, gas_used: gas, output: new Uint8Array(0) };
}

function executeRipemd160(input: Uint8Array, gas: bigint): PrecompileResult {
  // TODO: Implement RIPEMD160
  // Gas cost: 600 + 120 * ceil(input.length / 32)
  return { success: false, gas_used: gas, output: new Uint8Array(0) };
}

function executeIdentity(input: Uint8Array, gas: bigint): PrecompileResult {
  // IDENTITY just copies input to output
  // Gas cost: 15 + 3 * ceil(input.length / 32)
  const words = BigInt(Math.ceil(input.length / 32));
  const gas_cost = 15n + 3n * words;

  if (gas < gas_cost) {
    return { success: false, gas_used: gas, output: new Uint8Array(0) };
  }

  return {
    success: true,
    gas_used: gas_cost,
    output: new Uint8Array(input),
  };
}

function executeModexp(input: Uint8Array, gas: bigint, hardfork: Hardfork): PrecompileResult {
  // TODO: Implement MODEXP
  return { success: false, gas_used: gas, output: new Uint8Array(0) };
}

function executeEcAdd(input: Uint8Array, gas: bigint): PrecompileResult {
  // TODO: Implement EC_ADD
  return { success: false, gas_used: gas, output: new Uint8Array(0) };
}

function executeEcMul(input: Uint8Array, gas: bigint): PrecompileResult {
  // TODO: Implement EC_MUL
  return { success: false, gas_used: gas, output: new Uint8Array(0) };
}

function executeEcPairing(input: Uint8Array, gas: bigint): PrecompileResult {
  // TODO: Implement EC_PAIRING
  return { success: false, gas_used: gas, output: new Uint8Array(0) };
}

function executeBlake2f(input: Uint8Array, gas: bigint): PrecompileResult {
  // TODO: Implement BLAKE2F
  return { success: false, gas_used: gas, output: new Uint8Array(0) };
}

function executeKzgPointEval(input: Uint8Array, gas: bigint): PrecompileResult {
  // TODO: Implement KZG_POINT_EVAL
  return { success: false, gas_used: gas, output: new Uint8Array(0) };
}

function executeBlsStub(input: Uint8Array, gas: bigint): PrecompileResult {
  // TODO: Implement BLS12-381 operations
  return { success: false, gas_used: gas, output: new Uint8Array(0) };
}
