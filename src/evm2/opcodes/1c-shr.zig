const std = @import("std");

pub const Op1C = struct {
    test "hello world" {
        try std.testing.expect(true);
    }
};
