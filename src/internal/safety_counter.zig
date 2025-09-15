const std = @import("std");
const builtin = @import("builtin");
const log = @import("../log.zig");

pub const Mode = enum {
    enabled,
    disabled,
};

pub fn SafetyCounter(comptime T: type, comptime mode: Mode) type {
    return struct {
        count: T,
        limit: T,

        const Self = @This();

        pub fn init(limit: T) Self {
            return .{
                .count = 0,
                .limit = limit,
            };
        }

        pub fn inc(self: *Self) void {
            if (mode == .disabled) return;

            self.count += 1;
            if (self.count >= self.limit) {
                log.err("SafetyCounter limit reached: count={d}, limit={d}", .{ self.count, self.limit });
                log.err("Either bytecode is executing way more instructions than normal for an EVM contract, or there is a bug in the EVM causing an infinite loop", .{});
                if (builtin.target.cpu.arch == .wasm32) {
                    unreachable;
                } else {
                    @panic("EVM instruction limit exceeded - possible infinite loop or excessive bytecode execution");
                }
            }
        }

        pub fn set(self: *Self, count: T) void {
            if (mode == .disabled) return;

            self.count = count;
            if (self.count >= self.limit) {
                log.err("SafetyCounter limit reached via set: count={d}, limit={d}", .{ self.count, self.limit });
                log.err("Either bytecode is executing way more instructions than normal for an EVM contract, or there is a bug in the EVM causing an infinite loop", .{});
                if (builtin.target.cpu.arch == .wasm32) {
                    unreachable;
                } else {
                    @panic("EVM instruction limit exceeded - possible infinite loop or excessive bytecode execution");
                }
            }
        }
    };
}

test "SafetyCounter basic functionality" {
    const Counter = SafetyCounter(u32, .enabled);
    var counter = Counter.init(5);

    try std.testing.expectEqual(@as(u32, 0), counter.count);
    try std.testing.expectEqual(@as(u32, 5), counter.limit);

    counter.inc();
    try std.testing.expectEqual(@as(u32, 1), counter.count);

    counter.inc();
    try std.testing.expectEqual(@as(u32, 2), counter.count);

    counter.set(3);
    try std.testing.expectEqual(@as(u32, 3), counter.count);
}

test "SafetyCounter disabled mode" {
    const Counter = SafetyCounter(u32, .disabled);
    var counter = Counter.init(2);

    try std.testing.expectEqual(@as(u32, 0), counter.count);
    try std.testing.expectEqual(@as(u32, 2), counter.limit);

    // In disabled mode, inc() and set() should be no-ops
    counter.inc();
    try std.testing.expectEqual(@as(u32, 0), counter.count);

    counter.inc();
    try std.testing.expectEqual(@as(u32, 0), counter.count);

    counter.inc();
    try std.testing.expectEqual(@as(u32, 0), counter.count);

    counter.set(10);
    try std.testing.expectEqual(@as(u32, 0), counter.count);
}

test "SafetyCounter with different types" {
    // Test with u64
    const Counter64 = SafetyCounter(u64, .enabled);
    var counter64 = Counter64.init(100);
    try std.testing.expectEqual(@as(u64, 0), counter64.count);
    counter64.inc();
    try std.testing.expectEqual(@as(u64, 1), counter64.count);

    // Test with usize
    const CounterSize = SafetyCounter(usize, .enabled);
    var counter_size = CounterSize.init(10);
    try std.testing.expectEqual(@as(usize, 0), counter_size.count);
    counter_size.inc();
    try std.testing.expectEqual(@as(usize, 1), counter_size.count);
}

test "SafetyCounter set below limit" {
    const Counter = SafetyCounter(u32, .enabled);
    var counter = Counter.init(10);

    counter.set(5);
    try std.testing.expectEqual(@as(u32, 5), counter.count);

    counter.set(9);
    try std.testing.expectEqual(@as(u32, 9), counter.count);
}