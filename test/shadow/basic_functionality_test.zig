/// Comprehensive tests for shadow execution basic functionality
/// Tests shadow mode configuration, mismatch creation/cleanup, and API methods

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const build_options = @import("build_options");

// Import EVM and related modules
const Evm = @import("evm").Evm;
const MemoryDatabase = @import("evm").MemoryDatabase;
const CallParams = @import("evm").CallParams;
const CallResult = @import("evm").CallResult;
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const ExecutionError = @import("evm").execution.ExecutionError;

// Test utility function to create a basic EVM instance
fn createTestEvm(allocator: std.mem.Allocator) !*Evm {
    var memory_db = MemoryDatabase.init(allocator);
    const db_interface = memory_db.to_database_interface();
    const evm = try allocator.create(Evm);
    evm.* = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    return evm;
}

// Test utility function to destroy test EVM
fn destroyTestEvm(allocator: std.mem.Allocator, evm: *Evm) void {
    evm.deinit();
    allocator.destroy(evm);
}

test "shadow mode configuration - set and check modes" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        // Skip test if shadow comparison is not enabled
        return;
    }
    
    const allocator = testing.allocator;
    const evm = try createTestEvm(allocator);
    defer destroyTestEvm(allocator, evm);
    
    // Default mode should be off
    try testing.expectEqual(Evm.DebugShadow.ShadowMode.off, evm.shadow_mode);
    try testing.expect(!evm.is_shadow_enabled());
    
    // Test setting per_call mode
    evm.set_shadow_mode(.per_call);
    if (builtin.mode == .Debug) {
        try testing.expectEqual(Evm.DebugShadow.ShadowMode.per_call, evm.shadow_mode);
        try testing.expect(evm.is_shadow_enabled());
    } else if (builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall) {
        // Should be forced to off in release modes
        try testing.expectEqual(Evm.DebugShadow.ShadowMode.off, evm.shadow_mode);
        try testing.expect(!evm.is_shadow_enabled());
    }
    
    // Test setting per_block mode
    evm.set_shadow_mode(.per_block);
    if (builtin.mode == .Debug) {
        try testing.expectEqual(Evm.DebugShadow.ShadowMode.per_block, evm.shadow_mode);
        try testing.expect(evm.is_shadow_enabled());
    } else if (builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall) {
        // Should be forced to off in release modes
        try testing.expectEqual(Evm.DebugShadow.ShadowMode.off, evm.shadow_mode);
        try testing.expect(!evm.is_shadow_enabled());
    }
    
    // Test disabling shadow mode
    evm.set_shadow_mode(.off);
    try testing.expectEqual(Evm.DebugShadow.ShadowMode.off, evm.shadow_mode);
    try testing.expect(!evm.is_shadow_enabled());
}

test "shadow mismatch ownership transfer" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    const evm = try createTestEvm(allocator);
    defer destroyTestEvm(allocator, evm);
    
    // Initially no mismatch
    try testing.expect(evm.take_last_shadow_mismatch() == null);
    
    // Create a mismatch manually for testing
    const mismatch = try Evm.DebugShadow.ShadowMismatch.create(
        .per_call,
        0,
        .success,
        "true",
        "false",
        allocator,
    );
    
    // Store mismatch in EVM
    evm.last_shadow_mismatch = mismatch;
    
    // Take ownership of mismatch
    const taken_mismatch = evm.take_last_shadow_mismatch();
    try testing.expect(taken_mismatch != null);
    if (taken_mismatch) |m| {
        var mutable_m = m;
        defer mutable_m.deinit(allocator);
        
        try testing.expectEqual(Evm.DebugShadow.MismatchContext.per_call, m.context);
        try testing.expectEqual(Evm.DebugShadow.MismatchField.success, m.field);
        try testing.expectEqualStrings("true", m.lhs_summary);
        try testing.expectEqualStrings("false", m.rhs_summary);
    }
    
    // Subsequent take should return null
    try testing.expect(evm.take_last_shadow_mismatch() == null);
}

test "shadow configuration persistence across resets" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    const evm = try createTestEvm(allocator);
    defer destroyTestEvm(allocator, evm);
    
    // Set shadow mode
    evm.set_shadow_mode(.per_call);
    const mode_before = evm.shadow_mode;
    
    // Reset EVM
    evm.reset();
    
    // Shadow mode should persist across reset
    try testing.expectEqual(mode_before, evm.shadow_mode);
}

test "shadow mismatch cleanup on EVM deinit" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    // Create EVM and mismatch
    const evm = try createTestEvm(allocator);
    
    // Create a mismatch that will be owned by EVM
    const mismatch = try Evm.DebugShadow.ShadowMismatch.create(
        .per_call,
        0,
        .gas_left,
        "1000",
        "500",
        allocator,
    );
    
    evm.last_shadow_mismatch = mismatch;
    
    // Deinit should clean up the mismatch without leaking
    destroyTestEvm(allocator, evm);
    
    // If we get here without assertion failures, cleanup worked
    try testing.expect(true);
}

test "shadow config default values" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    const evm = try createTestEvm(allocator);
    defer destroyTestEvm(allocator, evm);
    
    // Check default configuration values
    try testing.expectEqual(@as(usize, 64), evm.shadow_cfg.stack_compare_limit);
    try testing.expectEqual(@as(usize, 256), evm.shadow_cfg.max_memory_compare);
    try testing.expectEqual(@as(usize, 128), evm.shadow_cfg.max_summary_length);
    try testing.expectEqual(false, evm.shadow_cfg.compare_memory_content);
    try testing.expectEqual(true, evm.shadow_cfg.fail_fast);
}

test "shadow mode in different build modes" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    const evm = try createTestEvm(allocator);
    defer destroyTestEvm(allocator, evm);
    
    // Test behavior based on build mode
    evm.set_shadow_mode(.per_call);
    
    switch (builtin.mode) {
        .Debug => {
            // Shadow should be enabled in debug mode
            try testing.expect(evm.is_shadow_enabled());
            try testing.expectEqual(Evm.DebugShadow.ShadowMode.per_call, evm.shadow_mode);
        },
        .ReleaseFast, .ReleaseSmall => {
            // Shadow should be forced off in release modes
            try testing.expect(!evm.is_shadow_enabled());
            try testing.expectEqual(Evm.DebugShadow.ShadowMode.off, evm.shadow_mode);
        },
        .ReleaseSafe => {
            // ReleaseSafe should allow shadow mode
            if (comptime builtin.mode == .ReleaseSafe) {
                try testing.expect(evm.is_shadow_enabled());
                try testing.expectEqual(Evm.DebugShadow.ShadowMode.per_call, evm.shadow_mode);
            }
        },
    }
}

test "shadow mismatch creation with long summaries" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    // Create very long summary strings
    const long_string = "x" ** 200; // 200 character string
    
    var mismatch = try Evm.DebugShadow.ShadowMismatch.create(
        .per_block,
        42,
        .output,
        long_string,
        long_string,
        allocator,
    );
    defer mismatch.deinit(allocator);
    
    // Summaries should be truncated to max_summary_length (128)
    try testing.expect(mismatch.lhs_summary.len <= 128);
    try testing.expect(mismatch.rhs_summary.len <= 128);
    try testing.expectEqual(@as(usize, 42), mismatch.op_pc);
}

test "shadow mismatch with diff index and count" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var mismatch = try Evm.DebugShadow.ShadowMismatch.create(
        .per_call,
        0,
        .output,
        "diff@5: 0xAA",
        "diff@5: 0xBB",
        allocator,
    );
    defer mismatch.deinit(allocator);
    
    // Set optional diff information
    mismatch.diff_index = 5;
    mismatch.diff_count = 1;
    
    try testing.expectEqual(@as(?usize, 5), mismatch.diff_index);
    try testing.expectEqual(@as(?usize, 1), mismatch.diff_count);
}

test "shadow API when disabled at build time" {
    if (comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        // Skip this test when shadow is enabled
        return;
    }
    
    const allocator = testing.allocator;
    const evm = try createTestEvm(allocator);
    defer destroyTestEvm(allocator, evm);
    
    // When disabled at build time, all operations should be no-ops
    evm.set_shadow_mode(.per_call);
    try testing.expect(!evm.is_shadow_enabled());
    try testing.expectEqual(Evm.DebugShadow.ShadowMode.off, evm.shadow_mode);
    
    // take_last_shadow_mismatch should always return null
    try testing.expect(evm.take_last_shadow_mismatch() == null);
}