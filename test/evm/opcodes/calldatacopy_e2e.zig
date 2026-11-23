//! CALLDATACOPY must copy the caller-supplied input, both for a top-level call and
//! for a nested CALL whose input slice lives in the caller's memory.
const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const gas_limit: u64 = 1_000_000;
const outer = primitives.Address{ .bytes = [_]u8{0x42} ++ @as([19]u8, @splat(0)) };
const inner = primitives.Address{ .bytes = [_]u8{0x43} ++ @as([19]u8, @splat(0)) };
const caller = primitives.Address{ .bytes = [_]u8{0x10} ++ @as([19]u8, @splat(0)) };

// CALLDATASIZE; PUSH0; PUSH0; CALLDATACOPY; CALLDATASIZE; PUSH0; RETURN
const echo = [_]u8{ 0x36, 0x5f, 0x5f, 0x37, 0x36, 0x5f, 0xf3 };

// Expand memory to 0x1000 first so the copy lands in a grown buffer, then echo.
// PUSH1 1; PUSH2 0x1000; MSTORE; CALLDATASIZE; PUSH0; PUSH0; CALLDATACOPY; CALLDATASIZE; PUSH0; RETURN
const grow_then_echo = [_]u8{ 0x60, 0x01, 0x61, 0x10, 0x00, 0x52, 0x36, 0x5f, 0x5f, 0x37, 0x36, 0x5f, 0xf3 };

fn deploy(db: *evm.Database, address: primitives.Address, code: []const u8) !void {
    const code_hash = try db.set_code(code);
    try db.set_account(address.bytes, evm.Account{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = @as([32]u8, @splat(0)),
    });
}

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
const PragueEvm = evm.Evm(.{ .eips = evm.Eips{ .hardfork = .PRAGUE } });

test "CALLDATACOPY: top-level call echoes its input" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();
    try deploy(&db, outer, &echo);
    var vm = try PragueEvm.init(allocator, &db, block_info, context, 0, caller);
    defer vm.deinit();
    const input = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x03, 0x04, 0x05 };
    var result = vm.call(.{ .call = .{ .caller = caller, .to = outer, .value = 0, .input = &input, .gas = gas_limit } });
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
    try std.testing.expectEqualSlices(u8, &input, result.output);
}

test "CALLDATACOPY: top-level call after memory growth echoes its input" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();
    try deploy(&db, outer, &grow_then_echo);
    var vm = try PragueEvm.init(allocator, &db, block_info, context, 0, caller);
    defer vm.deinit();
    const input = @as([68]u8, @splat(0xab));
    var result = vm.call(.{ .call = .{ .caller = caller, .to = outer, .value = 0, .input = &input, .gas = gas_limit } });
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
    try std.testing.expectEqualSlices(u8, &input, result.output);
}

test "CALLDATACOPY: nested CALL input reaches the callee" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();
    try deploy(&db, inner, &grow_then_echo);
    // Outer: copy own calldata to memory 0, CALL inner with it, return inner's output.
    // CALLDATASIZE PUSH0 PUSH0 CALLDATACOPY
    // PUSH1 0x40 (retSize) PUSH1 0x80 (retOffset) CALLDATASIZE (argsSize) PUSH0 (argsOffset)
    // PUSH0 (value) PUSH20 inner GAS CALL POP
    // RETURNDATASIZE PUSH1 0x80 RETURN
    const outer_code = [_]u8{ 0x36, 0x5f, 0x5f, 0x37, 0x60, 0x40, 0x60, 0x80, 0x36, 0x5f, 0x5f, 0x73 } ++ inner.bytes ++ [_]u8{ 0x5a, 0xf1, 0x50, 0x3d, 0x60, 0x80, 0xf3 };
    try deploy(&db, outer, &outer_code);
    var vm = try PragueEvm.init(allocator, &db, block_info, context, 0, caller);
    defer vm.deinit();
    const input = [_]u8{ 0x11, 0x22, 0x33, 0x44 } ++ @as([32]u8, @splat(0x55));
    var result = vm.call(.{ .call = .{ .caller = caller, .to = outer, .value = 0, .input = &input, .gas = gas_limit } });
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
    try std.testing.expectEqualSlices(u8, &input, result.output);
}

test "CALLDATACOPY: source offset beyond calldata and beyond usize copies zeros" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();
    // PUSH1 4 (len) PUSH32 2^256-1 (offset) PUSH0 (dest) CALLDATACOPY PUSH1 4 PUSH0 RETURN
    const code = [_]u8{ 0x60, 0x04, 0x7f } ++ @as([32]u8, @splat(0xff)) ++ [_]u8{ 0x5f, 0x37, 0x60, 0x04, 0x5f, 0xf3 };
    try deploy(&db, outer, &code);
    var vm = try PragueEvm.init(allocator, &db, block_info, context, 0, caller);
    defer vm.deinit();
    const input = [_]u8{ 1, 2, 3, 4 };
    var result = vm.call(.{ .call = .{ .caller = caller, .to = outer, .value = 0, .input = &input, .gas = gas_limit } });
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, result.output);
}

test "CALLDATACOPY: zero length with huge offsets is a no-op" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();
    // PUSH0 (len) PUSH32 max (offset) PUSH32 max (dest) CALLDATACOPY STOP
    const code = [_]u8{ 0x5f, 0x7f } ++ @as([32]u8, @splat(0xff)) ++ [_]u8{0x7f} ++ @as([32]u8, @splat(0xff)) ++ [_]u8{ 0x37, 0x00 };
    try deploy(&db, outer, &code);
    var vm = try PragueEvm.init(allocator, &db, block_info, context, 0, caller);
    defer vm.deinit();
    var result = vm.call(.{ .call = .{ .caller = caller, .to = outer, .value = 0, .input = &.{}, .gas = gas_limit } });
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
    // 21000 intrinsic + PUSH0 + 2 PUSH32 + CALLDATACOPY static gas; no memory or copy gas.
    try std.testing.expectEqual(@as(u64, 21_000 + 2 + 3 + 3 + 3), gas_limit - result.gas_left);
}

test "CALLDATACOPY: memory grows in whole words (MSIZE after a 1-byte copy is 32)" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();
    // PUSH1 1 (len) PUSH0 (offset) PUSH0 (dest) CALLDATACOPY MSIZE PUSH0 MSTORE PUSH1 0x20 PUSH0 RETURN
    const code = [_]u8{ 0x60, 0x01, 0x5f, 0x5f, 0x37, 0x59, 0x5f, 0x52, 0x60, 0x20, 0x5f, 0xf3 };
    try deploy(&db, outer, &code);
    var vm = try PragueEvm.init(allocator, &db, block_info, context, 0, caller);
    defer vm.deinit();
    const input = [_]u8{0x99};
    var result = vm.call(.{ .call = .{ .caller = caller, .to = outer, .value = 0, .input = &input, .gas = gas_limit } });
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
    try std.testing.expectEqualSlices(u8, &(@as([31]u8, @splat(0)) ++ [_]u8{0x20}), result.output);
}

test "EXTCODECOPY: copies another account's code with address on top of the stack" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();
    try deploy(&db, inner, &echo);
    // PUSH1 7 (size) PUSH0 (offset) PUSH0 (dest) PUSH20 inner EXTCODECOPY PUSH1 7 PUSH0 RETURN
    const code = [_]u8{ 0x60, 0x07, 0x5f, 0x5f, 0x73 } ++ inner.bytes ++ [_]u8{ 0x3c, 0x60, 0x07, 0x5f, 0xf3 };
    try deploy(&db, outer, &code);
    var vm = try PragueEvm.init(allocator, &db, block_info, context, 0, caller);
    defer vm.deinit();
    var result = vm.call(.{ .call = .{ .caller = caller, .to = outer, .value = 0, .input = &.{}, .gas = gas_limit } });
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
    try std.testing.expectEqualSlices(u8, &echo, result.output);
}

test "CALL: value-free call to a nonexistent account succeeds" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();
    const nobody = primitives.Address{ .bytes = [_]u8{0x77} ++ @as([19]u8, @splat(0)) };
    var vm = try PragueEvm.init(allocator, &db, block_info, context, 0, caller);
    defer vm.deinit();
    var result = vm.call(.{ .call = .{ .caller = caller, .to = nobody, .value = 0, .input = &.{}, .gas = gas_limit } });
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(gas_limit - 21_000, result.gas_left);
}
