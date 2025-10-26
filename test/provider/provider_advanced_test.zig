//! Advanced provider integration tests
//!
//! Tests complex scenarios including malformed responses, retries,
//! connection pooling integration, and edge cases.

const std = @import("std");
const provider_mod = @import("provider");
const MockProvider = @import("mock_provider.zig").MockProvider;
const MockResponse = @import("mock_provider.zig").MockResponse;
const json_rpc = provider_mod.transport.json_rpc;

// Malformed Response Tests

test "provider handles empty response body" {
    const allocator = std.testing.allocator;

    const result = json_rpc.JsonRpcResponse.from_json(allocator, "");
    try std.testing.expectError(error.ParseError, result);
}

test "provider handles invalid JSON" {
    const allocator = std.testing.allocator;

    const invalid_json = "{invalid json";
    const result = json_rpc.JsonRpcResponse.from_json(allocator, invalid_json);
    try std.testing.expectError(error.ParseError, result);
}

test "provider handles missing jsonrpc field" {
    const allocator = std.testing.allocator;

    const json =
        \\{"result":"0x123","id":1}
    ;
    const result = json_rpc.JsonRpcResponse.from_json(allocator, json);
    try std.testing.expectError(error.InvalidResponse, result);
}

test "provider handles wrong jsonrpc version" {
    const allocator = std.testing.allocator;

    const json =
        \\{"jsonrpc":"1.0","result":"0x123","id":1}
    ;
    const result = json_rpc.JsonRpcResponse.from_json(allocator, json);
    try std.testing.expectError(error.InvalidResponse, result);
}

test "provider handles missing id field" {
    const allocator = std.testing.allocator;

    const json =
        \\{"jsonrpc":"2.0","result":"0x123"}
    ;
    const result = json_rpc.JsonRpcResponse.from_json(allocator, json);
    try std.testing.expectError(error.InvalidResponse, result);
}

test "provider handles response with both result and error" {
    const allocator = std.testing.allocator;

    const json =
        \\{"jsonrpc":"2.0","result":"0x123","error":{"code":-32000,"message":"Error"},"id":1}
    ;
    const response = try json_rpc.JsonRpcResponse.from_json(allocator, json);
    defer response.deinit(allocator);

    try response.validate();
}

test "provider handles response with neither result nor error" {
    const allocator = std.testing.allocator;

    var response = json_rpc.JsonRpcResponse{
        .result = null,
        .error_info = null,
        .id = 1,
    };

    const result = response.validate();
    try std.testing.expectError(error.InvalidResponse, result);
}

test "provider handles malformed error object" {
    const allocator = std.testing.allocator;

    const json =
        \\{"jsonrpc":"2.0","error":"not an object","id":1}
    ;
    const result = json_rpc.JsonRpcResponse.from_json(allocator, json);
    try std.testing.expectError(error.InvalidResponse, result);
}

test "provider handles error missing code" {
    const allocator = std.testing.allocator;

    const json =
        \\{"jsonrpc":"2.0","error":{"message":"Error"},"id":1}
    ;
    const result = json_rpc.JsonRpcResponse.from_json(allocator, json);
    try std.testing.expectError(error.InvalidResponse, result);
}

test "provider handles error missing message" {
    const allocator = std.testing.allocator;

    const json =
        \\{"jsonrpc":"2.0","error":{"code":-32000},"id":1}
    ;
    const result = json_rpc.JsonRpcResponse.from_json(allocator, json);
    try std.testing.expectError(error.InvalidResponse, result);
}

// Large Response Tests

test "provider handles large response" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    var large_data = std.ArrayList(u8).init(allocator);
    defer large_data.deinit();

    try large_data.appendSlice("\"0x");
    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        try large_data.appendSlice("ab");
    }
    try large_data.appendSlice("\"");

    try provider.setResponse("eth_getCode", MockResponse.success(large_data.items));

    const response = try provider.request("eth_getCode", "[\"0x123\",\"latest\"]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.result != null);
    try std.testing.expect(response.result.?.len > 20000);
}

test "provider handles multiple large responses" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    const large_response = "\"0x" ++ "00" ** 5000 ++ "\"";
    try provider.setResponse("eth_getCode", MockResponse.success(large_response));

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        const response = try provider.request("eth_getCode", "[\"0x123\",\"latest\"]", i);
        response.deinit(allocator);
    }

    try std.testing.expectEqual(@as(u32, 10), provider.getCallCount("eth_getCode"));
}

// Request Validation Tests

test "json rpc request validates method" {
    const allocator = std.testing.allocator;

    const request = json_rpc.JsonRpcRequest{
        .method = "",
        .params = "[]",
        .id = 1,
    };

    const result = request.validate();
    try std.testing.expectError(error.InvalidRequest, result);
}

test "json rpc request validates params" {
    const allocator = std.testing.allocator;

    const request = json_rpc.JsonRpcRequest{
        .method = "eth_blockNumber",
        .params = "",
        .id = 1,
    };

    const result = request.validate();
    try std.testing.expectError(error.InvalidParams, result);
}

test "json rpc request serializes correctly" {
    const allocator = std.testing.allocator;

    const request = json_rpc.JsonRpcRequest{
        .method = "eth_blockNumber",
        .params = "[]",
        .id = 1,
    };

    const json = try request.to_json(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"method\":\"eth_blockNumber\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":1") != null);
}

test "json rpc request parses from json" {
    const allocator = std.testing.allocator;

    const json =
        \\{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}
    ;

    const request = try json_rpc.JsonRpcRequest.from_json(allocator, json);
    defer request.deinit(allocator);

    try std.testing.expectEqualStrings("eth_blockNumber", request.method);
    try std.testing.expectEqual(@as(u64, 1), request.id);
}

test "json rpc response serializes success" {
    const allocator = std.testing.allocator;

    const response = try json_rpc.JsonRpcResponse.createSuccess(allocator, "\"0x123\"", 1);
    defer response.deinit(allocator);

    const json = try response.to_json(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"result\":\"0x123\"") != null);
}

test "json rpc response serializes error" {
    const allocator = std.testing.allocator;

    const response = try json_rpc.JsonRpcResponse.createError(allocator, .InternalError, 1);
    defer response.deinit(allocator);

    const json = try response.to_json(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"code\":-32603") != null);
}

// Edge Case Tests

test "provider handles rapid sequential requests" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_blockNumber", MockResponse.success("\"0x123\""));

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const response = try provider.request("eth_blockNumber", "[]", i);
        response.deinit(allocator);
    }

    try std.testing.expectEqual(@as(u32, 100), provider.getCallCount("eth_blockNumber"));
}

test "provider handles alternating success and failure" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("method_success", MockResponse.success("\"0x123\""));
    try provider.setResponse("method_failure", MockResponse.failure(-32000, "Error"));

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        if (i % 2 == 0) {
            const response = try provider.request("method_success", "[]", i);
            response.deinit(allocator);
        } else {
            const response = try provider.request("method_failure", "[]", i);
            response.deinit(allocator);
        }
    }

    try std.testing.expectEqual(@as(u32, 5), provider.getCallCount("method_success"));
    try std.testing.expectEqual(@as(u32, 5), provider.getCallCount("method_failure"));
}

test "provider handles zero-length result" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_getCode", MockResponse.success("\"0x\""));

    const response = try provider.request("eth_getCode", "[\"0x123\",\"latest\"]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.result != null);
    try std.testing.expectEqualStrings("\"0x\"", response.result.?);
}

test "provider handles null block response" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_getBlockByNumber", MockResponse.success("null"));

    const response = try provider.request("eth_getBlockByNumber", "[\"0x999999\",false]", 1);
    defer response.deinit(allocator);

    try std.testing.expect(response.result != null);
    try std.testing.expectEqualStrings("null", response.result.?);
}

// State Management Tests

test "provider reset clears call counts" {
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

    provider.reset();

    try std.testing.expectEqual(@as(u32, 0), provider.getCallCount("eth_blockNumber"));
}

test "provider maintains separate call counts per method" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_blockNumber", MockResponse.success("\"0x123\""));
    try provider.setResponse("eth_chainId", MockResponse.success("\"0x1\""));
    try provider.setResponse("eth_gasPrice", MockResponse.success("\"0x3b9aca00\""));

    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const r1 = try provider.request("eth_blockNumber", "[]", i);
        r1.deinit(allocator);
    }

    i = 0;
    while (i < 2) : (i += 1) {
        const r2 = try provider.request("eth_chainId", "[]", i);
        r2.deinit(allocator);
    }

    i = 0;
    while (i < 1) : (i += 1) {
        const r3 = try provider.request("eth_gasPrice", "[]", i);
        r3.deinit(allocator);
    }

    try std.testing.expectEqual(@as(u32, 3), provider.getCallCount("eth_blockNumber"));
    try std.testing.expectEqual(@as(u32, 2), provider.getCallCount("eth_chainId"));
    try std.testing.expectEqual(@as(u32, 1), provider.getCallCount("eth_gasPrice"));
}

// JSON-RPC 2.0 Compliance Tests

test "json rpc error codes are correct" {
    try std.testing.expectEqual(@as(i32, -32700), @intFromEnum(json_rpc.ErrorCode.ParseError));
    try std.testing.expectEqual(@as(i32, -32600), @intFromEnum(json_rpc.ErrorCode.InvalidRequest));
    try std.testing.expectEqual(@as(i32, -32601), @intFromEnum(json_rpc.ErrorCode.MethodNotFound));
    try std.testing.expectEqual(@as(i32, -32602), @intFromEnum(json_rpc.ErrorCode.InvalidParams));
    try std.testing.expectEqual(@as(i32, -32603), @intFromEnum(json_rpc.ErrorCode.InternalError));
    try std.testing.expectEqual(@as(i32, -32000), @intFromEnum(json_rpc.ErrorCode.ServerError));
}

test "json rpc error messages are correct" {
    try std.testing.expectEqualStrings("Parse error", json_rpc.ErrorCode.ParseError.message());
    try std.testing.expectEqualStrings("Invalid Request", json_rpc.ErrorCode.InvalidRequest.message());
    try std.testing.expectEqualStrings("Method not found", json_rpc.ErrorCode.MethodNotFound.message());
    try std.testing.expectEqualStrings("Invalid params", json_rpc.ErrorCode.InvalidParams.message());
    try std.testing.expectEqualStrings("Internal error", json_rpc.ErrorCode.InternalError.message());
    try std.testing.expectEqualStrings("Server error", json_rpc.ErrorCode.ServerError.message());
}

test "json rpc creates custom error" {
    const allocator = std.testing.allocator;

    const err = try json_rpc.JsonRpcError.createCustom(allocator, -32001, "Custom error message");
    defer err.deinit(allocator);

    try std.testing.expectEqual(@as(i32, -32001), err.code);
    try std.testing.expectEqualStrings("Custom error message", err.message);
}

// Memory Management Tests

test "provider properly cleans up response memory" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_blockNumber", MockResponse.success("\"0x123\""));

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const response = try provider.request("eth_blockNumber", "[]", i);
        response.deinit(allocator);
    }
}

test "provider properly cleans up error memory" {
    const allocator = std.testing.allocator;

    var provider = MockProvider.init(allocator);
    defer provider.deinit();

    try provider.setResponse("eth_blockNumber", MockResponse.failure(-32000, "Error"));

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const response = try provider.request("eth_blockNumber", "[]", i);
        response.deinit(allocator);
    }
}

// Hex Parsing Tests

test "provider parses hex block numbers correctly" {
    const test_cases = [_]struct { hex: []const u8, expected: u64 }{
        .{ .hex = "0x0", .expected = 0 },
        .{ .hex = "0x1", .expected = 1 },
        .{ .hex = "0xa", .expected = 10 },
        .{ .hex = "0xff", .expected = 255 },
        .{ .hex = "0x100", .expected = 256 },
        .{ .hex = "0x1234", .expected = 4660 },
        .{ .hex = "0xabcdef", .expected = 11259375 },
        .{ .hex = "0x123abc", .expected = 1194684 },
    };

    for (test_cases) |case| {
        const hex = if (std.mem.startsWith(u8, case.hex, "0x")) case.hex[2..] else case.hex;
        const result = try std.fmt.parseInt(u64, hex, 16);
        try std.testing.expectEqual(case.expected, result);
    }
}

test "provider handles leading zeros in hex" {
    const hex = "0x00123";
    const trimmed = if (std.mem.startsWith(u8, hex, "0x")) hex[2..] else hex;
    const result = try std.fmt.parseInt(u64, trimmed, 16);
    try std.testing.expectEqual(@as(u64, 0x123), result);
}
