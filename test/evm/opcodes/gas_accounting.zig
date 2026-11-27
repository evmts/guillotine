//! Exact gas accounting regressions for the dispatch-based Frame.
//!
//! Each case runs the same bytecode through `Evm.call` and through the
//! sequential reference interpreter (`MinimalEvm`) and checks that both spend
//! exactly the Yellow Paper amount of execution gas. The cases pin three bugs:
//! - EXP and KECCAK256 charged their static base gas twice (block gas plus handler).
//! - KECCAK256 skipped memory-expansion gas.
//! - Basic-block gas omitted or mispriced JUMP, JUMPI, PC and block terminators,
//!   and never charged code that follows a non-taken JUMPI.
const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const gas_limit: u64 = 1_000_000;
const intrinsic: u64 = 21_000;

const contract = primitives.Address{ .bytes = [_]u8{0x42} ++ @as([19]u8, @splat(0)) };
const caller = primitives.Address{ .bytes = [_]u8{0x10} ++ @as([19]u8, @splat(0)) };

fn guillotineExecutionGas(code: []const u8) !u64 {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();
    const code_hash = try db.set_code(code);
    try db.set_account(contract.bytes, evm.Account{
        .balance = 0,
        .nonce = 0,
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
        .allow_gas_price_below_base_fee = true,
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
    try std.testing.expect(result.success);
    return gas_limit - result.gas_left - intrinsic;
}

fn minimalExecutionGas(code: []const u8) !u64 {
    const allocator = std.testing.allocator;
    const minimal = try evm.MinimalEvm.initPtr(allocator);
    defer minimal.deinitPtr(allocator);
    minimal.setHardfork(.CANCUN);
    try minimal.setCode(contract, code);
    const result = try minimal.execute(code, @intCast(gas_limit), caller, contract, 0, &.{});
    try std.testing.expect(result.success);
    return gas_limit - result.gas_left - intrinsic;
}

fn expectExecutionGas(code: []const u8, expected: u64) !void {
    try std.testing.expectEqual(expected, try minimalExecutionGas(code));
    try std.testing.expectEqual(expected, try guillotineExecutionGas(code));
}

test "gas: EXP charges 10 base plus 50 per exponent byte exactly once" {
    // PUSH1 2; PUSH1 2; EXP; STOP = 3 + 3 + (10 + 50) + 0
    try expectExecutionGas(&.{ 0x60, 0x02, 0x60, 0x02, 0x0a, 0x00 }, 66);
}

test "gas: EXP with a two-byte exponent" {
    // PUSH2 0x0100; PUSH1 2; EXP; STOP = 3 + 3 + (10 + 2 * 50)
    try expectExecutionGas(&.{ 0x61, 0x01, 0x00, 0x60, 0x02, 0x0a, 0x00 }, 116);
}

test "gas: EXP with a zero exponent charges only the base" {
    // PUSH0; PUSH1 7; EXP; STOP = 2 + 3 + 10
    try expectExecutionGas(&.{ 0x5f, 0x60, 0x07, 0x0a, 0x00 }, 15);
}

test "gas: KECCAK256 of zero bytes charges only the 30 gas base" {
    // PUSH1 0; PUSH1 0; KECCAK256; STOP = 3 + 3 + 30
    try expectExecutionGas(&.{ 0x60, 0x00, 0x60, 0x00, 0x20, 0x00 }, 36);
}

test "gas: KECCAK256 of one word charges base, word and memory expansion" {
    // PUSH1 32; PUSH1 0; KECCAK256; STOP = 3 + 3 + (30 + 6) + 3 memory
    try expectExecutionGas(&.{ 0x60, 0x20, 0x60, 0x00, 0x20, 0x00 }, 45);
}

test "gas: KECCAK256 over already-expanded memory charges no expansion" {
    // PUSH1 1; PUSH1 0; MSTORE (3+3+3+3 mem); PUSH1 33; PUSH1 0; KECCAK256 (30 + 2*6 + 3 mem); STOP
    try expectExecutionGas(&.{ 0x60, 0x01, 0x60, 0x00, 0x52, 0x60, 0x21, 0x60, 0x00, 0x20, 0x00 }, 63);
}

test "gas: ADD baseline" {
    try expectExecutionGas(&.{ 0x60, 0x02, 0x60, 0x02, 0x01, 0x00 }, 9);
}

test "gas: EXP after JUMP into a JUMPDEST block" {
    // PUSH1 3; JUMP; JUMPDEST; PUSH1 2; PUSH1 2; EXP; STOP = 3 + 8 + 1 + 3 + 3 + 60
    try expectExecutionGas(&.{ 0x60, 0x03, 0x56, 0x5b, 0x60, 0x02, 0x60, 0x02, 0x0a, 0x00 }, 78);
}

test "gas: KECCAK256 after JUMP into a JUMPDEST block" {
    // PUSH1 3; JUMP; JUMPDEST; PUSH1 0; PUSH1 0; KECCAK256; STOP = 3 + 8 + 1 + 3 + 3 + 30
    try expectExecutionGas(&.{ 0x60, 0x03, 0x56, 0x5b, 0x60, 0x00, 0x60, 0x00, 0x20, 0x00 }, 48);
}

test "gas: JUMPDEST block ending in JUMP charges the JUMP" {
    // PUSH1 3; JUMP; JUMPDEST; PUSH1 8; JUMP; INVALID; JUMPDEST; STOP = 3 + 8 + 1 + 3 + 8 + 1
    try expectExecutionGas(&.{ 0x60, 0x03, 0x56, 0x5b, 0x60, 0x08, 0x56, 0xfe, 0x5b, 0x00 }, 24);
}

test "gas: dead code after JUMP in the first block is not charged" {
    // PUSH1 4; JUMP; ADD (dead); JUMPDEST; STOP = 3 + 8 + 1
    try expectExecutionGas(&.{ 0x60, 0x04, 0x56, 0x01, 0x5b, 0x00 }, 12);
}

test "gas: taken JUMPI charges 10" {
    // PUSH1 1; PUSH1 7; JUMPI; INVALID; INVALID; JUMPDEST; STOP = 3 + 3 + 10 + 1
    try expectExecutionGas(&.{ 0x60, 0x01, 0x60, 0x07, 0x57, 0xfe, 0xfe, 0x5b, 0x00 }, 17);
}

test "gas: code after a non-taken JUMPI in the first block is charged" {
    // PUSH1 0; PUSH1 11; JUMPI; PUSH1 1; PUSH1 2; ADD; STOP; JUMPDEST; STOP
    // = 3 + 3 + 10 + 3 + 3 + 3
    try expectExecutionGas(&.{ 0x60, 0x00, 0x60, 0x0b, 0x57, 0x60, 0x01, 0x60, 0x02, 0x01, 0x00, 0x5b, 0x00 }, 25);
}

test "gas: code after a non-taken JUMPI in a JUMPDEST block is charged" {
    // PUSH1 3; JUMP; JUMPDEST; PUSH1 0; PUSH1 15; JUMPI; PUSH1 1; PUSH1 2; ADD; STOP; JUMPDEST; STOP
    // = 3 + 8 + 1 + 3 + 3 + 10 + 3 + 3 + 3
    try expectExecutionGas(&.{ 0x60, 0x03, 0x56, 0x5b, 0x60, 0x00, 0x60, 0x0f, 0x57, 0x60, 0x01, 0x60, 0x02, 0x01, 0x00, 0x5b, 0x00 }, 37);
}

test "gas: taken JUMPI skips the fall-through block" {
    // PUSH1 1; PUSH1 11; JUMPI; PUSH1 1; PUSH1 2; ADD; STOP; JUMPDEST; STOP = 3 + 3 + 10 + 1
    try expectExecutionGas(&.{ 0x60, 0x01, 0x60, 0x0b, 0x57, 0x60, 0x01, 0x60, 0x02, 0x01, 0x00, 0x5b, 0x00 }, 17);
}

test "gas: PC costs 2" {
    // PC; PC; ADD; STOP = 2 + 2 + 3
    try expectExecutionGas(&.{ 0x58, 0x58, 0x01, 0x00 }, 7);
}

test "gas: countdown loop with a JUMPI back edge" {
    // PUSH1 3; JUMPDEST; PUSH1 1; SWAP1; SUB; DUP1; PUSH1 2; JUMPI; STOP
    // = 3 + 3 * (1 + 3 + 3 + 3 + 3 + 3 + 10)
    try expectExecutionGas(&.{ 0x60, 0x03, 0x5b, 0x60, 0x01, 0x90, 0x03, 0x80, 0x60, 0x02, 0x57, 0x00 }, 81);
}

test "gas: SELFDESTRUCT ending a JUMPDEST block charges its 5000 base" {
    // PUSH1 3; JUMP; JUMPDEST; ADDRESS; SELFDESTRUCT = 3 + 8 + 1 + 2 + 5000
    try expectExecutionGas(&.{ 0x60, 0x03, 0x56, 0x5b, 0x30, 0xff }, 5014);
}

test "gas: RETURN ending a JUMPDEST block charges memory expansion" {
    // PUSH1 3; JUMP; JUMPDEST; PUSH1 32; PUSH1 0; RETURN = 3 + 8 + 1 + 3 + 3 + 3 memory
    try expectExecutionGas(&.{ 0x60, 0x03, 0x56, 0x5b, 0x60, 0x20, 0x60, 0x00, 0xf3 }, 21);
}
