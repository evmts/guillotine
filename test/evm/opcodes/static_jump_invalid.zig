//! A PUSH+JUMP(I) whose target is not a JUMPDEST is legal bytecode. Preprocessing
//! must accept it; the jump fails with all gas consumed only when actually taken.
//! Every case is checked against the sequential reference interpreter (MinimalEvm).
const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const gas_limit: u64 = 100_000;
const contract = primitives.Address{ .bytes = [_]u8{0x42} ++ @as([19]u8, @splat(0)) };
const caller = primitives.Address{ .bytes = [_]u8{0x10} ++ @as([19]u8, @splat(0)) };

const Outcome = struct { success: bool, gas_used: u64 };

// Both vm.call and MinimalEvm.execute charge the 21000 transaction intrinsic gas.
const intrinsic: u64 = 21_000;

fn guillotineRun(code: []const u8) !Outcome {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();
    const code_hash = try db.set_code(code);
    try db.set_account(contract.bytes, evm.Account{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
    });
    const block_info = evm.BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = @as([32]u8, @splat(0)),
    };
    const context = evm.TransactionContext{
        .gas_limit = gas_limit,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    const CancunEvm = evm.Evm(.{ .eips = evm.Eips{ .hardfork = .CANCUN } });
    var vm = try CancunEvm.init(allocator, &db, block_info, context, 0, caller);
    defer vm.deinit();
    var result = vm.call(.{ .call = .{
        .caller = caller,
        .to = contract,
        .value = 0,
        .input = &.{},
        .gas = gas_limit,
    } });
    defer result.deinit(allocator);
    return .{ .success = result.success, .gas_used = gas_limit - result.gas_left };
}

fn minimalRun(code: []const u8) !Outcome {
    const allocator = std.testing.allocator;
    const minimal = try evm.MinimalEvm.initPtr(allocator);
    defer minimal.deinitPtr(allocator);
    minimal.setHardfork(.CANCUN);
    try minimal.setCode(contract, code);
    const result = try minimal.execute(code, @intCast(gas_limit), caller, contract, 0, &.{});
    return .{ .success = result.success, .gas_used = gas_limit - result.gas_left };
}

test "static jump: unreachable PUSH1+JUMP to a non-JUMPDEST does not abort execution" {
    // STOP; PUSH1 0x10; JUMP
    const code = [_]u8{ 0x00, 0x60, 0x10, 0x56 };
    const got = try guillotineRun(&code);
    try std.testing.expect(got.success);
    try std.testing.expectEqual(intrinsic, got.gas_used);
    try std.testing.expectEqual(try minimalRun(&code), got);
}

test "static jump: taken PUSH1+JUMP to a non-JUMPDEST fails and consumes all gas" {
    // PUSH1 0x03; JUMP; STOP (pc 3 is STOP, not JUMPDEST)
    const code = [_]u8{ 0x60, 0x03, 0x56, 0x00 };
    const got = try guillotineRun(&code);
    try std.testing.expect(!got.success);
    try std.testing.expectEqual(gas_limit, got.gas_used);
    try std.testing.expectEqual(try minimalRun(&code), got);
}

test "static jump: taken PUSH1+JUMP into push data fails" {
    // PUSH1 0x04; JUMP; PUSH1 0x5b; STOP (pc 4 is a 0x5b byte inside push data)
    const code = [_]u8{ 0x60, 0x04, 0x56, 0x60, 0x5b, 0x00 };
    const got = try guillotineRun(&code);
    try std.testing.expect(!got.success);
    try std.testing.expectEqual(gas_limit, got.gas_used);
    try std.testing.expectEqual(try minimalRun(&code), got);
}

test "static jump: PUSH1+JUMPI to a non-JUMPDEST falls through on a zero condition" {
    // PUSH1 0; PUSH1 0x20; JUMPI; PUSH1 1; POP; STOP
    const code = [_]u8{ 0x60, 0x00, 0x60, 0x20, 0x57, 0x60, 0x01, 0x50, 0x00 };
    const got = try guillotineRun(&code);
    try std.testing.expect(got.success);
    try std.testing.expectEqual(intrinsic + 3 + 3 + 10 + 3 + 2, got.gas_used);
    try std.testing.expectEqual(try minimalRun(&code), got);
}

test "static jump: PUSH1+JUMPI to a non-JUMPDEST fails on a nonzero condition" {
    // PUSH1 1; PUSH1 0x20; JUMPI; STOP
    const code = [_]u8{ 0x60, 0x01, 0x60, 0x20, 0x57, 0x00 };
    const got = try guillotineRun(&code);
    try std.testing.expect(!got.success);
    try std.testing.expectEqual(gas_limit, got.gas_used);
    try std.testing.expectEqual(try minimalRun(&code), got);
}

test "static jump: PUSH32 target beyond any pc falls through JUMPI on a zero condition" {
    // PUSH1 0; PUSH32 0xff..ff; JUMPI; STOP
    const code = [_]u8{ 0x60, 0x00, 0x7f } ++ @as([32]u8, @splat(0xff)) ++ [_]u8{ 0x57, 0x00 };
    const got = try guillotineRun(&code);
    try std.testing.expect(got.success);
    try std.testing.expectEqual(intrinsic + 3 + 3 + 10, got.gas_used);
    try std.testing.expectEqual(try minimalRun(&code), got);
}

test "static jump: unreachable PUSH32 JUMP beyond any pc does not abort execution" {
    // STOP; PUSH32 0xff..ff; JUMP
    const code = [_]u8{ 0x00, 0x7f } ++ @as([32]u8, @splat(0xff)) ++ [_]u8{0x56};
    const got = try guillotineRun(&code);
    try std.testing.expect(got.success);
    try std.testing.expectEqual(intrinsic, got.gas_used);
    try std.testing.expectEqual(try minimalRun(&code), got);
}

test "static jump: taken PUSH32 JUMP beyond any pc fails and consumes all gas" {
    const code = [_]u8{0x7f} ++ @as([32]u8, @splat(0xff)) ++ [_]u8{ 0x56, 0x00 };
    const got = try guillotineRun(&code);
    try std.testing.expect(!got.success);
    try std.testing.expectEqual(gas_limit, got.gas_used);
    try std.testing.expectEqual(try minimalRun(&code), got);
}

test "static jump: valid and invalid static jumps coexist" {
    // PUSH1 0x07; JUMP; PUSH1 0x30; JUMP; INVALID; JUMPDEST(7); STOP
    const code = [_]u8{ 0x60, 0x07, 0x56, 0x60, 0x30, 0x56, 0xfe, 0x5b, 0x00 };
    const got = try guillotineRun(&code);
    try std.testing.expect(got.success);
    try std.testing.expectEqual(intrinsic + 3 + 8 + 1, got.gas_used);
    try std.testing.expectEqual(try minimalRun(&code), got);
}
