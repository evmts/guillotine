const std = @import("std");

pub const Op0B = struct {
    test "hello world" {
        try std.testing.expect(true);
    }
};
