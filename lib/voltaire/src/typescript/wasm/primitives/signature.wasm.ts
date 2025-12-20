/**
 * WASM implementation of signature operations (secp256k1)
 * Uses WebAssembly bindings to Zig implementation
 */

const primitives = require('../../../wasm/loader.js');

/**
 * Parsed ECDSA signature components
 */
export interface ParsedSignature {
	/** R component (32 bytes) */
	r: Uint8Array;
	/** S component (32 bytes) */
	s: Uint8Array;
	/** V recovery parameter (1 byte) */
	v: number;
}

/**
 * Recover public key from ECDSA signature
 * @param messageHash - 32-byte message hash
 * @param r - R component of signature (32 bytes)
 * @param s - S component of signature (32 bytes)
 * @param v - Recovery parameter (0-3)
 * @returns Uncompressed public key (64 bytes)
 */
export function secp256k1RecoverPubkey(
	messageHash: Uint8Array,
	r: Uint8Array,
	s: Uint8Array,
	v: number,
): Uint8Array {
	if (messageHash.length !== 32) {
		throw new Error("Message hash must be 32 bytes");
	}
	if (r.length !== 32 || s.length !== 32) {
		throw new Error("Signature components r and s must be 32 bytes each");
	}
	if (v < 0 || v > 3) {
		throw new Error("Recovery parameter v must be 0-3");
	}

	const hashArr = new Uint8Array(messageHash);
	const rArr = new Uint8Array(r);
	const sArr = new Uint8Array(s);

	return primitives.secp256k1RecoverPubkey(hashArr, rArr, sArr, v);
}

/**
 * Recover Ethereum address from ECDSA signature
 * @param messageHash - 32-byte message hash
 * @param r - R component of signature (32 bytes)
 * @param s - S component of signature (32 bytes)
 * @param v - Recovery parameter (0-3)
 * @returns Ethereum address (20 bytes)
 */
export function secp256k1RecoverAddress(
	messageHash: Uint8Array,
	r: Uint8Array,
	s: Uint8Array,
	v: number,
): Uint8Array {
	if (messageHash.length !== 32) {
		throw new Error("Message hash must be 32 bytes");
	}
	if (r.length !== 32 || s.length !== 32) {
		throw new Error("Signature components r and s must be 32 bytes each");
	}
	if (v < 0 || v > 3) {
		throw new Error("Recovery parameter v must be 0-3");
	}

	const hashArr = new Uint8Array(messageHash);
	const rArr = new Uint8Array(r);
	const sArr = new Uint8Array(s);

	return primitives.secp256k1RecoverAddress(hashArr, rArr, sArr, v);
}

/**
 * Derive public key from private key using secp256k1
 * @param privateKey - 32-byte private key
 * @returns Uncompressed public key (64 bytes)
 */
export function secp256k1PubkeyFromPrivate(privateKey: Uint8Array): Uint8Array {
	if (privateKey.length !== 32) {
		throw new Error("Private key must be 32 bytes");
	}

	const keyArr = new Uint8Array(privateKey);
	return primitives.secp256k1PubkeyFromPrivate(keyArr);
}

/**
 * Validate ECDSA signature components (r, s)
 * @param r - R component of signature (32 bytes)
 * @param s - S component of signature (32 bytes)
 * @returns true if signature is valid
 */
export function secp256k1ValidateSignature(
	r: Uint8Array,
	s: Uint8Array,
): boolean {
	if (r.length !== 32 || s.length !== 32) {
		throw new Error("Signature components r and s must be 32 bytes each");
	}

	const rArr = new Uint8Array(r);
	const sArr = new Uint8Array(s);

	return primitives.secp256k1ValidateSignature(rArr, sArr);
}

/**
 * Normalize signature to low-S form (EIP-2)
 * Modifies signature components to ensure s is in the lower half of the curve order
 * @param r - R component of signature (32 bytes)
 * @param s - S component of signature (32 bytes)
 * @returns Normalized [r, s] components
 */
export function signatureNormalize(
	r: Uint8Array,
	s: Uint8Array,
): [Uint8Array, Uint8Array] {
	if (r.length !== 32 || s.length !== 32) {
		throw new Error("Signature components r and s must be 32 bytes each");
	}

	const rArr = new Uint8Array(r);
	const sArr = new Uint8Array(s);

	const [normalizedR, normalizedS] = primitives.signatureNormalize(rArr, sArr);
	return [new Uint8Array(normalizedR), new Uint8Array(normalizedS)];
}

/**
 * Check if signature is in canonical form (low-S)
 * @param r - R component of signature (32 bytes)
 * @param s - S component of signature (32 bytes)
 * @returns true if signature is canonical
 */
export function signatureIsCanonical(r: Uint8Array, s: Uint8Array): boolean {
	if (r.length !== 32 || s.length !== 32) {
		throw new Error("Signature components r and s must be 32 bytes each");
	}

	const rArr = new Uint8Array(r);
	const sArr = new Uint8Array(s);

	return primitives.signatureIsCanonical(rArr, sArr);
}

/**
 * Parse signature from compact or standard format
 * @param sigData - Signature bytes (64 or 65 bytes)
 * @returns Parsed signature components
 */
export function signatureParse(sigData: Uint8Array): ParsedSignature {
	if (sigData.length !== 64 && sigData.length !== 65) {
		throw new Error("Signature must be 64 or 65 bytes");
	}

	const sigArr = new Uint8Array(sigData);
	const [r, s, vBytes] = primitives.signatureParse(sigArr);

	return {
		r: new Uint8Array(r),
		s: new Uint8Array(s),
		v: vBytes[0],
	};
}

/**
 * Serialize signature components to compact format
 * @param r - R component of signature (32 bytes)
 * @param s - S component of signature (32 bytes)
 * @param v - Recovery parameter
 * @param includeV - Whether to include v byte (65 bytes) or not (64 bytes)
 * @returns Serialized signature
 */
export function signatureSerialize(
	r: Uint8Array,
	s: Uint8Array,
	v: number,
	includeV: boolean = true,
): Uint8Array {
	if (r.length !== 32 || s.length !== 32) {
		throw new Error("Signature components r and s must be 32 bytes each");
	}

	const rArr = new Uint8Array(r);
	const sArr = new Uint8Array(s);

	return primitives.signatureSerialize(rArr, sArr, v, includeV);
}

// Re-export for convenience
export default {
	secp256k1RecoverPubkey,
	secp256k1RecoverAddress,
	secp256k1PubkeyFromPrivate,
	secp256k1ValidateSignature,
	signatureNormalize,
	signatureIsCanonical,
	signatureParse,
	signatureSerialize,
};
