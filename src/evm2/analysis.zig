const std = @import("std");

pub const Analysis = struct {
    test "hello world" {
        try std.testing.expect(true);
    }
};