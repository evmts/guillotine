const std = @import("std");

pub const Op1A = struct {
    test "hello world" {
        try std.testing.expect(true);
    }
};
