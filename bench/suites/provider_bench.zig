const std = @import("std");
const micro = @import("micro");
const provider = @import("provider");
const validation = provider.validation;

const N: usize = 512;

fn benchValidateAddress(_: std.mem.Allocator) !u64 {
    const addrs = [_][]const u8{
        "0x742d35Cc6634C0532925a3b844Bc454e4438f44e",
        "0xdAC17F958D2ee523a2206206994597C13D831ec7",
        "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
    };
    var ok: u64 = 0;
    for (0..N) |i| {
        try validation.validateAddress(addrs[i & 3]);
        ok += 1;
    }
    return ok;
}

fn benchValidateTxHash(_: std.mem.Allocator) !u64 {
    const hash = "0x88df016429689c079f3b2f6ad39fa052532c56795b733da78a91ebe6a713944b";
    var ok: u64 = 0;
    for (0..N) |_| {
        try validation.validateTransactionHash(hash);
        ok += 1;
    }
    return ok;
}

fn benchParseHexU64(_: std.mem.Allocator) !u64 {
    const vals = [_][]const u8{ "0x123456789abcdef", "0xdeadbeef", "0x16e3600", "0xffffffff" };
    var acc: u64 = 0;
    for (0..N) |i| {
        acc +%= try validation.parseHexU64(vals[i & 3]);
    }
    return acc;
}

fn benchParseHexU256(_: std.mem.Allocator) !u64 {
    const vals = [_][]const u8{
        "0x0000000000000000000000000000000000000000000000056bc75e2d63100000",
        "0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f",
    };
    var acc: u64 = 0;
    for (0..N) |i| {
        const v = try validation.parseHexU256(vals[i & 1]);
        acc +%= @truncate(v);
    }
    return acc;
}

fn benchJsonRpcSerialize(allocator: std.mem.Allocator) !u64 {
    var total_len: u64 = 0;
    for (0..128) |i| {
        const req = provider.transport.json_rpc.JsonRpcRequest{
            .id = @intCast(i + 1),
            .method = "eth_getBalance",
            .params = "[\"0x742d35Cc6634C0532925a3b844Bc454e4438f44e\",\"latest\"]",
        };
        const json = try req.to_json(allocator);
        defer allocator.free(json);
        var parsed = try provider.transport.json_rpc.JsonRpcRequest.from_json(allocator, json);
        defer parsed.deinit(allocator);
        total_len +%= json.len + parsed.method.len;
    }
    return total_len;
}

pub fn main() void {
    micro.runSuite("provider", &.{
        .{ .name = "provider/validate-address", .operations = N, .run = benchValidateAddress },
        .{ .name = "provider/validate-tx-hash", .operations = N, .run = benchValidateTxHash },
        .{ .name = "provider/parse-hex-u64", .operations = N, .run = benchParseHexU64 },
        .{ .name = "provider/parse-hex-u256", .operations = N, .run = benchParseHexU256 },
        .{ .name = "provider/json-rpc-serialize", .operations = 128, .run = benchJsonRpcSerialize },
    });
}
