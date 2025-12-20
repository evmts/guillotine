/**
 * WASM implementation of U256 operations
 * Uses WebAssembly bindings to Zig implementation
 */

import * as loader from "../../../../wasm/loader.js";

/**
 * Convert hex string to U256 (32-byte big-endian)
 * @param hex - Hex string (with or without 0x prefix)
 * @returns 32-byte U256 value
 */
export function u256FromHex(hex: string): Uint8Array {
	return loader.u256FromHex(hex);
}

/**
 * Convert U256 to hex string
 * @param value - 32-byte U256 value (big-endian)
 * @returns Hex string with 0x prefix
 */
export function u256ToHex(value: Uint8Array): string {
	if (value.length !== 32) {
		throw new Error("U256 value must be 32 bytes");
	}
	return loader.u256ToHex(value);
}

/**
 * Convert bigint to U256 bytes
 * @param value - BigInt value
 * @returns 32-byte U256 value
 */
export function u256FromBigInt(value: bigint): Uint8Array {
	if (value < 0n) {
		throw new Error("U256 cannot be negative");
	}
	if (value >= 2n ** 256n) {
		throw new Error("Value exceeds U256 maximum");
	}

	// Convert bigint to hex and pad to 64 chars (32 bytes)
	const hex = "0x" + value.toString(16).padStart(64, "0");
	return u256FromHex(hex);
}

/**
 * Convert U256 bytes to bigint
 * @param value - 32-byte U256 value
 * @returns BigInt value
 */
export function u256ToBigInt(value: Uint8Array): bigint {
	if (value.length !== 32) {
		throw new Error("U256 value must be 32 bytes");
	}

	// Convert bytes to hex string and parse as bigint
	const hex = u256ToHex(value);
	return BigInt(hex);
}

// Re-export for convenience
export default {
	u256FromHex,
	u256ToHex,
	u256FromBigInt,
	u256ToBigInt,
};
