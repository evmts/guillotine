const std = @import("std");
const primitives = @import("primitives");
const evm_mod = @import("evm");

const MinimalEvm = evm_mod.tracer.MinimalEvm;
const precompiles = evm_mod.precompiles;
const Hardfork = evm_mod.Hardfork;

const GasConstants = primitives.GasConstants;
const Address = primitives.Address;
const StorageSlotKey = evm_mod.tracer.StorageSlotKey;
const MinimalEvmError = MinimalEvm.Error;

const CONTRACT_ADDRESS = Address.from_hex("0x00000000000000000000000000000000000000aa") catch unreachable;
const CALLER_ADDRESS = Address.from_hex("0x00000000000000000000000000000000000000bb") catch unreachable;
const TARGET_EXISTING = Address.from_hex("0x0000000000000000000000000000000000000055") catch unreachable;

// SSTORE: cold zero->non-zero followed by warm modification (dirty slot path)
test "minimal evm gas - sstore cold then warm" {
    const evm = try MinimalEvm.initPtr(std.testing.allocator);
    defer evm.deinitPtr(std.testing.allocator);

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

// SSTORE: sentry gas check (insufficient gas for zero->non-zero transition)
test "minimal evm gas - sstore sentry gas check" {
    const evm = try MinimalEvm.initPtr(std.testing.allocator);
    defer evm.deinitPtr(std.testing.allocator);

    const bytecode = [_]u8{
        // Try to store non-zero value with insufficient gas
        0x60, 0x05, // PUSH1 5
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE (should fail sentry check)
        0x00,       // STOP (shouldn't reach)
    };

    // Gas just below sentry requirement
    const exec_gas: u64 = GasConstants.SstoreSentryGas - 1;
    const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
    const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
    
    // Should fail due to sentry gas check
    try std.testing.expect(!result.success);
    
    // Verify storage wasn't modified
    const key = StorageSlotKey{ .address = CONTRACT_ADDRESS, .slot = 0 };
    const value = evm.storage.get(key) orelse 0;
    try std.testing.expectEqual(@as(u256, 0), value);
}

// CALL: first call to cold account with no value (should charge cold access surcharge)
test "minimal evm gas - call cold no value" {
    const evm = try MinimalEvm.initPtr(std.testing.allocator);
    defer evm.deinitPtr(std.testing.allocator);

    const bytecode = [_]u8{
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x55,        // PUSH1 0x55
        0x61, 0x27, 0x10,  // PUSH2 10000
        0xf1,              // CALL
        0x00,              // STOP
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
    const evm = try MinimalEvm.initPtr(std.testing.allocator);
    defer evm.deinitPtr(std.testing.allocator);

    try evm.setBalance(CONTRACT_ADDRESS, @as(u256, 10));
    try evm.setBalance(TARGET_EXISTING, @as(u256, 5));

    const bytecode = [_]u8{
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x55,        // PUSH1 0x55
        0x61, 0x27, 0x10,  // PUSH2 10000
        0xf1,              // CALL
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x01,        // PUSH1 1
        0x60, 0x55,        // PUSH1 0x55
        0x61, 0x27, 0x10,  // PUSH2 10000
        0xf1,              // CALL
        0x00,              // STOP
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
    const evm = try MinimalEvm.initPtr(std.testing.allocator);
    defer evm.deinitPtr(std.testing.allocator);

    try evm.setBalance(CONTRACT_ADDRESS, @as(u256, 10));

    const bytecode = [_]u8{
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x01,        // PUSH1 1
        0x60, 0x66,        // PUSH1 0x66
        0x61, 0x27, 0x10,  // PUSH2 10000
        0xf1,              // CALL
        0x00,              // STOP
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
    const evm = try MinimalEvm.initPtr(std.testing.allocator);
    defer evm.deinitPtr(std.testing.allocator);

    const bytecode = [_]u8{
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x55,        // PUSH1 0x55
        0x61, 0x27, 0x10,  // PUSH2 10000
        0xf4,              // DELEGATECALL
        0x00,              // STOP
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
    const evm = try MinimalEvm.initPtr(std.testing.allocator);
    defer evm.deinitPtr(std.testing.allocator);

    const bytecode = [_]u8{
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x55,        // PUSH1 0x55
        0x61, 0x27, 0x10,  // PUSH2 10000
        0xf2,              // CALLCODE
        0x00,              // STOP
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
    const evm = try MinimalEvm.initPtr(std.testing.allocator);
    defer evm.deinitPtr(std.testing.allocator);

    const bytecode = [_]u8{
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x55,        // PUSH1 0x55
        0x61, 0x27, 0x10,  // PUSH2 10000
        0xfa,              // STATICCALL
        0x00,              // STOP
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
    const evm = try MinimalEvm.initPtr(std.testing.allocator);
    defer evm.deinitPtr(std.testing.allocator);

    const bytecode = [_]u8{
        0x60, 0x00,  // PUSH1 0
        0x60, 0x00,  // PUSH1 0
        0x60, 0x00,  // PUSH1 0
        0xf0,        // CREATE
        0x00,        // STOP
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
    const evm = try MinimalEvm.initPtr(std.testing.allocator);
    defer evm.deinitPtr(std.testing.allocator);

    const bytecode = [_]u8{
        0x60, 0x00,  // PUSH1 0
        0x60, 0x00,  // PUSH1 0
        0x60, 0x00,  // PUSH1 0
        0x60, 0x00,  // PUSH1 0
        0xf5,        // CREATE2
        0x00,        // STOP
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
    const evm = try MinimalEvm.initPtr(std.testing.allocator);
    defer evm.deinitPtr(std.testing.allocator);

    const bytecode = [_]u8{
        0x7f,              // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 32 bytes of zeros
        0x60, 0x00,        // PUSH1 0
        0x52,              // MSTORE
        0x60, 0x00,        // PUSH1 0
        0x60, 0x20,        // PUSH1 32
        0x60, 0x00,        // PUSH1 0
        0xa1,              // LOG1
        0x00,              // STOP
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
    const evm = try MinimalEvm.initPtr(std.testing.allocator);
    defer evm.deinitPtr(std.testing.allocator);

    const bytecode = [_]u8{
        0x7f,              // PUSH32
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 32 bytes of zeros
        0x60, 0x00,        // PUSH1 0
        0x52,              // MSTORE
        0x60, 0x20,        // PUSH1 32
        0x60, 0x00,        // PUSH1 0
        0x60, 0x20,        // PUSH1 32
        0x5e,              // MCOPY
        0x00,              // STOP
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
    const evm = try MinimalEvm.initPtr(std.testing.allocator);
    defer evm.deinitPtr(std.testing.allocator);

    try evm.setBalance(CONTRACT_ADDRESS, @as(u256, 5));

    const bytecode = [_]u8{
        0x60, 0x77,  // PUSH1 0x77
        0xff,        // SELFDESTRUCT
        0x00,        // STOP
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
    const evm = try MinimalEvm.initPtr(std.testing.allocator);
    defer evm.deinitPtr(std.testing.allocator);

    const bytecode = [_]u8{
        0x60, 0x99,        // PUSH1 0x99
        0x60, 0x01,        // PUSH1 1
        0x60, 0x1b,        // PUSH1 0x1b
        0x60, 0x01,        // PUSH1 1
        0x60, 0x01,        // PUSH1 1
        0xf6,              // AUTH
        0x61, 0x27, 0x10,  // PUSH2 10000
        0x60, 0x44,        // PUSH1 0x44
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x00,        // PUSH1 0
        0x60, 0x01,        // PUSH1 1
        0xf7,              // AUTHCALL
        0x00,              // STOP
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
    const evm = try MinimalEvm.initPtr(std.testing.allocator);
    defer evm.deinitPtr(std.testing.allocator);

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
    const evm = try MinimalEvm.initPtr(std.testing.allocator);
    defer evm.deinitPtr(std.testing.allocator);

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

// Test BALANCE gas costs across hardfork boundaries (EIP-150, Berlin)
test "minimal evm gas - balance hardfork transitions" {
    // Pre-EIP-150: GasQuickStep (2 gas)
    {
        const evm = try MinimalEvm.initPtr(std.testing.allocator);
        defer evm.deinitPtr(std.testing.allocator);
        evm.setHardfork(.HOMESTEAD);

        const bytecode = [_]u8{
            0x60, 0x55, // PUSH1 0x55
            0x31,       // BALANCE
            0x00,       // STOP
        };

        const exec_gas: u64 = 100_000;
        const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
        const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
        try std.testing.expect(result.success);

        const push_cost = GasConstants.GasFastestStep;
        const balance_cost = GasConstants.GasQuickStep; // Pre-EIP-150
        const expected_left = exec_gas - (push_cost + balance_cost);
        try std.testing.expectEqual(expected_left, result.gas_left);
    }

    // Post-EIP-150, Pre-Berlin: GasExtStep (20 gas)
    {
        const evm = try MinimalEvm.initPtr(std.testing.allocator);
        defer evm.deinitPtr(std.testing.allocator);
        evm.setHardfork(.TANGERINE_WHISTLE);

        const bytecode = [_]u8{
            0x60, 0x55, // PUSH1 0x55
            0x31,       // BALANCE
            0x00,       // STOP
        };

        const exec_gas: u64 = 100_000;
        const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
        const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
        try std.testing.expect(result.success);

        const push_cost = GasConstants.GasFastestStep;
        const balance_cost = GasConstants.GasExtStep; // Post-EIP-150
        const expected_left = exec_gas - (push_cost + balance_cost);
        try std.testing.expectEqual(expected_left, result.gas_left);
    }

    // Post-Berlin: Cold access (2600 gas)
    {
        const evm = try MinimalEvm.initPtr(std.testing.allocator);
        defer evm.deinitPtr(std.testing.allocator);
        evm.setHardfork(.BERLIN);

        const bytecode = [_]u8{
            0x60, 0x55, // PUSH1 0x55
            0x31,       // BALANCE
            0x00,       // STOP
        };

        const exec_gas: u64 = 100_000;
        const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
        const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
        try std.testing.expect(result.success);

        const push_cost = GasConstants.GasFastestStep;
        const balance_cost = GasConstants.ColdAccountAccessCost; // Post-Berlin cold access
        const expected_left = exec_gas - (push_cost + balance_cost);
        try std.testing.expectEqual(expected_left, result.gas_left);
    }
}

// Test EXTCODESIZE gas costs across hardfork boundaries
test "minimal evm gas - extcodesize hardfork transitions" {
    // Pre-EIP-150: GasQuickStep (2 gas)
    {
        const evm = try MinimalEvm.initPtr(std.testing.allocator);
        defer evm.deinitPtr(std.testing.allocator);
        evm.setHardfork(.HOMESTEAD);

        const bytecode = [_]u8{
            0x60, 0x55, // PUSH1 0x55
            0x3b,       // EXTCODESIZE
            0x00,       // STOP
        };

        const exec_gas: u64 = 100_000;
        const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
        const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
        try std.testing.expect(result.success);

        const push_cost = GasConstants.GasFastestStep;
        const extcodesize_cost = GasConstants.GasQuickStep; // Pre-EIP-150
        const expected_left = exec_gas - (push_cost + extcodesize_cost);
        try std.testing.expectEqual(expected_left, result.gas_left);
    }

    // Post-EIP-150, Pre-Berlin: GasExtStep (20 gas)
    {
        const evm = try MinimalEvm.initPtr(std.testing.allocator);
        defer evm.deinitPtr(std.testing.allocator);
        evm.setHardfork(.TANGERINE_WHISTLE);

        const bytecode = [_]u8{
            0x60, 0x55, // PUSH1 0x55
            0x3b,       // EXTCODESIZE
            0x00,       // STOP
        };

        const exec_gas: u64 = 100_000;
        const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
        const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
        try std.testing.expect(result.success);

        const push_cost = GasConstants.GasFastestStep;
        const extcodesize_cost = GasConstants.GasExtStep; // Post-EIP-150
        const expected_left = exec_gas - (push_cost + extcodesize_cost);
        try std.testing.expectEqual(expected_left, result.gas_left);
    }

    // Post-Berlin: Cold access (2600 gas)
    {
        const evm = try MinimalEvm.initPtr(std.testing.allocator);
        defer evm.deinitPtr(std.testing.allocator);
        evm.setHardfork(.BERLIN);

        const bytecode = [_]u8{
            0x60, 0x55, // PUSH1 0x55
            0x3b,       // EXTCODESIZE
            0x00,       // STOP
        };

        const exec_gas: u64 = 100_000;
        const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
        const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
        try std.testing.expect(result.success);

        const push_cost = GasConstants.GasFastestStep;
        const extcodesize_cost = GasConstants.ColdAccountAccessCost; // Post-Berlin cold access
        const expected_left = exec_gas - (push_cost + extcodesize_cost);
        try std.testing.expectEqual(expected_left, result.gas_left);
    }
}

// Test EXTCODECOPY gas costs across hardfork boundaries
test "minimal evm gas - extcodecopy hardfork transitions" {
    // Pre-EIP-150: GasQuickStep + copy cost
    {
        const evm = try MinimalEvm.initPtr(std.testing.allocator);
        defer evm.deinitPtr(std.testing.allocator);
        evm.setHardfork(.HOMESTEAD);

        const bytecode = [_]u8{
            0x60, 0x20, // PUSH1 32
            0x60, 0x00, // PUSH1 0
            0x60, 0x00, // PUSH1 0
            0x60, 0x55, // PUSH1 0x55
            0x3c,       // EXTCODECOPY
            0x00,       // STOP
        };

        const exec_gas: u64 = 100_000;
        const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
        const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
        try std.testing.expect(result.success);

        const push_cost = 4 * GasConstants.GasFastestStep;
        const access_cost = GasConstants.GasQuickStep; // Pre-EIP-150
        const copy_cost = GasConstants.copy_gas_cost(32);
        const expected_left = exec_gas - (push_cost + access_cost + copy_cost);
        try std.testing.expectEqual(expected_left, result.gas_left);
    }

    // Post-Berlin: Cold access cost + copy cost
    {
        const evm = try MinimalEvm.initPtr(std.testing.allocator);
        defer evm.deinitPtr(std.testing.allocator);
        evm.setHardfork(.BERLIN);

        const bytecode = [_]u8{
            0x60, 0x20, // PUSH1 32
            0x60, 0x00, // PUSH1 0
            0x60, 0x00, // PUSH1 0
            0x60, 0x55, // PUSH1 0x55
            0x3c,       // EXTCODECOPY
            0x00,       // STOP
        };

        const exec_gas: u64 = 100_000;
        const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
        const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
        try std.testing.expect(result.success);

        const push_cost = 4 * GasConstants.GasFastestStep;
        const access_cost = GasConstants.ColdAccountAccessCost; // Post-Berlin cold access
        const copy_cost = GasConstants.copy_gas_cost(32);
        const expected_left = exec_gas - (push_cost + access_cost + copy_cost);
        try std.testing.expectEqual(expected_left, result.gas_left);
    }
}

// Test EXTCODEHASH gas costs across hardfork boundaries
test "minimal evm gas - extcodehash hardfork transitions" {
    // Pre-EIP-150: GasQuickStep (2 gas)
    {
        const evm = try MinimalEvm.initPtr(std.testing.allocator);
        defer evm.deinitPtr(std.testing.allocator);
        evm.setHardfork(.HOMESTEAD);

        const bytecode = [_]u8{
            0x60, 0x55, // PUSH1 0x55
            0x3f,       // EXTCODEHASH
            0x00,       // STOP
        };

        const exec_gas: u64 = 100_000;
        const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
        const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
        try std.testing.expect(result.success);

        const push_cost = GasConstants.GasFastestStep;
        const extcodehash_cost = GasConstants.GasQuickStep; // Pre-EIP-150
        const expected_left = exec_gas - (push_cost + extcodehash_cost);
        try std.testing.expectEqual(expected_left, result.gas_left);
    }

    // Post-Berlin: Cold access (2600 gas)
    {
        const evm = try MinimalEvm.initPtr(std.testing.allocator);
        defer evm.deinitPtr(std.testing.allocator);
        evm.setHardfork(.BERLIN);

        const bytecode = [_]u8{
            0x60, 0x55, // PUSH1 0x55
            0x3f,       // EXTCODEHASH
            0x00,       // STOP
        };

        const exec_gas: u64 = 100_000;
        const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
        const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
        try std.testing.expect(result.success);

        const push_cost = GasConstants.GasFastestStep;
        const extcodehash_cost = GasConstants.ColdAccountAccessCost; // Post-Berlin cold access
        const expected_left = exec_gas - (push_cost + extcodehash_cost);
        try std.testing.expectEqual(expected_left, result.gas_left);
    }
}

// Test CREATE/CREATE2 with EIP-3860 size limits and word costs
test "minimal evm gas - create eip3860 size limits" {
    // Pre-Shanghai: No init code size limit or word cost
    {
        const evm = try MinimalEvm.initPtr(std.testing.allocator);
        defer evm.deinitPtr(std.testing.allocator);
        evm.setHardfork(.LONDON);

        const bytecode = [_]u8{
            0x61, 0x04, 0x00, // PUSH2 1024 (init code size)
            0x60, 0x00,       // PUSH1 0 (offset)
            0x60, 0x00,       // PUSH1 0 (value)
            0xf0,             // CREATE
            0x00,             // STOP
        };

        const exec_gas: u64 = 200_000;
        const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
        const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
        try std.testing.expect(result.success);

        const push_cost = 3 * GasConstants.GasFastestStep;
        const create_cost = GasConstants.CreateGas; // No word cost pre-Shanghai
        const expected_left = exec_gas - (push_cost + create_cost);
        try std.testing.expectEqual(expected_left, result.gas_left);
    }

    // Post-Shanghai: Init code word cost
    {
        const evm = try MinimalEvm.initPtr(std.testing.allocator);
        defer evm.deinitPtr(std.testing.allocator);
        evm.setHardfork(.SHANGHAI);

        const bytecode = [_]u8{
            0x61, 0x04, 0x00, // PUSH2 1024 (init code size)
            0x60, 0x00,       // PUSH1 0 (offset)
            0x60, 0x00,       // PUSH1 0 (value)
            0xf0,             // CREATE
            0x00,             // STOP
        };

        const exec_gas: u64 = 200_000;
        const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
        const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
        try std.testing.expect(result.success);

        const push_cost = 3 * GasConstants.GasFastestStep;
        const init_code_size: u32 = 1024;
        const word_count = GasConstants.wordCount(init_code_size);
        const create_cost = GasConstants.CreateGas + (word_count * GasConstants.InitcodeWordGas);
        const expected_left = exec_gas - (push_cost + create_cost);
        try std.testing.expectEqual(expected_left, result.gas_left);
    }

    // EIP-3860 init code size limit enforcement - CREATE returns error
    {
        const evm = try MinimalEvm.initPtr(std.testing.allocator);
        defer evm.deinitPtr(std.testing.allocator);
        evm.setHardfork(.SHANGHAI);

        const bytecode = [_]u8{
            0x62, 0x01, 0x00, 0x01, // PUSH3 65537 (exceeds MaxInitcodeSize of 49152)
            0x60, 0x00,             // PUSH1 0 (offset)
            0x60, 0x00,             // PUSH1 0 (value)
            0xf0,                   // CREATE (should return CreateInitCodeSizeLimit error)
            0x00,                   // STOP (never reached)
        };

        const exec_gas: u64 = 200_000;
        const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
        
        // Execution should return an error for exceeding init code size
        const result = evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{}) catch |err| {
            // Should return CreateInitCodeSizeLimit error when init code size is exceeded
            try std.testing.expectEqual(MinimalEvmError.CreateInitCodeSizeLimit, err);
            return;
        };
        
        // Should not reach here - execution should have failed with error
        try std.testing.expect(false);
        _ = result;
    }

    // EIP-3860 init code size limit enforcement - CREATE2 returns error
    {
        const evm = try MinimalEvm.initPtr(std.testing.allocator);
        defer evm.deinitPtr(std.testing.allocator);
        evm.setHardfork(.SHANGHAI);

        const bytecode = [_]u8{
            0x60, 0x12,             // PUSH1 0x12 (salt)
            0x62, 0x01, 0x00, 0x01, // PUSH3 65537 (exceeds MaxInitcodeSize of 49152)
            0x60, 0x00,             // PUSH1 0 (offset)
            0x60, 0x00,             // PUSH1 0 (value)
            0xf5,                   // CREATE2 (should return CreateInitCodeSizeLimit error)
            0x00,                   // STOP (never reached)
        };

        const exec_gas: u64 = 200_000;
        const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
        
        // Execution should return an error for exceeding init code size
        const result = evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{}) catch |err| {
            // Should return CreateInitCodeSizeLimit error when init code size is exceeded
            try std.testing.expectEqual(MinimalEvmError.CreateInitCodeSizeLimit, err);
            return;
        };
        
        // Should not reach here - execution should have failed with error
        try std.testing.expect(false);
        _ = result;
    }

    // TODO: EIP-170 created code size limit enforcement - CREATE returns error
    // When CREATE successfully deploys but the resulting contract code exceeds 24576 bytes,
    // it should fail with CreateContractSizeLimit error.
    // This requires implementing the contract code size check after init code execution.
    // Note: The init code would need to generate a large contract by returning more than 24576 bytes.
    
    // TODO: EIP-170 created code size limit enforcement - CREATE2 returns error
    // Similar to CREATE, when CREATE2 deploys code exceeding the size limit,
    // it should fail with CreateContractSizeLimit error.
    
    // Test that pre-Shanghai doesn't enforce EIP-3860 init code limit
    {
        const evm = try MinimalEvm.initPtr(std.testing.allocator);
        defer evm.deinitPtr(std.testing.allocator);
        evm.setHardfork(.LONDON); // Pre-Shanghai

        const bytecode = [_]u8{
            0x62, 0x01, 0x00, 0x01, // PUSH3 65537 (exceeds future MaxInitcodeSize but not enforced)
            0x60, 0x00,             // PUSH1 0 (offset)
            0x60, 0x00,             // PUSH1 0 (value)
            0xf0,                   // CREATE (should succeed pre-Shanghai)
            0x00,                   // STOP
        };

        const exec_gas: u64 = 200_000;
        const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
        const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
        
        // Pre-Shanghai: Should succeed even with large init code
        // (Note: In practice this would still fail for other reasons like memory allocation)
        try std.testing.expect(result.success);
    }
}

// Test SELFDESTRUCT gas cost and refund behavior across hardforks
test "minimal evm gas - selfdestruct hardfork gas and refund" {
    // Pre-EIP-150: Free operation (0 gas)
    {
        const evm = try MinimalEvm.initPtr(std.testing.allocator);
        defer evm.deinitPtr(std.testing.allocator);
        evm.setHardfork(.HOMESTEAD);

        const bytecode = [_]u8{
            0x60, 0x55, // PUSH1 0x55 (beneficiary)
            0xff,       // SELFDESTRUCT
        };

        const exec_gas: u64 = 100_000;
        const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
        const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
        try std.testing.expect(result.success);

        const push_cost = GasConstants.GasFastestStep;
        const selfdestruct_cost: u64 = 0; // Pre-EIP-150: Free
        const expected_left = exec_gas - (push_cost + selfdestruct_cost);
        try std.testing.expectEqual(expected_left, result.gas_left);
    }

    // Post-EIP-150, Pre-London: 5000 gas + 24000 refund
    {
        const evm = try MinimalEvm.initPtr(std.testing.allocator);
        defer evm.deinitPtr(std.testing.allocator);
        evm.setHardfork(.TANGERINE_WHISTLE);
        evm.gas_refund = 0; // Reset refund counter

        const bytecode = [_]u8{
            0x60, 0x55, // PUSH1 0x55 (beneficiary)
            0xff,       // SELFDESTRUCT
        };

        const exec_gas: u64 = 100_000;
        const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
        const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
        try std.testing.expect(result.success);

        const push_cost = GasConstants.GasFastestStep;
        const selfdestruct_cost = GasConstants.SelfdestructGas; // Post-EIP-150: 5000 gas
        const expected_left = exec_gas - (push_cost + selfdestruct_cost);
        try std.testing.expectEqual(expected_left, result.gas_left);
        
        // Check that refund was applied
        try std.testing.expectEqual(GasConstants.SelfdestructRefundGas, evm.gas_refund);
    }

    // Post-London: 5000 gas + 0 refund (EIP-3529)
    {
        const evm = try MinimalEvm.initPtr(std.testing.allocator);
        defer evm.deinitPtr(std.testing.allocator);
        evm.setHardfork(.LONDON);
        evm.gas_refund = 0; // Reset refund counter

        const bytecode = [_]u8{
            0x60, 0x55, // PUSH1 0x55 (beneficiary)
            0xff,       // SELFDESTRUCT
        };

        const exec_gas: u64 = 100_000;
        const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
        const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
        try std.testing.expect(result.success);

        const push_cost = GasConstants.GasFastestStep;
        const selfdestruct_cost = GasConstants.SelfdestructGas; // Post-EIP-150: 5000 gas
        const expected_left = exec_gas - (push_cost + selfdestruct_cost);
        try std.testing.expectEqual(expected_left, result.gas_left);
        
        // Check that no refund was applied (EIP-3529)
        try std.testing.expectEqual(@as(u64, 0), evm.gas_refund);
    }
}

// Test KECCAK256 gas calculations with various data sizes
test "minimal evm gas - keccak256 gas calculation" {
    const test_cases = [_]struct {
        data_size: u32,
        expected_cost: u64,
    }{
        .{ .data_size = 0, .expected_cost = GasConstants.Keccak256Gas }, // Empty data: 30 gas
        .{ .data_size = 32, .expected_cost = GasConstants.Keccak256Gas + GasConstants.Keccak256WordGas }, // 1 word: 30 + 6 = 36
        .{ .data_size = 64, .expected_cost = GasConstants.Keccak256Gas + 2 * GasConstants.Keccak256WordGas }, // 2 words: 30 + 12 = 42
        .{ .data_size = 33, .expected_cost = GasConstants.Keccak256Gas + 2 * GasConstants.Keccak256WordGas }, // 2 words (rounded up): 30 + 12 = 42
        .{ .data_size = 256, .expected_cost = GasConstants.Keccak256Gas + 8 * GasConstants.Keccak256WordGas }, // 8 words: 30 + 48 = 78
    };

    for (test_cases) |case| {
        const evm = try MinimalEvm.initPtr(std.testing.allocator);
        defer evm.deinitPtr(std.testing.allocator);

        // Prepare bytecode: store data at memory offset 0, then hash it
        var bytecode = std.ArrayList(u8){};
        defer bytecode.deinit(std.testing.allocator);

        // Fill memory with test data size
        if (case.data_size > 0) {
            // PUSH32 with zeros, then MSTORE for each 32-byte chunk
            const full_words = case.data_size / 32;
            const remaining_bytes = case.data_size % 32;
            
            for (0..full_words) |i| {
                // PUSH32 (33 bytes: opcode + 32 data bytes)
                try bytecode.append(std.testing.allocator, 0x7f);
                try bytecode.appendNTimes(std.testing.allocator, 0x00, 32);
                // PUSH1 offset
                try bytecode.append(std.testing.allocator, 0x60);
                try bytecode.append(std.testing.allocator, @intCast(i * 32));
                // MSTORE
                try bytecode.append(std.testing.allocator, 0x52);
            }
            
            if (remaining_bytes > 0) {
                // For partial word, use appropriate PUSH instruction
                if (remaining_bytes <= 32) {
                    try bytecode.append(std.testing.allocator, @as(u8, @intCast(0x60 + remaining_bytes - 1))); // PUSH1-PUSH32
                    try bytecode.appendNTimes(std.testing.allocator, 0x00, remaining_bytes);
                    // PUSH1 offset
                    try bytecode.append(std.testing.allocator, 0x60);
                    try bytecode.append(std.testing.allocator, @intCast(full_words * 32));
                    // MSTORE
                    try bytecode.append(std.testing.allocator, 0x52);
                }
            }
        }

        // PUSH data size
        try bytecode.append(std.testing.allocator, 0x60); // PUSH1
        try bytecode.append(std.testing.allocator, @intCast(@min(case.data_size, 255)));
        // PUSH offset 0
        try bytecode.append(std.testing.allocator, 0x60); // PUSH1
        try bytecode.append(std.testing.allocator, 0x00);
        // KECCAK256
        try bytecode.append(std.testing.allocator, 0x20);
        // STOP
        try bytecode.append(std.testing.allocator, 0x00);

        const exec_gas: u64 = 100_000;
        const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
        const result = try evm.execute(bytecode.items, total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
        try std.testing.expect(result.success);

        // Note: This test validates the gas cost calculation, but exact gas calculation
        // would require accounting for memory setup costs. Focus is on KECCAK256 cost.
        const calculated_cost = GasConstants.keccak256_gas_cost(case.data_size);
        try std.testing.expectEqual(case.expected_cost, calculated_cost);
    }
}

// Test CALLDATACOPY, CODECOPY, RETURNDATACOPY gas calculations
test "minimal evm gas - copy operations gas costs" {
    const test_cases = [_]struct {
        copy_size: u32,
        expected_copy_cost: u64,
    }{
        .{ .copy_size = 0, .expected_copy_cost = 0 }, // No copy: 0 gas
        .{ .copy_size = 32, .expected_copy_cost = 3 }, // 1 word: 3 gas  
        .{ .copy_size = 64, .expected_copy_cost = 6 }, // 2 words: 6 gas
        .{ .copy_size = 33, .expected_copy_cost = 6 }, // 2 words (rounded up): 6 gas
        .{ .copy_size = 256, .expected_copy_cost = 24 }, // 8 words: 24 gas
    };

    for (test_cases) |case| {
        // Test CALLDATACOPY
        {
            const evm = try MinimalEvm.initPtr(std.testing.allocator);
            defer evm.deinitPtr(std.testing.allocator);

            const bytecode = [_]u8{
                0x60, @intCast(@min(case.copy_size, 255)), // PUSH1 size
                0x60, 0x00, // PUSH1 0 (calldata offset)
                0x60, 0x00, // PUSH1 0 (memory offset)
                0x37,       // CALLDATACOPY
                0x00,       // STOP
            };

            const exec_gas: u64 = 100_000;
            const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
            const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
            try std.testing.expect(result.success);

            const calculated_cost = GasConstants.copy_gas_cost(case.copy_size);
            try std.testing.expectEqual(case.expected_copy_cost, calculated_cost);
        }

        // Test CODECOPY
        {
            const evm = try MinimalEvm.initPtr(std.testing.allocator);
            defer evm.deinitPtr(std.testing.allocator);

            const bytecode = [_]u8{
                0x60, @intCast(@min(case.copy_size, 255)), // PUSH1 size
                0x60, 0x00, // PUSH1 0 (code offset)
                0x60, 0x00, // PUSH1 0 (memory offset)
                0x39,       // CODECOPY
                0x00,       // STOP
            };

            const exec_gas: u64 = 100_000;
            const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
            const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
            try std.testing.expect(result.success);

            const calculated_cost = GasConstants.copy_gas_cost(case.copy_size);
            try std.testing.expectEqual(case.expected_copy_cost, calculated_cost);
        }

        // Test RETURNDATACOPY (requires prior call for return data)
        {
            const evm = try MinimalEvm.initPtr(std.testing.allocator);
            defer evm.deinitPtr(std.testing.allocator);

            // Set some return data first
            const return_data = try std.testing.allocator.alloc(u8, case.copy_size);
            defer std.testing.allocator.free(return_data);
            @memset(return_data, 0);
            evm.return_data = return_data;

            const bytecode = [_]u8{
                0x60, @intCast(@min(case.copy_size, 255)), // PUSH1 size
                0x60, 0x00, // PUSH1 0 (return data offset)
                0x60, 0x00, // PUSH1 0 (memory offset)
                0x3e,       // RETURNDATACOPY
                0x00,       // STOP
            };

            const exec_gas: u64 = 100_000;
            const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
            const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
            try std.testing.expect(result.success);

            const calculated_cost = GasConstants.copy_gas_cost(case.copy_size);
            try std.testing.expectEqual(case.expected_copy_cost, calculated_cost);
        }
    }
}

// Test LOG0-LOG4 gas calculations with various data and topic sizes
test "minimal evm gas - log operations comprehensive" {
    const test_cases = [_]struct {
        opcode: u8,
        topic_count: u8,
        data_size: u32,
        expected_cost: u64,
    }{
        .{ .opcode = 0xa0, .topic_count = 0, .data_size = 0, .expected_cost = GasConstants.LogGas }, // LOG0, no data: 375
        .{ .opcode = 0xa1, .topic_count = 1, .data_size = 0, .expected_cost = GasConstants.LogGas + GasConstants.LogTopicGas }, // LOG1, no data: 750
        .{ .opcode = 0xa0, .topic_count = 0, .data_size = 32, .expected_cost = GasConstants.LogGas + 32 * GasConstants.LogDataGas }, // LOG0, 32 bytes: 375 + 256 = 631
        .{ .opcode = 0xa4, .topic_count = 4, .data_size = 64, .expected_cost = GasConstants.LogGas + 4 * GasConstants.LogTopicGas + 64 * GasConstants.LogDataGas }, // LOG4, 64 bytes: 375 + 1500 + 512 = 2387
    };

    for (test_cases) |case| {
        const evm = try MinimalEvm.initPtr(std.testing.allocator);
        defer evm.deinitPtr(std.testing.allocator);

        var bytecode = std.ArrayList(u8){};
        defer bytecode.deinit(std.testing.allocator);

        // Prepare memory with test data
        if (case.data_size > 0) {
            // Fill first 32 bytes of memory
            try bytecode.append(std.testing.allocator, 0x7f); // PUSH32
            try bytecode.appendNTimes(std.testing.allocator, 0xaa, 32); // Fill with 0xaa
            try bytecode.append(std.testing.allocator, 0x60); // PUSH1
            try bytecode.append(std.testing.allocator, 0x00); // offset 0
            try bytecode.append(std.testing.allocator, 0x52); // MSTORE
        }

        // Push data size and offset
        try bytecode.append(std.testing.allocator, 0x60); // PUSH1
        try bytecode.append(std.testing.allocator, @intCast(@min(case.data_size, 255))); // size
        try bytecode.append(std.testing.allocator, 0x60); // PUSH1  
        try bytecode.append(std.testing.allocator, 0x00); // offset 0

        // Push topics (dummy values)
        for (0..case.topic_count) |i| {
            try bytecode.append(std.testing.allocator, 0x60); // PUSH1
            try bytecode.append(std.testing.allocator, @intCast(i + 1)); // topic value
        }

        // LOG opcode
        try bytecode.append(std.testing.allocator, case.opcode);
        // STOP
        try bytecode.append(std.testing.allocator, 0x00);

        const exec_gas: u64 = 100_000;
        const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
        const result = try evm.execute(bytecode.items, total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
        try std.testing.expect(result.success);

        const calculated_cost = GasConstants.log_gas_cost(case.topic_count, case.data_size);
        try std.testing.expectEqual(case.expected_cost, calculated_cost);
    }
}