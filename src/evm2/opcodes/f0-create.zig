const std = @import("std");

pub const OpF0 = struct {
    test "hello world" {
        try std.testing.expect(true);
    }
};
