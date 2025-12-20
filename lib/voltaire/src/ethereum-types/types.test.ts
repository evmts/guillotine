/**
 * Tests for Ethereum Types
 *
 * Validates type structure, type guards, and utility functions
 */

import { describe, expect, test } from "bun:test";
import type {
	AccessList,
	Address,
	BlockInfo,
	Filter,
	Hash32,
	Log,
	ReceiptInfo,
	TransactionInfo,
	Uint,
	Withdrawal,
} from "./index";
import {
	getEventSignature,
	getIndexedParameters,
	gweiToEth,
	gweiToWei,
	hasBlockInfo,
	hasFullTransactions,
	hasRoot,
	hasStatus,
	hasTransactionHashes,
	hasTransactionInfo,
	isEip1559Transaction,
	isEip4844Receipt,
	isEip4844Transaction,
	isEip7702Transaction,
	isLegacyTransaction,
	isMinedBlock,
	isPendingBlock,
	isPendingLog,
	isPostCancunBlock,
	isPostLondonBlock,
	isPostShanghaiBlock,
	isProofOfStakeBlock,
	isRemovedLog,
	isSuccessful,
	isValidWithdrawal,
	normalizeFilterAddress,
	topicMatches,
	topicsMatch,
	usesBlockHash,
	usesBlockRange,
	validateFilter,
	weiToGwei,
} from "./index";

describe("TransactionInfo", () => {
	test("should create valid legacy transaction", () => {
		const tx: TransactionInfo = {
			blockHash:
				"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
			blockNumber: "0x1" as Uint,
			from: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			hash: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd" as Hash32,
			transactionIndex: "0x0" as Uint,
			type: "0x0",
			to: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			gas: "0x5208" as Uint,
			value: "0xde0b6b3a7640000" as Uint,
			input: "0x" as `0x${string}`,
			nonce: "0x0" as Uint,
			r: "0x1234567890123456789012345678901234567890123456789012345678901234" as Uint,
			s: "0x1234567890123456789012345678901234567890123456789012345678901234" as Uint,
			v: "0x1b" as Uint,
			gasPrice: "0x3b9aca00" as Uint,
		};

		expect(tx.type).toBe("0x0");
		expect(tx.gasPrice).toBeDefined();
		expect(isLegacyTransaction(tx)).toBe(true);
		expect(isEip1559Transaction(tx)).toBe(false);
	});

	test("should create valid EIP-1559 transaction", () => {
		const tx: TransactionInfo = {
			blockHash:
				"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
			blockNumber: "0x1" as Uint,
			from: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			hash: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd" as Hash32,
			transactionIndex: "0x0" as Uint,
			type: "0x2",
			to: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			gas: "0x5208" as Uint,
			value: "0xde0b6b3a7640000" as Uint,
			input: "0x" as `0x${string}`,
			nonce: "0x0" as Uint,
			r: "0x1234567890123456789012345678901234567890123456789012345678901234" as Uint,
			s: "0x1234567890123456789012345678901234567890123456789012345678901234" as Uint,
			v: "0x0" as Uint,
			chainId: "0x1" as Uint,
			maxFeePerGas: "0x3b9aca00" as Uint,
			maxPriorityFeePerGas: "0x59682f00" as Uint,
			accessList: [],
		};

		expect(tx.type).toBe("0x2");
		expect(tx.maxFeePerGas).toBeDefined();
		expect(isEip1559Transaction(tx)).toBe(true);
		expect(isLegacyTransaction(tx)).toBe(false);
	});

	test("should create valid EIP-4844 transaction", () => {
		const tx: TransactionInfo = {
			blockHash:
				"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
			blockNumber: "0x1" as Uint,
			from: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			hash: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd" as Hash32,
			transactionIndex: "0x0" as Uint,
			type: "0x3",
			to: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			gas: "0x5208" as Uint,
			value: "0xde0b6b3a7640000" as Uint,
			input: "0x" as `0x${string}`,
			nonce: "0x0" as Uint,
			r: "0x1234567890123456789012345678901234567890123456789012345678901234" as Uint,
			s: "0x1234567890123456789012345678901234567890123456789012345678901234" as Uint,
			v: "0x0" as Uint,
			chainId: "0x1" as Uint,
			maxFeePerGas: "0x3b9aca00" as Uint,
			maxPriorityFeePerGas: "0x59682f00" as Uint,
			maxFeePerBlobGas: "0x1" as Uint,
			blobVersionedHashes: [
				"0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" as Hash32,
			],
			accessList: [],
		};

		expect(tx.type).toBe("0x3");
		expect(tx.maxFeePerBlobGas).toBeDefined();
		expect(isEip4844Transaction(tx)).toBe(true);
	});

	test("should create valid EIP-7702 transaction", () => {
		const tx: TransactionInfo = {
			blockHash:
				"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
			blockNumber: "0x1" as Uint,
			from: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			hash: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd" as Hash32,
			transactionIndex: "0x0" as Uint,
			type: "0x4",
			to: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			gas: "0x5208" as Uint,
			value: "0xde0b6b3a7640000" as Uint,
			input: "0x" as `0x${string}`,
			nonce: "0x0" as Uint,
			r: "0x1234567890123456789012345678901234567890123456789012345678901234" as Uint,
			s: "0x1234567890123456789012345678901234567890123456789012345678901234" as Uint,
			v: "0x0" as Uint,
			chainId: "0x1" as Uint,
			maxFeePerGas: "0x3b9aca00" as Uint,
			maxPriorityFeePerGas: "0x59682f00" as Uint,
			authorizationList: [
				{
					chainId: "0x1" as Uint,
					address: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
					nonce: "0x0" as Uint,
					v: "0x1b" as Uint,
					r: "0x1234567890123456789012345678901234567890123456789012345678901234" as Uint,
					s: "0x1234567890123456789012345678901234567890123456789012345678901234" as Uint,
				},
			],
			accessList: [],
		};

		expect(tx.type).toBe("0x4");
		expect(tx.authorizationList).toBeDefined();
		expect(isEip7702Transaction(tx)).toBe(true);
	});

	test("should handle access list", () => {
		const accessList: AccessList = [
			{
				address: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
				storageKeys: [
					"0x0000000000000000000000000000000000000000000000000000000000000001" as Hash32,
					"0x0000000000000000000000000000000000000000000000000000000000000002" as Hash32,
				],
			},
		];

		expect(accessList).toHaveLength(1);
		expect(accessList[0].storageKeys).toHaveLength(2);
	});
});

describe("ReceiptInfo", () => {
	test("should create valid successful receipt", () => {
		const receipt: ReceiptInfo = {
			type: "0x2",
			transactionHash:
				"0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd" as Hash32,
			transactionIndex: "0x0" as Uint,
			blockHash:
				"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
			blockNumber: "0x1" as Uint,
			from: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			to: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			cumulativeGasUsed: "0x5208" as Uint,
			gasUsed: "0x5208" as Uint,
			contractAddress: null,
			logs: [],
			logsBloom:
				"0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`,
			status: "0x1" as Uint,
			effectiveGasPrice: "0x3b9aca00" as Uint,
		};

		expect(hasStatus(receipt)).toBe(true);
		expect(hasRoot(receipt)).toBe(false);
		expect(isSuccessful(receipt)).toBe(true);
	});

	test("should create valid failed receipt", () => {
		const receipt: ReceiptInfo = {
			type: "0x2",
			transactionHash:
				"0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd" as Hash32,
			transactionIndex: "0x0" as Uint,
			blockHash:
				"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
			blockNumber: "0x1" as Uint,
			from: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			to: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			cumulativeGasUsed: "0x5208" as Uint,
			gasUsed: "0x5208" as Uint,
			contractAddress: null,
			logs: [],
			logsBloom:
				"0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`,
			status: "0x0" as Uint,
			effectiveGasPrice: "0x3b9aca00" as Uint,
		};

		expect(isSuccessful(receipt)).toBe(false);
	});

	test("should create valid EIP-4844 receipt", () => {
		const receipt: ReceiptInfo = {
			type: "0x3",
			transactionHash:
				"0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd" as Hash32,
			transactionIndex: "0x0" as Uint,
			blockHash:
				"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
			blockNumber: "0x1" as Uint,
			from: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			to: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			cumulativeGasUsed: "0x5208" as Uint,
			gasUsed: "0x5208" as Uint,
			blobGasUsed: "0x20000" as Uint,
			contractAddress: null,
			logs: [],
			logsBloom:
				"0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`,
			status: "0x1" as Uint,
			effectiveGasPrice: "0x3b9aca00" as Uint,
			blobGasPrice: "0x1" as Uint,
		};

		expect(isEip4844Receipt(receipt)).toBe(true);
	});

	test("should create contract creation receipt", () => {
		const receipt: ReceiptInfo = {
			type: "0x0",
			transactionHash:
				"0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd" as Hash32,
			transactionIndex: "0x0" as Uint,
			blockHash:
				"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
			blockNumber: "0x1" as Uint,
			from: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			to: null,
			cumulativeGasUsed: "0x5208" as Uint,
			gasUsed: "0x5208" as Uint,
			contractAddress: "0x1234567890123456789012345678901234567890" as Address,
			logs: [],
			logsBloom:
				"0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`,
			status: "0x1" as Uint,
			effectiveGasPrice: "0x3b9aca00" as Uint,
		};

		expect(receipt.to).toBeNull();
		expect(receipt.contractAddress).not.toBeNull();
	});
});

describe("Log", () => {
	test("should create valid log", () => {
		const log: Log = {
			address: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			topics: [
				"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" as Hash32,
				"0x0000000000000000000000000000000000000000000000000000000000000001" as Hash32,
			],
			data: "0x0000000000000000000000000000000000000000000000000de0b6b3a7640000" as `0x${string}`,
			blockNumber: "0x1" as Uint,
			transactionHash:
				"0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd" as Hash32,
			transactionIndex: "0x0" as Uint,
			blockHash:
				"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
			logIndex: "0x0" as Uint,
			removed: false,
		};

		expect(hasBlockInfo(log)).toBe(true);
		expect(hasTransactionInfo(log)).toBe(true);
		expect(isPendingLog(log)).toBe(false);
		expect(isRemovedLog(log)).toBe(false);
	});

	test("should handle pending log", () => {
		const log: Log = {
			address: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			topics: [
				"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" as Hash32,
			],
			data: "0x0000000000000000000000000000000000000000000000000de0b6b3a7640000" as `0x${string}`,
		};

		expect(isPendingLog(log)).toBe(true);
	});

	test("should get event signature", () => {
		const log: Log = {
			address: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			topics: [
				"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" as Hash32,
				"0x0000000000000000000000000000000000000000000000000000000000000001" as Hash32,
			],
			data: "0x0000000000000000000000000000000000000000000000000de0b6b3a7640000" as `0x${string}`,
		};

		const signature = getEventSignature(log);
		expect(signature).toBe(
			"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
		);

		const indexed = getIndexedParameters(log);
		expect(indexed).toHaveLength(1);
		expect(indexed[0]).toBe(
			"0x0000000000000000000000000000000000000000000000000000000000000001",
		);
	});
});

describe("Filter", () => {
	test("should create valid filter with block range", () => {
		const filter: Filter = {
			fromBlock: "0x1" as Uint,
			toBlock: "0x10" as Uint,
			address: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			topics: [
				"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" as Hash32,
			],
		};

		expect(validateFilter(filter)).toBe(true);
		expect(usesBlockRange(filter)).toBe(true);
		expect(usesBlockHash(filter)).toBe(false);
	});

	test("should create valid filter with block hash", () => {
		const filter: Filter = {
			blockHash:
				"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
			address: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
		};

		expect(validateFilter(filter)).toBe(true);
		expect(usesBlockHash(filter)).toBe(true);
		expect(usesBlockRange(filter)).toBe(false);
	});

	test("should validate filter with block hash and range", () => {
		const filter: Filter = {
			fromBlock: "0x1" as Uint,
			blockHash:
				"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
			address: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
		};

		expect(validateFilter(filter)).toBe(false);
	});

	test("should normalize filter address", () => {
		const single = normalizeFilterAddress(
			"0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
		);
		expect(single).toHaveLength(1);

		const multiple = normalizeFilterAddress([
			"0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			"0x1234567890123456789012345678901234567890" as Address,
		]);
		expect(multiple).toHaveLength(2);

		const empty = normalizeFilterAddress(null);
		expect(empty).toHaveLength(0);
	});

	test("should match topics", () => {
		const topic =
			"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" as Hash32;

		expect(topicMatches(topic, null)).toBe(true);
		expect(topicMatches(topic, topic)).toBe(true);
		expect(topicMatches(topic, [topic])).toBe(true);
		expect(
			topicMatches(
				topic,
				"0x0000000000000000000000000000000000000000000000000000000000000001" as Hash32,
			),
		).toBe(false);
	});

	test("should match log topics", () => {
		const logTopics: Hash32[] = [
			"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" as Hash32,
			"0x0000000000000000000000000000000000000000000000000000000000000001" as Hash32,
		];

		const filterTopics1: [Hash32] = [
			"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" as Hash32,
		];
		expect(topicsMatch(logTopics, filterTopics1)).toBe(true);

		const filterTopics2: [Hash32, Hash32] = [
			"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" as Hash32,
			"0x0000000000000000000000000000000000000000000000000000000000000001" as Hash32,
		];
		expect(topicsMatch(logTopics, filterTopics2)).toBe(true);

		const filterTopics3: [Hash32, Hash32] = [
			"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" as Hash32,
			"0x0000000000000000000000000000000000000000000000000000000000000002" as Hash32,
		];
		expect(topicsMatch(logTopics, filterTopics3)).toBe(false);
	});
});

describe("Withdrawal", () => {
	test("should create valid withdrawal", () => {
		const withdrawal: Withdrawal = {
			index: "0x1" as Uint,
			validatorIndex: "0x64" as Uint,
			address: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
			amount: "0x3b9aca00" as Uint, // 1 ETH in Gwei
		};

		expect(isValidWithdrawal(withdrawal)).toBe(true);
	});

	test("should convert Gwei to Wei", () => {
		const gwei = "0x3b9aca00" as Uint; // 1 ETH in Gwei
		const wei = gweiToWei(gwei);
		expect(wei).toBe(BigInt("1000000000000000000"));
	});

	test("should convert Wei to Gwei", () => {
		const wei = BigInt("1000000000000000000"); // 1 ETH in Wei
		const gwei = weiToGwei(wei);
		expect(gwei).toBe("0x3b9aca00");
	});

	test("should convert Gwei to ETH", () => {
		const gwei = "0x3b9aca00" as Uint; // 1 ETH in Gwei
		const eth = gweiToEth(gwei);
		expect(eth).toBe(1);
	});
});

describe("Block", () => {
	test("should create valid mined block", () => {
		const block: BlockInfo = {
			number: "0x1" as Uint,
			hash: "0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
			parentHash:
				"0x0000000000000000000000000000000000000000000000000000000000000000" as Hash32,
			sha3Uncles:
				"0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347" as Hash32,
			logsBloom:
				"0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`,
			transactionsRoot:
				"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421" as Hash32,
			stateRoot:
				"0xd7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544" as Hash32,
			receiptsRoot:
				"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421" as Hash32,
			miner: "0x0000000000000000000000000000000000000000" as Address,
			difficulty: "0x0" as Uint,
			extraData: "0x" as `0x${string}`,
			gasLimit: "0x1c9c380" as Uint,
			gasUsed: "0x0" as Uint,
			timestamp: "0x5f5e100" as Uint,
			size: "0x220" as Uint,
			transactions: [],
			uncles: [],
		};

		expect(isMinedBlock(block)).toBe(true);
		expect(isPendingBlock(block)).toBe(false);
		expect(isProofOfStakeBlock(block)).toBe(true);
	});

	test("should create post-London block", () => {
		const block: BlockInfo = {
			number: "0x1" as Uint,
			hash: "0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
			parentHash:
				"0x0000000000000000000000000000000000000000000000000000000000000000" as Hash32,
			sha3Uncles:
				"0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347" as Hash32,
			logsBloom:
				"0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`,
			transactionsRoot:
				"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421" as Hash32,
			stateRoot:
				"0xd7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544" as Hash32,
			receiptsRoot:
				"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421" as Hash32,
			miner: "0x0000000000000000000000000000000000000000" as Address,
			difficulty: "0x0" as Uint,
			extraData: "0x" as `0x${string}`,
			gasLimit: "0x1c9c380" as Uint,
			gasUsed: "0x0" as Uint,
			timestamp: "0x5f5e100" as Uint,
			size: "0x220" as Uint,
			transactions: [],
			uncles: [],
			baseFeePerGas: "0x7" as Uint,
		};

		expect(isPostLondonBlock(block)).toBe(true);
	});

	test("should create post-Shanghai block", () => {
		const block: BlockInfo = {
			number: "0x1" as Uint,
			hash: "0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
			parentHash:
				"0x0000000000000000000000000000000000000000000000000000000000000000" as Hash32,
			sha3Uncles:
				"0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347" as Hash32,
			logsBloom:
				"0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`,
			transactionsRoot:
				"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421" as Hash32,
			stateRoot:
				"0xd7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544" as Hash32,
			receiptsRoot:
				"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421" as Hash32,
			miner: "0x0000000000000000000000000000000000000000" as Address,
			difficulty: "0x0" as Uint,
			extraData: "0x" as `0x${string}`,
			gasLimit: "0x1c9c380" as Uint,
			gasUsed: "0x0" as Uint,
			timestamp: "0x5f5e100" as Uint,
			size: "0x220" as Uint,
			transactions: [],
			uncles: [],
			baseFeePerGas: "0x7" as Uint,
			withdrawalsRoot:
				"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421" as Hash32,
			withdrawals: [
				{
					index: "0x1" as Uint,
					validatorIndex: "0x64" as Uint,
					address: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
					amount: "0x3b9aca00" as Uint,
				},
			],
		};

		expect(isPostShanghaiBlock(block)).toBe(true);
	});

	test("should create post-Cancun block", () => {
		const block: BlockInfo = {
			number: "0x1" as Uint,
			hash: "0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
			parentHash:
				"0x0000000000000000000000000000000000000000000000000000000000000000" as Hash32,
			sha3Uncles:
				"0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347" as Hash32,
			logsBloom:
				"0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`,
			transactionsRoot:
				"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421" as Hash32,
			stateRoot:
				"0xd7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544" as Hash32,
			receiptsRoot:
				"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421" as Hash32,
			miner: "0x0000000000000000000000000000000000000000" as Address,
			difficulty: "0x0" as Uint,
			extraData: "0x" as `0x${string}`,
			gasLimit: "0x1c9c380" as Uint,
			gasUsed: "0x0" as Uint,
			timestamp: "0x5f5e100" as Uint,
			size: "0x220" as Uint,
			transactions: [],
			uncles: [],
			baseFeePerGas: "0x7" as Uint,
			blobGasUsed: "0x20000" as Uint,
			excessBlobGas: "0x0" as Uint,
			parentBeaconBlockRoot:
				"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
		};

		expect(isPostCancunBlock(block)).toBe(true);
	});

	test("should handle transaction hashes", () => {
		const block: BlockInfo = {
			number: "0x1" as Uint,
			hash: "0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
			parentHash:
				"0x0000000000000000000000000000000000000000000000000000000000000000" as Hash32,
			sha3Uncles:
				"0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347" as Hash32,
			logsBloom:
				"0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`,
			transactionsRoot:
				"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421" as Hash32,
			stateRoot:
				"0xd7f8974fb5ac78d9ac099b9ad5018bedc2ce0a72dad1827a1709da30580f0544" as Hash32,
			receiptsRoot:
				"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421" as Hash32,
			miner: "0x0000000000000000000000000000000000000000" as Address,
			difficulty: "0x0" as Uint,
			extraData: "0x" as `0x${string}`,
			gasLimit: "0x1c9c380" as Uint,
			gasUsed: "0x0" as Uint,
			timestamp: "0x5f5e100" as Uint,
			size: "0x220" as Uint,
			transactions: [
				"0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd" as Hash32,
			],
			uncles: [],
		};

		expect(hasTransactionHashes(block)).toBe(true);
		expect(hasFullTransactions(block)).toBe(false);
	});
});
