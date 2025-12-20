/**
 * WASM implementation of RLP (Recursive Length Prefix) encoding
 * Uses WebAssembly bindings to Zig implementation
 */

import * as loader from "../../../../wasm/loader.js";

/**
 * Encode bytes as RLP
 * @param data - Data to encode
 * @returns RLP-encoded bytes
 */
export function encodeBytes(data: Uint8Array): Uint8Array {
	const input = new Uint8Array(data);
	return loader.rlpEncodeBytes(input);
}

/**
 * Encode unsigned integer (u256) as RLP
 * @param value - 32-byte big-endian u256 value
 * @returns RLP-encoded bytes
 */
export function encodeUint(value: Uint8Array): Uint8Array {
	const input = new Uint8Array(value);
	if (input.length !== 32) {
		throw new Error("Value must be 32 bytes (u256)");
	}
	return loader.rlpEncodeUint(input);
}

/**
 * Encode unsigned integer from bigint
 * @param value - BigInt value
 * @returns RLP-encoded bytes
 */
export function encodeUintFromBigInt(value: bigint): Uint8Array {
	// Convert bigint to 32-byte big-endian buffer
	const hex = value.toString(16).padStart(64, "0");
	const bytes = new Uint8Array(32);
	for (let i = 0; i < 32; i++) {
		bytes[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
	}
	return encodeUint(bytes);
}

/**
 * Convert RLP bytes to hex string
 * @param rlpData - RLP-encoded data
 * @returns Hex string with 0x prefix
 */
export function toHex(rlpData: Uint8Array): string {
	const input = new Uint8Array(rlpData);
	return loader.rlpToHex(input);
}

/**
 * Convert hex string to RLP bytes
 * @param hex - Hex string (with or without 0x prefix)
 * @returns RLP bytes
 */
export function fromHex(hex: string): Uint8Array {
	return loader.rlpFromHex(hex);
}

// Re-export for convenience
export default {
	encodeBytes,
	encodeUint,
	encodeUintFromBigInt,
	toHex,
	fromHex,
};
