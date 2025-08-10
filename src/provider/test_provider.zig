const std = @import("std");
const Provider = @import("provider.zig").Provider;

test "provider initialization" {
    const allocator = std.testing.allocator;

    var provider = try Provider.init(allocator, "https://eth.llamarpc.com");
    defer provider.deinit();

    // Just test initialization works
    try std.testing.expect(provider.url.len > 0);
}

test "parse hex numbers" {
    const allocator = std.testing.allocator;

    var provider = try Provider.init(allocator, "https://eth.llamarpc.com");
    defer provider.deinit();

    // Test hex parsing with common values
    const cases = [_]struct { hex: []const u8, expected: u64 }{
        .{ .hex = "\"0x0\"", .expected = 0 },
        .{ .hex = "\"0x1\"", .expected = 1 },
        .{ .hex = "\"0xff\"", .expected = 255 },
        .{ .hex = "\"0x100\"", .expected = 256 },
        .{ .hex = "\"0x539\"", .expected = 1337 },
    };

    for (cases) |case| {
        const trimmed = std.mem.trim(u8, case.hex, "\"");
        const hex = if (std.mem.startsWith(u8, trimmed, "0x")) trimmed[2..] else trimmed;
        const result = try std.fmt.parseInt(u64, hex, 16);
        try std.testing.expectEqual(case.expected, result);
    }
}
