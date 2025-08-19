const std = @import("std");
const has_revm = @hasDecl(@import("root"), "revm");

test "check revm availability" {
    if (has_revm) {
        const revm = @import("revm");
        
        // Try to create a basic revm instance
        const allocator = std.testing.allocator;
        var vm = try revm.Revm.init(allocator, .{});
        defer vm.deinit();
        
    } else {
    }
}