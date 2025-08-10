// Main test package

pub const evm = @import("evm/package.zig");
pub const differential = @import("differential/package.zig");

// Root level test files
pub const dynamic_gas_simple_test = @import("dynamic_gas_simple_test.zig");
pub const dynamic_gas_test = @import("dynamic_gas_test.zig");
pub const revm_test = @import("revm_test.zig");

test {
    _ = evm;
    _ = differential;
    _ = dynamic_gas_simple_test;
    _ = dynamic_gas_test;
    _ = revm_test;
}
