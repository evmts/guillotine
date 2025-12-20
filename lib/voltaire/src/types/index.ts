/**
 * TypeScript type definitions for Ethereum primitives
 *
 * Maps C API types to TypeScript types
 * Based on primitives.h struct definitions
 */

/**
 * Ethereum address (20 bytes)
 *
 * Maps to C type: PrimitivesAddress
 * struct PrimitivesAddress { uint8_t bytes[20]; }
 */
export interface Address {
  /** Raw 20-byte address data */
  bytes: Uint8Array;
}

/**
 * Hash value (32 bytes)
 * Used for Keccak-256, SHA-256, etc.
 *
 * Maps to C type: PrimitivesHash
 * struct PrimitivesHash { uint8_t bytes[32]; }
 */
export interface Hash {
  /** Raw 32-byte hash data */
  bytes: Uint8Array;
}

/**
 * 256-bit unsigned integer (32 bytes, big-endian)
 *
 * Maps to C type: PrimitivesU256
 * struct PrimitivesU256 { uint8_t bytes[32]; }
 */
export interface U256 {
  /** Raw 32-byte big-endian integer data */
  bytes: Uint8Array;
}

/**
 * Hex string format
 * Always includes "0x" prefix
 */
export type HexString = `0x${string}`;

/**
 * Address as hex string (42 characters: "0x" + 40 hex)
 */
export type AddressHex = `0x${string}`;

/**
 * Hash as hex string (66 characters: "0x" + 64 hex)
 */
export type HashHex = `0x${string}`;

/**
 * U256 as hex string (up to 66 characters: "0x" + up to 64 hex)
 */
export type U256Hex = `0x${string}`;

/**
 * Type guard: Check if string is valid hex format
 */
export function isHexString(value: unknown): value is HexString {
  return typeof value === 'string' && /^0x[0-9a-fA-F]*$/.test(value);
}

/**
 * Type guard: Check if string is valid address hex (42 chars)
 */
export function isAddressHex(value: unknown): value is AddressHex {
  return typeof value === 'string' && /^0x[0-9a-fA-F]{40}$/.test(value);
}

/**
 * Type guard: Check if string is valid hash hex (66 chars)
 */
export function isHashHex(value: unknown): value is HashHex {
  return typeof value === 'string' && /^0x[0-9a-fA-F]{64}$/.test(value);
}

/**
 * Type guard: Check if value is Address
 */
export function isAddress(value: unknown): value is Address {
  return (
    typeof value === 'object' &&
    value !== null &&
    'bytes' in value &&
    value.bytes instanceof Uint8Array &&
    value.bytes.length === 20
  );
}

/**
 * Type guard: Check if value is Hash
 */
export function isHash(value: unknown): value is Hash {
  return (
    typeof value === 'object' &&
    value !== null &&
    'bytes' in value &&
    value.bytes instanceof Uint8Array &&
    value.bytes.length === 32
  );
}

/**
 * Type guard: Check if value is U256
 */
export function isU256(value: unknown): value is U256 {
  return (
    typeof value === 'object' &&
    value !== null &&
    'bytes' in value &&
    value.bytes instanceof Uint8Array &&
    value.bytes.length === 32
  );
}

/**
 * C API sizes (in bytes)
 */
export const SIZES = {
  /** Address size in bytes */
  ADDRESS: 20,
  /** Hash size in bytes */
  HASH: 32,
  /** U256 size in bytes */
  U256: 32,
  /** Address hex string length (with 0x prefix) */
  ADDRESS_HEX: 42,
  /** Hash hex string length (with 0x prefix) */
  HASH_HEX: 66,
  /** U256 hex string max length (with 0x prefix) */
  U256_HEX: 66,
} as const;

/**
 * Create Address from bytes
 *
 * @param bytes 20-byte Uint8Array
 * @returns Address object
 * @throws Error if bytes length is not 20
 */
export function createAddress(bytes: Uint8Array): Address {
  if (bytes.length !== SIZES.ADDRESS) {
    throw new Error(`Address must be ${SIZES.ADDRESS} bytes, got ${bytes.length}`);
  }
  return { bytes: new Uint8Array(bytes) };
}

/**
 * Create Hash from bytes
 *
 * @param bytes 32-byte Uint8Array
 * @returns Hash object
 * @throws Error if bytes length is not 32
 */
export function createHash(bytes: Uint8Array): Hash {
  if (bytes.length !== SIZES.HASH) {
    throw new Error(`Hash must be ${SIZES.HASH} bytes, got ${bytes.length}`);
  }
  return { bytes: new Uint8Array(bytes) };
}

/**
 * Create U256 from bytes
 *
 * @param bytes 32-byte big-endian Uint8Array
 * @returns U256 object
 * @throws Error if bytes length is not 32
 */
export function createU256(bytes: Uint8Array): U256 {
  if (bytes.length !== SIZES.U256) {
    throw new Error(`U256 must be ${SIZES.U256} bytes, got ${bytes.length}`);
  }
  return { bytes: new Uint8Array(bytes) };
}

/**
 * Zero address (0x0000000000000000000000000000000000000000)
 */
export const ZERO_ADDRESS: Address = {
  bytes: new Uint8Array(20),
};

/**
 * Zero hash (0x0000...0000, 32 bytes)
 */
export const ZERO_HASH: Hash = {
  bytes: new Uint8Array(32),
};

/**
 * Zero U256 (0x0000...0000, 32 bytes)
 */
export const ZERO_U256: U256 = {
  bytes: new Uint8Array(32),
};

/**
 * Check if address is zero address
 *
 * @param address Address to check
 * @returns true if all bytes are zero
 */
export function isZeroAddress(address: Address): boolean {
  return address.bytes.every((byte) => byte === 0);
}

/**
 * Check if hash is zero hash
 *
 * @param hash Hash to check
 * @returns true if all bytes are zero
 */
export function isZeroHash(hash: Hash): boolean {
  return hash.bytes.every((byte) => byte === 0);
}

/**
 * Compare two addresses for equality
 *
 * @param a First address
 * @param b Second address
 * @returns true if addresses are equal
 */
export function addressEquals(a: Address, b: Address): boolean {
  if (a.bytes.length !== b.bytes.length) {
    return false;
  }
  for (let i = 0; i < a.bytes.length; i++) {
    if (a.bytes[i] !== b.bytes[i]) {
      return false;
    }
  }
  return true;
}

/**
 * Compare two hashes for equality
 *
 * @param a First hash
 * @param b Second hash
 * @returns true if hashes are equal
 */
export function hashEquals(a: Hash, b: Hash): boolean {
  if (a.bytes.length !== b.bytes.length) {
    return false;
  }
  for (let i = 0; i < a.bytes.length; i++) {
    if (a.bytes[i] !== b.bytes[i]) {
      return false;
    }
  }
  return true;
}

/**
 * Compare two U256 values for equality
 *
 * @param a First U256
 * @param b Second U256
 * @returns true if values are equal
 */
export function u256Equals(a: U256, b: U256): boolean {
  if (a.bytes.length !== b.bytes.length) {
    return false;
  }
  for (let i = 0; i < a.bytes.length; i++) {
    if (a.bytes[i] !== b.bytes[i]) {
      return false;
    }
  }
  return true;
}

/**
 * Convert bytes to hex string with 0x prefix
 *
 * @param bytes Input bytes
 * @returns Hex string with 0x prefix
 */
export function bytesToHex(bytes: Uint8Array): HexString {
  return `0x${Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')}` as HexString;
}

/**
 * Convert Address to hex string
 *
 * @param address Address object
 * @returns 42-character hex string
 */
export function addressToHex(address: Address): AddressHex {
  return bytesToHex(address.bytes) as AddressHex;
}

/**
 * Convert Hash to hex string
 *
 * @param hash Hash object
 * @returns 66-character hex string
 */
export function hashToHex(hash: Hash): HashHex {
  return bytesToHex(hash.bytes) as HashHex;
}

/**
 * Convert U256 to hex string
 *
 * @param value U256 object
 * @returns Hex string (up to 66 characters)
 */
export function u256ToHex(value: U256): U256Hex {
  return bytesToHex(value.bytes) as U256Hex;
}
