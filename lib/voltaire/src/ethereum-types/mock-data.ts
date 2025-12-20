/**
 * Mock Data for Ethereum Types
 *
 * Example data for testing and documentation purposes
 */

import type {
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

/**
 * Mock legacy transaction (Type 0)
 */
export const mockLegacyTransaction: TransactionInfo = {
	blockHash:
		"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
	blockNumber: "0x1" as Uint,
	from: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
	hash: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd" as Hash32,
	transactionIndex: "0x0" as Uint,
	type: "0x0",
	to: "0x1234567890123456789012345678901234567890" as Address,
	gas: "0x5208" as Uint,
	value: "0xde0b6b3a7640000" as Uint, // 1 ETH
	input: "0x" as `0x${string}`,
	nonce: "0x0" as Uint,
	r: "0x88ff6cf0fefd94db46111149ae4bfc179e9b94721fffd821d38d16464b3f71d0" as Uint,
	s: "0x45e0aff800961cfce805daef7016b9b675c137a6a41a548f7b60a3484c06a33a" as Uint,
	v: "0x1c" as Uint,
	gasPrice: "0x4a817c800" as Uint, // 20 Gwei
	chainId: "0x1" as Uint,
};

/**
 * Mock EIP-1559 transaction (Type 2)
 */
export const mockEip1559Transaction: TransactionInfo = {
	blockHash:
		"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
	blockNumber: "0x1" as Uint,
	from: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
	hash: "0xdef789def789def789def789def789def789def789def789def789def789def7" as Hash32,
	transactionIndex: "0x1" as Uint,
	type: "0x2",
	to: "0x1234567890123456789012345678901234567890" as Address,
	gas: "0x5208" as Uint,
	value: "0xde0b6b3a7640000" as Uint, // 1 ETH
	input: "0x" as `0x${string}`,
	nonce: "0x5" as Uint,
	r: "0x88ff6cf0fefd94db46111149ae4bfc179e9b94721fffd821d38d16464b3f71d0" as Uint,
	s: "0x45e0aff800961cfce805daef7016b9b675c137a6a41a548f7b60a3484c06a33a" as Uint,
	v: "0x0" as Uint,
	chainId: "0x1" as Uint,
	maxFeePerGas: "0x59682f00" as Uint, // 1.5 Gwei
	maxPriorityFeePerGas: "0x3b9aca00" as Uint, // 1 Gwei
	accessList: [
		{
			address: "0x1234567890123456789012345678901234567890" as Address,
			storageKeys: [
				"0x0000000000000000000000000000000000000000000000000000000000000001" as Hash32,
				"0x0000000000000000000000000000000000000000000000000000000000000002" as Hash32,
			],
		},
	],
};

/**
 * Mock EIP-4844 transaction (Type 3)
 */
export const mockEip4844Transaction: TransactionInfo = {
	blockHash:
		"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
	blockNumber: "0x1" as Uint,
	from: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
	hash: "0x456789456789456789456789456789456789456789456789456789456789456789" as Hash32,
	transactionIndex: "0x2" as Uint,
	type: "0x3",
	to: "0x1234567890123456789012345678901234567890" as Address,
	gas: "0x7a120" as Uint,
	value: "0x0" as Uint,
	input: "0xabcd1234" as `0x${string}`,
	nonce: "0xa" as Uint,
	r: "0x88ff6cf0fefd94db46111149ae4bfc179e9b94721fffd821d38d16464b3f71d0" as Uint,
	s: "0x45e0aff800961cfce805daef7016b9b675c137a6a41a548f7b60a3484c06a33a" as Uint,
	v: "0x0" as Uint,
	chainId: "0x1" as Uint,
	maxFeePerGas: "0x59682f00" as Uint,
	maxPriorityFeePerGas: "0x3b9aca00" as Uint,
	maxFeePerBlobGas: "0x1" as Uint,
	blobVersionedHashes: [
		"0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" as Hash32,
		"0xfedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210" as Hash32,
	],
	accessList: [],
};

/**
 * Mock EIP-7702 transaction (Type 4)
 */
export const mockEip7702Transaction: TransactionInfo = {
	blockHash:
		"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
	blockNumber: "0x1" as Uint,
	from: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
	hash: "0x789abc789abc789abc789abc789abc789abc789abc789abc789abc789abc789abc" as Hash32,
	transactionIndex: "0x3" as Uint,
	type: "0x4",
	to: "0x1234567890123456789012345678901234567890" as Address,
	gas: "0x5208" as Uint,
	value: "0x0" as Uint,
	input: "0x" as `0x${string}`,
	nonce: "0xf" as Uint,
	r: "0x88ff6cf0fefd94db46111149ae4bfc179e9b94721fffd821d38d16464b3f71d0" as Uint,
	s: "0x45e0aff800961cfce805daef7016b9b675c137a6a41a548f7b60a3484c06a33a" as Uint,
	v: "0x0" as Uint,
	chainId: "0x1" as Uint,
	maxFeePerGas: "0x59682f00" as Uint,
	maxPriorityFeePerGas: "0x3b9aca00" as Uint,
	authorizationList: [
		{
			chainId: "0x1" as Uint,
			address: "0x9876543210987654321098765432109876543210" as Address,
			nonce: "0x0" as Uint,
			v: "0x1b" as Uint,
			r: "0x1234567890123456789012345678901234567890123456789012345678901234" as Uint,
			s: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd" as Uint,
		},
	],
	accessList: [],
};

/**
 * Mock ERC-20 Transfer event log
 * Event signature: Transfer(address indexed from, address indexed to, uint256 value)
 */
export const mockTransferLog: Log = {
	address: "0x1234567890123456789012345678901234567890" as Address,
	topics: [
		// Transfer event signature
		"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" as Hash32,
		// from address (indexed)
		"0x000000000000000000000000742d35cc6634c0532925a3b844bc9e7595f0beb" as Hash32,
		// to address (indexed)
		"0x0000000000000000000000001234567890123456789012345678901234567890" as Hash32,
	],
	data: "0x0000000000000000000000000000000000000000000000000de0b6b3a7640000" as `0x${string}`, // 1 ETH value
	blockNumber: "0x1" as Uint,
	transactionHash:
		"0xdef789def789def789def789def789def789def789def789def789def789def7" as Hash32,
	transactionIndex: "0x1" as Uint,
	blockHash:
		"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
	logIndex: "0x0" as Uint,
	removed: false,
};

/**
 * Mock successful transaction receipt
 */
export const mockSuccessfulReceipt: ReceiptInfo = {
	type: "0x2",
	transactionHash:
		"0xdef789def789def789def789def789def789def789def789def789def789def7" as Hash32,
	transactionIndex: "0x1" as Uint,
	blockHash:
		"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
	blockNumber: "0x1" as Uint,
	from: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
	to: "0x1234567890123456789012345678901234567890" as Address,
	cumulativeGasUsed: "0xa410" as Uint,
	gasUsed: "0x5208" as Uint,
	contractAddress: null,
	logs: [mockTransferLog],
	logsBloom:
		"0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`,
	status: "0x1" as Uint,
	effectiveGasPrice: "0x4a817c800" as Uint,
};

/**
 * Mock failed transaction receipt
 */
export const mockFailedReceipt: ReceiptInfo = {
	type: "0x2",
	transactionHash:
		"0xbad123bad123bad123bad123bad123bad123bad123bad123bad123bad123bad1" as Hash32,
	transactionIndex: "0x5" as Uint,
	blockHash:
		"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
	blockNumber: "0x1" as Uint,
	from: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
	to: "0x1234567890123456789012345678901234567890" as Address,
	cumulativeGasUsed: "0x14a28" as Uint,
	gasUsed: "0x5208" as Uint,
	contractAddress: null,
	logs: [],
	logsBloom:
		"0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`,
	status: "0x0" as Uint,
	effectiveGasPrice: "0x4a817c800" as Uint,
};

/**
 * Mock contract creation receipt
 */
export const mockContractCreationReceipt: ReceiptInfo = {
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
	contractAddress: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd" as Address,
	logs: [],
	logsBloom:
		"0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" as `0x${string}`,
	status: "0x1" as Uint,
	effectiveGasPrice: "0x4a817c800" as Uint,
};

/**
 * Mock pending log (no block information)
 */
export const mockPendingLog: Log = {
	address: "0x1234567890123456789012345678901234567890" as Address,
	topics: [
		"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" as Hash32,
	],
	data: "0x0000000000000000000000000000000000000000000000000de0b6b3a7640000" as `0x${string}`,
};

/**
 * Mock log filter with block range
 */
export const mockBlockRangeFilter: Filter = {
	fromBlock: "0x1" as Uint,
	toBlock: "0x100" as Uint,
	address: "0x1234567890123456789012345678901234567890" as Address,
	topics: [
		"0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef" as Hash32,
		null, // Match any 'from' address
		null, // Match any 'to' address
	],
};

/**
 * Mock log filter with block hash
 */
export const mockBlockHashFilter: Filter = {
	blockHash:
		"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
	address: [
		"0x1234567890123456789012345678901234567890" as Address,
		"0x9876543210987654321098765432109876543210" as Address,
	],
};

/**
 * Mock withdrawal
 */
export const mockWithdrawal: Withdrawal = {
	index: "0x1" as Uint,
	validatorIndex: "0x64" as Uint, // Validator 100
	address: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb0" as Address,
	amount: "0x3b9aca00" as Uint, // 1 ETH in Gwei
};

/**
 * Mock post-Merge block (proof-of-stake)
 */
export const mockPostMergeBlock: BlockInfo = {
	number: "0x1000" as Uint,
	hash: "0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
	parentHash:
		"0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" as Hash32,
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
	difficulty: "0x0" as Uint, // Proof-of-stake has 0 difficulty
	extraData: "0x" as `0x${string}`,
	gasLimit: "0x1c9c380" as Uint,
	gasUsed: "0xa410" as Uint,
	timestamp: "0x64f5d5e0" as Uint,
	size: "0x3e8" as Uint,
	transactions: [
		"0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd" as Hash32,
		"0xdef789def789def789def789def789def789def789def789def789def789def7" as Hash32,
	],
	uncles: [],
	baseFeePerGas: "0x7" as Uint,
	mixHash:
		"0x0000000000000000000000000000000000000000000000000000000000000000" as Hash32,
	nonce: "0x0" as Uint,
};

/**
 * Mock post-Shanghai block (with withdrawals)
 */
export const mockPostShanghaiBlock: BlockInfo = {
	...mockPostMergeBlock,
	number: "0x2000" as Uint,
	withdrawalsRoot:
		"0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421" as Hash32,
	withdrawals: [mockWithdrawal],
};

/**
 * Mock post-Cancun block (with blob gas)
 */
export const mockPostCancunBlock: BlockInfo = {
	...mockPostShanghaiBlock,
	number: "0x3000" as Uint,
	blobGasUsed: "0x20000" as Uint,
	excessBlobGas: "0x0" as Uint,
	parentBeaconBlockRoot:
		"0x1234567890123456789012345678901234567890123456789012345678901234" as Hash32,
};
