const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const testing = std.testing;

test "shadow tracer: step mode switching" {
    const allocator = testing.allocator;
    
    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();
    
    const db_interface = db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    var shadow_tracer = try evm.tracing.ShadowTracer.init(
        allocator,
        &vm,
        .per_block,
        .{},
    );
    defer shadow_tracer.deinit();
    
    // Test step mode manipulation
    try testing.expectEqual(@as(@TypeOf(shadow_tracer.base.step_mode), .passive), shadow_tracer.get_step_mode());
    
    shadow_tracer.set_step_mode(.single_step);
    try testing.expectEqual(@as(@TypeOf(shadow_tracer.base.step_mode), .single_step), shadow_tracer.get_step_mode());
    
    shadow_tracer.set_step_mode(.block_step);
    try testing.expectEqual(@as(@TypeOf(shadow_tracer.base.step_mode), .block_step), shadow_tracer.get_step_mode());
    
    shadow_tracer.reset_step_mode();
    try testing.expectEqual(@as(@TypeOf(shadow_tracer.base.step_mode), .passive), shadow_tracer.get_step_mode());
}

test "shadow tracer: execution tracking reset" {
    const allocator = testing.allocator;
    
    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();
    
    const db_interface = db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    var shadow_tracer = try evm.tracing.ShadowTracer.init(
        allocator,
        &vm,
        .per_block,
        .{},
    );
    defer shadow_tracer.deinit();
    
    // Manually set some tracking values
    shadow_tracer.current_primary_step = 10;
    shadow_tracer.current_primary_block = 5;
    shadow_tracer.current_shadow_step = 8;
    shadow_tracer.current_shadow_block = 4;
    
    // Reset tracking
    shadow_tracer.reset_execution_tracking();
    
    // Verify all tracking is reset
    try testing.expectEqual(@as(usize, 0), shadow_tracer.get_primary_step());
    try testing.expectEqual(@as(usize, 0), shadow_tracer.get_primary_block());
    try testing.expectEqual(@as(usize, 0), shadow_tracer.get_shadow_step());
    try testing.expectEqual(@as(usize, 0), shadow_tracer.get_shadow_block());
    try testing.expectEqual(@as(?evm.tracing.step_types.StepTransition, null), shadow_tracer.last_transition);
}

test "shadow tracer: breakpoint management" {
    const allocator = testing.allocator;
    
    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();
    
    const db_interface = db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    var shadow_tracer = try evm.tracing.ShadowTracer.init(
        allocator,
        &vm,
        .per_block,
        .{},
    );
    defer shadow_tracer.deinit();
    
    // Add breakpoints
    try shadow_tracer.add_breakpoint(10);
    try shadow_tracer.add_breakpoint(20);
    try shadow_tracer.add_breakpoint(30);
    
    // Remove a breakpoint
    const removed = shadow_tracer.remove_breakpoint(20);
    try testing.expect(removed);
    
    // Try to remove non-existent breakpoint
    const not_removed = shadow_tracer.remove_breakpoint(25);
    try testing.expect(!not_removed);
    
    // Clear all breakpoints
    shadow_tracer.clear_breakpoints();
}

test "shadow tracer: getters work correctly" {
    const allocator = testing.allocator;
    
    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();
    
    const db_interface = db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    var shadow_tracer = try evm.tracing.ShadowTracer.init(
        allocator,
        &vm,
        .per_block,
        .{},
    );
    defer shadow_tracer.deinit();
    
    // Test initial values
    try testing.expectEqual(@as(usize, 0), shadow_tracer.get_primary_step());
    try testing.expectEqual(@as(usize, 0), shadow_tracer.get_primary_block());
    try testing.expectEqual(@as(usize, 0), shadow_tracer.get_shadow_step());
    try testing.expectEqual(@as(usize, 0), shadow_tracer.get_shadow_block());
    
    // Modify values
    shadow_tracer.current_primary_step = 5;
    shadow_tracer.current_primary_block = 2;
    shadow_tracer.current_shadow_step = 4;
    shadow_tracer.current_shadow_block = 1;
    
    // Test getters
    try testing.expectEqual(@as(usize, 5), shadow_tracer.get_primary_step());
    try testing.expectEqual(@as(usize, 2), shadow_tracer.get_primary_block());
    try testing.expectEqual(@as(usize, 4), shadow_tracer.get_shadow_step());
    try testing.expectEqual(@as(usize, 1), shadow_tracer.get_shadow_block());
}

test "shadow tracer: no mismatches initially" {
    const allocator = testing.allocator;
    
    var db = evm.MemoryDatabase.init(allocator);
    defer db.deinit();
    
    const db_interface = db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();
    
    var shadow_tracer = try evm.tracing.ShadowTracer.init(
        allocator,
        &vm,
        .per_block,
        .{},
    );
    defer shadow_tracer.deinit();
    
    // Should have no mismatches initially
    try testing.expect(!shadow_tracer.has_mismatches());
    
    // Get mismatch report
    const report = try shadow_tracer.get_mismatch_report(allocator);
    defer allocator.free(report);
    
    // Report should indicate no mismatches
    try testing.expect(std.mem.indexOf(u8, report, "All comparisons passed") != null);
}

// Note: More comprehensive stepping tests would require setting up proper
// bytecode execution contexts with valid analysis data, which is complex
// and better tested through integration tests that run actual EVM code.