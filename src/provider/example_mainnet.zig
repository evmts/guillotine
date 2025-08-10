const std = @import("std");
const Provider = @import("provider.zig").Provider;
const Address = @import("primitives").Address;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize provider with mainnet RPC endpoint
    const rpcUrl = std.os.getenv("ETH_RPC_URL") orelse "https://eth.llamarpc.com";
    var provider = try Provider.init(allocator, rpcUrl);
    defer provider.deinit();

    // Get current block number
    const blockNumber = try provider.getBlockNumber();
    std.log.info("Current block number: {}", .{blockNumber});

    // Get ETH balance of Vitalik's address
    const vitalikAddress = try Address.fromString("0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045");
    const balance = try provider.getBalance(vitalikAddress);
    std.log.info("Vitalik's balance: {} wei", .{balance});

    // Get block by number
    const block = try provider.getBlockByNumber(blockNumber, false);
    defer block.deinit(allocator);
    std.log.info("Block hash: {s}", .{block.hash});
    std.log.info("Block timestamp: {}", .{block.timestamp});

    // Get transaction count (nonce)
    const nonce = try provider.getTransactionCount(vitalikAddress);
    std.log.info("Vitalik's nonce: {}", .{nonce});

    // Raw JSON-RPC request example
    const result = try provider.request("eth_chainId", null);
    defer allocator.free(result);
    std.log.info("Chain ID: {s}", .{result});
}
