const std = @import("std");
const micro = @import("micro");
const primitives = @import("voltaire");
const eips_mod = @import("eips");
const Eips = eips_mod.Eips;

const N: usize = 512;

fn benchBlobGasPrice(_: std.mem.Allocator) !u64 {
    const eips = Eips{ .hardfork = .OSAKA };
    var acc: u64 = 0;
    for (0..N) |i| {
        acc +%= eips.blob_gas_price(@intCast(i * 131_072));
    }
    return acc;
}

fn benchCalldataTokens4KB(allocator: std.mem.Allocator) !u64 {
    const eips = Eips{ .hardfork = .OSAKA };
    const data = try allocator.alloc(u8, 4096);
    defer allocator.free(data);
    for (data, 0..) |*b, i| b.* = if ((i & 3) == 0) 0 else @truncate(i);
    var acc: u64 = 0;
    for (0..64) |_| {
        const tokens = eips.tokens_in_calldata(data);
        acc +%= eips.calldata_gas_cost(tokens, false, data.len);
        acc +%= eips.floor_gas_cost(tokens);
    }
    return acc;
}

fn benchEffectiveGasPrice(_: std.mem.Allocator) !u64 {
    const eips = Eips{ .hardfork = .OSAKA };
    var acc: u64 = 0;
    for (0..N) |i| {
        const r = eips.effective_gas_price(
            15_000_000_000 + @as(u256, i) * 1_000,
            50_000_000_000,
            2_000_000_000,
        );
        acc +%= @truncate(r.effective_gas_price +% r.miner_fee);
    }
    return acc;
}

fn benchEipFeatureQueries(_: std.mem.Allocator) !u64 {
    const eips = Eips{ .hardfork = .OSAKA };
    var acc: u64 = 0;
    for (0..N) |i| {
        const base: u64 = @intFromBool(eips.eip_1559_is_enabled()) +
            @intFromBool(eips.eip_1153_transient_storage_enabled()) +
            @intFromBool(eips.eip_4844_blob_transactions_enabled()) +
            @intFromBool(eips.eip_7702_eoa_code_enabled()) +
            @intFromBool(eips.eip_2537_bls_precompiles_enabled());
        acc +%= base + eips.eip_3529_gas_refund_cap(1_000_000, @intCast(i * 1000));
    }
    return acc;
}

pub fn main() void {
    micro.runSuite("eips", &.{
        .{ .name = "eips/blob-gas-price", .operations = N, .run = benchBlobGasPrice },
        .{ .name = "eips/calldata-eip7623-4KB", .operations = 64, .bytes = 64 * 4096, .run = benchCalldataTokens4KB },
        .{ .name = "eips/effective-gas-price", .operations = N, .run = benchEffectiveGasPrice },
        .{ .name = "eips/feature-queries", .operations = N, .run = benchEipFeatureQueries },
    });
}
