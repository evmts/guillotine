//! The `evm` module seen by `specs/eest_runner.zig` when the build runs with
//! `-Devm-enable-fusion=false`.
//!
//! The runner builds each fork's EVM as `evm.Evm(.{ ... })` and never sets
//! `enable_fusion`, so it inherits the `EvmConfig` default (on). This module
//! re-exports the declarations the runner uses and wraps `Evm` so every
//! instantiation has fusion off. `build.zig` substitutes it for the real `evm`
//! module, which lets CI run the official state tests with fusion on and off
//! from one runner.
const std = @import("std");
const base = @import("evm_base");

pub const Account = base.Account;
pub const Database = base.Database;
pub const EvmConfig = base.EvmConfig;
pub const Hardfork = base.Hardfork;
pub const Log = base.Log;
pub const Primitives = base.Primitives;
pub const kzg_setup = base.kzg_setup;
pub const state_root = base.state_root;

/// `base.Evm(config)` with `enable_fusion` forced to `false`.
pub fn Evm(comptime config: EvmConfig) type {
    var unfused = config;
    unfused.enable_fusion = false;
    return base.Evm(unfused);
}

test "fusion-off Evm is the base Evm with enable_fusion = false" {
    try std.testing.expect(Evm(.{}) == base.Evm(.{ .enable_fusion = false }));
    try std.testing.expect(Evm(.{ .enable_fusion = true }) == base.Evm(.{ .enable_fusion = false }));
    try std.testing.expect(Evm(.{}) != base.Evm(.{ .enable_fusion = true }));
}
