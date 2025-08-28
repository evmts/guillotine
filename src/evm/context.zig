//! EVM execution context for stack frame operations.
//!
//! This module provides all context data needed for EVM opcode execution,
//! eliminating the need for most handlers to access the EVM directly.
//! Context data is populated per-frame and includes transaction, block,
//! and call-specific information.

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
const BlockInfo = @import("block_info.zig").DefaultBlockInfo;

/// Execution context for EVM frames.
/// Contains all data needed by context handlers without requiring EVM access.
pub const Context = struct {
    // === TRANSACTION CONTEXT ===
    /// Original transaction sender
    tx_origin: Address,
    /// Gas price for the transaction
    gas_price: u256,
    /// Chain ID
    chain_id: u64,

    // === CALL CONTEXT ===
    /// Current call's caller address
    caller: Address,
    /// Current call's value
    value: u256,
    /// Current call's input data
    calldata: []const u8,

    // === BLOCK CONTEXT ===
    /// Block information
    block_info: BlockInfo,
    /// Blob versioned hashes (EIP-4844)
    blob_versioned_hashes: []const [32]u8,
    /// Blob base fee (EIP-4844)
    blob_base_fee: u256,

    /// Initialize context with transaction and call data
    pub fn init(
        tx_origin: Address,
        gas_price: u256,
        chain_id: u64,
        caller: Address,
        value: u256,
        calldata: []const u8,
        block_info: BlockInfo,
        blob_versioned_hashes: []const [32]u8,
        blob_base_fee: u256,
    ) Context {
        return Context{
            .tx_origin = tx_origin,
            .gas_price = gas_price,
            .chain_id = chain_id,
            .caller = caller,
            .value = value,
            .calldata = calldata,
            .block_info = block_info,
            .blob_versioned_hashes = blob_versioned_hashes,
            .blob_base_fee = blob_base_fee,
        };
    }

    /// Get block hash for the given block number
    pub fn get_block_hash(self: *const Context, block_number: u64) ?[32]u8 {
        const current_block = self.block_info.number;

        // EVM BLOCKHASH rules:
        // - Return null for current block and future blocks
        // - Return null for blocks older than 256 blocks
        // - Return null for block 0 (genesis)
        if (block_number >= current_block or
            current_block > block_number + 256 or
            block_number == 0)
        {
            return null;
        }

        // For testing/simulation purposes, generate a deterministic hash
        // In a real implementation, this would look up the actual block hash
        var hash: [32]u8 = undefined;
        hash[0..8].* = std.mem.toBytes(block_number);
        hash[8..16].* = std.mem.toBytes(current_block);

        // Fill rest with deterministic pattern based on block number
        var i: usize = 16;
        while (i < 32) : (i += 1) {
            hash[i] = @as(u8, @truncate(block_number +% i));
        }

        return hash;
    }

    /// Get blob hash for the given index (EIP-4844)
    pub fn get_blob_hash(self: *const Context, index: u256) ?[32]u8 {
        if (index >= self.blob_versioned_hashes.len) {
            return null;
        }
        const idx = @as(usize, @intCast(index));
        return self.blob_versioned_hashes[idx];
    }
};