// Differential tests module

pub const arithmetic_differential_test = @import("arithmetic_differential_test.zig");
pub const bitwise_differential_test = @import("bitwise_differential_test.zig");
pub const block_differential_test = @import("block_differential_test.zig");
pub const comparison_differential_test = @import("comparison_differential_test.zig");
pub const control_differential_test = @import("control_differential_test.zig");
pub const crypto_differential_test = @import("crypto_differential_test.zig");
pub const environment_differential_test = @import("environment_differential_test.zig");
pub const external_differential_test = @import("external_differential_test.zig");
pub const logging_differential_test = @import("logging_differential_test.zig");
pub const memory_differential_test = @import("memory_differential_test.zig");
pub const precompile_differential_test = @import("precompile_differential_test.zig");
pub const stack_differential_test = @import("stack_differential_test.zig");
pub const storage_differential_test = @import("storage_differential_test.zig");
pub const fusion_differential_test = @import("fusion_differential_test.zig");
pub const call_differential_test = @import("call_differential_test.zig");
pub const jumps_differential_test = @import("jumps_differential_test.zig");
pub const staticcall_min_differential_test = @import("staticcall_min_differential_test.zig");
pub const snailtracer_differential_test = @import("snailtracer_differential_test.zig");
pub const erc20_differential_test = @import("erc20_differential_test.zig");
pub const ten_thousand_hashes_differential_test = @import("ten_thousand_hashes_differential_test.zig");
pub const system_differential_test = @import("system_differential_test.zig");

test {
    _ = arithmetic_differential_test;
    _ = bitwise_differential_test;
    _ = block_differential_test;
    _ = comparison_differential_test;
    _ = control_differential_test;
    _ = crypto_differential_test;
    _ = environment_differential_test;
    _ = external_differential_test;
    _ = logging_differential_test;
    _ = memory_differential_test;
    _ = precompile_differential_test;
    _ = stack_differential_test;
    _ = storage_differential_test;
    _ = fusion_differential_test;
    _ = call_differential_test;
    _ = jumps_differential_test;
    _ = staticcall_min_differential_test;
    _ = snailtracer_differential_test;
    _ = erc20_differential_test;
    _ = ten_thousand_hashes_differential_test;
    _ = system_differential_test;
}
