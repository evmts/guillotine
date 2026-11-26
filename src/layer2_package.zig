//! Root of the public `layer2` package module (`dep.module("layer2")`).
//!
//! The `evm` module owns src/layer2/mod.zig, and a file may belong to one
//! module only, so this root re-exports `evm.layer2` instead of rooting a
//! second module there. A consumer can import both `evm` and `layer2`.
//! `evm_host` (the OP Stack host over Guillotine's EVM) is not part of the
//! `evm` module and is reached only from here.

const layer2 = @import("evm").layer2;

pub const optimism = layer2.optimism;
pub const base = layer2.base;
pub const layer2_config = layer2.layer2_config;
pub const Layer2Config = layer2.Layer2Config;
pub const OptimismConfig = layer2.OptimismConfig;
pub const BaseConfig = layer2.BaseConfig;
pub const OpSpecId = layer2.OpSpecId;
pub const executor = layer2.executor;
pub const evm_host = @import("layer2/evm_host.zig");
