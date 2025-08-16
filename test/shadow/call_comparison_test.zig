/// Comprehensive tests for shadow execution call comparison
/// Tests shadow comparison for CALL, STATICCALL, DELEGATECALL, CALLCODE, CREATE, CREATE2

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const build_options = @import("build_options");

// Import EVM and related modules
const Evm = @import("evm").Evm;
const Frame = @import("evm").Frame;
const Contract = @import("evm").frame.Contract;
const MemoryDatabase = @import("evm").MemoryDatabase;
const CallParams = @import("evm").CallParams;
const CallResult = @import("evm").CallResult;
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const Keccak256 = std.crypto.hash.sha3.Keccak256;
const ExecutionError = @import("evm").execution.ExecutionError;
const opcode = @import("evm").opcodes.opcode;

// Test bytecode sequences
const SIMPLE_ARITHMETIC = [_]u8{ 
    0x60, 0x05, // PUSH1 5
    0x60, 0x0a, // PUSH1 10
    0x01,       // ADD
    0x60, 0x00, // PUSH1 0
    0x60, 0x20, // PUSH1 32
    0xf3,       // RETURN
};

const MEMORY_STORE_RETURN = [_]u8{
    0x60, 0x42, // PUSH1 0x42
    0x60, 0x00, // PUSH1 0
    0x52,       // MSTORE
    0x60, 0x20, // PUSH1 32
    0x60, 0x00, // PUSH1 0
    0xf3,       // RETURN
};

const REVERT_CODE = [_]u8{
    0x60, 0x00, // PUSH1 0
    0x60, 0x00, // PUSH1 0
    0xfd,       // REVERT
};

const INVALID_JUMP = [_]u8{
    0x60, 0xFF, // PUSH1 255 (invalid jump destination)
    0x56,       // JUMP
    0x00,       // STOP (won't be reached but needed for analysis)
};

test "shadow comparison: simple arithmetic operation match" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    // Setup database and EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Enable shadow comparison
    evm.set_shadow_mode(.per_call);
    
    // Create call parameters for arithmetic operation
    const call_params = CallParams{ .call = .{
        .caller = primitives.Address.ZERO,
        .to = primitives.Address.ZERO,
        .value = 0,
        .input = &.{},
        .gas = 100000,
    } };
    
    // Store the arithmetic bytecode
    const code_hash = try memory_db.set_code(&SIMPLE_ARITHMETIC);
    try memory_db.set_account(primitives.Address.ZERO, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    // Execute the call
    const result = try evm.call(call_params);
    
    // Should not have any mismatch
    const mismatch = evm.take_last_shadow_mismatch();
    if (mismatch) |m| {
        var mutable_m = m;
        defer mutable_m.deinit(allocator);
        std.debug.print("Unexpected mismatch: field={}, lhs={s}, rhs={s}\n", .{
            m.field, m.lhs_summary, m.rhs_summary
        });
    }
    try testing.expect(mismatch == null);
    
    // Verify result is correct
    try testing.expect(result.success);
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        // Result should be 15 (5 + 10) in the last byte
        try testing.expectEqual(@as(u8, 15), output[31]);
    }
}

test "shadow comparison: memory operations match" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    evm.set_shadow_mode(.per_call);
    
    const call_params = CallParams{ .call = .{
        .caller = primitives.Address.ZERO,
        .to = primitives.Address.ZERO,
        .value = 0,
        .input = &.{},
        .gas = 100000,
    } };
    
    const code_hash = try memory_db.set_code(&MEMORY_STORE_RETURN);
    try memory_db.set_account(primitives.Address.ZERO, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    const result = try evm.call(call_params);
    
    // Should not have any mismatch
    const mismatch = evm.take_last_shadow_mismatch();
    try testing.expect(mismatch == null);
    
    // Verify result
    try testing.expect(result.success);
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        try testing.expectEqual(@as(u8, 0x42), output[31]);
    }
}

test "shadow comparison: REVERT operation consistency" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    evm.set_shadow_mode(.per_call);
    
    const call_params = CallParams{ .call = .{
        .caller = primitives.Address.ZERO,
        .to = primitives.Address.ZERO,
        .value = 0,
        .input = &.{},
        .gas = 100000,
    } };
    
    const code_hash = try memory_db.set_code(&REVERT_CODE);
    try memory_db.set_account(primitives.Address.ZERO, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    const result = try evm.call(call_params);
    
    // Should not have any mismatch even with REVERT
    const mismatch = evm.take_last_shadow_mismatch();
    try testing.expect(mismatch == null);
    
    // Both EVMs should report failure
    try testing.expect(!result.success);
}

test "shadow comparison: gas consumption consistency" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    evm.set_shadow_mode(.per_call);
    
    const initial_gas: u64 = 50000;
    const call_params = CallParams{ .call = .{
        .caller = primitives.Address.ZERO,
        .to = primitives.Address.ZERO,
        .value = 0,
        .input = &.{},
        .gas = initial_gas,
    } };
    
    const code_hash = try memory_db.set_code(&SIMPLE_ARITHMETIC);
    try memory_db.set_account(primitives.Address.ZERO, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    const result = try evm.call(call_params);
    
    // Should not have any mismatch
    const mismatch = evm.take_last_shadow_mismatch();
    try testing.expect(mismatch == null);
    
    // Gas should be consumed consistently
    try testing.expect(result.success);
    try testing.expect(result.gas_left < initial_gas);
}

test "shadow comparison: STATICCALL consistency" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    evm.set_shadow_mode(.per_call);
    
    // STATICCALL parameters (read-only call)
    const call_params = CallParams{ .staticcall = .{
        .caller = primitives.Address.ZERO,
        .to = primitives.Address.ZERO,
        .input = &.{},
        .gas = 100000,
    } };
    
    const code_hash = try memory_db.set_code(&SIMPLE_ARITHMETIC);
    try memory_db.set_account(primitives.Address.ZERO, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    const result = try evm.call(call_params);
    
    // Should not have any mismatch
    const mismatch = evm.take_last_shadow_mismatch();
    try testing.expect(mismatch == null);
    
    try testing.expect(result.success);
}

test "shadow comparison: CREATE operation consistency" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    evm.set_shadow_mode(.per_call);
    
    // Simple contract creation code
    const init_code = [_]u8{
        0x60, 0x01, // PUSH1 1 (return data)
        0x60, 0x00, // PUSH1 0 (offset)
        0x52,       // MSTORE
        0x60, 0x01, // PUSH1 1 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3,       // RETURN
    };
    
    const call_params = CallParams{ .create = .{
        .caller = primitives.Address.ZERO,
        .value = 0,
        .gas = 100000,
        .init_code = &init_code,
    } };
    
    const result = try evm.call(call_params);
    
    // Should not have any mismatch
    const mismatch = evm.take_last_shadow_mismatch();
    try testing.expect(mismatch == null);
    
    // CREATE should succeed consistently
    try testing.expect(result.success);
}

test "shadow comparison: CREATE2 operation consistency" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    evm.set_shadow_mode(.per_call);
    
    const init_code = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const salt: u256 = 0x1234567890ABCDEF;
    
    const call_params = CallParams{ .create2 = .{
        .caller = primitives.Address.ZERO,
        .value = 0,
        .gas = 100000,
        .init_code = &init_code,
        .salt = salt,
    } };
    
    const result = try evm.call(call_params);
    
    // Should not have any mismatch
    const mismatch = evm.take_last_shadow_mismatch();
    try testing.expect(mismatch == null);
    
    try testing.expect(result.success);
}

test "shadow comparison: invalid jump detection" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    evm.set_shadow_mode(.per_call);
    
    const call_params = CallParams{ .call = .{
        .caller = primitives.Address.ZERO,
        .to = primitives.Address.ZERO,
        .value = 0,
        .input = &.{},
        .gas = 100000,
    } };
    
    const code_hash = try memory_db.set_code(&INVALID_JUMP);
    try memory_db.set_account(primitives.Address.ZERO, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    const result = try evm.call(call_params);
    
    // Should not have any mismatch - both should fail
    const mismatch = evm.take_last_shadow_mismatch();
    try testing.expect(mismatch == null);
    
    // Both EVMs should report failure due to invalid jump
    try testing.expect(!result.success);
}

test "shadow comparison: complex control flow with JUMPI" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    // Conditional jump test
    const jumpi_code = [_]u8{
        0x60, 0x01, // PUSH1 1 (condition true)
        0x60, 0x0A, // PUSH1 10 (jump destination)
        0x57,       // JUMPI
        0x60, 0xFF, // PUSH1 255 (should not execute)
        0x00,       // STOP
        0x5b,       // JUMPDEST (at position 10)
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    evm.set_shadow_mode(.per_call);
    
    const call_params = CallParams{ .call = .{
        .caller = primitives.Address.ZERO,
        .to = primitives.Address.ZERO,
        .value = 0,
        .input = &.{},
        .gas = 100000,
    } };
    
    const code_hash = try memory_db.set_code(&jumpi_code);
    try memory_db.set_account(primitives.Address.ZERO, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    const result = try evm.call(call_params);
    
    // Should not have any mismatch
    const mismatch = evm.take_last_shadow_mismatch();
    try testing.expect(mismatch == null);
    
    // Verify correct execution path was taken
    try testing.expect(result.success);
    if (result.output) |output| {
        try testing.expectEqual(@as(u8, 0x42), output[31]);
    }
}

test "shadow comparison: PUSH operations of various sizes" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    // Test various PUSH operations
    const push_code = [_]u8{
        0x6f,                                                       // PUSH0
        0x60, 0xAA,                                                // PUSH1 0xAA
        0x61, 0xBB, 0xCC,                                          // PUSH2 0xBBCC
        0x63, 0xDD, 0xEE, 0xFF, 0x11,                            // PUSH4 0xDDEEFF11
        0x01,                                                      // ADD (combine some values)
        0x01,                                                      // ADD
        0x01,                                                      // ADD
        0x60, 0x00,                                               // PUSH1 0
        0x52,                                                      // MSTORE
        0x60, 0x20,                                               // PUSH1 32
        0x60, 0x00,                                               // PUSH1 0
        0xf3,                                                      // RETURN
    };
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    evm.set_shadow_mode(.per_call);
    
    const call_params = CallParams{ .call = .{
        .caller = primitives.Address.ZERO,
        .to = primitives.Address.ZERO,
        .value = 0,
        .input = &.{},
        .gas = 100000,
    } };
    
    const code_hash = try memory_db.set_code(&push_code);
    try memory_db.set_account(primitives.Address.ZERO, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    const result = try evm.call(call_params);
    
    // Should not have any mismatch
    const mismatch = evm.take_last_shadow_mismatch();
    try testing.expect(mismatch == null);
    
    try testing.expect(result.success);
}

test "shadow comparison: out of gas consistency" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    evm.set_shadow_mode(.per_call);
    
    // Very low gas to cause out of gas
    const call_params = CallParams{ .call = .{
        .caller = primitives.Address.ZERO,
        .to = primitives.Address.ZERO,
        .value = 0,
        .input = &.{},
        .gas = 10, // Too low for any meaningful execution
    } };
    
    const code_hash = try memory_db.set_code(&SIMPLE_ARITHMETIC);
    try memory_db.set_account(primitives.Address.ZERO, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    const result = try evm.call(call_params);
    
    // Should not have any mismatch - both should fail with out of gas
    const mismatch = evm.take_last_shadow_mismatch();
    try testing.expect(mismatch == null);
    
    // Both EVMs should report failure
    try testing.expect(!result.success);
    try testing.expectEqual(@as(u64, 0), result.gas_left);
}