const std = @import("std");
const Allocator = std.mem.Allocator;
const HttpTransport = @import("transport/http_simple.zig").HttpTransport;
const json_rpc = @import("transport/json_rpc.zig");
// Define transport errors locally since we removed the errors.zig file
const TransportError = error{
    NetworkError,
    Timeout,
    InvalidResponse,
    InvalidRequest,
    OutOfMemory,
    ConnectionFailed,
    TlsError,
    AuthenticationFailed,
};

pub const ProviderError = error{
    TransportError,
    JsonRpcError,
    InvalidResponse,
    NetworkError,
    Timeout,
    InvalidRequest,
    OutOfMemory,
} || Allocator.Error;

pub const Provider = struct {
    allocator: Allocator,
    transport: HttpTransport,

    pub fn init(allocator: Allocator, url: []const u8) ProviderError!Provider {
        const transport = HttpTransport.init(allocator, url) catch |err| switch (err) {
            error.OutOfMemory => return ProviderError.OutOfMemory,
        };

        return Provider{
            .allocator = allocator,
            .transport = transport,
        };
    }

    pub fn deinit(self: *Provider) void {
        self.transport.deinit();
    }

    pub fn request(self: *Provider, method: []const u8, params: []const u8) ProviderError!json_rpc.JsonRpcResponse {
        return self.transport.request(method, params) catch |err| switch (err) {
            TransportError.NetworkError => ProviderError.NetworkError,
            TransportError.Timeout => ProviderError.Timeout,
            TransportError.InvalidResponse => ProviderError.InvalidResponse,
            TransportError.InvalidRequest => ProviderError.InvalidRequest,
            TransportError.OutOfMemory => ProviderError.OutOfMemory,
            else => ProviderError.TransportError,
        };
    }

    // Convenience methods for common RPC calls
    pub fn get_block_by_number(self: *Provider, block_number: u64, include_txs: bool) ProviderError!json_rpc.JsonRpcResponse {
        const params = std.fmt.allocPrint(self.allocator,
            \\["0x{x}",{s}]
        , .{ block_number, if (include_txs) "true" else "false" }) catch |err| switch (err) {
            error.OutOfMemory => return ProviderError.OutOfMemory,
        };
        defer self.allocator.free(params);

        return self.request("eth_getBlockByNumber", params);
    }

    pub fn get_transaction_receipt(self: *Provider, tx_hash: []const u8) ProviderError!json_rpc.JsonRpcResponse {
        const params = std.fmt.allocPrint(self.allocator,
            \\["{s}"]
        , .{tx_hash}) catch |err| switch (err) {
            error.OutOfMemory => return ProviderError.OutOfMemory,
        };
        defer self.allocator.free(params);

        return self.request("eth_getTransactionReceipt", params);
    }

    pub fn get_chain_id(self: *Provider) ProviderError!json_rpc.JsonRpcResponse {
        return self.request("eth_chainId", "[]");
    }

    pub fn get_block_number(self: *Provider) ProviderError!json_rpc.JsonRpcResponse {
        return self.request("eth_blockNumber", "[]");
    }

    pub fn get_balance(self: *Provider, address: []const u8, block_tag: []const u8) ProviderError!json_rpc.JsonRpcResponse {
        const params = std.fmt.allocPrint(self.allocator,
            \\["{s}","{s}"]
        , .{ address, block_tag }) catch |err| switch (err) {
            error.OutOfMemory => return ProviderError.OutOfMemory,
        };
        defer self.allocator.free(params);

        return self.request("eth_getBalance", params);
    }

    pub fn get_transaction_count(self: *Provider, address: []const u8, block_tag: []const u8) ProviderError!json_rpc.JsonRpcResponse {
        const params = std.fmt.allocPrint(self.allocator,
            \\["{s}","{s}"]
        , .{ address, block_tag }) catch |err| switch (err) {
            error.OutOfMemory => return ProviderError.OutOfMemory,
        };
        defer self.allocator.free(params);

        return self.request("eth_getTransactionCount", params);
    }

    pub fn get_code(self: *Provider, address: []const u8, block_tag: []const u8) ProviderError!json_rpc.JsonRpcResponse {
        const params = std.fmt.allocPrint(self.allocator,
            \\["{s}","{s}"]
        , .{ address, block_tag }) catch |err| switch (err) {
            error.OutOfMemory => return ProviderError.OutOfMemory,
        };
        defer self.allocator.free(params);

        return self.request("eth_getCode", params);
    }

    pub fn get_storage_at(self: *Provider, address: []const u8, slot: []const u8, block_tag: []const u8) ProviderError!json_rpc.JsonRpcResponse {
        const params = std.fmt.allocPrint(self.allocator,
            \\["{s}","{s}","{s}"]
        , .{ address, slot, block_tag }) catch |err| switch (err) {
            error.OutOfMemory => return ProviderError.OutOfMemory,
        };
        defer self.allocator.free(params);

        return self.request("eth_getStorageAt", params);
    }

    pub fn call(self: *Provider, call_params: []const u8, block_tag: []const u8) ProviderError!json_rpc.JsonRpcResponse {
        const params = std.fmt.allocPrint(self.allocator,
            \\[{s},"{s}"]
        , .{ call_params, block_tag }) catch |err| switch (err) {
            error.OutOfMemory => return ProviderError.OutOfMemory,
        };
        defer self.allocator.free(params);

        return self.request("eth_call", params);
    }
};
