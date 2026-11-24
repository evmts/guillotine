//! execution-specs `call`/`callcode`: when the sender cannot afford `value`, the
//! opcode pushes 0 and refunds the whole sub-call gas (forwarded gas plus the
//! 2300 stipend). Only the access and value-transfer costs stay spent.
const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const gas_limit: u64 = 100_000;
const intrinsic: u64 = 21_000;
const caller_addr = primitives.Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 19 };
const a_addr = primitives.Address{ .bytes = [_]u8{0xaa} ++ [_]u8{0} ** 19 };
const b_addr = primitives.Address{ .bytes = [_]u8{0xbb} ++ [_]u8{0} ** 19 };

fn executionGas(opcode: u8) !u64 {
    const allocator = std.testing.allocator;
    // PUSH0 x4 (ret/args), PUSH1 1 (value), PUSH20 B, PUSH2 50000, CALL/CALLCODE, PUSH1 0, SSTORE, STOP
    const code = [_]u8{ 0x5f, 0x5f, 0x5f, 0x5f, 0x60, 0x01, 0x73 } ++ b_addr.bytes ++ [_]u8{ 0x61, 0xc3, 0x50, opcode, 0x60, 0x00, 0x55, 0x00 };
    var db = evm.Database.init(allocator);
    defer db.deinit();
    const code_hash = try db.set_code(&code);
    try db.set_account(a_addr.bytes, evm.Account{ .balance = 0, .nonce = 0, .code_hash = code_hash, .storage_root = [_]u8{0} ** 32 });
    try db.set_account(b_addr.bytes, evm.Account{ .balance = 0, .nonce = 1, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 });
    try db.set_storage(a_addr.bytes, 0, 7);
    const block_info = evm.BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    const context = evm.TransactionContext{ .gas_limit = gas_limit, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 };
    const CancunEvm = evm.Evm(.{ .eips = evm.Eips{ .hardfork = .CANCUN } });
    var vm = try CancunEvm.init(allocator, &db, block_info, context, 0, caller_addr);
    defer vm.deinit();
    var result = vm.call(.{ .call = .{ .caller = caller_addr, .to = a_addr, .value = 0, .input = &.{}, .gas = gas_limit } });
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
    // The call failed and pushed 0, which SSTORE wrote over the 7.
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(a_addr.bytes, 0));
    // Refund counter: 7 -> 0 earns 4800, capped at gas_used / 5.
    return gas_limit - result.gas_left - intrinsic;
}

// Pushes: 4 * PUSH0 (2) + PUSH1 + PUSH20 + PUSH2 + PUSH1 (3) = 20.
// CALL/CALLCODE: cold B 2600 + value 9000 - stipend 2300 refunded = 9300.
// SSTORE 7 -> 0, cold slot: 2100 + 2900 = 5000. Total 14320.
// Refund: min(4800, (21000 + 14320) / 5 = 7064) = 4800 -> 9520 execution gas net.
const expected: u64 = 20 + 9300 + 5000 - 4800;

test "CALL: insufficient balance refunds forwarded gas and stipend" {
    try std.testing.expectEqual(expected, try executionGas(0xf1));
}

test "CALLCODE: insufficient balance refunds forwarded gas and stipend" {
    try std.testing.expectEqual(expected, try executionGas(0xf2));
}
