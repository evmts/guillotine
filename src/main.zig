//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.
const std = @import("std");

pub fn main() !void {
    // Prints to log
    const log = @import("Guillotine_lib").log;
    log.info("All your {s} are belong to us.", .{"codebase"});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Run `zig build test` to run the tests.\n", .{});
}

test "simple test" {
    var list = std.ArrayList(i32){};
    defer list.deinit(std.testing.allocator); // Try commenting this out and see if zig detects the memory leak!
    try list.append(std.testing.allocator, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}


/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("Guillotine_lib");
