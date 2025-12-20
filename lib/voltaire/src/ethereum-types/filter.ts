/**
 * Log Filter Types
 *
 * Used for eth_getLogs and eth_newFilter
 * Allows filtering logs by block range, address, and topics
 *
 * Reference: https://github.com/ethereum/execution-apis/blob/main/src/eth/filter.yaml
 */

import type { Address, Bytes32, Uint } from "./base-types";
import type { BlockTag } from "./base-types";

/**
 * Filter topics - array of topic sets for flexible filtering
 *
 * - null matches any topic
 * - Single value matches that specific topic
 * - Array of values matches any of those topics (OR logic)
 */
export type FilterTopic = null | Bytes32 | readonly Bytes32[];

/**
 * Filter topics array
 *
 * Maximum 4 topics (topic0, topic1, topic2, topic3)
 * Each position can use OR logic by providing an array of values
 */
export type FilterTopics = readonly [
	FilterTopic?,
	FilterTopic?,
	FilterTopic?,
	FilterTopic?,
];

/**
 * Log filter parameters
 *
 * Used to filter logs by block range, contract address, and event topics
 */
export interface Filter {
	/** Starting block (inclusive), defaults to "latest" */
	fromBlock?: Uint | BlockTag;

	/** Ending block (inclusive), defaults to "latest" */
	toBlock?: Uint | BlockTag;

	/** Contract address or array of addresses to filter logs from */
	address?: null | Address | readonly Address[];

	/** Array of topics to filter by */
	topics?: FilterTopics;

	/** Block hash to filter logs from (alternative to fromBlock/toBlock range) */
	blockHash?: Bytes32;
}

/**
 * Validates that filter uses either block range OR block hash, not both
 */
export function validateFilter(filter: Filter): boolean {
	if (filter.blockHash) {
		// If blockHash is specified, fromBlock and toBlock must not be present
		return filter.fromBlock === undefined && filter.toBlock === undefined;
	}
	return true;
}

/**
 * Type guard to check if filter uses block range
 */
export function usesBlockRange(filter: Filter): filter is Filter & {
	fromBlock?: Uint | BlockTag;
	toBlock?: Uint | BlockTag;
} {
	return filter.blockHash === undefined;
}

/**
 * Type guard to check if filter uses block hash
 */
export function usesBlockHash(
	filter: Filter,
): filter is Filter & { blockHash: Bytes32 } {
	return filter.blockHash !== undefined;
}

/**
 * Normalize filter address to array
 */
export function normalizeFilterAddress(
	address?: null | Address | readonly Address[],
): readonly Address[] {
	if (!address) {
		return [];
	}
	if (Array.isArray(address)) {
		return address;
	}
	return [address] as readonly Address[];
}

/**
 * Check if a topic matches a filter topic
 */
export function topicMatches(
	logTopic: Bytes32 | undefined,
	filterTopic: FilterTopic,
): boolean {
	// null matches any topic
	if (filterTopic === null || filterTopic === undefined) {
		return true;
	}

	// No log topic but filter expects one
	if (!logTopic) {
		return false;
	}

	// Single topic match
	if (typeof filterTopic === "string") {
		return logTopic === filterTopic;
	}

	// Array of topics (OR logic)
	return (filterTopic as readonly Bytes32[]).includes(logTopic);
}

/**
 * Check if log topics match filter topics
 */
export function topicsMatch(
	logTopics: readonly Bytes32[],
	filterTopics?: FilterTopics,
): boolean {
	if (!filterTopics) {
		return true;
	}

	for (let i = 0; i < filterTopics.length; i++) {
		const filterTopic = filterTopics[i];
		if (filterTopic === undefined) {
			continue;
		}

		if (!topicMatches(logTopics[i], filterTopic)) {
			return false;
		}
	}

	return true;
}
