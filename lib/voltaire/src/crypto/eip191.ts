/**
 * EIP-191: Signed Data Standard
 * Personal message signing format
 */

import { FFIType, dlopen, ptr, suffix } from "bun:ffi";
import { resolve } from "node:path";

// Load the C library (reuse from keccak)
const libPath = resolve(
	import.meta.dir,
	`../../zig-out/lib/libprimitives_c.${suffix}`,
);

const {
	symbols: { primitives_eip191_hash_message, primitives_hash_to_hex },
} = dlopen(libPath, {
	primitives_eip191_hash_message: {
		args: [FFIType.ptr, FFIType.u64, FFIType.ptr],
		returns: FFIType.i32,
	},
	primitives_hash_to_hex: {
		args: [FFIType.ptr, FFIType.ptr],
		returns: FFIType.i32,
	},
});

export type Hex = `0x${string}`;
export type Address = `0x${string}`;
export type Signature = {
	r: Hex;
	s: Hex;
	v: number;
};

/**
 * Hash a message using EIP-191 personal message format
 * Format: "\x19Ethereum Signed Message:\n" + len(message) + message
 * @param message - Message to hash (string or Uint8Array)
 * @returns 32-byte hash as hex string with 0x prefix
 */
export function hashMessage(message: string | Uint8Array): Hex {
	// Convert string to bytes
	const bytes =
		typeof message === "string" ? new TextEncoder().encode(message) : message;

	// Handle empty message (FFI doesn't like empty pointers)
	const messageBytes = bytes.length === 0 ? new Uint8Array(1) : bytes;
	const messageLength = bytes.length; // Use original length

	// Allocate output buffer for 32-byte hash
	const hashBuffer = new Uint8Array(32);

	// Call C function
	const result = primitives_eip191_hash_message(
		ptr(messageBytes),
		messageLength,
		ptr(hashBuffer),
	);

	if (result !== 0) {
		throw new Error(`EIP-191 hash failed with error code: ${result}`);
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
	return new TextDecoder().decode(hexBuffer) as Hex;
}

/**
 * Sign a message using EIP-191 personal message format
 * NOTE: This is a stub implementation that requires proper secp256k1 signing
 * to be exposed via the C API. For now, it throws an error.
 * @param message - Message to sign
 * @param privateKey - Private key as hex string (0x-prefixed)
 * @returns Signature object with r, s, v components
 */
export function signMessage(
	message: string | Uint8Array,
	privateKey: Hex,
): Signature {
	throw new Error(
		"signMessage not yet implemented - requires secp256k1 C API bindings",
	);
}

/**
 * Verify a signature against a message and address
 * NOTE: This is a stub implementation that requires proper signature recovery
 * to be exposed via the C API. For now, it throws an error.
 * @param message - Original message that was signed
 * @param signature - Signature object or compact hex string
 * @param address - Expected signer address
 * @returns true if signature is valid, false otherwise
 */
export function verifyMessage(
	message: string | Uint8Array,
	signature: Signature | Hex,
	address: Address,
): boolean {
	throw new Error(
		"verifyMessage not yet implemented - requires secp256k1 C API bindings",
	);
}

/**
 * Recover the address that signed a message
 * NOTE: This is a stub implementation that requires proper signature recovery
 * to be exposed via the C API. For now, it throws an error.
 * @param message - Original message that was signed
 * @param signature - Signature object or compact hex string
 * @returns Recovered Ethereum address
 */
export function recoverMessageAddress(
	message: string | Uint8Array,
	signature: Signature | Hex,
): Address {
	throw new Error(
		"recoverMessageAddress not yet implemented - requires secp256k1 C API bindings",
	);
}
