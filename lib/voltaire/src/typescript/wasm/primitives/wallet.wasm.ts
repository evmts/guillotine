/**
 * WASM implementation of wallet key generation
 * Uses WebAssembly bindings to Zig implementation
 */

const primitives = require('../../../wasm/loader.js');

/**
 * Generate a cryptographically secure random private key
 * @returns 32-byte private key
 */
export function generatePrivateKey(): Uint8Array {
	return primitives.generatePrivateKey();
}

/**
 * Compress uncompressed secp256k1 public key
 * @param uncompressed - 64-byte uncompressed public key (x, y coordinates)
 * @returns 33-byte compressed public key (0x02/0x03 prefix + x coordinate)
 */
export function compressPublicKey(uncompressed: Uint8Array): Uint8Array {
	if (uncompressed.length !== 64) {
		throw new Error("Uncompressed public key must be 64 bytes");
	}

	return primitives.compressPublicKey(uncompressed);
}

// Re-export for convenience
export default {
	generatePrivateKey,
	compressPublicKey,
};
