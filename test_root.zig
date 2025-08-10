// Root level tests module

pub const test_sizes = @import("test_sizes.zig");
pub const test_execute_red = @import("test_execute_red.zig");
pub const test_instruction_green = @import("test_instruction_green.zig");
pub const test_instruction_red = @import("test_instruction_red.zig");

test {
    _ = test_sizes;
    _ = test_execute_red;
    _ = test_instruction_green;
    _ = test_instruction_red;
}
