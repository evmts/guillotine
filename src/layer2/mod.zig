/// Layer 2 blockchain support module.
///
/// When layer2_config = .none (default), no L2 code is referenced and it is
/// eliminated at compile time.
pub const optimism = @import("optimism/mod.zig");
pub const base = @import("base/mod.zig");
pub const layer2_config = @import("layer2_config.zig");
pub const Layer2Config = layer2_config.Layer2Config;
pub const OptimismConfig = layer2_config.OptimismConfig;
pub const BaseConfig = layer2_config.BaseConfig;
pub const OpSpecId = optimism.OpSpecId;
