/**
 * WASM implementation of hex utilities
 * Uses WebAssembly bindings to Zig implementation
 */

import * as loader from "../../../../wasm/loader.js";

/**
 * Convert hex string to bytes
 * @param hex - Hex string (with or without 0x prefix)
 * @returns Raw bytes
 */
export function hexToBytes(hex: string): Uint8Array {
	return loader.hexToBytes(hex);
}

/**
 * Convert bytes to hex string
 * @param data - Raw bytes
 * @returns Hex string with 0x prefix
 */
export function bytesToHex(data: Uint8Array): string {
	const input = new Uint8Array(data);
	return loader.bytesToHex(input);
}

// Re-export for convenience
export default {
	hexToBytes,
	bytesToHex,
};
