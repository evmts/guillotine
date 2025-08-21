const std = @import("std");

pub const Frame = struct {
    test "hello world" {
        try std.testing.expect(true);
    }
};