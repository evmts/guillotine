/// Optimism L2 public exports.
///
/// This module provides all Optimism-specific types and functionality
/// for the Guillotine EVM Layer 2 support.
pub const OpSpecId = @import("spec.zig").OpSpecId;
pub const constants = @import("constants.zig");
pub const L1BlockInfo = @import("l1_block_info.zig").L1BlockInfo;
pub const MockDatabase = @import("l1_block_info.zig").MockDatabase;
pub const precompiles = @import("precompiles.zig");
pub const getOptimismPrecompileOverrides = precompiles.getOptimismPrecompileOverrides;
