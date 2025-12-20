/**
 * Transaction Info Type
 *
 * Represents a transaction with full block context
 * Returned by eth_getTransactionByHash, eth_getTransactionByBlockHashAndIndex, etc.
 *
 * Reference: https://github.com/ethereum/execution-apis/blob/main/src/schemas/transaction.yaml
 */

import type {
	Address,
	Byte,
	Bytes,
	Bytes32,
	Hash32,
	Uint,
	Uint256,
} from "./base-types";

/**
 * Transaction with block context
 *
 * This is the full transaction object returned by JSON-RPC methods that includes
 * the block information where the transaction was included.
 */
export interface TransactionInfo {
	/** Hash of the block containing this transaction */
	blockHash: Hash32;

	/** Number of the block containing this transaction */
	blockNumber: Uint;

	/** Address of the sender */
	from: Address;

	/** Hash of the transaction */
	hash: Hash32;

	/** Position of the transaction in the block */
	transactionIndex: Uint;

	/** Transaction type (0x0 for legacy, 0x1 for EIP-2930, 0x2 for EIP-1559, 0x3 for EIP-4844, 0x4 for EIP-7702) */
	type: Byte;

	/** Address of the receiver, null for contract creation */
	to: Address | null;

	/** Gas provided by the sender */
	gas: Uint;

	/** Value transferred in wei */
	value: Uint256;

	/** Input data */
	input: Bytes;

	/** Transaction nonce */
	nonce: Uint;

	/** ECDSA signature r */
	r: Uint256;

	/** ECDSA signature s */
	s: Uint256;

	/** ECDSA signature v */
	v: Uint;

	/** Chain ID (for replay protection) */
	chainId?: Uint;

	// Legacy transaction fields
	/** Gas price (legacy transactions) */
	gasPrice?: Uint;

	// EIP-1559 fields
	/** Maximum fee per gas (EIP-1559) */
	maxFeePerGas?: Uint;

	/** Maximum priority fee per gas (EIP-1559) */
	maxPriorityFeePerGas?: Uint;

	// EIP-2930 fields
	/** Access list (EIP-2930, EIP-1559, EIP-4844, EIP-7702) */
	accessList?: AccessListItem[];

	// EIP-4844 fields
	/** Maximum fee per blob gas (EIP-4844) */
	maxFeePerBlobGas?: Uint;

	/** Blob versioned hashes (EIP-4844) */
	blobVersionedHashes?: Bytes32[];

	// EIP-7702 fields
	/** Authorization list (EIP-7702) */
	authorizationList?: Authorization[];
}

/**
 * Access list item (EIP-2930)
 */
export interface AccessListItem {
	/** Address to access */
	address: Address;

	/** Storage keys to access */
	storageKeys: readonly Hash32[];
}

/**
 * Authorization item (EIP-7702)
 *
 * Allows an EOA to delegate its code execution to a contract
 */
export interface Authorization {
	/** Chain ID */
	chainId: Uint;

	/** Address of the contract to delegate to */
	address: Address;

	/** Nonce */
	nonce: Uint;

	/** ECDSA signature v */
	v: Uint;

	/** ECDSA signature r */
	r: Uint256;

	/** ECDSA signature s */
	s: Uint256;
}

/**
 * Type alias for access list
 */
export type AccessList = readonly AccessListItem[];

/**
 * Type guard to check if a transaction is legacy
 */
export function isLegacyTransaction(
	tx: TransactionInfo,
): tx is TransactionInfo & { gasPrice: Uint } {
	return tx.type === "0x0" || tx.type === "0x00";
}

/**
 * Type guard to check if a transaction is EIP-1559
 */
export function isEip1559Transaction(
	tx: TransactionInfo,
): tx is TransactionInfo & {
	maxFeePerGas: Uint;
	maxPriorityFeePerGas: Uint;
} {
	return tx.type === "0x2" || tx.type === "0x02";
}

/**
 * Type guard to check if a transaction is EIP-4844
 */
export function isEip4844Transaction(
	tx: TransactionInfo,
): tx is TransactionInfo & {
	maxFeePerBlobGas: Uint;
	blobVersionedHashes: Bytes32[];
} {
	return tx.type === "0x3" || tx.type === "0x03";
}

/**
 * Type guard to check if a transaction is EIP-7702
 */
export function isEip7702Transaction(
	tx: TransactionInfo,
): tx is TransactionInfo & { authorizationList: Authorization[] } {
	return tx.type === "0x4" || tx.type === "0x04";
}
