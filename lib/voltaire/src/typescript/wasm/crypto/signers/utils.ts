/**
 * WASM implementation of signer utility functions
 */

import type { Signer } from "./private-key-signer.js";

export function getAddress(signer: Signer): string {
	return signer.address;
}

export async function recoverTransactionAddress(_transaction: any): Promise<string> {
	// Note: Transaction address recovery requires:
	// 1. Deserialize transaction from RLP
	// 2. Extract signature (r, s, v)
	// 3. Reconstruct transaction hash
	// 4. Recover address from signature and hash using secp256k1RecoverAddress
	//
	// This requires additional WASM bindings
	throw new Error(
		"recoverTransactionAddress not yet implemented. Requires RLP deserialization and signature recovery bindings",
	);
}
