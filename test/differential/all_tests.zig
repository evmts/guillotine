// Root file that imports all differential tests

test {
    _ = @import("math_operations_test.zig");
    _ = @import("system_handlers_test.zig");
    _ = @import("jump_handlers_test.zig");
    _ = @import("memory_operations_test.zig");
    _ = @import("storage_operations_test.zig");
}