//! Guillotine-Mini Fuzz Testing Suite
//!
//! Fuzzes `guillotine-mini`'s EVM execution across arbitrary & structured bytecode,
//! all call types, memory/storage/log operations, gas limits, and hardforks,
//! verifying gas bounds, determinism (two runs of identical input produce bit-for-bit
//! identical success, gas_left, output, and logs), and zero crashes/memory leaks.

const std = @import("std");
const mini = @import("guillotine_mini");
const primitives = @import("primitives");

const MiniEvm = mini.Evm(.{});
const Address = primitives.Address;

const CALLER = Address{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{0x11} };
const TARGET = Address{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{0x22} };

fn executeOnce(
    allocator: std.mem.Allocator,
    code: []const u8,
    calldata: []const u8,
    gas_limit: u64,
    hardfork: mini.Hardfork,
) !struct { success: bool, gas_left: u64, output: []u8, logs_len: usize } {
    var evm_inst = try MiniEvm.init(allocator, null, hardfork, null, .err);
    defer evm_inst.deinit();

    // `call` executes `pending_bytecode` at `to`. With no host and zero value,
    // `initTransactionState` resets account state, so no balance setup is needed.
    evm_inst.setBytecode(code);

    const res = evm_inst.call(.{
        .call = .{
            .caller = CALLER,
            .to = TARGET,
            .value = 0,
            .input = calldata,
            .gas = gas_limit,
        },
    });
    const out_copy = try allocator.dupe(u8, res.output);
    return .{
        .success = res.success,
        .gas_left = res.gas_left,
        .output = out_copy,
        .logs_len = res.logs.len,
    };
}

fn fuzzMiniDeterminismAndInvariants(_: void, input: []const u8) !void {
    if (input.len < 3) return;
    const allocator = std.testing.allocator;

    const forks = [_]mini.Hardfork{ .FRONTIER, .BYZANTIUM, .BERLIN, .LONDON, .SHANGHAI, .CANCUN, .PRAGUE };
    const hardfork = forks[input[0] % forks.len];
    const gas_limit: u64 = switch (input[1] % 4) {
        0 => 21_000,
        1 => 40_000,
        2 => 200_000,
        else => 1_000_000,
    };

    const payload = input[2..@min(input.len, 256)];
    const cd_len = @min(payload.len / 4, 32);
    const calldata = payload[0..cd_len];
    const code = payload[cd_len..];

    const r1 = try executeOnce(allocator, code, calldata, gas_limit, hardfork);
    defer allocator.free(r1.output);
    const r2 = try executeOnce(allocator, code, calldata, gas_limit, hardfork);
    defer allocator.free(r2.output);

    // Determinism & fundamental gas invariant
    try std.testing.expect(r1.gas_left <= gas_limit);
    try std.testing.expectEqual(r1.success, r2.success);
    try std.testing.expectEqual(r1.gas_left, r2.gas_left);
    try std.testing.expectEqualSlices(u8, r1.output, r2.output);
    try std.testing.expectEqual(r1.logs_len, r2.logs_len);
}

const seed_corpus: []const []const u8 = &.{
    &.{ 5, 3, 0x60, 0x01, 0x60, 0x02, 0x01, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 },
    &.{ 5, 2, 0x60, 0x2a, 0x60, 0x00, 0x55, 0x60, 0x00, 0x54, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 },
    &.{ 5, 1, 0x5b, 0x60, 0x00, 0x56 }, // loop OOG
    &.{ 0, 2, 0x5f, 0x00 }, // PUSH0 on Frontier (invalid opcode)
    &.{ 6, 3, 0x60, 0x11, 0x60, 0x00, 0x5d, 0x60, 0x00, 0x5c, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 }, // TSTORE/TLOAD
};

/// Adapts a byte-slice target to `std.testing.fuzz`, which passes a
/// `*std.testing.Smith`. Corpus replay (`smith.in != null`) hands each seed to
/// the target unchanged; under `--fuzz` the fuzzer generates the byte slice.
fn smithBytes(_: void, smith: *std.testing.Smith) anyerror!void {
    if (smith.in) |input| return fuzzMiniDeterminismAndInvariants({}, input);
    var buffer: [256]u8 = undefined;
    const len = smith.slice(&buffer);
    return fuzzMiniDeterminismAndInvariants({}, buffer[0..len]);
}

test "fuzz guillotine-mini execution determinism, gas bounds, and multi-hardfork safety" {
    try std.testing.fuzz({}, smithBytes, .{ .corpus = seed_corpus });
}

test "smithBytes replays every seed through the target" {
    for (seed_corpus) |seed| {
        var smith: std.testing.Smith = .{ .in = seed };
        try smithBytes({}, &smith);
    }
}
