/// EVM configuration package
/// Exports all configuration-related types and utilities

pub const EvmConfig = @import("evm_config.zig").EvmConfig;
pub const EipFlags = @import("eip_flags.zig").EipFlags;
pub const EipOverrides = @import("overrides.zig").EipOverrides;
pub const GasCostOverrides = @import("overrides.zig").GasCostOverrides;
pub const MemoryConfig = @import("overrides.zig").MemoryConfig;
pub const GasConfig = @import("overrides.zig").GasConfig;
pub const DatabaseConfig = @import("overrides.zig").DatabaseConfig;

// Re-export commonly used functions
pub const mainnet = EvmConfig.mainnet;
pub const testnet = EvmConfig.testnet;
pub const from_hardfork = EvmConfig.from_hardfork;

// Re-export predefined configurations
pub const MAINNET_LATEST = EvmConfig.MAINNET_LATEST;
pub const SEPOLIA = EvmConfig.SEPOLIA;
pub const GOERLI = EvmConfig.GOERLI;
pub const HOLESKY = EvmConfig.HOLESKY;

// Re-export L2 configurations
pub const optimism = EvmConfig.optimism;
pub const arbitrum = EvmConfig.arbitrum;
pub const polygon = EvmConfig.polygon;
pub const base = EvmConfig.base;
pub const zksync = EvmConfig.zksync;

// Re-export test configurations
pub const TEST_MINIMAL = EipOverrides.TEST_MINIMAL;
pub const TEST_FULL = EipOverrides.TEST_FULL;
pub const TEST_GAS = EipOverrides.TEST_GAS;