//! Execution context for EVM transactions and calls
//!
//! Provides transaction-level context information including block data,
//! transaction parameters, and execution environment.

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

/// Transaction execution context
pub const Context = struct {
    /// Transaction origin (tx.origin)
    origin: Address,
    
    /// Gas price for the transaction
    gas_price: u256,
    
    /// Chain ID for the current network
    chain_id: u64,
    
    /// Block timestamp
    timestamp: u64,
    
    /// Block number
    block_number: u64,
    
    /// Block gas limit
    gas_limit: u64,
    
    /// Block base fee (EIP-1559)
    base_fee: u256,
    
    /// Block coinbase (miner address)
    coinbase: Address,
    
    /// Block difficulty
    difficulty: u256,
    
    /// Previous block hash (prevrandao in post-merge)
    prevrandao: [32]u8,
    
    /// Blob base fee (EIP-4844)
    blob_base_fee: u128,
    
    /// Static flag for STATICCALL context
    is_static: bool = false,
    
    /// Default initialization
    pub fn init() Context {
        return .{
            .origin = Address.ZERO_ADDRESS,
            .gas_price = 0,
            .chain_id = 1,
            .timestamp = 0,
            .block_number = 0,
            .gas_limit = 30_000_000,
            .base_fee = 0,
            .coinbase = Address.ZERO_ADDRESS,
            .difficulty = 0,
            .prevrandao = [_]u8{0} ** 32,
            .blob_base_fee = 0,
            .is_static = false,
        };
    }
};