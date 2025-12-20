/**
 * WASM implementation of Ethereum Address type
 * Uses WebAssembly bindings to Zig implementation
 */

import * as loader from "../../../../wasm/loader.js";

/**
 * Ethereum address (20 bytes)
 * Implemented using WASM Zig code
 */
export class Address {
	private readonly bytes: Uint8Array;

	private constructor(bytes: Uint8Array) {
		if (bytes.length !== 20) {
			throw new Error("Address must be exactly 20 bytes");
		}
		this.bytes = bytes;
	}

	/**
	 * Create address from hex string (with or without 0x prefix)
	 * @param hex - Hex string representation
	 * @returns Address instance
	 */
	static fromHex(hex: string): Address {
		const bytes = loader.addressFromHex(hex);
		return new Address(bytes);
	}

	/**
	 * Create address from 20-byte buffer
	 * @param bytes - 20-byte buffer
	 * @returns Address instance
	 */
	static fromBytes(bytes: Uint8Array): Address {
		return new Address(new Uint8Array(bytes));
	}

	/**
	 * Convert address to hex string (42 chars: "0x" + 40 hex)
	 * @returns Lowercase hex string with 0x prefix
	 */
	toHex(): string {
		return loader.addressToHex(this.bytes);
	}

	/**
	 * Convert address to EIP-55 checksummed hex string
	 * @returns Mixed-case checksummed hex string
	 */
	toChecksumHex(): string {
		return loader.addressToChecksumHex(this.bytes);
	}

	/**
	 * Check if this is the zero address (0x0000...0000)
	 * @returns true if zero address
	 */
	isZero(): boolean {
		return loader.addressIsZero(this.bytes);
	}

	/**
	 * Compare with another address for equality
	 * @param other - Address to compare with
	 * @returns true if addresses are equal
	 */
	equals(other: Address): boolean {
		return loader.addressEquals(this.bytes, other.bytes);
	}

	/**
	 * Validate EIP-55 checksum of a hex string
	 * @param hex - Hex string to validate
	 * @returns true if checksum is valid
	 */
	static validateChecksum(hex: string): boolean {
		return loader.addressValidateChecksum(hex);
	}

	/**
	 * Calculate CREATE contract address (from sender and nonce)
	 * @param sender - Deployer address
	 * @param nonce - Account nonce
	 * @returns Computed contract address
	 */
	static calculateCreateAddress(sender: Address, nonce: number): Address {
		const bytes = loader.calculateCreateAddress(sender.bytes, nonce);
		return new Address(bytes);
	}

	/**
	 * Calculate CREATE2 contract address
	 * @param sender - Deployer address
	 * @param salt - 32-byte salt
	 * @param initCode - Contract initialization code
	 * @returns Computed contract address
	 */
	static calculateCreate2Address(
		sender: Address,
		salt: Uint8Array,
		initCode: Uint8Array,
	): Address {
		const bytes = loader.calculateCreate2Address(sender.bytes, salt, initCode);
		return new Address(bytes);
	}

	/**
	 * Get raw bytes
	 * @returns 20-byte Uint8Array
	 */
	toBytes(): Uint8Array {
		return new Uint8Array(this.bytes);
	}

	/**
	 * String representation (checksummed hex)
	 * @returns Checksummed hex string
	 */
	toString(): string {
		return this.toChecksumHex();
	}
}

// Re-export for convenience
export default Address;
