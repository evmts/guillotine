const std = @import("std");

pub const Dispatcher = struct {
    test "hello world" {
        try std.testing.expect(true);
    }
};