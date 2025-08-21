const std = @import("std");

pub const OpA0 = struct {
    test "hello world" {
        try std.testing.expect(true);
    }
};
