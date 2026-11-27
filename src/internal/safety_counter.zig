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

        pub const Error = error{SafetyLimitExceeded};

        /// Count one step. Returns `error.SafetyLimitExceeded` once the limit is
        /// reached, and on every later call, so the caller can stop with a typed error.
        /// The process is never aborted: the input that drives the counter can be
        /// adversarial EVM code.
        pub fn tick(self: *Self) Error!void {
            if (mode == .disabled) return;

            if (self.count >= self.limit) return Error.SafetyLimitExceeded;
            self.count += 1;
            if (self.count >= self.limit) {
                log.warn("SafetyCounter limit reached: count={d}, limit={d}", .{ self.count, self.limit });
                return Error.SafetyLimitExceeded;
            }
        }

        /// True once the limit has been reached.
        pub fn isExceeded(self: *const Self) bool {
            if (mode == .disabled) return false;
            return self.count >= self.limit;
        }

        /// Count one step for callers that cannot return an error. The count saturates
        /// at the limit and the condition is logged once; check `isExceeded()` (or use
        /// `tick()`) to act on it. Never panics.
        pub fn inc(self: *Self) void {
            if (mode == .disabled) return;

            if (self.count >= self.limit) return;
            self.count += 1;
            if (self.count >= self.limit) {
                log.warn("SafetyCounter limit reached: count={d}, limit={d}", .{ self.count, self.limit });
                log.warn(
                    "Either bytecode is executing way more instructions than normal for an EVM contract, " ++
                        "or there is a bug in the EVM causing an infinite loop",
                    .{},
                );
            }
        }

        /// Set the count. A value at or above the limit saturates at the limit and
        /// is logged; check `isExceeded()` to act on it. Never panics.
        pub fn set(self: *Self, count: T) void {
            if (mode == .disabled) return;

            if (count >= self.limit) {
                self.count = self.limit;
                log.warn("SafetyCounter limit reached via set: count={d}, limit={d}", .{ count, self.limit });
                return;
            }
            self.count = count;
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
test "SafetyCounter tick returns a typed error at the limit and never panics" {
    const Counter = SafetyCounter(u32, .enabled);
    var counter = Counter.init(3);

    try counter.tick();
    try counter.tick();
    try std.testing.expect(!counter.isExceeded());
    try std.testing.expectError(error.SafetyLimitExceeded, counter.tick());
    try std.testing.expect(counter.isExceeded());
    // Stays tripped, count does not run away.
    try std.testing.expectError(error.SafetyLimitExceeded, counter.tick());
    try std.testing.expectEqual(@as(u32, 3), counter.count);
}

test "SafetyCounter inc and set saturate at the limit instead of panicking" {
    const Counter = SafetyCounter(u8, .enabled);
    var counter = Counter.init(2);

    counter.inc();
    try std.testing.expect(!counter.isExceeded());
    counter.inc();
    try std.testing.expect(counter.isExceeded());
    counter.inc();
    counter.inc();
    try std.testing.expectEqual(@as(u8, 2), counter.count);

    var other = Counter.init(5);
    other.set(200);
    try std.testing.expect(other.isExceeded());
    try std.testing.expectEqual(@as(u8, 5), other.count);
    other.set(1);
    try std.testing.expect(!other.isExceeded());
}

test "SafetyCounter disabled mode never trips" {
    const Counter = SafetyCounter(u8, .disabled);
    var counter = Counter.init(1);
    var i: usize = 0;
    while (i < 1000) : (i += 1) try counter.tick();
    try std.testing.expect(!counter.isExceeded());
}
