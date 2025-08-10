// Main test package

pub const evm = @import("evm/package.zig");
pub const differential = @import("differential/package.zig");

// Root level test files
pub const dynamic_gas_simple_test = @import("dynamic_gas_simple_test.zig");
pub const dynamic_gas_test = @import("dynamic_gas_test.zig");
pub const revm_test = @import("revm_test.zig");
pub const snailtracer_test = @import("snailtracer_test.zig");
pub const erc20_test = @import("erc20_test.zig");
pub const thousand_hashes_test = @import("1000_hashes.zig");

test {
    _ = evm;
    _ = differential;
    _ = dynamic_gas_simple_test;
    _ = dynamic_gas_test;
    _ = revm_test;
    _ = snailtracer_test;
    _ = erc20_test;
    _ = thousand_hashes_test;
}