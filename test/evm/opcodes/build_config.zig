//! `zig build` options select the configuration of `evm.DefaultEvm`
//! (src/root.zig getBuildConfig). These tests run in the test-opcodes gate,
//! where `evm` is a dependency module, so its stale inline tests stay out.
const std = @import("std");
const evm = @import("evm");
const build_options = @import("build_options");

test "parseHardfork accepts enum tags and EEST fork names" {
    try std.testing.expectEqual(evm.Hardfork.OSAKA, comptime evm.parseHardfork("OSAKA"));
    try std.testing.expectEqual(evm.Hardfork.CANCUN, comptime evm.parseHardfork("Cancun"));
    try std.testing.expectEqual(evm.Hardfork.TANGERINE_WHISTLE, comptime evm.parseHardfork("TANGERINE_WHISTLE"));
    try std.testing.expectEqual(evm.Hardfork.TANGERINE_WHISTLE, comptime evm.parseHardfork("TangerineWhistle"));
}

test "getBuildConfig reflects build options" {
    const config = comptime evm.getBuildConfig();
    try std.testing.expectEqual(comptime evm.parseHardfork(build_options.hardfork), config.eips.hardfork);
    try std.testing.expectEqual(build_options.enable_fusion, config.enable_fusion);
    try std.testing.expectEqual(build_options.disable_gas_checks, config.disable_gas_checks);
    try std.testing.expectEqual(build_options.disable_balance_checks, config.disable_balance_checks);
    try std.testing.expectEqual(build_options.max_call_depth, config.max_call_depth);
    try std.testing.expectEqual(build_options.stack_size, config.stack_size);
    try std.testing.expectEqual(build_options.block_gas_limit, config.block_gas_limit);
    try std.testing.expectEqual(build_options.memory_limit, config.memory_limit);
    try std.testing.expectEqual(build_options.enable_tracing, config.tracer_config.enabled);
    try std.testing.expectEqual(
        std.meta.stringToEnum(evm.OptimizeStrategy, build_options.optimize_strategy).?,
        evm.optimize_strategy,
    );
}

test "DefaultEvm is the build-configured EVM" {
    try std.testing.expect(evm.DefaultEvm == evm.BuildConfiguredEvm);
}
