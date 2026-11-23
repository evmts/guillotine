//! Compatibility entry point for the former zbench runner. Build through
//! bench_step.addBenchSteps or bench/build.zig to provide the EVM modules.
pub const main = @import("main.zig").main;
