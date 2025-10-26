//! Comprehensive provider integration tests
//!
//! Tests all RPC methods, error scenarios, retries, timeouts, and concurrent access.

const std = @import("std");
const provider_mod = @import("provider");
const MockProvider = @import("mock_provider.zig").MockProvider;
const MockResponse = @import("mock_provider.zig").MockResponse;
const json_rpc = provider_mod.transport.json_rpc;
const HttpTransport = provider_mod.transport.HttpTransport;
const ConnectionPool = provider_mod.ConnectionPool;
const RateLimiter = provider_mod.RateLimiter;

// RPC Method End-to-End Tests

test "eth_blockNumber request and parse" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_blockNumber", MockResponse.success("\"0x123abc\""));

    const response = try provider.request("eth_blockNumber", "[]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.result != null);
    const result = response.result.?;

    const trimmed = std.mem.trim(u8, result, "\"");
    const hex = if (std.mem.startsWith(u8, trimmed, "0x")) trimmed[2..] else trimmed;
    const block_number = try std.fmt.parseInt(u64, hex, 16);

    try std.testing.expectEqual(@as(u64, 0x123abc), block_number);
}

test "eth_getBalance request with parameters" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    const address = "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb";
    const params = try std.fmt.allocPrint(allocator, "[\"{s}\",\"latest\"]", .{address});
    defer allocator.free(params);

    try provider.setResponse("eth_getBalance", MockResponse.success("\"0xde0b6b3a7640000\""));

    const response = try provider.request("eth_getBalance", params, 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.result != null);
}

test "eth_getTransactionCount request" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_getTransactionCount", MockResponse.success("\"0x5\""));

    const response = try provider.request("eth_getTransactionCount", "[\"0x123\",\"latest\"]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.result != null);

    const trimmed = std.mem.trim(u8, response.result.?, "\"");
    const hex = if (std.mem.startsWith(u8, trimmed, "0x")) trimmed[2..] else trimmed;
    const nonce = try std.fmt.parseInt(u64, hex, 16);

    try std.testing.expectEqual(@as(u64, 5), nonce);
}

test "eth_call request" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    const call_data = "\"0x70a08231000000000000000000000000742d35cc6634c0532925a3b844bc9e7595f0beb\"";
    try provider.setResponse("eth_call", MockResponse.success(call_data));

    const response = try provider.request("eth_call", "[{\"to\":\"0xA0b86\",\"data\":\"0x123\"},\"latest\"]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.result != null);
}

test "eth_getBlockByNumber with full transactions" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    const block_json =
        \\{"hash":"0xabc","number":"0x123","timestamp":"0x456"}
    ;

    try provider.setResponse("eth_getBlockByNumber", MockResponse.success(block_json));

    const response = try provider.request("eth_getBlockByNumber", "[\"0x123\",true]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.result != null);
}

test "eth_getTransactionReceipt request" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    const receipt_json =
        \\{"transactionHash":"0xabc","status":"0x1","gasUsed":"0x5208"}
    ;

    try provider.setResponse("eth_getTransactionReceipt", MockResponse.success(receipt_json));

    const response = try provider.request("eth_getTransactionReceipt", "[\"0xabc\"]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.result != null);
}

test "eth_chainId request" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_chainId", MockResponse.success("\"0x1\""));

    const response = try provider.request("eth_chainId", "[]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.result != null);

    const trimmed = std.mem.trim(u8, response.result.?, "\"");
    const hex = if (std.mem.startsWith(u8, trimmed, "0x")) trimmed[2..] else trimmed;
    const chain_id = try std.fmt.parseInt(u64, hex, 16);

    try std.testing.expectEqual(@as(u64, 1), chain_id);
}

test "eth_gasPrice request" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_gasPrice", MockResponse.success("\"0x3b9aca00\""));

    const response = try provider.request("eth_gasPrice", "[]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.result != null);
}

test "eth_estimateGas request" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_estimateGas", MockResponse.success("\"0x5208\""));

    const response = try provider.request("eth_estimateGas", "[{\"to\":\"0x123\"}]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.result != null);
}

test "eth_getCode request" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_getCode", MockResponse.success("\"0x6080604052\""));

    const response = try provider.request("eth_getCode", "[\"0x123\",\"latest\"]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.result != null);
}

// Error Scenario Tests

test "provider handles JSON-RPC error response" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_getBalance", MockResponse.failure(-32000, "Insufficient funds"));

    const response = try provider.request("eth_getBalance", "[\"0x123\",\"latest\"]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.error_info != null);
    try std.testing.expectEqual(@as(i32, -32000), response.error_info.?.code);
}

test "provider handles parse error" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_blockNumber", MockResponse.failure(-32700, "Parse error"));

    const response = try provider.request("eth_blockNumber", "[]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.error_info != null);
    try std.testing.expectEqual(@as(i32, -32700), response.error_info.?.code);
}

test "provider handles invalid request error" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("invalid_method", MockResponse.failure(-32600, "Invalid Request"));

    const response = try provider.request("invalid_method", "[]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.error_info != null);
    try std.testing.expectEqual(@as(i32, -32600), response.error_info.?.code);
}

test "provider handles method not found error" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    const response = try provider.request("nonexistent_method", "[]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.error_info != null);
    try std.testing.expectEqual(@as(i32, -32601), response.error_info.?.code);
}

test "provider handles invalid params error" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_getBalance", MockResponse.failure(-32602, "Invalid params"));

    const response = try provider.request("eth_getBalance", "[\"invalid\"]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.error_info != null);
    try std.testing.expectEqual(@as(i32, -32602), response.error_info.?.code);
}

test "provider handles internal error" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_blockNumber", MockResponse.failure(-32603, "Internal error"));

    const response = try provider.request("eth_blockNumber", "[]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.error_info != null);
    try std.testing.expectEqual(@as(i32, -32603), response.error_info.?.code);
}

test "provider handles server error" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_blockNumber", MockResponse.failure(-32000, "Server error"));

    const response = try provider.request("eth_blockNumber", "[]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.error_info != null);
    try std.testing.expectEqual(@as(i32, -32000), response.error_info.?.code);
}

test "provider handles network failure after multiple calls" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_blockNumber", MockResponse.success("\"0x123\""));
    provider.setFailAfterCalls(2);

    const response1 = try provider.request("eth_blockNumber", "[]", 1);
    response1.deinit(allocator);

    const response2 = try provider.request("eth_blockNumber", "[]", 2);
    response2.deinit(allocator);

    const result = provider.request("eth_blockNumber", "[]", 3);
    try std.testing.expectError(error.NetworkError, result);
}

// Timeout and Delay Tests

test "provider handles delayed responses" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    const delayed = MockResponse.success("\"0x123\"").withDelay(100);
    try provider.setResponse("eth_blockNumber", delayed);

    const start = std.time.milliTimestamp();
    const response = try provider.request("eth_blockNumber", "[]", 1);
    defer response.deinit(allocator);
    const elapsed = std.time.milliTimestamp() - start;

    try std.testing.expect(elapsed >= 95);
    try std.testing.expect(response.result != null);
}

test "provider handles multiple delayed requests" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    const delayed = MockResponse.success("\"0x123\"").withDelay(50);
    try provider.setResponse("eth_blockNumber", delayed);

    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const response = try provider.request("eth_blockNumber", "[]", i);
        response.deinit(allocator);
    }

    try std.testing.expectEqual(@as(u32, 3), provider.getCallCount("eth_blockNumber"));
}

// Concurrent Request Tests

test "provider handles concurrent requests safely" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_blockNumber", MockResponse.success("\"0x123\""));

    const ThreadContext = struct {
        provider: *MockProvider,
        allocator: Allocator,
        request_count: u32,

        fn worker(ctx: *@This()) void {
            var i: u32 = 0;
            while (i < ctx.request_count) : (i += 1) {
                const response = ctx.provider.request("eth_blockNumber", "[]", i) catch unreachable;
                response.deinit(ctx.allocator);
            }
        }
    };

    var context = ThreadContext{
        .provider = &provider,
        .allocator = allocator,
        .request_count = 50,
    };

    const thread1 = try std.Thread.spawn(.{}, ThreadContext.worker, .{&context});
    const thread2 = try std.Thread.spawn(.{}, ThreadContext.worker, .{&context});
    const thread3 = try std.Thread.spawn(.{}, ThreadContext.worker, .{&context});

    thread1.join();
    thread2.join();
    thread3.join();

    try std.testing.expectEqual(@as(u32, 150), provider.getCallCount("eth_blockNumber"));
}

test "provider handles mixed concurrent requests" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_blockNumber", MockResponse.success("\"0x123\""));
    try provider.setResponse("eth_chainId", MockResponse.success("\"0x1\""));

    const ThreadContext = struct {
        provider: *MockProvider,
        allocator: Allocator,
        method: []const u8,

        fn worker(ctx: *@This()) void {
            var i: u32 = 0;
            while (i < 25) : (i += 1) {
                const response = ctx.provider.request(ctx.method, "[]", i) catch unreachable;
                response.deinit(ctx.allocator);
            }
        }
    };

    var context1 = ThreadContext{
        .provider = &provider,
        .allocator = allocator,
        .method = "eth_blockNumber",
    };
    var context2 = ThreadContext{
        .provider = &provider,
        .allocator = allocator,
        .method = "eth_chainId",
    };

    const thread1 = try std.Thread.spawn(.{}, ThreadContext.worker, .{&context1});
    const thread2 = try std.Thread.spawn(.{}, ThreadContext.worker, .{&context2});

    thread1.join();
    thread2.join();

    try std.testing.expectEqual(@as(u32, 25), provider.getCallCount("eth_blockNumber"));
    try std.testing.expectEqual(@as(u32, 25), provider.getCallCount("eth_chainId"));
}

test "provider handles concurrent errors safely" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_blockNumber", MockResponse.failure(-32000, "Server error"));

    const ThreadContext = struct {
        provider: *MockProvider,
        allocator: Allocator,
        error_count: *std.atomic.Value(u32),

        fn worker(ctx: *@This()) void {
            var i: u32 = 0;
            while (i < 20) : (i += 1) {
                const response = ctx.provider.request("eth_blockNumber", "[]", i) catch unreachable;
                defer response.deinit(ctx.allocator);
                if (response.error_info != null) {
                    _ = ctx.error_count.fetchAdd(1, .monotonic);
                }
            }
        }
    };

    var error_count = std.atomic.Value(u32).init(0);
    var context = ThreadContext{
        .provider = &provider,
        .allocator = allocator,
        .error_count = &error_count,
    };

    const thread1 = try std.Thread.spawn(.{}, ThreadContext.worker, .{&context});
    const thread2 = try std.Thread.spawn(.{}, ThreadContext.worker, .{&context});

    thread1.join();
    thread2.join();

    try std.testing.expectEqual(@as(u32, 40), error_count.load(.monotonic));
}

// Rate Limiting Tests

test "rate limiter limits request rate" {
    var limiter = try RateLimiter.init(.{
        .max_tokens = 5,
        .tokens_per_second = 10,
    });

    var success_count: u32 = 0;
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        if (limiter.tryAcquire()) {
            success_count += 1;
        }
    }

    try std.testing.expectEqual(@as(u32, 5), success_count);
}

test "rate limiter refills over time" {
    var limiter = try RateLimiter.init(.{
        .max_tokens = 10,
        .tokens_per_second = 10,
    });

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        try std.testing.expect(limiter.tryAcquire());
    }

    std.time.sleep(std.time.ns_per_s);

    i = 0;
    while (i < 10) : (i += 1) {
        try std.testing.expect(limiter.tryAcquire());
    }
}

// Performance and Load Tests

test "provider handles high request volume" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_blockNumber", MockResponse.success("\"0x123\""));

    const start = std.time.milliTimestamp();

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const response = try provider.request("eth_blockNumber", "[]", i);
        response.deinit(allocator);
    }

    const elapsed = std.time.milliTimestamp() - start;

    try std.testing.expectEqual(@as(u32, 1000), provider.getCallCount("eth_blockNumber"));
    try std.testing.expect(elapsed < 5000);
}

test "provider memory usage under load" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    const large_response = "\"0x" ++ "00" ** 1000 ++ "\"";
    try provider.setResponse("eth_blockNumber", MockResponse.success(large_response));

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const response = try provider.request("eth_blockNumber", "[]", i);
        response.deinit(allocator);
    }

    try std.testing.expectEqual(@as(u32, 100), provider.getCallCount("eth_blockNumber"));
}

test "provider handles burst then sustained load" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_blockNumber", MockResponse.success("\"0x123\""));

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const response = try provider.request("eth_blockNumber", "[]", i);
        response.deinit(allocator);
    }

    std.time.sleep(100 * std.time.ns_per_ms);

    i = 0;
    while (i < 100) : (i += 1) {
        const response = try provider.request("eth_blockNumber", "[]", i + 100);
        response.deinit(allocator);
    }

    try std.testing.expectEqual(@as(u32, 200), provider.getCallCount("eth_blockNumber"));
}
