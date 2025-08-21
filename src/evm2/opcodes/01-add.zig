const std = @import("std");

pub const Op01 = struct {
    test "hello world" {
        try std.testing.expect(true);
    }
};
