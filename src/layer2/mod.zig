/// Layer 2 blockchain support module.
///
/// This module provides L2-specific functionality as a zero-cost abstraction.
/// When layer2_config = .none (default), all L2 code is eliminated at
/// compile time, resulting in identical binary size to pre-L2 builds.
pub const optimism = @import("optimism/mod.zig");
pub const Layer2Config = @import("layer2_config.zig").Layer2Config;
pub const OptimismConfig = @import("layer2_config.zig").OptimismConfig;
