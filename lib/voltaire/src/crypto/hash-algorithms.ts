/**
 * Hash algorithm implementations
 * SHA-256, RIPEMD-160, Blake2b
 */

/**
 * Compute SHA-256 hash
 * @param data - Input data as Uint8Array or hex string
 * @returns 32-byte hash as hex string with 0x prefix
 */
export function sha256(data: Uint8Array | string): string {
	throw new Error("not implemented - requires C API binding");
}

/**
 * Compute RIPEMD-160 hash
 * @param data - Input data as Uint8Array or hex string
 * @returns 20-byte hash as hex string with 0x prefix
 */
export function ripemd160(data: Uint8Array | string): string {
	throw new Error("not implemented - requires C API binding");
}

/**
 * Compute Blake2b hash
 * @param data - Input data as Uint8Array or hex string
 * @returns 64-byte hash as hex string with 0x prefix
 */
export function blake2b(data: Uint8Array | string): string {
	throw new Error("not implemented - requires C API binding");
}
