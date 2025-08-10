const std = @import("std");
const Address = @import("primitives").Address;

pub const Provider = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, url: []const u8) !Provider {
        const urlCopy = try allocator.dupe(u8, url);
        return Provider{
            .allocator = allocator,
            .url = urlCopy,
            .client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Provider) void {
        self.client.deinit();
        self.allocator.free(self.url);
    }

    pub fn request(self: *Provider, method: []const u8, params: ?std.json.Value) ![]const u8 {
        const payload = JsonRpcRequest{
            .jsonrpc = "2.0",
            .method = method,
            .params = params,
            .id = 1,
        };

        const body = try std.json.stringifyAlloc(self.allocator, payload, .{});
        defer self.allocator.free(body);

        var headers = std.http.Client.Request.Headers{};
        const uri = try std.Uri.parse(self.url);

        var req = try self.client.open(.POST, uri, &headers);
        defer req.deinit();

        req.headers.append("Content-Type", "application/json") catch {};
        req.headers.append("Accept", "application/json") catch {};

        try req.send(body);
        try req.finish();
        try req.wait();

        const responseBody = try req.reader().readAllAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(responseBody);

        const parsed = try std.json.parseFromSlice(JsonRpcResponse, self.allocator, responseBody, .{});
        defer parsed.deinit();

        if (parsed.value.@"error") |err| {
            std.log.err("JSON-RPC error: {s}", .{err.message});
            return error.JsonRpcError;
        }

        if (parsed.value.result) |result| {
            return try self.allocator.dupe(u8, result.raw);
        }

        return error.NoResult;
    }

    pub fn getBlockNumber(self: *Provider) !u64 {
        const result = try self.request("eth_blockNumber", null);
        defer self.allocator.free(result);

        // Remove quotes and 0x prefix
        const trimmed = std.mem.trim(u8, result, "\"");
        const hex = if (std.mem.startsWith(u8, trimmed, "0x")) trimmed[2..] else trimmed;

        return try std.fmt.parseInt(u64, hex, 16);
    }

    pub fn getBalance(self: *Provider, addr: Address) !primitives.u256 {
        var params = std.json.Array.init(self.allocator);
        defer params.deinit();

        const addrHex = try std.fmt.allocPrint(self.allocator, "0x{s}", .{std.fmt.fmtSliceHexLower(&addr.bytes)});
        defer self.allocator.free(addrHex);

        try params.append(std.json.Value{ .string = addrHex });
        try params.append(std.json.Value{ .string = "latest" });

        const result = try self.request("eth_getBalance", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        const trimmed = std.mem.trim(u8, result, "\"");
        const hex = if (std.mem.startsWith(u8, trimmed, "0x")) trimmed[2..] else trimmed;

        return try std.fmt.parseInt(primitives.u256, hex, 16);
    }

    pub fn getTransactionCount(self: *Provider, addr: Address) !u64 {
        var params = std.json.Array.init(self.allocator);
        defer params.deinit();

        const addrHex = try std.fmt.allocPrint(self.allocator, "0x{s}", .{std.fmt.fmtSliceHexLower(&addr.bytes)});
        defer self.allocator.free(addrHex);

        try params.append(std.json.Value{ .string = addrHex });
        try params.append(std.json.Value{ .string = "latest" });

        const result = try self.request("eth_getTransactionCount", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        const trimmed = std.mem.trim(u8, result, "\"");
        const hex = if (std.mem.startsWith(u8, trimmed, "0x")) trimmed[2..] else trimmed;

        return try std.fmt.parseInt(u64, hex, 16);
    }

    pub fn getBlockByNumber(self: *Provider, blockNumber: u64, fullTxs: bool) !Block {
        var params = std.json.Array.init(self.allocator);
        defer params.deinit();

        const blockHex = try std.fmt.allocPrint(self.allocator, "0x{x}", .{blockNumber});
        defer self.allocator.free(blockHex);

        try params.append(std.json.Value{ .string = blockHex });
        try params.append(std.json.Value{ .bool = fullTxs });

        const result = try self.request("eth_getBlockByNumber", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        const parsed = try std.json.parseFromSlice(BlockJson, self.allocator, result, .{});
        defer parsed.deinit();

        return Block{
            .hash = try self.allocator.dupe(u8, parsed.value.hash),
            .number = try std.fmt.parseInt(u64, parsed.value.number[2..], 16),
            .timestamp = try std.fmt.parseInt(u64, parsed.value.timestamp[2..], 16),
            .allocator = self.allocator,
        };
    }
};

const JsonRpcRequest = struct {
    jsonrpc: []const u8,
    method: []const u8,
    params: ?std.json.Value,
    id: u32,
};

const JsonRpcResponse = struct {
    jsonrpc: []const u8,
    result: ?std.json.RawValue = null,
    @"error": ?JsonRpcError = null,
    id: u32,
};

const JsonRpcError = struct {
    code: i32,
    message: []const u8,
};

const BlockJson = struct {
    hash: []const u8,
    number: []const u8,
    timestamp: []const u8,
};

pub const Block = struct {
    hash: []const u8,
    number: u64,
    timestamp: u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *const Block, allocator: std.mem.Allocator) void {
        allocator.free(self.hash);
    }
};

const primitives = @import("primitives");
