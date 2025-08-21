const std = @import("std");

pub const Op0A = struct {
    test "hello world" {
        try std.testing.expect(true);
    }
};
