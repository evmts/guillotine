const std = @import("std");
const Address = @import("primitives").Address;
const validation = @import("validation.zig");

pub const ProviderError = error{
    JsonRpcError,
    NoResult,
    InvalidResponse,
    InvalidAddress,
    InvalidBlockNumber,
    InvalidBlockTag,
    InvalidHexString,
    InvalidU256,
    InvalidTransactionHash,
    ValidationError,
} || std.mem.Allocator.Error || std.fmt.ParseIntError || validation.ValidationError;

pub const Provider = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    client: std.http.Client,

    /// Initialize a new JSON-RPC provider.
    ///
    /// Creates a provider that connects to an Ethereum JSON-RPC endpoint
    /// to fetch blockchain data including blocks, accounts, and transactions.
    ///
    /// Parameters:
    ///   allocator: Memory allocator for HTTP client and data
    ///   url: JSON-RPC endpoint URL (e.g., "https://mainnet.infura.io/v3/...")
    ///
    /// Returns:
    ///   Initialized provider ready for JSON-RPC requests
    ///
    /// Errors:
    ///   InvalidResponse: URL is empty
    ///   OutOfMemory: Failed to allocate memory
    pub fn init(allocator: std.mem.Allocator, url: []const u8) !Provider {
        if (url.len == 0) return error.InvalidResponse;
        const urlCopy = try allocator.dupe(u8, url);
        return Provider{
            .allocator = allocator,
            .url = urlCopy,
            .client = std.http.Client{ .allocator = allocator },
        };
    }

    /// Clean up provider resources.
    ///
    /// Closes the HTTP client and frees the URL string.
    /// The provider must not be used after calling deinit.
    pub fn deinit(self: *Provider) void {
        self.client.deinit();
        self.allocator.free(self.url);
    }

    pub fn request(self: *Provider, method: []const u8, params: ?std.json.Value) ProviderError![]const u8 {
        if (method.len == 0) return ProviderError.InvalidResponse;

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

        try req.headers.append("Content-Type", "application/json");
        try req.headers.append("Accept", "application/json");

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

    /// Get the current block number from the network.
    ///
    /// Returns:
    ///   Current block number
    ///
    /// Errors:
    ///   JsonRpcError: RPC request failed
    ///   InvalidResponse: Malformed response
    ///   ValidationError: Block number out of valid range
    pub fn getBlockNumber(self: *Provider) ProviderError!u64 {
        const result = try self.request("eth_blockNumber", null);
        defer self.allocator.free(result);

        const block_num = try validation.parseHexU64(result);
        try validation.validateBlockNumber(block_num);
        return block_num;
    }

    /// Get account balance at the latest block.
    ///
    /// Convenience wrapper for getBalanceAtBlock(addr, "latest").
    ///
    /// Parameters:
    ///   addr: Address to query
    ///
    /// Returns:
    ///   Account balance in wei
    pub fn getBalance(self: *Provider, addr: Address) ProviderError!u256 {
        return self.getBalanceAtBlock(addr, "latest");
    }

    /// Get account balance at a specific block.
    ///
    /// Parameters:
    ///   addr: Address to query
    ///   block_tag: Block identifier ("latest", "earliest", "pending", or hex number)
    ///
    /// Returns:
    ///   Account balance in wei at the specified block
    ///
    /// Errors:
    ///   InvalidBlockTag: Invalid block tag format
    ///   JsonRpcError: RPC request failed
    ///   InvalidU256: Balance value out of range
    pub fn getBalanceAtBlock(self: *Provider, addr: Address, block_tag: []const u8) ProviderError!u256 {
        try validation.validateBlockTag(block_tag);

        var params = std.json.Array.init(self.allocator);
        defer params.deinit();

        const addrHex = try std.fmt.allocPrint(self.allocator, "0x{s}", .{std.fmt.fmtSliceHexLower(&addr.bytes)});
        defer self.allocator.free(addrHex);

        try params.append(std.json.Value{ .string = addrHex });
        try params.append(std.json.Value{ .string = block_tag });

        const result = try self.request("eth_getBalance", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        return try validation.parseHexU256(result);
    }

    pub fn getTransactionCount(self: *Provider, addr: Address) ProviderError!u64 {
        return self.getTransactionCountAtBlock(addr, "latest");
    }

    pub fn getTransactionCountAtBlock(self: *Provider, addr: Address, block_tag: []const u8) ProviderError!u64 {
        try validation.validateBlockTag(block_tag);

        var params = std.json.Array.init(self.allocator);
        defer params.deinit();

        const addrHex = try std.fmt.allocPrint(self.allocator, "0x{s}", .{std.fmt.fmtSliceHexLower(&addr.bytes)});
        defer self.allocator.free(addrHex);

        try params.append(std.json.Value{ .string = addrHex });
        try params.append(std.json.Value{ .string = block_tag });

        const result = try self.request("eth_getTransactionCount", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        return try validation.parseHexU64(result);
    }

    pub fn getBlockByNumber(self: *Provider, blockNumber: u64, fullTxs: bool) ProviderError!Block {
        try validation.validateBlockNumber(blockNumber);

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

        const block_num = try validation.parseHexU64(parsed.value.number);
        const timestamp = try validation.parseHexU64(parsed.value.timestamp);

        return Block{
            .hash = try self.allocator.dupe(u8, parsed.value.hash),
            .number = block_num,
            .timestamp = timestamp,
            .allocator = self.allocator,
        };
    }

    pub fn getBlockByTag(self: *Provider, block_tag: []const u8, fullTxs: bool) ProviderError!Block {
        try validation.validateBlockTag(block_tag);

        var params = std.json.Array.init(self.allocator);
        defer params.deinit();

        try params.append(std.json.Value{ .string = block_tag });
        try params.append(std.json.Value{ .bool = fullTxs });

        const result = try self.request("eth_getBlockByNumber", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        const parsed = try std.json.parseFromSlice(BlockJson, self.allocator, result, .{});
        defer parsed.deinit();

        const block_num = try validation.parseHexU64(parsed.value.number);
        const timestamp = try validation.parseHexU64(parsed.value.timestamp);

        return Block{
            .hash = try self.allocator.dupe(u8, parsed.value.hash),
            .number = block_num,
            .timestamp = timestamp,
            .allocator = self.allocator,
        };
    }

    pub fn getTransactionReceipt(self: *Provider, tx_hash: []const u8) ProviderError![]const u8 {
        try validation.validateTransactionHash(tx_hash);

        var params = std.json.Array.init(self.allocator);
        defer params.deinit();

        try params.append(std.json.Value{ .string = tx_hash });

        return self.request("eth_getTransactionReceipt", std.json.Value{ .array = params });
    }

    pub fn getCode(self: *Provider, addr: Address, blockTag: []const u8) ProviderError![]u8 {
        try validation.validateBlockTag(blockTag);

        var params = std.json.Array.init(self.allocator);
        defer params.deinit();

        const addrHex = try std.fmt.allocPrint(self.allocator, "0x{s}", .{std.fmt.fmtSliceHexLower(&addr.bytes)});
        defer self.allocator.free(addrHex);

        try params.append(std.json.Value{ .string = addrHex });
        try params.append(std.json.Value{ .string = blockTag });

        const result = try self.request("eth_getCode", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        const trimmed = std.mem.trim(u8, result, "\"");
        if (!std.mem.startsWith(u8, trimmed, "0x")) {
            return ProviderError.InvalidResponse;
        }

        const hex = trimmed[2..];
        if (hex.len == 0) {
            return try self.allocator.alloc(u8, 0);
        }

        if (hex.len % 2 != 0) {
            return ProviderError.InvalidResponse;
        }

        const code = try self.allocator.alloc(u8, hex.len / 2);
        errdefer self.allocator.free(code);

        for (0..code.len) |i| {
            const byte_hex = hex[i * 2 .. i * 2 + 2];
            code[i] = try std.fmt.parseInt(u8, byte_hex, 16);
        }

        return code;
    }

    pub fn getStorageAt(self: *Provider, addr: Address, slot: u256, blockTag: []const u8) ProviderError!u256 {
        try validation.validateBlockTag(blockTag);

        var params = std.json.Array.init(self.allocator);
        defer params.deinit();

        const addrHex = try std.fmt.allocPrint(self.allocator, "0x{s}", .{std.fmt.fmtSliceHexLower(&addr.bytes)});
        defer self.allocator.free(addrHex);

        const slotHex = try std.fmt.allocPrint(self.allocator, "0x{x}", .{slot});
        defer self.allocator.free(slotHex);

        try params.append(std.json.Value{ .string = addrHex });
        try params.append(std.json.Value{ .string = slotHex });
        try params.append(std.json.Value{ .string = blockTag });

        const result = try self.request("eth_getStorageAt", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        return try validation.parseHexU256(result);
    }

    pub fn call(self: *Provider, from: ?Address, to: Address, gas: ?u64, gasPrice: ?u256, value: ?u256, data: []const u8, blockTag: []const u8) ProviderError![]u8 {
        try validation.validateBlockTag(blockTag);

        var callObj = std.json.ObjectMap.init(self.allocator);
        defer callObj.deinit();

        if (from) |f| {
            const fromHex = try std.fmt.allocPrint(self.allocator, "0x{s}", .{std.fmt.fmtSliceHexLower(&f.bytes)});
            defer self.allocator.free(fromHex);
            try callObj.put("from", std.json.Value{ .string = fromHex });
        }

        const toHex = try std.fmt.allocPrint(self.allocator, "0x{s}", .{std.fmt.fmtSliceHexLower(&to.bytes)});
        defer self.allocator.free(toHex);
        try callObj.put("to", std.json.Value{ .string = toHex });

        if (gas) |g| {
            const gasHex = try std.fmt.allocPrint(self.allocator, "0x{x}", .{g});
            defer self.allocator.free(gasHex);
            try callObj.put("gas", std.json.Value{ .string = gasHex });
        }

        if (gasPrice) |gp| {
            const gasPriceHex = try std.fmt.allocPrint(self.allocator, "0x{x}", .{gp});
            defer self.allocator.free(gasPriceHex);
            try callObj.put("gasPrice", std.json.Value{ .string = gasPriceHex });
        }

        if (value) |v| {
            const valueHex = try std.fmt.allocPrint(self.allocator, "0x{x}", .{v});
            defer self.allocator.free(valueHex);
            try callObj.put("value", std.json.Value{ .string = valueHex });
        }

        if (data.len > 0) {
            const dataHex = try std.fmt.allocPrint(self.allocator, "0x{s}", .{std.fmt.fmtSliceHexLower(data)});
            defer self.allocator.free(dataHex);
            try callObj.put("data", std.json.Value{ .string = dataHex });
        }

        var params = std.json.Array.init(self.allocator);
        defer params.deinit();

        try params.append(std.json.Value{ .object = callObj });
        try params.append(std.json.Value{ .string = blockTag });

        const result = try self.request("eth_call", std.json.Value{ .array = params });
        defer self.allocator.free(result);

        const trimmed = std.mem.trim(u8, result, "\"");
        if (!std.mem.startsWith(u8, trimmed, "0x")) {
            return ProviderError.InvalidResponse;
        }

        const hex = trimmed[2..];
        if (hex.len == 0) {
            return try self.allocator.alloc(u8, 0);
        }

        if (hex.len % 2 != 0) {
            return ProviderError.InvalidResponse;
        }

        const returnData = try self.allocator.alloc(u8, hex.len / 2);
        errdefer self.allocator.free(returnData);

        for (0..returnData.len) |i| {
            const byte_hex = hex[i * 2 .. i * 2 + 2];
            returnData[i] = try std.fmt.parseInt(u8, byte_hex, 16);
        }

        return returnData;
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
