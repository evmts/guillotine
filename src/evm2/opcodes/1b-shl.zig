const std = @import("std");

pub const Op1B = struct {
    test "hello world" {
        try std.testing.expect(true);
    }
};
