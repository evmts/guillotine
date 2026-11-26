//! Ethereum Provider - Blockchain connectivity and RPC client implementation
//!
//! This module provides a complete Ethereum provider implementation for
//! interacting with Ethereum nodes via JSON-RPC. It supports all standard
//! Ethereum RPC methods and provides type-safe interfaces for blockchain
//! operations.
//!
//! ## Features
//!
//! - **JSON-RPC Client**: Complete Ethereum JSON-RPC 2.0 implementation
//! - **HTTP Transport**: Reliable HTTP/HTTPS connectivity to Ethereum nodes
//! - **Type Safety**: Strongly typed request/response handling
//! - **Error Handling**: Comprehensive error types and recovery
//! - **Async Operations**: Non-blocking network operations
//!
//! ## Supported RPC Methods
//!
//! ### Block Operations
//! - `eth_getBlockByNumber` - Get block by number
//! - `eth_getBlockByHash` - Get block by hash
//! - `eth_blockNumber` - Get latest block number
//! - `eth_getBlockTransactionCountByNumber` - Get transaction count
//!
//! ### Transaction Operations
//! - `eth_getTransactionByHash` - Get transaction details
//! - `eth_getTransactionReceipt` - Get transaction receipt
//! - `eth_sendRawTransaction` - Send signed transaction
//! - `eth_estimateGas` - Estimate gas consumption
//!
//! ### Account Operations
//! - `eth_getBalance` - Get account balance
//! - `eth_getTransactionCount` - Get account nonce
//! - `eth_getCode` - Get contract code
//! - `eth_getStorageAt` - Get storage slot value
//!
//! ### Network Operations
//! - `eth_chainId` - Get chain ID
//! - `eth_gasPrice` - Get current gas price
//! - `net_version` - Get network version
//! - `web3_clientVersion` - Get client version
//!
//! ## Usage Examples
//!
//! ### Basic Setup
//! ```zig
//! const provider = @import("provider");
//!
//! // Create provider instance
//! var p = try provider.Provider.init(allocator, "https://mainnet.infura.io/v3/YOUR_KEY");
//! defer p.deinit();
//! ```
//!
//! ### Block Operations
//! ```zig
//! // Get latest block
//! const block = try p.getBlockByNumber("latest", true);
//! defer block.deinit();
//!
//! // Get specific block
//! const block_123 = try p.getBlockByNumber("0x7b", false);
//! defer block_123.deinit();
//! ```
//!
//! ### Transaction Operations
//! ```zig
//! // Get transaction
//! const tx = try p.getTransactionByHash("0x1234...");
//! defer tx.deinit();
//!
//! // Send transaction
//! const tx_hash = try p.sendRawTransaction(signed_tx_data);
//! defer tx_hash.deinit();
//! ```
//!
//! ### Account Queries
//! ```zig
//! // Get balance
//! const balance = try p.getBalance("0x742d35Cc6641C91B6E4bb6ac...", "latest");
//!
//! // Get nonce
//! const nonce = try p.getTransactionCount("0x742d35Cc6641C91B6E4bb6ac...", "latest");
//! ```
//!
//! ## Error Handling
//!
//! The provider uses comprehensive error types:
//! - `NetworkError`: Connection and transport errors
//! - `JsonRpcError`: Protocol-level JSON-RPC errors
//! - `SerializationError`: Data encoding/decoding errors
//! - `InvalidResponse`: Malformed server responses
//! - `RateLimitExceeded`: Rate limiting from provider
//!
//! ## Configuration
//!
//! ### Network Endpoints
//! - **Mainnet**: `https://mainnet.infura.io/v3/YOUR_KEY`
//! - **Goerli**: `https://goerli.infura.io/v3/YOUR_KEY`
//! - **Sepolia**: `https://sepolia.infura.io/v3/YOUR_KEY`
//! - **Local**: `http://localhost:8545`
//!
//! ### Request Settings
//! - **Timeout**: Configurable request timeout
//! - **Retries**: Automatic retry on transient failures
//! - **Rate Limiting**: Built-in rate limiting support
//!
//! ## Design Principles
//!
//! 1. **Reliability**: Robust error handling and retry logic
//! 2. **Performance**: Efficient JSON serialization and HTTP transport
//! 3. **Type Safety**: Strongly typed interfaces prevent runtime errors
//! 4. **Simplicity**: Clean API that's easy to use and understand
//! 5. **Extensibility**: Easy to add new RPC methods and features

// Simple provider implementation
pub const Provider = @import("provider.zig").Provider;
pub const Block = @import("provider.zig").Block;

// Export transport layer for testing
pub const transport = struct {
    pub const json_rpc = @import("transport/json_rpc.zig");
    pub const HttpTransport = @import("transport/http_simple.zig").HttpTransport;
};

// Export utilities for testing
pub const ConnectionPool = @import("connection_pool.zig").ConnectionPool;
pub const RateLimiter = @import("rate_limiter.zig").RateLimiter;
