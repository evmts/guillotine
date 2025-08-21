const std = @import("std");

pub const OpA1 = struct {
    test "hello world" {
        try std.testing.expect(true);
    }
};
