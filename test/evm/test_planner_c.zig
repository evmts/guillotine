// ============================================================================
// PLANNER C API TESTS - Comprehensive test suite for planner_c.zig
// ============================================================================

const std = @import("std");
const testing = std.testing;

// Import the C API
const planner_c = @import("../../src/evm/planner_c.zig");

test "Planner C API: Basic lifecycle" {
    // Create planner
    const planner_handle = planner_c.evm_planner_create();
    try testing.expect(planner_handle != null);
    defer planner_c.evm_planner_destroy(planner_handle);
    
    // Basic functionality test - should not crash
    // The simplified planner is mainly for API compatibility
}

test "Planner C API: Plan creation and destruction" {
    const planner_handle = planner_c.evm_planner_create();
    try testing.expect(planner_handle != null);
    defer planner_c.evm_planner_destroy(planner_handle);
    
    // Simple bytecode: PUSH1 42, PUSH1 10, ADD, STOP
    const test_bytecode = [_]u8{ 0x60, 0x2A, 0x60, 0x0A, 0x01, 0x00 };
    
    // Create plan
    const plan_handle = planner_c.evm_planner_plan_bytecode(planner_handle, &test_bytecode, test_bytecode.len);
    try testing.expect(plan_handle != null);
    defer planner_c.evm_planner_plan_destroy(plan_handle);
    
    // Test plan properties
    const instruction_count = planner_c.evm_planner_plan_get_instruction_count(plan_handle);
    try testing.expect(instruction_count > 0); // Should have some instructions
    
    const constant_count = planner_c.evm_planner_plan_get_constant_count(plan_handle);
    try testing.expectEqual(@as(u32, 2), constant_count); // Two PUSH1 constants
    
    // Test PC mapping (should not be available in simplified planner)
    try testing.expectEqual(@as(c_int, 0), planner_c.evm_planner_plan_has_pc_mapping(plan_handle));
}

test "Planner C API: Invalid bytecode handling" {
    const planner_handle = planner_c.evm_planner_create();
    try testing.expect(planner_handle != null);
    defer planner_c.evm_planner_destroy(planner_handle);
    
    // Test empty bytecode
    const empty_plan = planner_c.evm_planner_plan_bytecode(planner_handle, &[_]u8{}, 0);
    try testing.expect(empty_plan == null);
    
    // Test oversized bytecode
    const oversized = [_]u8{0x00} ** 25000;
    const oversized_plan = planner_c.evm_planner_plan_bytecode(planner_handle, &oversized, oversized.len);
    try testing.expect(oversized_plan == null);
    
    // Test null planner
    const null_plan = planner_c.evm_planner_plan_bytecode(null, &[_]u8{0x00}, 1);
    try testing.expect(null_plan == null);
}

test "Planner C API: Jump destination analysis" {
    const planner_handle = planner_c.evm_planner_create();
    try testing.expect(planner_handle != null);
    defer planner_c.evm_planner_destroy(planner_handle);
    
    // Bytecode with JUMPDEST
    const jump_bytecode = [_]u8{ 0x60, 0x05, 0x56, 0x00, 0x5B, 0x00 }; // PUSH1 5, JUMP, STOP, JUMPDEST, STOP
    
    const plan_handle = planner_c.evm_planner_plan_bytecode(planner_handle, &jump_bytecode, jump_bytecode.len);
    try testing.expect(plan_handle != null);
    defer planner_c.evm_planner_plan_destroy(plan_handle);
    
    // Test jump destination validation
    try testing.expectEqual(@as(c_int, 0), planner_c.evm_planner_plan_is_valid_jump_dest(plan_handle, 0)); // PUSH1
    try testing.expectEqual(@as(c_int, 1), planner_c.evm_planner_plan_is_valid_jump_dest(plan_handle, 4)); // JUMPDEST
    try testing.expectEqual(@as(c_int, 0), planner_c.evm_planner_plan_is_valid_jump_dest(plan_handle, 10)); // Out of bounds
}

test "Planner C API: Cache operations (simplified)" {
    const planner_handle = planner_c.evm_planner_create();
    try testing.expect(planner_handle != null);
    defer planner_c.evm_planner_destroy(planner_handle);
    
    const test_bytecode = [_]u8{ 0x60, 0x01, 0x00 }; // PUSH1 1, STOP
    
    // Test cache checking (should always return 0 in simplified version)
    try testing.expectEqual(@as(c_int, 0), planner_c.evm_planner_has_cached_plan(planner_handle, &test_bytecode, test_bytecode.len));
    
    // Test cached plan retrieval (should always return null in simplified version)
    const cached_plan = planner_c.evm_planner_get_cached_plan(planner_handle, &test_bytecode, test_bytecode.len);
    try testing.expect(cached_plan == null);
    
    // Test cache clearing (should succeed but do nothing)
    try testing.expectEqual(planner_c.EVM_PLANNER_SUCCESS, planner_c.evm_planner_clear_cache(planner_handle));
}

test "Planner C API: Cache statistics" {
    const planner_handle = planner_c.evm_planner_create();
    try testing.expect(planner_handle != null);
    defer planner_c.evm_planner_destroy(planner_handle);
    
    var hits: u64 = 999;
    var misses: u64 = 999;
    var size: u32 = 999;
    var capacity: u32 = 999;
    
    const result = planner_c.evm_planner_get_cache_stats(planner_handle, &hits, &misses, &size, &capacity);
    try testing.expectEqual(planner_c.EVM_PLANNER_SUCCESS, result);
    
    // In simplified version, should return zero values except capacity
    try testing.expectEqual(@as(u64, 0), hits);
    try testing.expectEqual(@as(u64, 0), misses);
    try testing.expectEqual(@as(u32, 0), size);
    try testing.expectEqual(@as(u32, 256), capacity); // Fixed capacity
    
    // Test with null outputs (should not crash)
    const null_result = planner_c.evm_planner_get_cache_stats(planner_handle, null, null, null, null);
    try testing.expectEqual(planner_c.EVM_PLANNER_SUCCESS, null_result);
}

test "Planner C API: Error handling" {
    // Test null pointer handling
    try testing.expectEqual(@as(c_int, 0), planner_c.evm_planner_has_cached_plan(null, &[_]u8{0x00}, 1));
    try testing.expect(planner_c.evm_planner_get_cached_plan(null, &[_]u8{0x00}, 1) == null);
    try testing.expectEqual(planner_c.EVM_PLANNER_ERROR_NULL_POINTER, planner_c.evm_planner_clear_cache(null));
    
    // Test cache stats with null planner
    var dummy: u64 = 0;
    try testing.expectEqual(planner_c.EVM_PLANNER_ERROR_NULL_POINTER, 
                           planner_c.evm_planner_get_cache_stats(null, &dummy, &dummy, null, null));
    
    // Test error string conversion
    const success_str = planner_c.evm_planner_error_string(planner_c.EVM_PLANNER_SUCCESS);
    try testing.expect(std.mem.eql(u8, std.mem.span(success_str), "Success"));
    
    const null_ptr_str = planner_c.evm_planner_error_string(planner_c.EVM_PLANNER_ERROR_NULL_POINTER);
    try testing.expect(std.mem.eql(u8, std.mem.span(null_ptr_str), "Null pointer"));
    
    const unknown_str = planner_c.evm_planner_error_string(-999);
    try testing.expect(std.mem.eql(u8, std.mem.span(unknown_str), "Unknown error"));
}

test "Planner C API: Multiple plans" {
    const planner_handle = planner_c.evm_planner_create();
    try testing.expect(planner_handle != null);
    defer planner_c.evm_planner_destroy(planner_handle);
    
    // Create multiple plans with different bytecode
    const bytecode1 = [_]u8{ 0x60, 0x01, 0x00 }; // PUSH1 1, STOP
    const bytecode2 = [_]u8{ 0x60, 0x02, 0x00 }; // PUSH1 2, STOP
    const bytecode3 = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 }; // PUSH1 1, PUSH1 2, ADD, STOP
    
    const plan1 = planner_c.evm_planner_plan_bytecode(planner_handle, &bytecode1, bytecode1.len);
    try testing.expect(plan1 != null);
    defer planner_c.evm_planner_plan_destroy(plan1);
    
    const plan2 = planner_c.evm_planner_plan_bytecode(planner_handle, &bytecode2, bytecode2.len);
    try testing.expect(plan2 != null);
    defer planner_c.evm_planner_plan_destroy(plan2);
    
    const plan3 = planner_c.evm_planner_plan_bytecode(planner_handle, &bytecode3, bytecode3.len);
    try testing.expect(plan3 != null);
    defer planner_c.evm_planner_plan_destroy(plan3);
    
    // Verify each plan has different properties
    try testing.expectEqual(@as(u32, 1), planner_c.evm_planner_plan_get_constant_count(plan1)); // One PUSH1
    try testing.expectEqual(@as(u32, 1), planner_c.evm_planner_plan_get_constant_count(plan2)); // One PUSH1
    try testing.expectEqual(@as(u32, 2), planner_c.evm_planner_plan_get_constant_count(plan3)); // Two PUSH1s
}

test "Planner C API: Plan destruction with null" {
    // Test that destroying null plans doesn't crash
    planner_c.evm_planner_plan_destroy(null); // Should not crash
    planner_c.evm_planner_destroy(null); // Should not crash
}

test "Planner C API: Built-in test" {
    // Test the built-in C API test
    try testing.expectEqual(@as(c_int, 0), planner_c.evm_planner_test_basic());
}

test "Planner C API: Edge case bytecode" {
    const planner_handle = planner_c.evm_planner_create();
    try testing.expect(planner_handle != null);
    defer planner_c.evm_planner_destroy(planner_handle);
    
    // Test with just STOP
    const stop_only = [_]u8{0x00};
    const stop_plan = planner_c.evm_planner_plan_bytecode(planner_handle, &stop_only, stop_only.len);
    try testing.expect(stop_plan != null);
    defer planner_c.evm_planner_plan_destroy(stop_plan);
    
    try testing.expectEqual(@as(u32, 1), planner_c.evm_planner_plan_get_instruction_count(stop_plan));
    try testing.expectEqual(@as(u32, 0), planner_c.evm_planner_plan_get_constant_count(stop_plan));
    
    // Test with maximum size PUSH32
    const push32_data = [_]u8{0xFF} ** 32;
    const push32_bytecode = [_]u8{0x7F} ++ push32_data ++ [_]u8{0x00}; // PUSH32 + data + STOP
    
    const push32_plan = planner_c.evm_planner_plan_bytecode(planner_handle, &push32_bytecode, push32_bytecode.len);
    try testing.expect(push32_plan != null);
    defer planner_c.evm_planner_plan_destroy(push32_plan);
    
    try testing.expectEqual(@as(u32, 1), planner_c.evm_planner_plan_get_constant_count(push32_plan)); // One PUSH32
    
    // Test with mixed PUSH sizes
    const mixed_pushes = [_]u8{
        0x60, 0x01,                     // PUSH1 0x01
        0x61, 0x02, 0x03,              // PUSH2 0x0203
        0x62, 0x04, 0x05, 0x06,        // PUSH3 0x040506
        0x00                            // STOP
    };
    
    const mixed_plan = planner_c.evm_planner_plan_bytecode(planner_handle, &mixed_pushes, mixed_pushes.len);
    try testing.expect(mixed_plan != null);
    defer planner_c.evm_planner_plan_destroy(mixed_plan);
    
    try testing.expectEqual(@as(u32, 3), planner_c.evm_planner_plan_get_constant_count(mixed_plan)); // Three PUSH instructions
}
