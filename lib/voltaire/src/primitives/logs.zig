const std = @import("std");
const Address = @import("address.zig").Address;

/// Simple log structure for Frame
pub const Log = struct {
    address: Address,
    topics: []const u256,
    data: []const u8,
};

/// Sentinel value used for null-terminated log arrays in Frame
pub const SENTINEL: Log = .{
    .address = Address.ZERO_ADDRESS,
    .topics = &[_]u256{},
    .data = &[_]u8{},
};

test "Log creation and field access" {
    const allocator = std.testing.allocator;

    const topics = try allocator.alloc(u256, 2);
    defer allocator.free(topics);
    topics[0] = 0x123456789abcdef;
    topics[1] = 0xfedcba9876543210;

    const data = "test log data";
    const zero_addr = [_]u8{0} ** 20;

    const log = Log{
        .address = zero_addr,
        .topics = topics,
        .data = data,
    };

    try std.testing.expectEqual(zero_addr, log.address);
    try std.testing.expectEqual(@as(usize, 2), log.topics.len);
    try std.testing.expectEqual(@as(u256, 0x123456789abcdef), log.topics[0]);
    try std.testing.expectEqual(@as(u256, 0xfedcba9876543210), log.topics[1]);
    try std.testing.expectEqualStrings("test log data", log.data);
}

test "Log with empty topics and data" {
    const zero_addr = [_]u8{0} ** 20;
    const log = Log{
        .address = zero_addr,
        .topics = &[_]u256{},
        .data = "",
    };

    try std.testing.expectEqual(zero_addr, log.address);
    try std.testing.expectEqual(@as(usize, 0), log.topics.len);
    try std.testing.expectEqual(@as(usize, 0), log.data.len);
}
