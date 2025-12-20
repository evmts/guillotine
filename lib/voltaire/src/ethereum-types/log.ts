/**
 * Event Log Type
 *
 * Represents an event log emitted during transaction execution
 * Returned by eth_getLogs, included in transaction receipts
 *
 * Reference: https://github.com/ethereum/execution-apis/blob/main/src/schemas/log.yaml
 */

import type { Address, Bytes, Bytes32, Hash32, Uint } from "./base-types";

/**
 * Event log entry
 *
 * Logs are created by smart contracts during transaction execution.
 * They contain indexed topics for efficient filtering and non-indexed data.
 */
export interface Log {
	/** Whether the log was removed due to a chain reorganization */
	removed?: boolean;

	/** Index of the log in the block */
	logIndex?: Uint;

	/** Index of the transaction that created this log */
	transactionIndex?: Uint;

	/** Hash of the transaction that created this log */
	transactionHash?: Hash32;

	/** Hash of the block containing this log */
	blockHash?: Hash32;

	/** Number of the block containing this log */
	blockNumber?: Uint;

	/** Timestamp of the block containing this log */
	blockTimestamp?: Uint;

	/** Address of the contract that emitted this log */
	address: Address;

	/** Non-indexed data of the log */
	data: Bytes;

	/** Array of 0 to 4 indexed log arguments (topics) */
	topics: readonly Bytes32[];
}

/**
 * Decoded log with event name and parameters
 */
export interface DecodedLog<T = Record<string, unknown>> {
	/** Name of the event */
	eventName: string;

	/** Contract address that emitted the log */
	address: Address;

	/** Decoded event arguments */
	args: T;

	/** Original log */
	log: Log;
}

/**
 * Type guard to check if log has block information
 */
export function hasBlockInfo(
	log: Log,
): log is Log & { blockHash: Hash32; blockNumber: Uint } {
	return log.blockHash !== undefined && log.blockNumber !== undefined;
}

/**
 * Type guard to check if log has transaction information
 */
export function hasTransactionInfo(
	log: Log,
): log is Log & { transactionHash: Hash32; transactionIndex: Uint } {
	return (
		log.transactionHash !== undefined && log.transactionIndex !== undefined
	);
}

/**
 * Type guard to check if log is pending (not yet mined)
 */
export function isPendingLog(log: Log): boolean {
	return !log.blockHash || !log.blockNumber;
}

/**
 * Type guard to check if log was removed due to reorganization
 */
export function isRemovedLog(log: Log): boolean {
	return log.removed === true;
}

/**
 * Get the event signature (topic0) from a log
 * Returns undefined if the log has no topics
 */
export function getEventSignature(log: Log): Bytes32 | undefined {
	return log.topics[0];
}

/**
 * Get indexed parameters (topic1-3) from a log
 */
export function getIndexedParameters(log: Log): readonly Bytes32[] {
	return log.topics.slice(1);
}
