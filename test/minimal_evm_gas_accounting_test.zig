const std = @import("std");
const primitives = @import("primitives");
const evm_mod = @import("evm");

const MinimalEvm = evm_mod.tracer.MinimalEvm;
const precompiles = evm_mod.precompiles;
const Hardfork = evm_mod.Hardfork;

const GasConstants = primitives.GasConstants;
const Address = primitives.Address;
const StorageSlotKey = evm_mod.tracer.StorageSlotKey;

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

// SSTORE: clear non-zero storage to zero, exercising refund cap rules
test "minimal evm gas - sstore clear applies refund cap" {
    const evm = try MinimalEvm.initPtr(std.testing.allocator);
    defer evm.deinitPtr(std.testing.allocator);

    // Pre-populate storage slot 0 with non-zero value so clearing it triggers refund
    // Set both the current storage value and mark it as the original value
    const storage_key = StorageSlotKey{ .address = CONTRACT_ADDRESS, .slot = @as(u256, 0) };
    try evm.storage.put(storage_key, @as(u256, 42));
    try evm.original_storage.put(storage_key, @as(u256, 42));

    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (new value)
        0x60, 0x00, // PUSH1 0 (slot)
        0x55,       // SSTORE (clear slot 0 to 0)
        0x00,       // STOP
    };

    const exec_gas: u64 = 100_000;
    const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
    const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
    try std.testing.expect(result.success);

    const push_cost: u64 = 2 * GasConstants.GasFastestStep;
    const clear_cost = GasConstants.ColdSloadCost + GasConstants.SstoreResetGas;
    const raw_used = push_cost + clear_cost;
    const refund_cap = raw_used / GasConstants.MaxRefundQuotient;
    const refund = @min(GasConstants.SstoreRefundGas, refund_cap);
    const expected_left = exec_gas - raw_used + refund;
    try std.testing.expectEqual(expected_left, result.gas_left);
}

// SSTORE: warm noop (storing same value should cost minimum)
test "minimal evm gas - sstore warm noop" {
    const evm = try MinimalEvm.initPtr(std.testing.allocator);
    defer evm.deinitPtr(std.testing.allocator);

    // Pre-set storage slot with value 9
    const key = StorageSlotKey{ .address = CONTRACT_ADDRESS, .slot = 0 };
    try evm.storage.put(key, 9);
    try evm.original_storage.put(key, 9);

    const bytecode = [_]u8{
        // First SSTORE to warm the slot (same value)
        0x60, 0x09, // PUSH1 9
        0x60, 0x00, // PUSH1 0 
        0x55,       // SSTORE (slot 0 = 9, already 9)
        // Second SSTORE (warm, same value)
        0x60, 0x09, // PUSH1 9
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE (slot 0 = 9, warm noop)
        0x00,       // STOP
    };

    const exec_gas: u64 = 100_000;
    const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
    const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
    try std.testing.expect(result.success);

    const push_cost: u64 = 4 * GasConstants.GasFastestStep;
    // First SSTORE: cold access + noop cost
    const first_sstore = GasConstants.ColdSloadCost + GasConstants.SloadGas;
    // Second SSTORE: warm noop
    const second_sstore = GasConstants.SloadGas;
    const expected_left = exec_gas - (push_cost + first_sstore + second_sstore);
    try std.testing.expectEqual(expected_left, result.gas_left);
    try std.testing.expectEqual(@as(u64, 0), evm.gas_refund);
}

// SSTORE: warm restore original (dirty slot going back to original value)
test "minimal evm gas - sstore warm restore original" {
    const evm = try MinimalEvm.initPtr(std.testing.allocator);
    defer evm.deinitPtr(std.testing.allocator);

    // Set original value as 3
    const key = StorageSlotKey{ .address = CONTRACT_ADDRESS, .slot = 0 };
    try evm.original_storage.put(key, 3);
    // Current value is 0 (different from original)
    try evm.storage.put(key, 0);

    const bytecode = [_]u8{
        // Warm the slot with SLOAD
        0x60, 0x00, // PUSH1 0
        0x54,       // SLOAD (warm the slot)
        0x50,       // POP
        // Restore to original value
        0x60, 0x03, // PUSH1 3 (original value)
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE (slot 0 = 3, restoring original)
        0x00,       // STOP
    };

    const exec_gas: u64 = 100_000;
    const total_gas: i64 = @intCast(GasConstants.TxGas + exec_gas);
    
    // Initial refund from previous dirty->clean transition
    evm.gas_refund = GasConstants.SstoreRefundGas;
    
    const result = try evm.execute(bytecode[0..], total_gas, CALLER_ADDRESS, CONTRACT_ADDRESS, @as(u256, 0), &[_]u8{});
    try std.testing.expect(result.success);

    const push_cost: u64 = 3 * GasConstants.GasFastestStep;
    const pop_cost: u64 = GasConstants.GasQuickStep;
    const sload_cost = GasConstants.ColdSloadCost + GasConstants.SloadGas;
    // SSTORE restore: warm access, restoring original clears refund
    const sstore_cost = GasConstants.SloadGas;
    const expected_left = exec_gas - (push_cost + sload_cost + pop_cost + sstore_cost);
    try std.testing.expectEqual(expected_left, result.gas_left);
    // Refund should be cleared when restoring to original
    try std.testing.expectEqual(@as(u64, 0), evm.gas_refund);
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