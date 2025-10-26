//! Mock provider for comprehensive testing
//!
//! Simulates all RPC methods with configurable responses, errors, and delays.
//! Thread-safe for concurrent request testing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const provider = @import("provider");
const json_rpc = provider.transport.json_rpc;

/// Mock RPC response configuration
pub const MockResponse = struct {
    result: ?[]const u8,
    error_code: ?i32,
    error_message: ?[]const u8,
    delay_ms: u32,

    pub fn success(result: []const u8) MockResponse {
        return .{
            .result = result,
            .error_code = null,
            .error_message = null,
            .delay_ms = 0,
        };
    }

    pub fn failure(code: i32, message: []const u8) MockResponse {
        return .{
            .result = null,
            .error_code = code,
            .error_message = message,
            .delay_ms = 0,
        };
    }

    pub fn withDelay(self: MockResponse, delay_ms: u32) MockResponse {
        var result = self;
        result.delay_ms = delay_ms;
        return result;
    }
};

/// Mock provider state
pub const MockProvider = struct {
    allocator: Allocator,
    responses: std.StringHashMap(MockResponse),
    call_counts: std.StringHashMap(u32),
    mutex: std.Thread.Mutex,
    fail_after_calls: ?u32,
    current_call_count: u32,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .responses = std.StringHashMap(MockResponse).init(allocator),
            .call_counts = std.StringHashMap(u32).init(allocator),
            .mutex = std.Thread.Mutex{},
            .fail_after_calls = null,
            .current_call_count = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        var resp_it = self.responses.iterator();
        while (resp_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.responses.deinit();

        var count_it = self.call_counts.iterator();
        while (count_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.call_counts.deinit();
    }

    /// Set expected response for a method
    pub fn setResponse(self: *Self, method: []const u8, response: MockResponse) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = try self.allocator.dupe(u8, method);
        try self.responses.put(key, response);
    }

    /// Configure provider to fail after N calls
    pub fn setFailAfterCalls(self: *Self, n: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.fail_after_calls = n;
        self.current_call_count = 0;
    }

    /// Get call count for a method
    pub fn getCallCount(self: *Self, method: []const u8) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.call_counts.get(method) orelse 0;
    }

    /// Reset all state
    pub fn reset(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var count_it = self.call_counts.valueIterator();
        while (count_it.next()) |count| {
            count.* = 0;
        }
        self.current_call_count = 0;
    }

    /// Handle mock request
    pub fn request(self: *Self, method: []const u8, params: []const u8, id: u64) !json_rpc.JsonRpcResponse {
        _ = params;
        self.mutex.lock();
        defer self.mutex.unlock();

        self.current_call_count += 1;

        if (self.fail_after_calls) |n| {
            if (self.current_call_count > n) {
                return error.NetworkError;
            }
        }

        const method_key = try self.allocator.dupe(u8, method);
        errdefer self.allocator.free(method_key);

        const count_entry = try self.call_counts.getOrPut(method_key);
        if (!count_entry.found_existing) {
            count_entry.key_ptr.* = method_key;
            count_entry.value_ptr.* = 0;
        } else {
            self.allocator.free(method_key);
        }
        count_entry.value_ptr.* += 1;

        const response = self.responses.get(method) orelse MockResponse.failure(-32601, "Method not found");

        if (response.delay_ms > 0) {
            self.mutex.unlock();
            std.time.sleep(response.delay_ms * std.time.ns_per_ms);
            self.mutex.lock();
        }

        if (response.error_code) |code| {
            const msg = response.error_message orelse "Unknown error";
            return json_rpc.JsonRpcResponse.createCustomError(self.allocator, code, msg, id);
        }

        if (response.result) |result| {
            return json_rpc.JsonRpcResponse.createSuccess(self.allocator, result, id);
        }

        return json_rpc.JsonRpcResponse.createError(self.allocator, .InternalError, id);
    }
};

test "mock provider initialization" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try std.testing.expectEqual(@as(u32, 0), provider.getCallCount("eth_blockNumber"));
}

test "mock provider set and get response" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_blockNumber", MockResponse.success("\"0x123456\""));

    const response = try provider.request("eth_blockNumber", "[]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.result != null);
    try std.testing.expectEqualStrings("\"0x123456\"", response.result.?);
}

test "mock provider error response" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_getBalance", MockResponse.failure(-32000, "Server error"));

    const response = try provider.request("eth_getBalance", "[\"0x123\",\"latest\"]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.error_info != null);
    try std.testing.expectEqual(@as(i32, -32000), response.error_info.?.code);
}

test "mock provider call counting" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_blockNumber", MockResponse.success("\"0x123\""));

    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const response = try provider.request("eth_blockNumber", "[]", i);
        response.deinit(allocator);
    }

    try std.testing.expectEqual(@as(u32, 5), provider.getCallCount("eth_blockNumber"));
}

test "mock provider fail after calls" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_blockNumber", MockResponse.success("\"0x123\""));
    provider.setFailAfterCalls(3);

    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const response = try provider.request("eth_blockNumber", "[]", i);
        response.deinit(allocator);
    }

    const result = provider.request("eth_blockNumber", "[]", 4);
    try std.testing.expectError(error.NetworkError, result);
}

test "mock provider reset" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_blockNumber", MockResponse.success("\"0x123\""));

    const response1 = try provider.request("eth_blockNumber", "[]", 1);
    response1.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), provider.getCallCount("eth_blockNumber"));

    provider.reset();

    try std.testing.expectEqual(@as(u32, 0), provider.getCallCount("eth_blockNumber"));
}

test "mock provider method not found" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    const response = try provider.request("unknown_method", "[]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.error_info != null);
    try std.testing.expectEqual(@as(i32, -32601), response.error_info.?.code);
}

test "mock provider delayed response" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    const delayed = MockResponse.success("\"0x123\"").withDelay(50);
    try provider.setResponse("eth_blockNumber", delayed);

    const start = std.time.milliTimestamp();
    const response = try provider.request("eth_blockNumber", "[]", 1);
    defer response.deinit(allocator);
    const elapsed = std.time.milliTimestamp() - start;

    try std.testing.expect(elapsed >= 45);
}

test "mock provider concurrent requests" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_blockNumber", MockResponse.success("\"0x123\""));

    const ThreadContext = struct {
        provider: *MockProvider,
        allocator: Allocator,

        fn worker(ctx: *@This()) void {
            var i: u32 = 0;
            while (i < 10) : (i += 1) {
                const response = ctx.provider.request("eth_blockNumber", "[]", i) catch unreachable;
                response.deinit(ctx.allocator);
            }
        }
    };

    var context = ThreadContext{
        .provider = &provider,
        .allocator = allocator,
    };

    const thread1 = try std.Thread.spawn(.{}, ThreadContext.worker, .{&context});
    const thread2 = try std.Thread.spawn(.{}, ThreadContext.worker, .{&context});

    thread1.join();
    thread2.join();

    try std.testing.expectEqual(@as(u32, 20), provider.getCallCount("eth_blockNumber"));
}
