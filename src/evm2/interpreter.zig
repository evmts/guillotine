const std = @import("std");

pub const Interpreter = struct {
    test "hello world" {
        try std.testing.expect(true);
    }
};