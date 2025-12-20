# Ethereum Types

Comprehensive TypeScript interfaces for Ethereum data structures based on the official [execution-apis specification](https://github.com/ethereum/execution-apis).

## Overview

This module provides type-safe interfaces for all major Ethereum data structures including transactions, receipts, logs, blocks, and more. All types follow the official JSON-RPC API specification and support all Ethereum network upgrades from legacy to the latest EIPs.

## Features

- **Complete Type Coverage**: All transaction types (Legacy, EIP-1559, EIP-4844, EIP-7702)
- **Type Guards**: Runtime validation with TypeScript type narrowing
- **Utility Functions**: Helper functions for filtering, validation, and conversion
- **Mock Data**: Example data for testing and documentation
- **Well Documented**: JSDoc comments with EIP references

## Installation

```typescript
import type {
  TransactionInfo,
  ReceiptInfo,
  Log,
  Filter,
  BlockInfo,
  Withdrawal
} from "./ethereum-types";
```

## Type Structure

### Base Types

Fundamental hex-encoded types used throughout:

```typescript
type Byte = `0x${string}`;           // Single byte
type Bytes = `0x${string}`;          // Variable-length bytes
type Bytes32 = `0x${string}`;        // 32-byte fixed length
type Bytes256 = `0x${string}`;       // 256-byte fixed length
type Address = `0x${string}`;        // 20-byte Ethereum address
type Hash32 = `0x${string}`;         // 32-byte hash
type Uint = `0x${string}`;           // Unsigned integer
```

### Transaction Types

#### TransactionInfo

Complete transaction with block context returned by `eth_getTransactionByHash`:

```typescript
interface TransactionInfo {
  blockHash: Hash32;
  blockNumber: Uint;
  from: Address;
  hash: Hash32;
  transactionIndex: Uint;
  type: Byte;
  to: Address | null;
  gas: Uint;
  value: Uint256;
  input: Bytes;
  nonce: Uint;
  r: Uint256;
  s: Uint256;
  v: Uint;
  // Type-specific fields...
}
```

**Supported Transaction Types:**

- **Legacy (0x0)**: Original transaction format with `gasPrice`
- **EIP-1559 (0x2)**: Fee market with `maxFeePerGas` and `maxPriorityFeePerGas`
- **EIP-4844 (0x3)**: Blob transactions with `blobVersionedHashes` and `maxFeePerBlobGas`
- **EIP-7702 (0x4)**: Account abstraction with `authorizationList`

**Type Guards:**

```typescript
if (isLegacyTransaction(tx)) {
  // tx.gasPrice is available
}

if (isEip1559Transaction(tx)) {
  // tx.maxFeePerGas and tx.maxPriorityFeePerGas are available
}

if (isEip4844Transaction(tx)) {
  // tx.blobVersionedHashes is available
}

if (isEip7702Transaction(tx)) {
  // tx.authorizationList is available
}
```

### Receipt Types

#### ReceiptInfo

Transaction receipt returned by `eth_getTransactionReceipt`:

```typescript
interface ReceiptInfo {
  type: Byte;
  transactionHash: Hash32;
  transactionIndex: Uint;
  blockHash: Hash32;
  blockNumber: Uint;
  from: Address;
  to: Address | null;
  cumulativeGasUsed: Uint;
  gasUsed: Uint;
  contractAddress: Address | null;
  logs: readonly Log[];
  logsBloom: Bytes256;
  status?: Uint;              // Post-Byzantium
  root?: Hash32;              // Pre-Byzantium
  effectiveGasPrice: Uint;
  // EIP-4844 fields
  blobGasUsed?: Uint;
  blobGasPrice?: Uint;
}
```

**Type Guards:**

```typescript
if (hasStatus(receipt)) {
  // receipt.status is available (post-Byzantium)
}

if (hasRoot(receipt)) {
  // receipt.root is available (pre-Byzantium)
}

if (isSuccessful(receipt)) {
  // Transaction succeeded
}

if (isEip4844Receipt(receipt)) {
  // receipt.blobGasUsed and receipt.blobGasPrice are available
}
```

### Log Types

#### Log

Event log emitted during transaction execution:

```typescript
interface Log {
  removed?: boolean;
  logIndex?: Uint;
  transactionIndex?: Uint;
  transactionHash?: Hash32;
  blockHash?: Hash32;
  blockNumber?: Uint;
  blockTimestamp?: Uint;
  address: Address;
  data: Bytes;
  topics: readonly Bytes32[];
}
```

**Utility Functions:**

```typescript
// Get event signature (topic0)
const signature = getEventSignature(log);

// Get indexed parameters (topic1-3)
const indexed = getIndexedParameters(log);

// Check if log is mined
if (hasBlockInfo(log)) {
  // log.blockHash and log.blockNumber are available
}

// Check if log is pending
if (isPendingLog(log)) {
  // Log not yet included in a block
}

// Check if log was removed due to reorg
if (isRemovedLog(log)) {
  // Handle reorganization
}
```

### Filter Types

#### Filter

Log filter for `eth_getLogs` and `eth_newFilter`:

```typescript
interface Filter {
  fromBlock?: Uint | BlockTag;
  toBlock?: Uint | BlockTag;
  address?: null | Address | readonly Address[];
  topics?: FilterTopics;
  blockHash?: Bytes32;
}
```

**Topic Filtering:**

Topics support flexible OR logic:

```typescript
const filter: Filter = {
  fromBlock: "0x1",
  toBlock: "latest",
  address: "0x1234...",
  topics: [
    "0xddf252ad...",  // Must match this event signature
    null,             // Match any 'from' address
    [                 // Match any of these 'to' addresses (OR logic)
      "0xabcd...",
      "0xef01..."
    ]
  ]
};
```

**Type Guards:**

```typescript
if (usesBlockRange(filter)) {
  // filter.fromBlock and filter.toBlock available
}

if (usesBlockHash(filter)) {
  // filter.blockHash available
  // Cannot use both blockHash and block range
}

// Validate filter
if (!validateFilter(filter)) {
  throw new Error("Invalid filter: cannot use both blockHash and block range");
}
```

**Utility Functions:**

```typescript
// Normalize address to array
const addresses = normalizeFilterAddress(filter.address);

// Check if topic matches filter topic
if (topicMatches(logTopic, filterTopic)) {
  // Topic matches
}

// Check if all log topics match filter topics
if (topicsMatch(log.topics, filter.topics)) {
  // Log matches filter
}
```

### Block Types

#### BlockInfo

Block header and transaction list returned by `eth_getBlockByHash` and `eth_getBlockByNumber`:

```typescript
interface BlockInfo {
  number: Uint | null;
  hash: Hash32 | null;
  parentHash: Hash32;
  // ... other fields
  transactions: readonly (Hash32 | TransactionInBlock)[];

  // Post-London (EIP-1559)
  baseFeePerGas?: Uint;

  // Post-Shanghai (EIP-4895)
  withdrawalsRoot?: Hash32;
  withdrawals?: readonly Withdrawal[];

  // Post-Cancun (EIP-4844)
  blobGasUsed?: Uint;
  excessBlobGas?: Uint;
  parentBeaconBlockRoot?: Hash32;
}
```

**Type Guards:**

```typescript
if (isMinedBlock(block)) {
  // block.number and block.hash are not null
}

if (isPendingBlock(block)) {
  // Block not yet mined
}

if (isProofOfStakeBlock(block)) {
  // Post-merge block (difficulty === 0)
}

if (isPostLondonBlock(block)) {
  // block.baseFeePerGas is available
}

if (isPostShanghaiBlock(block)) {
  // block.withdrawals is available
}

if (isPostCancunBlock(block)) {
  // block.blobGasUsed is available
}

if (hasFullTransactions(block)) {
  // block.transactions contains full transaction objects
}

if (hasTransactionHashes(block)) {
  // block.transactions contains only hashes
}
```

### Withdrawal Types

#### Withdrawal

Validator withdrawal from beacon chain to execution layer (EIP-4895):

```typescript
interface Withdrawal {
  index: Uint;
  validatorIndex: Uint;
  address: Address;
  amount: Uint;  // In Gwei
}
```

**Utility Functions:**

```typescript
// Convert Gwei to Wei
const wei = gweiToWei("0x3b9aca00");  // 1 ETH = 1,000,000,000 Gwei

// Convert Wei to Gwei
const gwei = weiToGwei(1_000_000_000_000_000_000n);  // 1 ETH

// Convert Gwei to ETH
const eth = gweiToEth("0x3b9aca00");  // 1.0

// Validate withdrawal
if (isValidWithdrawal(data)) {
  // data is a valid Withdrawal
}
```

## Mock Data

The module includes comprehensive mock data for testing:

```typescript
import {
  mockLegacyTransaction,
  mockEip1559Transaction,
  mockEip4844Transaction,
  mockEip7702Transaction,
  mockSuccessfulReceipt,
  mockFailedReceipt,
  mockTransferLog,
  mockBlockRangeFilter,
  mockPostMergeBlock,
  mockPostShanghaiBlock,
  mockPostCancunBlock
} from "./ethereum-types/mock-data";
```

## Usage Examples

### Filtering Logs

```typescript
import type { Filter, Log } from "./ethereum-types";
import { topicsMatch, normalizeFilterAddress } from "./ethereum-types";

const filter: Filter = {
  fromBlock: "0x1",
  toBlock: "latest",
  address: ["0x1234...", "0x5678..."],
  topics: [
    "0xddf252ad...",  // Transfer event
    null,             // Any from
    null              // Any to
  ]
};

function filterLogs(logs: Log[], filter: Filter): Log[] {
  return logs.filter(log => {
    // Check address
    const addresses = normalizeFilterAddress(filter.address);
    if (addresses.length > 0 && !addresses.includes(log.address)) {
      return false;
    }

    // Check topics
    if (!topicsMatch(log.topics, filter.topics)) {
      return false;
    }

    return true;
  });
}
```

### Processing Transaction Receipts

```typescript
import type { ReceiptInfo } from "./ethereum-types";
import { isSuccessful, isEip4844Receipt } from "./ethereum-types";

function processReceipt(receipt: ReceiptInfo) {
  if (!isSuccessful(receipt)) {
    console.error("Transaction failed");
    return;
  }

  console.log(`Gas used: ${parseInt(receipt.gasUsed, 16)}`);

  if (isEip4844Receipt(receipt)) {
    console.log(`Blob gas used: ${parseInt(receipt.blobGasUsed, 16)}`);
  }

  if (receipt.contractAddress) {
    console.log(`Contract deployed at: ${receipt.contractAddress}`);
  }

  console.log(`Logs: ${receipt.logs.length}`);
}
```

### Analyzing Blocks

```typescript
import type { BlockInfo } from "./ethereum-types";
import {
  isPostShanghaiBlock,
  isPostCancunBlock,
  hasFullTransactions
} from "./ethereum-types";

function analyzeBlock(block: BlockInfo) {
  console.log(`Block ${block.number}: ${block.hash}`);
  console.log(`Gas used: ${parseInt(block.gasUsed, 16)} / ${parseInt(block.gasLimit, 16)}`);

  if (isPostShanghaiBlock(block)) {
    console.log(`Withdrawals: ${block.withdrawals.length}`);
  }

  if (isPostCancunBlock(block)) {
    console.log(`Blob gas used: ${parseInt(block.blobGasUsed, 16)}`);
  }

  if (hasFullTransactions(block)) {
    console.log(`Full transactions: ${block.transactions.length}`);
  } else {
    console.log(`Transaction hashes: ${block.transactions.length}`);
  }
}
```

## EIP References

- **EIP-155**: Replay attack protection
- **EIP-1559**: Fee market change
- **EIP-2718**: Typed transaction envelope
- **EIP-2930**: Access list transaction type
- **EIP-4844**: Blob transactions (Proto-Danksharding)
- **EIP-4895**: Beacon chain withdrawals
- **EIP-7702**: Account abstraction via authorization list

## Integration with Existing Code

These types are designed to complement the existing transaction types in `src/primitives/transaction.ts`. The key differences:

1. **TransactionInfo**: Includes block context (blockHash, blockNumber, transactionIndex)
2. **Transaction** (existing): Raw transaction data for signing/encoding
3. **ReceiptInfo**: Complete receipt with execution results
4. **Log**: Event logs with optional block context
5. **Filter**: For querying historical logs

## Testing

Run the test suite:

```bash
bun test src/ethereum-types/types.test.ts
```

Tests cover:
- Type structure validation
- Type guard functions
- Utility function behavior
- Mock data integrity
- Edge cases (pending transactions, removed logs, etc.)

## License

This module follows the same license as the parent project.
