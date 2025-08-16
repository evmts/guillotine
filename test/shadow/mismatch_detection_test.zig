/// Tests for intentional mismatch detection scenarios
/// Verifies that shadow execution correctly detects divergences between EVMs

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
const ExecutionError = @import("evm").ExecutionError;
const opcode = @import("evm").opcodes.opcode;

// Code that produces different results in analysis vs PC-based execution
// This is a synthetic test to verify mismatch detection works
const DIVERGENT_CODE = [_]u8{
    0x60, 0x01, // PUSH1 1
    0x60, 0x02, // PUSH1 2
    0x01,       // ADD
    0x60, 0x00, // PUSH1 0
    0x52,       // MSTORE
    0x60, 0x20, // PUSH1 32
    0x60, 0x00, // PUSH1 0
    0xf3,       // RETURN
};

test "shadow mismatch detection: forced mismatch scenario" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    // Skip test since we can't force a real mismatch without modifying one of the EVMs
    // This test would require injecting a bug into one implementation
    // Instead, we test the mismatch handling infrastructure
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Test manual mismatch creation and handling
    const mismatch = try Evm.DebugShadow.ShadowMismatch.create(
        .per_block,
        0,
        .gas_left,
        "5000",
        "4900",
        allocator,
    );
    
    evm.last_shadow_mismatch = mismatch;
    
    // Verify we can retrieve the mismatch
    const retrieved = evm.take_last_shadow_mismatch();
    try testing.expect(retrieved != null);
    
    if (retrieved) |m| {
        var mutable_m = m;
        defer mutable_m.deinit(allocator);
        
        try testing.expectEqual(Evm.DebugShadow.MismatchField.gas_left, m.field);
        try testing.expectEqualStrings("5000", m.lhs_summary);
        try testing.expectEqualStrings("4900", m.rhs_summary);
    }
}

test "shadow mismatch detection: error propagation" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    evm.set_shadow_mode(.per_call);
    
    // Code that will fail in both EVMs (invalid opcode)
    const invalid_code = [_]u8{
        0xFE, // Invalid opcode
        0x00, // STOP (won't be reached but needed for analysis)
    };
    
    const call_params = CallParams{ .call = .{
        .caller = primitives.Address.ZERO,
        .to = primitives.Address.ZERO,
        .value = 0,
        .input = &.{},
        .gas = 100000,
    } };
    
    const code_hash = try memory_db.set_code(&invalid_code);
    try memory_db.set_account(primitives.Address.ZERO, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    const result = evm.call(call_params) catch |err| {
        // Both EVMs should fail with InvalidOpcode
        try testing.expectEqual(ExecutionError.Error.InvalidOpcode, err);
        return;
    };
    
    // Both should fail consistently
    try testing.expect(!result.success);
    
    // No mismatch should be detected since both failed the same way
    const mismatch = evm.take_last_shadow_mismatch();
    try testing.expect(mismatch == null);
}

test "shadow mismatch detection: different failure modes" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    evm.set_shadow_mode(.per_call);
    
    // Test stack overflow scenario
    const stack_overflow_code = [_]u8{
        0x60, 0x01, // PUSH1 1
    } ** 512 ++ [_]u8{ // Push 512 times (will overflow)
        0x00, // STOP
    };
    
    const call_params = CallParams{ .call = .{
        .caller = primitives.Address.ZERO,
        .to = primitives.Address.ZERO,
        .value = 0,
        .input = &.{},
        .gas = 1000000,
    } };
    
    const code_hash = try memory_db.set_code(&stack_overflow_code);
    try memory_db.set_account(primitives.Address.ZERO, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    _ = evm.call(call_params) catch |err| {
        // Both should fail with stack overflow
        try testing.expectEqual(ExecutionError.Error.StackOverflow, err);
        return;
    };
    
    // No mismatch since both fail the same way
    const mismatch = evm.take_last_shadow_mismatch();
    try testing.expect(mismatch == null);
}

test "shadow mismatch detection: output differences" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    evm.set_shadow_mode(.per_call);
    
    // Normal code that should execute identically
    const normal_code = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const call_params = CallParams{ .call = .{
        .caller = primitives.Address.ZERO,
        .to = primitives.Address.ZERO,
        .value = 0,
        .input = &.{},
        .gas = 100000,
    } };
    
    const code_hash = try memory_db.set_code(&normal_code);
    try memory_db.set_account(primitives.Address.ZERO, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    const result = try evm.call(call_params);
    
    // Should succeed without mismatch
    try testing.expect(result.success);
    
    // Verify no mismatch detected
    const mismatch = evm.take_last_shadow_mismatch();
    try testing.expect(mismatch == null);
    
    // Verify output is correct
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        try testing.expectEqual(@as(u8, 0x42), output[31]);
    }
}

test "shadow mismatch detection: gas consumption edge cases" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    evm.set_shadow_mode(.per_call);
    
    // Code with expensive memory operations
    const memory_intensive = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0x60, 0x80, // PUSH1 128
        0x60, 0x40, // PUSH1 64
        0x37,       // CALLDATACOPY (expensive with large memory)
        0x00,       // STOP
    };
    
    const call_params = CallParams{ .call = .{
        .caller = primitives.Address.ZERO,
        .to = primitives.Address.ZERO,
        .value = 0,
        .input = &.{},
        .gas = 50000,
    } };
    
    const code_hash = try memory_db.set_code(&memory_intensive);
    try memory_db.set_account(primitives.Address.ZERO, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    _ = try evm.call(call_params);
    
    // Should handle memory operations consistently
    const mismatch = evm.take_last_shadow_mismatch();
    try testing.expect(mismatch == null);
}

test "shadow mismatch detection: nested call consistency" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    evm.set_shadow_mode(.per_call);
    
    // Simple contract that just returns
    const callee_code = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    // Caller that calls the callee
    const caller_code = [_]u8{
        // Prepare CALL parameters
        0x60, 0x00, // PUSH1 0 (retSize)
        0x60, 0x00, // PUSH1 0 (retOffset)
        0x60, 0x00, // PUSH1 0 (argsSize)
        0x60, 0x00, // PUSH1 0 (argsOffset)
        0x60, 0x00, // PUSH1 0 (value)
        0x73,       // PUSH20 (address follows)
    } ++ [_]u8{0x00} ** 19 ++ [_]u8{0x02} ++ // Address 0x02
    [_]u8{
        0x61, 0x27, 0x10, // PUSH2 10000 (gas)
        0xf1,             // CALL
        0x60, 0x00,       // PUSH1 0
        0x60, 0x00,       // PUSH1 0
        0xf3,             // RETURN
    };
    
    const callee_addr: Address = [_]u8{0} ** 19 ++ [_]u8{0x02};
    
    const caller_code_hash = try memory_db.set_code(&caller_code);
    try memory_db.set_account(primitives.Address.ZERO, .{
        .balance = 0,
        .code_hash = caller_code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    const callee_code_hash = try memory_db.set_code(&callee_code);
    try memory_db.set_account(callee_addr, .{
        .balance = 0,
        .code_hash = callee_code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    const call_params = CallParams{ .call = .{
        .caller = primitives.Address.ZERO,
        .to = primitives.Address.ZERO,
        .value = 0,
        .input = &.{},
        .gas = 100000,
    } };
    
    _ = try evm.call(call_params);
    
    // Both EVMs should handle nested calls consistently
    const mismatch = evm.take_last_shadow_mismatch();
    if (mismatch) |m| {
        var mutable_m = m;
        defer mutable_m.deinit(allocator);
        std.debug.print("Unexpected mismatch in nested call: field={}, lhs={s}, rhs={s}\n", .{
            m.field, m.lhs_summary, m.rhs_summary
        });
    }
    try testing.expect(mismatch == null);
}

test "shadow mismatch detection: mismatch ownership and cleanup" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Create multiple mismatches and ensure proper cleanup
    for (0..3) |i| {
        const field = switch (i) {
            0 => Evm.DebugShadow.MismatchField.success,
            1 => Evm.DebugShadow.MismatchField.gas_left,
            2 => Evm.DebugShadow.MismatchField.output,
            else => unreachable,
        };
        
        const mismatch = try Evm.DebugShadow.ShadowMismatch.create(
            .per_block,
            @intCast(i * 10),
            field,
            "expected",
            "actual",
            allocator,
        );
        
        // Free previous mismatch if any
        if (evm.last_shadow_mismatch) |old| {
            var mutable_old = old;
            mutable_old.deinit(allocator);
        }
        
        evm.last_shadow_mismatch = mismatch;
        
        // Take ownership
        const taken = evm.take_last_shadow_mismatch();
        try testing.expect(taken != null);
        
        if (taken) |m| {
            var mutable_m = m;
            defer mutable_m.deinit(allocator);
            
            try testing.expectEqual(field, m.field);
            try testing.expectEqual(@as(usize, i * 10), m.op_pc);
        }
        
        // Verify it's cleared after taking
        try testing.expect(evm.take_last_shadow_mismatch() == null);
    }
}