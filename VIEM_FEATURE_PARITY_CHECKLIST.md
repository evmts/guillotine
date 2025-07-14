# Viem Feature Parity Checklist

## Primitives Package Features

### 🔷 Core Types & Utilities
- [ ] **Address**
  - [x] Basic 20-byte address type
  - [ ] Checksum validation (EIP-55)
  - [ ] `isAddress()` validation
  - [ ] `getAddress()` normalization
  - [ ] `isAddressEqual()` comparison
  - [ ] Zero address constant

- [ ] **Hash Types**
  - [ ] 32-byte hash type
  - [ ] Transaction hash type
  - [ ] Block hash type
  - [ ] Keccak256 implementation

- [ ] **Numeric Types**
  - [x] U256 type (using Zig's u256)
  - [ ] Ether units (wei, gwei, ether)
  - [ ] `parseEther()` function
  - [ ] `parseGwei()` function
  - [ ] `formatEther()` function
  - [ ] `formatGwei()` function
  - [ ] `parseUnits()` function
  - [ ] `formatUnits()` function

- [ ] **Hex & Bytes**
  - [ ] `toHex()` conversion
  - [ ] `fromHex()` conversion
  - [ ] `hexToBytes()` conversion
  - [ ] `bytesToHex()` conversion
  - [ ] `hexToString()` conversion
  - [ ] `stringToHex()` conversion
  - [ ] `isHex()` validation
  - [ ] `size()` for bytes
  - [ ] `slice()` for bytes
  - [ ] `concat()` for bytes
  - [ ] `pad()` for bytes
  - [ ] `trim()` for bytes

### 🔷 Transaction Primitives
- [ ] **Transaction Types**
  - [ ] Legacy transactions
  - [ ] EIP-1559 transactions
  - [ ] EIP-2930 access list transactions
  - [x] EIP-4844 blob transactions (partial)
  - [ ] EIP-7702 authorization transactions

- [ ] **Transaction Building**
  - [ ] `prepareTransactionRequest()`
  - [ ] `serializeTransaction()`
  - [ ] `parseTransaction()`
  - [ ] `getSerializedTransactionType()`
  - [ ] `getTransactionType()`

- [ ] **Transaction Signing**
  - [ ] `signTransaction()`
  - [ ] `recoverTransactionAddress()`
  - [ ] `hashTypedData()` (EIP-712)

### 🔷 ABI Encoding/Decoding
- [ ] **Basic ABI**
  - [ ] `encodeAbiParameters()`
  - [ ] `decodeAbiParameters()`
  - [ ] `encodeFunctionData()`
  - [ ] `decodeFunctionData()`
  - [ ] `encodeFunctionResult()`
  - [ ] `decodeFunctionResult()`

- [ ] **Event Handling**
  - [ ] `encodeEventTopics()`
  - [ ] `decodeEventLog()`
  - [ ] `parseEventLogs()`

- [ ] **Error Handling**
  - [ ] `encodeErrorResult()`
  - [ ] `decodeErrorResult()`

- [ ] **Packed Encoding**
  - [ ] `encodePacked()`

### 🔷 Signature & Crypto
- [ ] **ECDSA**
  - [ ] `sign()`
  - [ ] `signMessage()`
  - [ ] `recoverAddress()`
  - [ ] `recoverMessageAddress()`
  - [ ] `verifyMessage()`
  - [ ] `hashMessage()`

- [ ] **EIP-712**
  - [ ] `signTypedData()`
  - [ ] `verifyTypedData()`
  - [ ] `recoverTypedDataAddress()`

### 🔷 RLP Encoding
- [x] **Basic RLP**
  - [x] `toRlp()` encoding
  - [x] RLP decoding
  - [x] RLP list support

## Provider Package Features

### 🔶 Client Architecture
- [ ] **Client Types**
  - [ ] Public Client
  - [ ] Wallet Client  
  - [ ] Test Client
  - [ ] Client Actions pattern

- [ ] **Transport Layer**
  - [ ] HTTP transport
  - [ ] WebSocket transport
  - [ ] IPC transport
  - [ ] Custom transport interface
  - [ ] Fallback transport
  - [ ] Transport config (timeout, retry)

### 🔶 Public Actions (Read)
- [ ] **Chain Data**
  - [ ] `getChainId()`
  - [ ] `getBlockNumber()`
  - [ ] `getGasPrice()`
  - [ ] `getMaxPriorityFeePerGas()`
  - [ ] `getFeeHistory()`
  - [ ] `estimateGas()`

- [ ] **Block Data**
  - [ ] `getBlock()`
  - [ ] `getBlockTransactionCount()`
  - [ ] `watchBlocks()`
  - [ ] `watchBlockNumber()`

- [ ] **Transaction Data**
  - [ ] `getTransaction()`
  - [ ] `getTransactionReceipt()`
  - [ ] `getTransactionConfirmations()`
  - [ ] `waitForTransactionReceipt()`
  - [ ] `watchPendingTransactions()`

- [ ] **Account Data**
  - [ ] `getBalance()`
  - [ ] `getCode()`
  - [ ] `getStorageAt()`
  - [ ] `getTransactionCount()`
  - [ ] `getProof()`

- [ ] **Contract Calls**
  - [ ] `call()`
  - [ ] `readContract()`
  - [ ] `simulateContract()`
  - [ ] `multicall()`
  - [ ] `estimateContractGas()`

- [ ] **Events & Logs**
  - [ ] `getLogs()`
  - [ ] `createEventFilter()`
  - [ ] `createBlockFilter()`
  - [ ] `createPendingTransactionFilter()`
  - [ ] `getFilterChanges()`
  - [ ] `getFilterLogs()`
  - [ ] `uninstallFilter()`
  - [ ] `watchEvent()`
  - [ ] `watchContractEvent()`

- [ ] **ENS**
  - [ ] `getEnsAddress()`
  - [ ] `getEnsName()`
  - [ ] `getEnsAvatar()`
  - [ ] `getEnsText()`
  - [ ] `getEnsResolver()`

### 🔶 Wallet Actions (Write)
- [ ] **Transaction Sending**
  - [ ] `sendTransaction()`
  - [ ] `sendRawTransaction()`
  - [ ] `prepareTransactionRequest()`

- [ ] **Contract Interactions**
  - [ ] `writeContract()`
  - [ ] `deployContract()`

- [ ] **Account Management**
  - [ ] `getAddresses()`
  - [ ] `requestAddresses()`
  - [ ] `switchChain()`
  - [ ] `addChain()`
  - [ ] `watchAsset()`

- [ ] **Signing**
  - [ ] `signMessage()`
  - [ ] `signTransaction()`
  - [ ] `signTypedData()`

### 🔶 Test Actions
- [ ] **Test Utilities**
  - [ ] `mine()`
  - [ ] `setBalance()`
  - [ ] `setCode()`
  - [ ] `setNonce()`
  - [ ] `setStorageAt()`
  - [ ] `impersonateAccount()`
  - [ ] `stopImpersonatingAccount()`
  - [ ] `reset()`
  - [ ] `revert()`
  - [ ] `snapshot()`
  - [ ] `setNextBlockTimestamp()`
  - [ ] `increaseTime()`
  - [ ] `setBlockGasLimit()`

### 🔶 L2/Rollup Features
- [ ] **Optimism**
  - [ ] L1 fee estimation
  - [ ] L1 data fee
  - [ ] L1 gas price oracle

- [ ] **Arbitrum**
  - [ ] L1 gas estimation
  - [ ] L2 gas price
  - [ ] Retryable tickets

- [ ] **zkSync**
  - [ ] L2 transaction types
  - [ ] Account abstraction
  - [ ] Paymaster support

### 🔶 Account Abstraction (EIP-4337)
- [ ] **Smart Accounts**
  - [ ] Account interface
  - [ ] User operation building
  - [ ] Bundler interaction
  - [ ] Paymaster support

- [ ] **WebAuthn Accounts**
  - [ ] Passkey support
  - [ ] Signature verification

### 🔶 Utilities & Helpers
- [ ] **Caching**
  - [ ] Request caching
  - [ ] Block caching
  - [ ] Contract state caching

- [ ] **Error Handling**
  - [ ] Typed errors
  - [ ] Error parsing
  - [ ] Revert reason extraction

- [ ] **Middleware**
  - [ ] Request/response interceptors
  - [ ] Logging middleware
  - [ ] Metrics middleware

## Implementation Status

### Currently Implemented
- [x] Basic Address type
- [x] RLP encoding/decoding
- [x] Basic U256 support
- [x] StorageKey type
- [x] FeeMarket calculations (EIP-1559)
- [x] Partial blob transaction support

### Next Priority Items
1. [ ] Address checksum validation
2. [ ] Hex/bytes utilities
3. [ ] Basic HTTP transport
4. [ ] Core RPC methods (eth_call, eth_sendTransaction)
5. [ ] ABI encoding/decoding

### Long-term Goals
- [ ] Full viem API compatibility
- [ ] Performance optimizations leveraging Zig
- [ ] Comprehensive test coverage
- [ ] Developer-friendly documentation