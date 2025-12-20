/**
 * EIP-712: Typed structured data hashing and signing
 *
 * This module provides TypeScript wrappers for EIP-712 typed data signing.
 * The actual cryptographic operations are implemented in Zig and exposed via C FFI.
 *
 * IMPORTANT: EIP-712 is marked as UNAUDITED in the Zig implementation.
 * Use with caution in production systems.
 */

import { keccak256 } from "./keccak.ts";

export type Hex = `0x${string}`;
export type Address = `0x${string}`;
export type Signature = {
	r: Hex;
	s: Hex;
	v: number;
};

export interface TypedDataDomain {
	name?: string;
	version?: string;
	chainId?: number;
	verifyingContract?: Address;
	salt?: Hex;
}

export interface TypedDataField {
	name: string;
	type: string;
}

export interface TypedData {
	types: Record<string, TypedDataField[]>;
	primaryType: string;
	domain: TypedDataDomain;
	message: Record<string, unknown>;
}

/**
 * Encode a type according to EIP-712 spec
 * @param primaryType - The primary type name
 * @param types - All type definitions
 * @returns Encoded type string
 */
function encodeType(
	primaryType: string,
	types: Record<string, TypedDataField[]>,
): string {
	const deps = new Set<string>();
	const findDependencies = (type: string): void => {
		if (deps.has(type) || !types[type]) return;
		deps.add(type);
		for (const field of types[type]) {
			const baseType = field.type.replace(/\[\]$/, "");
			if (types[baseType]) {
				findDependencies(baseType);
			}
		}
	};

	findDependencies(primaryType);
	deps.delete(primaryType);

	const sortedDeps = [primaryType, ...Array.from(deps).sort()];

	return sortedDeps
		.map((type) => {
			const fields = types[type]
				.map((field) => `${field.type} ${field.name}`)
				.join(",");
			return `${type}(${fields})`;
		})
		.join("");
}

/**
 * Hash a type according to EIP-712
 * @param primaryType - The primary type name
 * @param types - All type definitions
 * @returns Keccak256 hash of the type encoding
 */
function hashType(
	primaryType: string,
	types: Record<string, TypedDataField[]>,
): Hex {
	return keccak256(encodeType(primaryType, types));
}

/**
 * Encode a value according to EIP-712
 * @param type - The type of the value
 * @param value - The value to encode
 * @param types - All type definitions
 * @returns Hex-encoded value
 */
function encodeValue(
	type: string,
	value: unknown,
	types: Record<string, TypedDataField[]>,
): Hex {
	// Handle arrays
	if (type.endsWith("[]")) {
		const baseType = type.slice(0, -2);
		const encodedArray = (value as unknown[])
			.map((item) => encodeValue(baseType, item, types))
			.join("");
		return keccak256(encodedArray);
	}

	// Handle basic types
	if (type === "string") {
		// Encode string as UTF-8 bytes, then hash
		const encoder = new TextEncoder();
		const bytes = encoder.encode(value as string);
		// Convert bytes to hex string for keccak256
		const hexString = `0x${Array.from(bytes)
			.map((b) => b.toString(16).padStart(2, "0"))
			.join("")}`;
		return keccak256(hexString);
	}

	if (type === "bytes") {
		// For bytes, value should already be a hex string
		return keccak256(value as string);
	}

	// Handle bytes32
	if (type === "bytes32") {
		return value as Hex;
	}

	// Handle address
	if (type === "address") {
		const addr = value as string;
		// Pad address to 32 bytes (12 zero bytes + 20 address bytes)
		return `0x${"0".repeat(24)}${addr.slice(2)}` as Hex;
	}

	// Handle numbers (uintN, intN)
	if (type.startsWith("uint") || type.startsWith("int")) {
		const num = BigInt(value as string | number);
		return `0x${num.toString(16).padStart(64, "0")}` as Hex;
	}

	// Handle bool
	if (type === "bool") {
		return `0x${"0".repeat(63)}${value ? "1" : "0"}` as Hex;
	}

	// Handle custom types (structs)
	if (types[type]) {
		return hashStruct(type, value as Record<string, unknown>, types);
	}

	throw new Error(`Unsupported type: ${type}`);
}

/**
 * Hash a struct according to EIP-712
 * @param primaryType - The primary type name
 * @param data - The struct data
 * @param types - All type definitions
 * @returns Keccak256 hash of the encoded struct
 */
function hashStruct(
	primaryType: string,
	data: Record<string, unknown>,
	types: Record<string, TypedDataField[]>,
): Hex {
	const typeHash = hashType(primaryType, types);
	const encodedValues = types[primaryType]
		.map((field) => encodeValue(field.type, data[field.name], types))
		.map((hex) => hex.slice(2))
		.join("");

	return keccak256(`${typeHash}${encodedValues}`);
}

/**
 * Calculate domain separator hash according to EIP-712
 * @param domain - Domain parameters
 * @returns 32-byte hash as hex string with 0x prefix
 */
export function hashDomain(domain: TypedDataDomain): Hex {
	const types: Record<string, TypedDataField[]> = {
		EIP712Domain: [],
	};

	const domainData: Record<string, unknown> = {};

	if (domain.name !== undefined) {
		types.EIP712Domain.push({ name: "name", type: "string" });
		domainData.name = domain.name;
	}
	if (domain.version !== undefined) {
		types.EIP712Domain.push({ name: "version", type: "string" });
		domainData.version = domain.version;
	}
	if (domain.chainId !== undefined) {
		types.EIP712Domain.push({ name: "chainId", type: "uint256" });
		domainData.chainId = domain.chainId;
	}
	if (domain.verifyingContract !== undefined) {
		types.EIP712Domain.push({ name: "verifyingContract", type: "address" });
		domainData.verifyingContract = domain.verifyingContract;
	}
	if (domain.salt !== undefined) {
		types.EIP712Domain.push({ name: "salt", type: "bytes32" });
		domainData.salt = domain.salt;
	}

	return hashStruct("EIP712Domain", domainData, types);
}

/**
 * Hash typed data according to EIP-712
 * Format: keccak256("\x19\x01" ‖ domainSeparator ‖ hashStruct(message))
 * @param typedData - Typed data object
 * @returns 32-byte hash as hex string with 0x prefix
 */
export function hashTypedData(typedData: TypedData): Hex {
	const domainSeparator = hashDomain(typedData.domain);
	const structHash = hashStruct(
		typedData.primaryType,
		typedData.message,
		typedData.types,
	);

	// EIP-712 prefix: \x19\x01
	const prefix = "0x1901";
	const encoded = `${prefix}${domainSeparator.slice(2)}${structHash.slice(2)}`;

	return keccak256(encoded);
}

/**
 * Sign typed data with a private key
 * NOTE: This is a stub implementation that requires proper secp256k1 signing
 * to be exposed via the C API. For now, it throws an error.
 * @param typedData - Typed data object
 * @param privateKey - Private key as hex string
 * @returns Signature object
 */
export function signTypedData(
	typedData: TypedData,
	privateKey: Hex,
): Signature {
	throw new Error(
		"signTypedData not yet implemented - requires secp256k1 C API bindings",
	);
}

/**
 * Verify typed data signature
 * NOTE: This is a stub implementation that requires proper signature recovery
 * to be exposed via the C API. For now, it throws an error.
 * @param typedData - Typed data object
 * @param signature - Signature object or compact hex string
 * @param address - Expected signer address
 * @returns true if signature is valid
 */
export function verifyTypedData(
	typedData: TypedData,
	signature: Signature | Hex,
	address: Address,
): boolean {
	throw new Error(
		"verifyTypedData not yet implemented - requires secp256k1 C API bindings",
	);
}

/**
 * Recover address from typed data signature
 * NOTE: This is a stub implementation that requires proper signature recovery
 * to be exposed via the C API. For now, it throws an error.
 * @param typedData - Typed data object
 * @param signature - Signature object or compact hex string
 * @returns Recovered Ethereum address
 */
export function recoverTypedDataAddress(
	typedData: TypedData,
	signature: Signature | Hex,
): Address {
	throw new Error(
		"recoverTypedDataAddress not yet implemented - requires secp256k1 C API bindings",
	);
}
