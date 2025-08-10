const std = @import("std");
const has_revm = @hasDecl(@import("root"), "revm");

test "check revm availability" {
    std.debug.print("\nChecking revm availability: {}\n", .{has_revm});
    if (has_revm) {
        const revm = @import("revm");
        std.debug.print("revm module loaded successfully\n", .{});

        // Try to create a basic revm instance
        const allocator = std.testing.allocator;
        var vm = try revm.Revm.init(allocator, .{});
        defer vm.deinit();

        std.debug.print("revm instance created successfully\n", .{});
    } else {
        std.debug.print("revm module not available\n", .{});
    }
}
