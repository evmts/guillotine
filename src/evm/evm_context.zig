//! EVM Context Methods
//!
//! This module contains methods for querying EVM context information
//! like hardfork configuration, block data, and transaction context.
//!
//! This demonstrates the proposed pattern for extracting methods from
//! the monolithic evm.zig file into focused, reusable modules.

const std = @import("std");
const primitives = @import("primitives");
const Hardfork = @import("hardfork.zig").Hardfork;
const BlockInfo = @import("block_info.zig").DefaultBlockInfo;

/// Context operations for EVM instances
pub fn Context(comptime EvmType: type) type {
    return struct {
        /// Check if hardfork is at least the target
        pub fn is_hardfork_at_least(evm: *EvmType, target: Hardfork) bool {
            return @intFromEnum(evm.hardfork_config) >= @intFromEnum(target);
        }

        /// Get current hardfork (deprecated - use EIPs)
        pub fn get_hardfork(evm: *EvmType) Hardfork {
            return evm.hardfork_config;
        }

        /// Get block information
        pub fn get_block_info(evm: *EvmType) BlockInfo {
            return evm.block_info;
        }

        // TODO: Extract additional context methods:
        // - get_depth() - Get call depth
        // - get_tx_origin() - Get transaction origin
        // - get_caller() - Get current caller
        // - get_call_value() - Get call value
        // - get_gas_left() - Get remaining gas
        // - is_static_context() - Check if in static context
        // - get_chain_id() - Get chain ID
        // - get_block_hash() - Get block hash by number
    };
}