// Root file that imports all differential tests

test {
    _ = @import("math_operations_test.zig");
    _ = @import("system_handlers_test.zig");
    _ = @import("jump_handlers_test.zig");
    _ = @import("memory_operations_test.zig");
    _ = @import("storage_operations_test.zig");
    _ = @import("stack_operations_test.zig");
    _ = @import("env_operations_test.zig");
    _ = @import("keccak_logs_test.zig");
    _ = @import("fixtures_test.zig");
    _ = @import("synthetic_toggle_test.zig");
}
