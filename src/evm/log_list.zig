//! Optimized log storage for EVM frames using u16 indexing.
//!
//! LogList is a specialized container for Log entries that uses u16 indexing
//! instead of usize, saving memory per frame. The u16 limit (65,535 logs)
//! is sufficient for all realistic use cases while being much smaller than
//! the theoretical gas-based maximum of ~80,000 logs per block.

const std = @import("std");
const Log = @import("logs.zig").Log;

/// Compact log container using u16 indexing for memory efficiency
pub const LogList = struct {
    items: []Log,
    len: u16,

    const Self = @This();

    /// Maximum number of logs that can be stored (u16 limit)
    pub const MAX_LOGS: u16 = std.math.maxInt(u16);

    /// Initialize empty log list
    pub fn init() Self {
        return Self{
            .items = &[_]Log{},
            .len = 0,
        };
    }

    /// Clean up allocated memory
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        // Free individual log data
        for (self.items[0..self.len]) |log_entry| {
            allocator.free(log_entry.topics);
            allocator.free(log_entry.data);
        }
        // Free items array
        if (self.items.len > 0) {
            allocator.free(self.items);
        }
    }

    /// Add a log entry to the list
    pub fn append(self: *Self, allocator: std.mem.Allocator, log_entry: Log) error{OutOfMemory}!void {
        if (self.len >= MAX_LOGS) {
            @branchHint(.cold);
            return error.OutOfMemory; // Too many logs
        }

        // Grow capacity if needed
        if (self.len >= self.items.len) {
            try self.grow(allocator);
        }

        self.items[self.len] = log_entry;
        self.len += 1;
    }

    /// Get slice of current log entries
    pub fn slice(self: *const Self) []const Log {
        return self.items[0..self.len];
    }

    /// Get number of logs
    pub fn count(self: *const Self) u16 {
        return self.len;
    }

    /// Grow the capacity of the log list
    fn grow(self: *Self, allocator: std.mem.Allocator) error{OutOfMemory}!void {
        const current_capacity = self.items.len;
        const new_capacity: u16 = if (current_capacity == 0) 
            8 // Start with 8 logs
        else 
            @min(@as(u16, @intCast(current_capacity)) * 2, MAX_LOGS); // Double capacity up to max

        if (new_capacity <= current_capacity) {
            @branchHint(.cold);
            return error.OutOfMemory; // Can't grow anymore
        }

        const new_items = allocator.alloc(Log, new_capacity) catch {
            @branchHint(.cold);
            return error.OutOfMemory;
        };

        // Copy existing items
        if (self.len > 0) {
            @memcpy(new_items[0..self.len], self.items[0..self.len]);
        }

        // Free old items if we had any
        if (current_capacity > 0) {
            allocator.free(self.items);
        }

        self.items = new_items;
    }
};

// Tests
test "LogList basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var log_list = LogList.init();
    defer log_list.deinit(allocator);
    
    // Test initial state
    try testing.expectEqual(@as(u16, 0), log_list.count());
    try testing.expectEqual(@as(usize, 0), log_list.slice().len);
}

test "LogList append and growth" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Address = @import("primitives").Address.Address;
    
    var log_list = LogList.init();
    defer log_list.deinit(allocator);
    
    // Create test log
    const topics = try allocator.alloc(u256, 1);
    topics[0] = 0x1234;
    const data = try allocator.alloc(u8, 4);
    data[0] = 0xab;
    data[1] = 0xcd;
    data[2] = 0xef;
    data[3] = 0x12;
    
    const test_log = Log{
        .address = Address.ZERO_ADDRESS,
        .topics = topics,
        .data = data,
    };
    
    try log_list.append(allocator, test_log);
    try testing.expectEqual(@as(u16, 1), log_list.count());
    
    const logs = log_list.slice();
    try testing.expectEqual(@as(usize, 1), logs.len);
    try testing.expectEqual(test_log.address, logs[0].address);
    try testing.expectEqual(@as(usize, 1), logs[0].topics.len);
    try testing.expectEqual(@as(u256, 0x1234), logs[0].topics[0]);
}

test "LogList memory efficiency" {
    const testing = std.testing;
    
    // Verify LogList is smaller than ArrayList(Log)
    const log_list_size = @sizeOf(LogList);
    const array_list_size = @sizeOf(std.ArrayList(Log));
    
    try testing.expect(log_list_size < array_list_size);
    
    // LogList should be: []Log (16) + u16 (2) = 18 bytes (with padding to 24)
    // vs ArrayList: []Log (16) + usize (8) = 24 bytes
    // LogList saves 6 bytes and limits logs to u16 range
}
