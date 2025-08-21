const std = @import("std");

pub const Op42 = struct {
    test "hello world" {
        try std.testing.expect(true);
    }
};
