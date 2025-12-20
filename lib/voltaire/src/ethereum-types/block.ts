/**
 * Block Types
 *
 * Represents Ethereum block structures
 * Returned by eth_getBlockByHash, eth_getBlockByNumber
 *
 * Reference: https://github.com/ethereum/execution-apis/blob/main/src/schemas/block.yaml
 */

import type {
	Address,
	Bytes,
	Bytes256,
	Hash32,
	Uint,
	Uint256,
} from "./base-types";
import type { Withdrawal } from "./withdrawal";

/**
 * Block header information
 */
export interface BlockInfo {
	/** Block number, null for pending blocks */
	number: Uint | null;

	/** Block hash, null for pending blocks */
	hash: Hash32 | null;

	/** Hash of the parent block */
	parentHash: Hash32;

	/** SHA3 of the uncles data in the block */
	sha3Uncles: Hash32;

	/** Bloom filter for logs in the block */
	logsBloom: Bytes256;

	/** Root of the transaction trie */
	transactionsRoot: Hash32;

	/** Root of the state trie */
	stateRoot: Hash32;

	/** Root of the receipts trie */
	receiptsRoot: Hash32;

	/** Address of the miner/validator who created this block */
	miner: Address;

	/** Difficulty of this block (0 for proof-of-stake) */
	difficulty: Uint;

	/** Total difficulty up to this block (removed post-merge) */
	totalDifficulty?: Uint;

	/** Arbitrary data included in the block */
	extraData: Bytes;

	/** Maximum gas allowed in this block */
	gasLimit: Uint;

	/** Total gas used by all transactions in this block */
	gasUsed: Uint;

	/** Unix timestamp of block creation */
	timestamp: Uint;

	/** Size of the block in bytes */
	size: Uint;

	/** Array of transaction hashes or full transaction objects */
	transactions: readonly (Hash32 | TransactionInBlock)[];

	/** Array of uncle block hashes */
	uncles: readonly Hash32[];

	// Post-London (EIP-1559) fields
	/** Base fee per gas (EIP-1559) */
	baseFeePerGas?: Uint;

	// Post-Shanghai (EIP-4895) fields
	/** Root of the withdrawals trie (EIP-4895) */
	withdrawalsRoot?: Hash32;

	/** Array of withdrawal objects (EIP-4895) */
	withdrawals?: readonly Withdrawal[];

	// Post-Cancun (EIP-4844) fields
	/** Total blob gas used in this block (EIP-4844) */
	blobGasUsed?: Uint;

	/** Excess blob gas (EIP-4844) */
	excessBlobGas?: Uint;

	/** Parent beacon block root (EIP-4788) */
	parentBeaconBlockRoot?: Hash32;

	// Proof-of-stake fields (post-merge)
	/** Mix hash / previous Randao (post-merge) */
	mixHash?: Hash32;

	/** Nonce (proof-of-work only, 0 for proof-of-stake) */
	nonce?: Uint;
}

/**
 * Transaction object as it appears in a block
 * This is a simplified version of TransactionInfo
 */
export interface TransactionInBlock {
	hash: Hash32;
	from: Address;
	to: Address | null;
	value: Uint256;
	gas: Uint;
	input: Bytes;
	nonce: Uint;
	transactionIndex: Uint;
	blockHash: Hash32;
	blockNumber: Uint;
	type: Bytes;
	// ... other transaction fields
}

/**
 * Type guard to check if transactions are full objects
 */
export function hasFullTransactions(
	block: BlockInfo,
): block is BlockInfo & { transactions: readonly TransactionInBlock[] } {
	if (block.transactions.length === 0) {
		return false;
	}
	return typeof block.transactions[0] === "object";
}

/**
 * Type guard to check if transactions are hashes
 */
export function hasTransactionHashes(
	block: BlockInfo,
): block is BlockInfo & { transactions: readonly Hash32[] } {
	if (block.transactions.length === 0) {
		return true; // Empty array defaults to hash mode
	}
	return typeof block.transactions[0] === "string";
}

/**
 * Type guard to check if block is mined (has number and hash)
 */
export function isMinedBlock(
	block: BlockInfo,
): block is BlockInfo & { number: Uint; hash: Hash32 } {
	return block.number !== null && block.hash !== null;
}

/**
 * Type guard to check if block is pending
 */
export function isPendingBlock(block: BlockInfo): boolean {
	return block.number === null || block.hash === null;
}

/**
 * Type guard to check if block is post-London (has base fee)
 */
export function isPostLondonBlock(
	block: BlockInfo,
): block is BlockInfo & { baseFeePerGas: Uint } {
	return block.baseFeePerGas !== undefined;
}

/**
 * Type guard to check if block is post-Shanghai (has withdrawals)
 */
export function isPostShanghaiBlock(block: BlockInfo): block is BlockInfo & {
	withdrawalsRoot: Hash32;
	withdrawals: readonly Withdrawal[];
} {
	return block.withdrawalsRoot !== undefined && block.withdrawals !== undefined;
}

/**
 * Type guard to check if block is post-Cancun (has blob gas)
 */
export function isPostCancunBlock(
	block: BlockInfo,
): block is BlockInfo & { blobGasUsed: Uint; excessBlobGas: Uint } {
	return block.blobGasUsed !== undefined && block.excessBlobGas !== undefined;
}

/**
 * Type guard to check if block is proof-of-stake (post-merge)
 */
export function isProofOfStakeBlock(block: BlockInfo): boolean {
	// Post-merge blocks have difficulty of 0
	return block.difficulty === "0x0";
}
