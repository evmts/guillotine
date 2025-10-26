const std = @import("std");
const Allocator = std.mem.Allocator;

// JSON-RPC 2.0 implementation with comprehensive validation

/// Standard JSON-RPC 2.0 error codes
pub const ErrorCode = enum(i32) {
    ParseError = -32700,
    InvalidRequest = -32600,
    MethodNotFound = -32601,
    InvalidParams = -32602,
    InternalError = -32603,
    ServerError = -32000,

    pub fn message(self: ErrorCode) []const u8 {
        return switch (self) {
            .ParseError => "Parse error",
            .InvalidRequest => "Invalid Request",
            .MethodNotFound => "Method not found",
            .InvalidParams => "Invalid params",
            .InternalError => "Internal error",
            .ServerError => "Server error",
        };
    }
};

pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,

    pub fn create(allocator: Allocator, error_code: ErrorCode) !JsonRpcError {
        return JsonRpcError{
            .code = @intFromEnum(error_code),
            .message = try allocator.dupe(u8, error_code.message()),
        };
    }

    pub fn createCustom(allocator: Allocator, code: i32, message: []const u8) !JsonRpcError {
        return JsonRpcError{
            .code = code,
            .message = try allocator.dupe(u8, message),
        };
    }

    pub fn deinit(self: JsonRpcError, allocator: Allocator) void {
        allocator.free(self.message);
    }
};

pub const JsonRpcRequest = struct {
    method: []const u8,
    params: []const u8, // JSON string
    id: u64,

    /// Validate request structure
    pub fn validate(self: JsonRpcRequest) !void {
        if (self.method.len == 0) {
            return error.InvalidRequest;
        }
        if (self.params.len == 0) {
            return error.InvalidParams;
        }
    }

    pub fn to_json(self: JsonRpcRequest, allocator: Allocator) ![]u8 {
        try self.validate();
        return std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","method":"{s}","params":{s},"id":{d}}}
        , .{ self.method, self.params, self.id });
    }

    /// Parse and validate JSON-RPC request from JSON string
    pub fn from_json(allocator: Allocator, json_str: []const u8) !JsonRpcRequest {
        if (json_str.len == 0) {
            return error.ParseError;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
            return error.ParseError;
        };
        defer parsed.deinit();

        const root = parsed.value.object;

        const jsonrpc = root.get("jsonrpc") orelse return error.InvalidRequest;
        if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) {
            return error.InvalidRequest;
        }

        const method = root.get("method") orelse return error.InvalidRequest;
        if (method != .string or method.string.len == 0) {
            return error.InvalidRequest;
        }

        const params = root.get("params") orelse return error.InvalidParams;

        const id = root.get("id") orelse return error.InvalidRequest;
        const id_value = switch (id) {
            .integer => |i| @as(u64, @intCast(i)),
            .float => |f| @as(u64, @intFromFloat(f)),
            else => return error.InvalidRequest,
        };

        var params_str = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer params_str.deinit();
        try std.json.stringify(params, .{}, params_str.writer());

        return JsonRpcRequest{
            .method = try allocator.dupe(u8, method.string),
            .params = try allocator.dupe(u8, params_str.items),
            .id = id_value,
        };
    }

    pub fn deinit(self: JsonRpcRequest, allocator: Allocator) void {
        allocator.free(self.method);
        allocator.free(self.params);
    }
};

pub const JsonRpcResponse = struct {
    result: ?[]const u8, // JSON string
    error_info: ?JsonRpcError,
    id: u64,

    /// Validate response structure
    pub fn validate(self: JsonRpcResponse) !void {
        const has_result = self.result != null;
        const has_error = self.error_info != null;

        if (has_result and has_error) {
            return error.InvalidResponse;
        }
        if (!has_result and !has_error) {
            return error.InvalidResponse;
        }
    }

    /// Create success response
    pub fn createSuccess(allocator: Allocator, result: []const u8, id: u64) !JsonRpcResponse {
        return JsonRpcResponse{
            .result = try allocator.dupe(u8, result),
            .error_info = null,
            .id = id,
        };
    }

    /// Create error response
    pub fn createError(allocator: Allocator, error_code: ErrorCode, id: u64) !JsonRpcResponse {
        return JsonRpcResponse{
            .result = null,
            .error_info = try JsonRpcError.create(allocator, error_code),
            .id = id,
        };
    }

    /// Create custom error response
    pub fn createCustomError(allocator: Allocator, code: i32, message: []const u8, id: u64) !JsonRpcResponse {
        return JsonRpcResponse{
            .result = null,
            .error_info = try JsonRpcError.createCustom(allocator, code, message),
            .id = id,
        };
    }

    pub fn to_json(self: JsonRpcResponse, allocator: Allocator) ![]u8 {
        try self.validate();

        if (self.error_info) |err| {
            return std.fmt.allocPrint(allocator,
                \\{{"jsonrpc":"2.0","error":{{"code":{d},"message":"{s}"}},"id":{d}}}
            , .{ err.code, err.message, self.id });
        } else if (self.result) |result| {
            return std.fmt.allocPrint(allocator,
                \\{{"jsonrpc":"2.0","result":{s},"id":{d}}}
            , .{ result, self.id });
        }

        return error.InvalidResponse;
    }

    pub fn from_json(allocator: Allocator, json_str: []const u8) !JsonRpcResponse {
        if (json_str.len == 0) {
            return error.ParseError;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
            return error.ParseError;
        };
        defer parsed.deinit();

        const root = parsed.value.object;

        const jsonrpc = root.get("jsonrpc") orelse return error.InvalidResponse;
        if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) {
            return error.InvalidResponse;
        }

        const id = if (root.get("id")) |id_val|
            switch (id_val) {
                .integer => |i| @as(u64, @intCast(i)),
                .float => |f| @as(u64, @intFromFloat(f)),
                else => return error.InvalidResponse,
            }
        else
            return error.InvalidResponse;

        if (root.get("error")) |error_val| {
            if (error_val != .object) {
                return error.InvalidResponse;
            }
            const error_obj = error_val.object;

            const code = if (error_obj.get("code")) |code_val|
                switch (code_val) {
                    .integer => |i| @as(i32, @intCast(i)),
                    .float => |f| @as(i32, @intFromFloat(f)),
                    else => return error.InvalidResponse,
                }
            else
                return error.InvalidResponse;

            const message = if (error_obj.get("message")) |msg_val|
                switch (msg_val) {
                    .string => |s| try allocator.dupe(u8, s),
                    else => return error.InvalidResponse,
                }
            else
                return error.InvalidResponse;

            return JsonRpcResponse{
                .result = null,
                .error_info = JsonRpcError{
                    .code = code,
                    .message = message,
                },
                .id = id,
            };
        }

        if (root.get("result")) |result_val| {
            var result_str = std.array_list.AlignedManaged(u8, null).init(allocator);
            defer result_str.deinit();

            try std.json.stringify(result_val, .{}, result_str.writer());

            return JsonRpcResponse{
                .result = try allocator.dupe(u8, result_str.items),
                .error_info = null,
                .id = id,
            };
        }

        return error.InvalidResponse;
    }

    pub fn deinit(self: JsonRpcResponse, allocator: Allocator) void {
        if (self.result) |result| {
            allocator.free(result);
        }
        if (self.error_info) |error_info| {
            error_info.deinit(allocator);
        }
    }
};
