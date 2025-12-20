/**
 * Keccak-256 hashing functions
 * Primary hash function for Ethereum
 */

import { FFIType, dlopen, ptr, suffix } from "bun:ffi";
import { resolve } from "node:path";

// Load the C library
const libPath = resolve(
	import.meta.dir,
	`../../zig-out/lib/libprimitives_c.${suffix}`,
);

// Define the C API
const {
	symbols: { primitives_keccak256, primitives_hash_to_hex },
} = dlopen(libPath, {
	primitives_keccak256: {
		args: [FFIType.ptr, FFIType.u64, FFIType.ptr],
		returns: FFIType.i32,
	},
	primitives_hash_to_hex: {
		args: [FFIType.ptr, FFIType.ptr],
		returns: FFIType.i32,
	},
});

/**
 * Pre-computed empty Keccak-256 hash constant
 * Hash of empty bytes: keccak256("")
 */
const KECCAK256_EMPTY =
	"0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";

/**
 * Convert hex string to Uint8Array
 */
function hexToBytes(hex: string): Uint8Array {
	const cleaned = hex.startsWith("0x") ? hex.slice(2) : hex;
	const bytes = new Uint8Array(cleaned.length / 2);
	for (let i = 0; i < bytes.length; i++) {
		bytes[i] = Number.parseInt(cleaned.slice(i * 2, i * 2 + 2), 16);
	}
	return bytes;
}

/**
 * Compute Keccak-256 hash of input data
 * @param data - Input data as Uint8Array or hex string
 * @returns 32-byte hash as hex string with 0x prefix
 */
export function keccak256(data: Uint8Array | string): string {
	// Convert string input to bytes
	const bytes = typeof data === "string" ? hexToBytes(data) : data;

	// Handle empty input - return precomputed hash
	if (bytes.length === 0) {
		return KECCAK256_EMPTY;
	}

	// Allocate output buffer for 32-byte hash
	const hashBuffer = new Uint8Array(32);

	// Call C function
	const result = primitives_keccak256(
		ptr(bytes),
		bytes.length,
		ptr(hashBuffer),
	);

	if (result !== 0) {
		throw new Error(`Keccak256 failed with error code: ${result}`);
	}

	// Convert hash to hex string
	const hexBuffer = new Uint8Array(66); // "0x" + 64 hex chars
	const hexResult = primitives_hash_to_hex(ptr(hashBuffer), ptr(hexBuffer));

	if (hexResult !== 0) {
		throw new Error(
			`Hash to hex conversion failed with error code: ${hexResult}`,
		);
	}

	// Convert buffer to string
	return new TextDecoder().decode(hexBuffer);
}

/**
 * Pre-computed empty Keccak-256 hash
 * Hash of empty bytes: keccak256("")
 * @returns 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
 */
export function keccak256Empty(): string {
	return KECCAK256_EMPTY;
}
