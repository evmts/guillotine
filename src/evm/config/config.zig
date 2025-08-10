/// EVM configuration module exports
///
/// This module provides a centralized configuration system for the EVM
/// with support for hardfork-based EIP derivation and L2 overrides.
pub const EvmConfig = @import("../config.zig").EvmConfig;
pub const EipFlags = @import("eip_flags.zig").EipFlags;
pub const EipOverrides = @import("overrides.zig").EipOverrides;
pub const GasCostOverrides = @import("overrides.zig").GasCostOverrides;
pub const ChainBehavior = @import("overrides.zig").ChainBehavior;

// Export derivation functions
pub const deriveEipFlagsFromHardfork = @import("eip_flags.zig").deriveEipFlagsFromHardfork;
pub const applyOverrides = @import("overrides.zig").applyOverrides;

// Export test configurations
pub const test_configs = @import("test_configs.zig");
