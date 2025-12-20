/**
 * Withdrawal Type
 *
 * Represents a validator withdrawal from the beacon chain to the execution layer
 * Introduced in the Shanghai/Capella upgrade (EIP-4895)
 *
 * Reference: https://eips.ethereum.org/EIPS/eip-4895
 */

import type { Address, Uint, Uint64, Uint256 } from "./base-types";

/**
 * Validator withdrawal
 *
 * Withdrawals move ETH from the beacon chain (consensus layer) to
 * the execution layer. They appear in blocks after the Shanghai upgrade.
 */
export interface Withdrawal {
	/** Monotonically increasing identifier issued by consensus layer */
	index: Uint;

	/** Index of validator associated with withdrawal */
	validatorIndex: Uint;

	/** Target address for withdrawn ether */
	address: Address;

	/** Amount of withdrawn ether in Gwei (1 ETH = 1,000,000,000 Gwei) */
	amount: Uint;
}

/**
 * Convert withdrawal amount from Gwei to Wei
 *
 * @param gwei Amount in Gwei
 * @returns Amount in Wei (as Uint256)
 */
export function gweiToWei(gwei: Uint): bigint {
	// Parse hex string to bigint
	const gweiValue = BigInt(gwei);
	// 1 Gwei = 10^9 Wei
	return gweiValue * BigInt(1000000000);
}

/**
 * Convert withdrawal amount from Wei to Gwei
 *
 * @param wei Amount in Wei
 * @returns Amount in Gwei (as Uint)
 */
export function weiToGwei(wei: bigint): Uint {
	// 1 Gwei = 10^9 Wei
	const gweiValue = wei / BigInt(1000000000);
	return `0x${gweiValue.toString(16)}` as Uint;
}

/**
 * Convert withdrawal amount to ETH (as decimal number)
 *
 * @param gwei Amount in Gwei
 * @returns Amount in ETH
 */
export function gweiToEth(gwei: Uint): number {
	const gweiValue = BigInt(gwei);
	// 1 ETH = 1,000,000,000 Gwei
	return Number(gweiValue) / 1000000000;
}

/**
 * Type guard to check if a value is a valid withdrawal
 */
export function isValidWithdrawal(value: unknown): value is Withdrawal {
	if (typeof value !== "object" || value === null) {
		return false;
	}

	const w = value as Partial<Withdrawal>;

	return (
		typeof w.index === "string" &&
		w.index.startsWith("0x") &&
		typeof w.validatorIndex === "string" &&
		w.validatorIndex.startsWith("0x") &&
		typeof w.address === "string" &&
		w.address.startsWith("0x") &&
		w.address.length === 42 &&
		typeof w.amount === "string" &&
		w.amount.startsWith("0x")
	);
}
