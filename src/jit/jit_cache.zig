//! Bounded cache of compiled programs keyed by code hash, with byte-checked hits.
//!
//! Each `lookup` counts a hit. Code compiles on the hit that reaches
//! `hot_threshold`; until then, and forever for ineligible code, `lookup`
//! returns null and the host interprets. At capacity the least recently used
//! entry is evicted and its pages unmapped.

const std = @import("std");
const compiler = @import("compiler.zig");

pub const Program = compiler.Program;

pub const Config = struct {
    capacity: usize = 64,
    hot_threshold: u32 = 2,
    options: compiler.Options = .{},
};

const State = enum { counting, compiled, ineligible };

const Entry = struct {
    hash: [32]u8,
    hits: u32,
    last_used: u64,
    state: State,
    program: ?Program,
    code: []const u8 = &.{},

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        if (self.program) |*program| {
            program.deinit();
            allocator.free(self.code);
        }
    }
};

pub const JitCache = struct {
    allocator: std.mem.Allocator,
    config: Config,
    entries: std.ArrayList(Entry) = .empty,
    tick: u64 = 0,
    compiled_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: Config) error{InvalidConfig}!JitCache {
        if (config.capacity == 0 or config.hot_threshold == 0) return error.InvalidConfig;
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *JitCache) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    fn find(self: *JitCache, hash: *const [32]u8) ?*Entry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, &entry.hash, hash)) return entry;
        }
        return null;
    }

    fn evictLeastRecent(self: *JitCache) void {
        var victim: usize = 0;
        for (self.entries.items, 0..) |entry, i| {
            if (entry.last_used < self.entries.items[victim].last_used) victim = i;
        }
        var removed = self.entries.swapRemove(victim);
        if (removed.program != null) self.compiled_count -= 1;
        removed.deinit(self.allocator);
    }

    /// Records a hit for `hash` and returns the compiled program once the
    /// code is hot and eligible. A compiled hash hit also requires identical bytes.
    /// The returned pointer is valid until the next `lookup` or `deinit`.
    pub fn lookup(self: *JitCache, hash: *const [32]u8, code: []const u8) compiler.CompileError!?*const Program {
        if (comptime !compiler.native_supported) return null;
        self.tick +%= 1;
        const entry = self.find(hash) orelse blk: {
            if (self.entries.items.len >= self.config.capacity) self.evictLeastRecent();
            try self.entries.append(self.allocator, .{
                .hash = hash.*,
                .hits = 0,
                .last_used = self.tick,
                .state = .counting,
                .program = null,
            });
            break :blk &self.entries.items[self.entries.items.len - 1];
        };
        entry.last_used = self.tick;
        entry.hits +|= 1;
        switch (entry.state) {
            .ineligible => return null,
            .compiled => return if (std.mem.eql(u8, entry.code, code)) &entry.program.? else null,
            .counting => {},
        }
        if (entry.hits < self.config.hot_threshold) return null;
        var program = (try compiler.compile(self.allocator, code, self.config.options)) orelse {
            entry.state = .ineligible;
            return null;
        };
        errdefer program.deinit();
        entry.code = try self.allocator.dupe(u8, code);
        entry.program = program;
        entry.state = .compiled;
        self.compiled_count += 1;
        return &entry.program.?;
    }

    pub fn len(self: *const JitCache) usize {
        return self.entries.items.len;
    }
};

test "JitCache compiles at the hot threshold and evicts LRU" {
    if (comptime !compiler.native_supported) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var cache = try JitCache.init(allocator, .{ .capacity = 2, .hot_threshold = 2 });
    defer cache.deinit();

    const stop = [_]u8{0x00};
    const add = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 };
    const sload = [_]u8{ 0x60, 0x00, 0x54, 0x00 };
    const h1 = [_]u8{1} ** 32;
    const h2 = [_]u8{2} ** 32;
    const h3 = [_]u8{3} ** 32;

    try std.testing.expect((try cache.lookup(&h1, &stop)) == null);
    try std.testing.expect((try cache.lookup(&h1, &stop)) != null);
    try std.testing.expectEqual(@as(usize, 1), cache.compiled_count);

    try std.testing.expect((try cache.lookup(&h3, &sload)) == null);
    try std.testing.expect((try cache.lookup(&h3, &sload)) == null);
    try std.testing.expect((try cache.lookup(&h3, &sload)) == null);

    // h1 is least recently used and gets evicted (and unmapped) for h2.
    try std.testing.expect((try cache.lookup(&h2, &add)) == null);
    try std.testing.expectEqual(@as(usize, 2), cache.len());
    try std.testing.expectEqual(@as(usize, 0), cache.compiled_count);
    try std.testing.expect((try cache.lookup(&h2, &add)) != null);
    try std.testing.expectEqual(@as(usize, 1), cache.compiled_count);
}

test "JitCache rejects a zero threshold" {
    try std.testing.expectError(error.InvalidConfig, JitCache.init(std.testing.allocator, .{ .hot_threshold = 0 }));
}

test "a hash hit cannot execute native code compiled for different bytes" {
    if (comptime !compiler.native_supported) return error.SkipZigTest;
    var cache = try JitCache.init(std.testing.allocator, .{});
    defer cache.deinit();
    const hash = [_]u8{3} ** 32;
    try std.testing.expectEqual(null, try cache.lookup(&hash, &.{0x00}));
    try std.testing.expect((try cache.lookup(&hash, &.{0x00})) != null);
    try std.testing.expect((try cache.lookup(&hash, &.{0xfe})) == null);
    try std.testing.expect((try cache.lookup(&hash, &.{0x00})) != null);
}
