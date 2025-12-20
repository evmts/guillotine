/**
 * WASM implementation of Keccak-256 hashing
 * Uses WebAssembly bindings to Zig implementation
 */

import * as loader from "../../../../wasm/loader.js";

/**
 * Keccak-256 hash (32 bytes)
 */
export class Hash {
	private readonly bytes: Uint8Array;

	private constructor(bytes: Uint8Array) {
		if (bytes.length !== 32) {
			throw new Error("Hash must be exactly 32 bytes");
		}
		this.bytes = bytes;
	}

	/**
	 * Compute Keccak-256 hash of input data
	 * @param data - Input data (string, Uint8Array, or Buffer)
	 * @returns Hash instance
	 */
	static keccak256(data: string | Uint8Array): Hash {
		const input = typeof data === "string"
			? new TextEncoder().encode(data)
			: new Uint8Array(data);
		const hashBytes = loader.keccak256(input);
		return new Hash(hashBytes);
	}

	/**
	 * Create hash from hex string
	 * @param hex - 32-byte hex string (with or without 0x prefix)
	 * @returns Hash instance
	 */
	static fromHex(hex: string): Hash {
		const bytes = loader.hashFromHex(hex);
		return new Hash(bytes);
	}

	/**
	 * Create hash from 32-byte buffer
	 * @param bytes - 32-byte buffer
	 * @returns Hash instance
	 */
	static fromBytes(bytes: Uint8Array): Hash {
		return new Hash(new Uint8Array(bytes));
	}

	/**
	 * Convert hash to hex string (66 chars: "0x" + 64 hex)
	 * @returns Hex string with 0x prefix
	 */
	toHex(): string {
		return loader.hashToHex(this.bytes);
	}

	/**
	 * Compare with another hash for equality (constant-time)
	 * @param other - Hash to compare with
	 * @returns true if hashes are equal
	 */
	equals(other: Hash): boolean {
		return loader.hashEquals(this.bytes, other.bytes);
	}

	/**
	 * Get raw bytes
	 * @returns 32-byte Uint8Array
	 */
	toBytes(): Uint8Array {
		return new Uint8Array(this.bytes);
	}

	/**
	 * String representation (hex)
	 * @returns Hex string with 0x prefix
	 */
	toString(): string {
		return this.toHex();
	}
}

/**
 * Compute Keccak-256 hash and return as hex string
 * @param data - Input data
 * @returns Hex hash string
 */
export function keccak256(data: string | Uint8Array): string {
	return Hash.keccak256(data).toHex();
}

/**
 * Compute EIP-191 personal message hash
 * Prepends "\x19Ethereum Signed Message:\n{length}" to message
 * @param message - Message to hash
 * @returns Hash of formatted message
 */
export function eip191HashMessage(message: string | Uint8Array): Hash {
	const input = typeof message === "string"
		? new TextEncoder().encode(message)
		: new Uint8Array(message);
	const hashBytes = loader.eip191HashMessage(input);
	return Hash.fromBytes(hashBytes);
}

// Re-export for convenience
export default Hash;
