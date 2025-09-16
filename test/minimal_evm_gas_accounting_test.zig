const std = @import("std");
const primitives = @import("primitives");
const evm_mod = @import("evm");

const MinimalEvm = evm_mod.tracer.MinimalEvm;
const precompiles = evm_mod.precompiles;
const Hardfork = evm_mod.Hardfork;

const GasConstants = primitives.GasConstants;
const Address = primitives.Address;

const CONTRACT_ADDRESS = Address.from_hex("0x00000000000000000000000000000000000000aa") catch unreachable;
const CALLER_ADDRESS = Address.from_hex("0x00000000000000000000000000000000000000bb") catch unreachable;
const TARGET_EXISTING = Address.from_hex("0x0000000000000000000000000000000000000055") catch unreachable;

// SSTORE: cold zero->non-zero followed by warm modification (dirty slot path)
test "minimal evm gas - sstore cold then warm" {
    var evm = try MinimalEvm.init(std.testing.allocator);
    defer evm.deinit();

    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE (slot 0 = 1)
        0x60, 0x02, // PUSH1 2
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE (slot 0 = 2, warm dirty)
        0x00,       // STOP
    };

    const exec_gas: u64 = 100_000;
    const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
    const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
    try std.testing.expect(result.success);

    const push_cost: u64 = 4 * GasConstants.GasFastestStep;
    const first_store_cost = GasConstants.ColdSloadCost + GasConstants.SstoreSetGas;
    const second_store_cost = GasConstants.SloadGas;
    const expected_left = exec_gas - (push_cost + first_store_cost + second_store_cost);
    try std.testing.expectEqual(expected_left, result.gas_left);
}

// SSTORE: zero->non-zero then clear back to zero, exercising refund cap rules
test "minimal evm gas - sstore clear applies refund cap" {
    var evm = try MinimalEvm.init(std.testing.allocator);
    defer evm.deinit();

    const bytecode = [_]u8{
        0x60, 0x01,
        0x60, 0x00,
        0x55,
        0x60, 0x00,
        0x60, 0x00,
        0x55,
        0x00,
    };

    const exec_gas: u64 = 100_000;
    const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
    const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
    try std.testing.expect(result.success);

    const push_cost: u64 = 4 * GasConstants.GasFastestStep;
    const set_cost = GasConstants.ColdSloadCost + GasConstants.SstoreSetGas;
    const clear_cost = GasConstants.SloadGas;
    const raw_used = push_cost + set_cost + clear_cost;
    const refund_cap = raw_used / GasConstants.MaxRefundQuotient;
    const refund = @min(GasConstants.SstoreRefundGas, refund_cap);
    const expected_left = exec_gas - raw_used + refund;
    try std.testing.expectEqual(expected_left, result.gas_left);
}

// CALL: first call to cold account with no value (should charge cold access surcharge)
test "minimal evm gas - call cold no value" {
    var evm = try MinimalEvm.init(std.testing.allocator);
    defer evm.deinit();

    const bytecode = [_]u8{
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x55,
        0x61, 0x27, 0x10,
        0xf1,
        0x00,
    };

    const exec_gas: u64 = 100_000;
    const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
    const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
    try std.testing.expect(result.success);

    const push_cost: u64 = 7 * GasConstants.GasFastestStep;
    const call_cost = GasConstants.call_gas_cost(false, false, true);
    const expected_left = exec_gas - (push_cost + call_cost);
    try std.testing.expectEqual(expected_left, result.gas_left);
}

// CALL: warm second invocation with value transfer on warmed account
test "minimal evm gas - call warm with value transfer" {
    var evm = try MinimalEvm.init(std.testing.allocator);
    defer evm.deinit();

    try evm.setBalance(CONTRACT_ADDRESS, @as(u256, 10));
    try evm.setBalance(TARGET_EXISTING, @as(u256, 5));

    const bytecode = [_]u8{
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x55,
        0x61, 0x27, 0x10,
        0xf1,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x01,
        0x60, 0x55,
        0x61, 0x27, 0x10,
        0xf1,
        0x00,
    };

    const exec_gas: u64 = 100_000;
    const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
    const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
    try std.testing.expect(result.success);

    const push_cost: u64 = 14 * GasConstants.GasFastestStep;
    const first_call = GasConstants.call_gas_cost(false, false, true);
    const second_call = GasConstants.call_gas_cost(true, false, false);
    const expected_left = exec_gas - (push_cost + first_call + second_call);
    try std.testing.expectEqual(expected_left, result.gas_left);
}

// CALL: value transfer to entirely new account should include new-account surcharge
test "minimal evm gas - call new account surcharge" {
    var evm = try MinimalEvm.init(std.testing.allocator);
    defer evm.deinit();

    try evm.setBalance(CONTRACT_ADDRESS, @as(u256, 10));

    const bytecode = [_]u8{
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x01,
        0x60, 0x66,
        0x61, 0x27, 0x10,
        0xf1,
        0x00,
    };

    const exec_gas: u64 = 100_000;
    const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
    const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
    try std.testing.expect(result.success);

    const push_cost: u64 = 7 * GasConstants.GasFastestStep;
    const call_cost = GasConstants.call_gas_cost(true, true, true);
    const expected_left = exec_gas - (push_cost + call_cost);
    try std.testing.expectEqual(expected_left, result.gas_left);
}

// DELEGATECALL: cold account access should match call gas schedule with no value
test "minimal evm gas - delegatecall cold" {
    var evm = try MinimalEvm.init(std.testing.allocator);
    defer evm.deinit();

    const bytecode = [_]u8{
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x55,
        0x61, 0x27, 0x10,
        0xf4,
        0x00,
    };

    const exec_gas: u64 = 100_000;
    const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
    const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
    try std.testing.expect(result.success);

    const push_cost: u64 = 6 * GasConstants.GasFastestStep;
    const call_cost = GasConstants.call_gas_cost(false, false, true);
    const expected_left = exec_gas - (push_cost + call_cost);
    try std.testing.expectEqual(expected_left, result.gas_left);
}

// CALLCODE: should follow same base/cold costs as CALL without creating new accounts
test "minimal evm gas - callcode cold" {
    var evm = try MinimalEvm.init(std.testing.allocator);
    defer evm.deinit();

    const bytecode = [_]u8{
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x55,
        0x61, 0x27, 0x10,
        0xf2,
        0x00,
    };

    const exec_gas: u64 = 100_000;
    const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
    const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
    try std.testing.expect(result.success);

    const push_cost: u64 = 7 * GasConstants.GasFastestStep;
    const call_cost = GasConstants.call_gas_cost(false, false, true);
    const expected_left = exec_gas - (push_cost + call_cost);
    try std.testing.expectEqual(expected_left, result.gas_left);
}

// STATICCALL: cold account access with zero value
test "minimal evm gas - staticcall cold" {
    var evm = try MinimalEvm.init(std.testing.allocator);
    defer evm.deinit();

    const bytecode = [_]u8{
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x55,
        0x61, 0x27, 0x10,
        0xfa,
        0x00,
    };

    const exec_gas: u64 = 100_000;
    const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
    const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
    try std.testing.expect(result.success);

    const push_cost: u64 = 7 * GasConstants.GasFastestStep;
    const call_cost = GasConstants.call_gas_cost(false, false, true);
    const expected_left = exec_gas - (push_cost + call_cost);
    try std.testing.expectEqual(expected_left, result.gas_left);
}

// CREATE: zero-length init code (charges base create cost)
test "minimal evm gas - create base cost" {
    var evm = try MinimalEvm.init(std.testing.allocator);
    defer evm.deinit();

    const bytecode = [_]u8{
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0xf0,
        0x00,
    };

    const exec_gas: u64 = 200_000;
    const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
    const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
    try std.testing.expect(result.success);

    const push_cost: u64 = 3 * GasConstants.GasFastestStep;
    const create_cost = GasConstants.CreateGas;
    const expected_left = exec_gas - (push_cost + create_cost);
    try std.testing.expectEqual(expected_left, result.gas_left);
}

// CREATE2: zero-length init code should charge create cost plus keccak hashing
test "minimal evm gas - create2 base and hash cost" {
    var evm = try MinimalEvm.init(std.testing.allocator);
    defer evm.deinit();

    const bytecode = [_]u8{
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0xf5,
        0x00,
    };

    const exec_gas: u64 = 200_000;
    const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
    const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
    try std.testing.expect(result.success);

    const push_cost: u64 = 4 * GasConstants.GasFastestStep;
    const create_cost = GasConstants.CreateGas;
    const hash_size: usize = 1 + 20 + 32 + 0;
    const hash_cost = GasConstants.keccak256_gas_cost(hash_size);
    const expected_left = exec_gas - (push_cost + create_cost + hash_cost);
    try std.testing.expectEqual(expected_left, result.gas_left);
}

// LOG1: log 32 bytes with one topic (includes data cost and memory expansion once)
test "minimal evm gas - log1 data and topic costs" {
    var evm = try MinimalEvm.init(std.testing.allocator);
    defer evm.deinit();

    const bytecode = [_]u8{
        0x7f,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x60, 0x00,
        0x52,
        0x60, 0x00,
        0x60, 0x20,
        0x60, 0x00,
        0xa1,
        0x00,
    };

    const exec_gas: u64 = 100_000;
    const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
    const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
    try std.testing.expect(result.success);

    const push_instr: u64 = 5;
    const push_cost: u64 = push_instr * GasConstants.GasFastestStep;
    const mstore_mem_cost = GasConstants.memory_gas_cost(0, 32);
    const mstore_cost = GasConstants.GasFastestStep + mstore_mem_cost;
    const log_cost = GasConstants.LogGas + GasConstants.LogTopicGas + (32 * GasConstants.LogDataGas);
    const expected_left = exec_gas - (push_cost + mstore_cost + log_cost);
    try std.testing.expectEqual(expected_left, result.gas_left);
}

// MCOPY: copy 32 bytes from offset 0 to 32 (covers base + copy gas + memory expansion)
test "minimal evm gas - mcopy base copy and memory expansion" {
    var evm = try MinimalEvm.init(std.testing.allocator);
    defer evm.deinit();

    const bytecode = [_]u8{
        0x7f,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x60, 0x00,
        0x52,
        0x60, 0x20,
        0x60, 0x00,
        0x60, 0x20,
        0x5e,
        0x00,
    };

    const exec_gas: u64 = 100_000;
    const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
    const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
    try std.testing.expect(result.success);

    const push_instr: u64 = 6;
    const push_cost: u64 = push_instr * GasConstants.GasFastestStep;
    const mstore_mem_cost = GasConstants.memory_gas_cost(0, 32);
    const mstore_cost = GasConstants.GasFastestStep + mstore_mem_cost;
    const max_end: u64 = 64;
    const mcopy_mem_cost = GasConstants.memory_gas_cost(32, max_end);
    const copy_cost = GasConstants.copy_gas_cost(32);
    const mcopy_cost = GasConstants.GasFastestStep + mcopy_mem_cost + copy_cost;
    const expected_left = exec_gas - (push_cost + mstore_cost + mcopy_cost);
    try std.testing.expectEqual(expected_left, result.gas_left);
}

// SELFDESTRUCT: cold beneficiary with non-zero balance triggers cold + new account charges
test "minimal evm gas - selfdestruct cold beneficiary" {
    var evm = try MinimalEvm.init(std.testing.allocator);
    defer evm.deinit();

    try evm.setBalance(CONTRACT_ADDRESS, @as(u256, 5));

    const bytecode = [_]u8{
        0x60, 0x77,
        0xff,
        0x00,
    };

    const exec_gas: u64 = 100_000;
    const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
    const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
    try std.testing.expect(result.success);

    const push_cost: u64 = GasConstants.GasFastestStep;
    const base_cost = GasConstants.SelfdestructGas;
    const cold_cost = GasConstants.ColdAccountAccessCost;
    const new_account_cost = GasConstants.CallNewAccountGas;
    const expected_left = exec_gas - (push_cost + base_cost + cold_cost + new_account_cost);
    try std.testing.expectEqual(expected_left, result.gas_left);
}

// AUTH + AUTHCALL: authorization flow then authenticated call should follow call gas schedule
test "minimal evm gas - auth and authcall gas accounting" {
    var evm = try MinimalEvm.init(std.testing.allocator);
    defer evm.deinit();

    const bytecode = [_]u8{
        0x60, 0x99,
        0x60, 0x01,
        0x60, 0x1b,
        0x60, 0x01,
        0x60, 0x01,
        0xf6,
        0x61, 0x27, 0x10,
        0x60, 0x44,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x00,
        0x60, 0x01,
        0xf7,
        0x00,
    };

    const exec_gas: u64 = 100_000;
    const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
    const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
    try std.testing.expect(result.success);

    const push_instr: u64 = 13;
    const push_cost: u64 = push_instr * GasConstants.GasFastestStep;
    const auth_cost: u64 = 3100;
    const authcall_cost = GasConstants.call_gas_cost(false, false, true);
    const expected_left = exec_gas - (push_cost + auth_cost + authcall_cost);
    try std.testing.expectEqual(expected_left, result.gas_left);
}

test "minimal evm gas - precompiles start warm" {
    var evm = try MinimalEvm.init(std.testing.allocator);
    defer evm.deinit();

    const bytecode = [_]u8{ 0x00 };
    const exec_gas: u64 = 10_000;
    const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
    const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
    try std.testing.expect(result.success);

    const precompile = precompiles.ECRECOVER_ADDRESS;
    const cost = try evm.access_address(precompile);
    try std.testing.expectEqual(GasConstants.WarmStorageReadCost, cost);
}

test "minimal evm gas - pre berlin skips warm tracking" {
    var evm = try MinimalEvm.init(std.testing.allocator);
    defer evm.deinit();

    evm.setHardfork(Hardfork.ISTANBUL);

    const bytecode = [_]u8{ 0x00 };
    const exec_gas: u64 = 10_000;
    const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
    const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
    try std.testing.expect(result.success);

    const first = try evm.access_address(TARGET_EXISTING);
    try std.testing.expectEqual(GasConstants.CallCodeCost, first);
    const second = try evm.access_address(TARGET_EXISTING);
    try std.testing.expectEqual(GasConstants.CallCodeCost, second);
}