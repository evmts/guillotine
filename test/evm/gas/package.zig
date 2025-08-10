// Gas tests module

pub const call_memory_gas_test = @import("call_memory_gas_test.zig");
pub const dynamic_gas_test = @import("dynamic_gas_test.zig");
pub const gas_accounting_test = @import("gas_accounting_test.zig");
pub const memory_expansion_gas_test = @import("memory_expansion_gas_test.zig");

test {
    _ = call_memory_gas_test;
    _ = dynamic_gas_test;
    _ = gas_accounting_test;
    _ = memory_expansion_gas_test;
}
