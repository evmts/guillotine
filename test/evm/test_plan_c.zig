// ============================================================================
// PLAN C API TESTS - Comprehensive test suite for plan_c.zig
// ============================================================================

const std = @import("std");
const testing = std.testing;

// Import the C API
const plan_c = @import("../../src/evm/plan_c.zig");

test "Plan C API: Basic lifecycle" {
    // Simple bytecode: PUSH1 42, PUSH1 10, ADD, STOP
    const test_bytecode = [_]u8{ 0x60, 0x2A, 0x60, 0x0A, 0x01, 0x00 };
    
    const handle = plan_c.evm_plan_create(&test_bytecode, test_bytecode.len);
    try testing.expect(handle != null);
    defer plan_c.evm_plan_destroy(handle);
    
    // Test basic properties
    const bytecode_len = plan_c.evm_plan_get_bytecode_len(handle);
    try testing.expectEqual(@as(usize, 6), bytecode_len);
    
    const instruction_count = plan_c.evm_plan_get_instruction_count(handle);
    try testing.expect(instruction_count > 0); // Should have instructions
    
    const constant_count = plan_c.evm_plan_get_constant_count(handle);
    try testing.expectEqual(@as(u32, 2), constant_count); // Two PUSH1 constants
}

test "Plan C API: Bytecode retrieval" {
    const test_bytecode = [_]u8{ 0x60, 0x42, 0x60, 0x10, 0x01, 0x00 };
    
    const handle = plan_c.evm_plan_create(&test_bytecode, test_bytecode.len);
    try testing.expect(handle != null);
    defer plan_c.evm_plan_destroy(handle);
    
    // Test bytecode retrieval
    var buffer: [10]u8 = undefined;
    const copied = plan_c.evm_plan_get_bytecode(handle, &buffer, buffer.len);
    try testing.expectEqual(@as(usize, 6), copied);
    try testing.expectEqualSlices(u8, test_bytecode[0..], buffer[0..copied]);
    
    // Test partial retrieval
    var small_buffer: [3]u8 = undefined;
    const partial_copied = plan_c.evm_plan_get_bytecode(handle, &small_buffer, small_buffer.len);
    try testing.expectEqual(@as(usize, 3), partial_copied);
    try testing.expectEqualSlices(u8, test_bytecode[0..3], small_buffer[0..]);
}

test "Plan C API: Jump destination analysis" {
    // Bytecode with JUMPDEST: PUSH1 5, JUMP, STOP, JUMPDEST, STOP
    const test_bytecode = [_]u8{ 0x60, 0x05, 0x56, 0x00, 0x5B, 0x00 };
    
    const handle = plan_c.evm_plan_create(&test_bytecode, test_bytecode.len);
    try testing.expect(handle != null);
    defer plan_c.evm_plan_destroy(handle);
    
    // Test jump destination validation
    try testing.expectEqual(@as(c_int, 0), plan_c.evm_plan_is_valid_jump_dest(handle, 0)); // PUSH1
    try testing.expectEqual(@as(c_int, 0), plan_c.evm_plan_is_valid_jump_dest(handle, 3)); // STOP
    try testing.expectEqual(@as(c_int, 1), plan_c.evm_plan_is_valid_jump_dest(handle, 4)); // JUMPDEST
    try testing.expectEqual(@as(c_int, 0), plan_c.evm_plan_is_valid_jump_dest(handle, 10)); // Out of bounds
    
    // Test PC mapping (should not be available in simplified plan)
    try testing.expectEqual(@as(c_int, 0), plan_c.evm_plan_has_pc_mapping(handle));
    
    // Test PC to instruction mapping (should fail)
    var instruction_idx: u32 = 0;
    const mapping_result = plan_c.evm_plan_pc_to_instruction(handle, 4, &instruction_idx);
    try testing.expectEqual(plan_c.EVM_PLAN_ERROR_INVALID_JUMP, mapping_result);
}

test "Plan C API: Constant access" {
    // Bytecode with different PUSH sizes
    const test_bytecode = [_]u8{
        0x60, 0x42,                     // PUSH1 0x42
        0x61, 0x01, 0x23,              // PUSH2 0x0123
        0x63, 0x01, 0x23, 0x45, 0x67,  // PUSH4 0x01234567
        0x00                            // STOP
    };
    
    const handle = plan_c.evm_plan_create(&test_bytecode, test_bytecode.len);
    try testing.expect(handle != null);
    defer plan_c.evm_plan_destroy(handle);
    
    const constant_count = plan_c.evm_plan_get_constant_count(handle);
    try testing.expectEqual(@as(u32, 3), constant_count); // Three PUSH constants
    
    // Test constant retrieval
    var constant_buffer: [32]u8 = undefined;
    
    // First constant (PUSH1 0x42)
    var result = plan_c.evm_plan_get_constant(handle, 0, &constant_buffer);
    try testing.expectEqual(plan_c.EVM_PLAN_SUCCESS, result);
    try testing.expectEqual(@as(u8, 0x42), constant_buffer[31]); // Right-aligned
    
    // Second constant (PUSH2 0x0123)
    result = plan_c.evm_plan_get_constant(handle, 1, &constant_buffer);
    try testing.expectEqual(plan_c.EVM_PLAN_SUCCESS, result);
    try testing.expectEqual(@as(u8, 0x01), constant_buffer[30]); // Right-aligned
    try testing.expectEqual(@as(u8, 0x23), constant_buffer[31]);
    
    // Third constant (PUSH4 0x01234567)
    result = plan_c.evm_plan_get_constant(handle, 2, &constant_buffer);
    try testing.expectEqual(plan_c.EVM_PLAN_SUCCESS, result);
    try testing.expectEqual(@as(u8, 0x01), constant_buffer[28]); // Right-aligned
    try testing.expectEqual(@as(u8, 0x23), constant_buffer[29]);
    try testing.expectEqual(@as(u8, 0x45), constant_buffer[30]);
    try testing.expectEqual(@as(u8, 0x67), constant_buffer[31]);
    
    // Test out-of-bounds constant access
    result = plan_c.evm_plan_get_constant(handle, 99, &constant_buffer);
    try testing.expectEqual(plan_c.EVM_PLAN_ERROR_INVALID_JUMP, result);
}

test "Plan C API: Instruction stream access" {
    const test_bytecode = [_]u8{ 0x60, 0x42, 0x01, 0x00 }; // PUSH1 0x42, ADD, STOP
    
    const handle = plan_c.evm_plan_create(&test_bytecode, test_bytecode.len);
    try testing.expect(handle != null);
    defer plan_c.evm_plan_destroy(handle);
    
    const instruction_count = plan_c.evm_plan_get_instruction_count(handle);
    try testing.expect(instruction_count >= 3); // At least PUSH1, ADD, STOP
    
    // Test instruction element access
    var element: u64 = 0;
    
    // First instruction should be PUSH1 (0x60)
    var result = plan_c.evm_plan_get_instruction_element(handle, 0, &element);
    try testing.expectEqual(plan_c.EVM_PLAN_SUCCESS, result);
    try testing.expectEqual(@as(u64, 0x60), element);
    
    // Test out-of-bounds access
    result = plan_c.evm_plan_get_instruction_element(handle, 999, &element);
    try testing.expectEqual(plan_c.EVM_PLAN_ERROR_INVALID_JUMP, result);
}

test "Plan C API: Statistics" {
    const complex_bytecode = [_]u8{
        0x60, 0x01,     // PUSH1 1
        0x60, 0x02,     // PUSH1 2
        0x01,           // ADD
        0x5B,           // JUMPDEST
        0x80,           // DUP1
        0x56,           // JUMP
        0x00,           // STOP
    };
    
    const handle = plan_c.evm_plan_create(&complex_bytecode, complex_bytecode.len);
    try testing.expect(handle != null);
    defer plan_c.evm_plan_destroy(handle);
    
    var stats: plan_c.PlanStats = undefined;
    const result = plan_c.evm_plan_get_stats(handle, &stats);
    try testing.expectEqual(plan_c.EVM_PLAN_SUCCESS, result);
    
    // Verify statistics
    try testing.expect(stats.instruction_count > 0);
    try testing.expectEqual(@as(u32, 2), stats.constant_count); // Two PUSH1 constants
    try testing.expectEqual(@as(u32, complex_bytecode.len), stats.bytecode_length);
    try testing.expectEqual(@as(c_int, 0), stats.has_pc_mapping); // Simplified plan
    try testing.expect(stats.memory_usage_bytes > 0);
}

test "Plan C API: Error handling" {
    // Test null pointer handling
    try testing.expectEqual(@as(usize, 0), plan_c.evm_plan_get_bytecode_len(null));
    try testing.expectEqual(@as(u32, 0), plan_c.evm_plan_get_instruction_count(null));
    try testing.expectEqual(@as(u32, 0), plan_c.evm_plan_get_constant_count(null));
    try testing.expectEqual(@as(c_int, 0), plan_c.evm_plan_has_pc_mapping(null));
    try testing.expectEqual(@as(c_int, 0), plan_c.evm_plan_is_valid_jump_dest(null, 0));
    
    // Test invalid plan creation
    const empty_plan = plan_c.evm_plan_create(&[_]u8{}, 0);
    try testing.expect(empty_plan == null);
    
    const too_large = [_]u8{0x00} ** 25000; // Larger than max allowed
    const large_plan = plan_c.evm_plan_create(&too_large, too_large.len);
    try testing.expect(large_plan == null);
    
    // Test error string conversion
    const success_str = plan_c.evm_plan_error_string(plan_c.EVM_PLAN_SUCCESS);
    try testing.expect(std.mem.eql(u8, std.mem.span(success_str), "Success"));
    
    const null_ptr_str = plan_c.evm_plan_error_string(plan_c.EVM_PLAN_ERROR_NULL_POINTER);
    try testing.expect(std.mem.eql(u8, std.mem.span(null_ptr_str), "Null pointer"));
    
    const invalid_str = plan_c.evm_plan_error_string(-999);
    try testing.expect(std.mem.eql(u8, std.mem.span(invalid_str), "Unknown error"));
}

test "Plan C API: Built-in test" {
    // Test the built-in C API test
    try testing.expectEqual(@as(c_int, 0), plan_c.evm_plan_test_basic());
}

test "Plan C API: Edge cases" {
    // Test plan with only STOP
    const stop_only = [_]u8{0x00};
    const stop_handle = plan_c.evm_plan_create(&stop_only, stop_only.len);
    try testing.expect(stop_handle != null);
    defer plan_c.evm_plan_destroy(stop_handle);
    
    try testing.expectEqual(@as(u32, 1), plan_c.evm_plan_get_instruction_count(stop_handle));
    try testing.expectEqual(@as(u32, 0), plan_c.evm_plan_get_constant_count(stop_handle)); // No PUSH instructions
    
    // Test plan with maximum PUSH32
    const push32_bytecode = [_]u8{0x7F} ++ [_]u8{0xFF} ** 32 ++ [_]u8{0x00}; // PUSH32 (all 0xFF) + STOP
    const push32_handle = plan_c.evm_plan_create(&push32_bytecode, push32_bytecode.len);
    try testing.expect(push32_handle != null);
    defer plan_c.evm_plan_destroy(push32_handle);
    
    try testing.expectEqual(@as(u32, 1), plan_c.evm_plan_get_constant_count(push32_handle)); // One PUSH32
    
    // Verify the PUSH32 constant
    var constant_buffer: [32]u8 = undefined;
    const result = plan_c.evm_plan_get_constant(push32_handle, 0, &constant_buffer);
    try testing.expectEqual(plan_c.EVM_PLAN_SUCCESS, result);
    try testing.expect(std.mem.eql(u8, &constant_buffer, &([_]u8{0xFF} ** 32)));
}
