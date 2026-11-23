//! Unified entry point for the maintained EVM C ABI.
const std = @import("std");
pub const api = @import("evm_c_api.zig");
comptime {
    _ = api;
}
test "maintained C ABI declarations" {
    std.testing.refAllDecls(api);
}
