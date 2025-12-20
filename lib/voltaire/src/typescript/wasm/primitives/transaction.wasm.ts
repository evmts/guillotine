/**
 * WASM implementation of transaction operations
 * Uses WebAssembly bindings to Zig implementation
 */

import * as loader from "../../../../wasm/loader.js";

/**
 * Transaction type enumeration
 */
export enum TransactionType {
	/** Legacy transaction (pre-EIP-2718) */
	Legacy = 0,
	/** EIP-2930 access list transaction */
	EIP2930 = 1,
	/** EIP-1559 fee market transaction */
	EIP1559 = 2,
	/** EIP-4844 blob transaction */
	EIP4844 = 3,
	/** EIP-7702 set code transaction */
	EIP7702 = 4,
}

/**
 * Detect transaction type from RLP-encoded data
 * @param data - RLP-encoded transaction data
 * @returns Transaction type (0-4)
 */
export function detectTransactionType(data: Uint8Array): TransactionType {
	const input = new Uint8Array(data);
	const txType: number = loader.txDetectType(input);

	if (txType < 0 || txType > 4) {
		throw new Error(`Invalid transaction type: ${txType}`);
	}

	return txType as TransactionType;
}

// Re-export for convenience
export default {
	TransactionType,
	detectTransactionType,
};
