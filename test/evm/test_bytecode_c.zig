// ============================================================================
// BYTECODE C API TESTS - Comprehensive test suite for bytecode_c.zig
// ============================================================================

const std = @import("std");
const testing = std.testing;

// Import the C API
const bytecode_c = @import("../../src/evm/bytecode_c.zig");

test "Bytecode C API: Basic lifecycle" {
    // Test bytecode creation and destruction
    const test_bytecode = [_]u8{ 0x60, 0x2A, 0x60, 0x0A, 0x01, 0x00 }; // PUSH1 42, PUSH1 10, ADD, STOP
    
    const handle = bytecode_c.evm_bytecode_create(&test_bytecode, test_bytecode.len);
    try testing.expect(handle != null);
    defer bytecode_c.evm_bytecode_destroy(handle);
    
    // Test length retrieval
    const length = bytecode_c.evm_bytecode_get_length(handle);
    try testing.expectEqual(@as(usize, 6), length);
}

test "Bytecode C API: Data access" {
    const test_bytecode = [_]u8{ 0x60, 0x42, 0x60, 0x10, 0x01, 0x00 }; // PUSH1 0x42, PUSH1 0x10, ADD, STOP
    
    const handle = bytecode_c.evm_bytecode_create(&test_bytecode, test_bytecode.len);
    try testing.expect(handle != null);
    defer bytecode_c.evm_bytecode_destroy(handle);
    
    // Test data retrieval
    var buffer: [10]u8 = undefined;
    const copied = bytecode_c.evm_bytecode_get_data(handle, &buffer, buffer.len);
    try testing.expectEqual(@as(usize, 6), copied);
    try testing.expectEqualSlices(u8, test_bytecode[0..], buffer[0..copied]);
    
    // Test opcode access
    try testing.expectEqual(@as(u8, 0x60), bytecode_c.evm_bytecode_get_opcode_at(handle, 0)); // PUSH1
    try testing.expectEqual(@as(u8, 0x42), bytecode_c.evm_bytecode_get_opcode_at(handle, 1)); // Data
    try testing.expectEqual(@as(u8, 0x01), bytecode_c.evm_bytecode_get_opcode_at(handle, 4)); // ADD
    try testing.expectEqual(@as(u8, 0x00), bytecode_c.evm_bytecode_get_opcode_at(handle, 5)); // STOP
}

test "Bytecode C API: Jump destination detection" {
    const test_bytecode = [_]u8{ 0x60, 0x05, 0x56, 0x00, 0x5B, 0x00 }; // PUSH1 5, JUMP, STOP, JUMPDEST, STOP
    
    const handle = bytecode_c.evm_bytecode_create(&test_bytecode, test_bytecode.len);
    try testing.expect(handle != null);
    defer bytecode_c.evm_bytecode_destroy(handle);
    
    // Test jump destination detection
    try testing.expectEqual(@as(c_int, 0), bytecode_c.evm_bytecode_is_jump_dest(handle, 0)); // PUSH1
    try testing.expectEqual(@as(c_int, 0), bytecode_c.evm_bytecode_is_jump_dest(handle, 3)); // STOP
    try testing.expectEqual(@as(c_int, 1), bytecode_c.evm_bytecode_is_jump_dest(handle, 4)); // JUMPDEST
    
    // Test jump destination enumeration
    var jump_dests: [10]u32 = undefined;
    var count: u32 = 0;
    const result = bytecode_c.evm_bytecode_find_jump_dests(handle, &jump_dests, jump_dests.len, &count);
    try testing.expectEqual(bytecode_c.EVM_BYTECODE_SUCCESS, result);
    try testing.expectEqual(@as(u32, 1), count);
    try testing.expectEqual(@as(u32, 4), jump_dests[0]);
}

test "Bytecode C API: Bytecode validation" {
    const valid_bytecode = [_]u8{ 0x60, 0x42, 0x60, 0x10, 0x01, 0x00 }; // Valid opcodes
    const invalid_bytecode = [_]u8{ 0x60, 0x42, 0x0C, 0x10, 0x01, 0x00 }; // Contains invalid opcode 0x0C
    
    // Test valid bytecode
    const valid_handle = bytecode_c.evm_bytecode_create(&valid_bytecode, valid_bytecode.len);
    try testing.expect(valid_handle != null);
    defer bytecode_c.evm_bytecode_destroy(valid_handle);
    
    const valid_invalid_count = bytecode_c.evm_bytecode_count_invalid_opcodes(valid_handle);
    try testing.expectEqual(@as(u32, 0), valid_invalid_count);
    
    // Test invalid bytecode
    const invalid_handle = bytecode_c.evm_bytecode_create(&invalid_bytecode, invalid_bytecode.len);
    try testing.expect(invalid_handle != null);
    defer bytecode_c.evm_bytecode_destroy(invalid_handle);
    
    const invalid_count = bytecode_c.evm_bytecode_count_invalid_opcodes(invalid_handle);
    try testing.expectEqual(@as(u32, 1), invalid_count);
}

test "Bytecode C API: Statistics collection" {
    // Complex bytecode with various instruction types
    const complex_bytecode = [_]u8{
        0x60, 0x42,     // PUSH1 0x42
        0x60, 0x10,     // PUSH1 0x10  
        0x01,           // ADD
        0x5B,           // JUMPDEST
        0x80,           // DUP1
        0x56,           // JUMP
        0x00,           // STOP
        0xF0,           // CREATE
        0xF1,           // CALL
        0xA0,           // LOG1
    };
    
    const handle = bytecode_c.evm_bytecode_create(&complex_bytecode, complex_bytecode.len);
    try testing.expect(handle != null);
    defer bytecode_c.evm_bytecode_destroy(handle);
    
    var stats: bytecode_c.CBytecodeStats = undefined;
    const result = bytecode_c.evm_bytecode_get_stats(handle, &stats);
    try testing.expectEqual(bytecode_c.EVM_BYTECODE_SUCCESS, result);
    
    // Verify statistics
    try testing.expectEqual(@as(usize, complex_bytecode.len), stats.total_bytes);
    try testing.expect(stats.instruction_count > 0);
    try testing.expectEqual(@as(u32, 1), stats.jump_dest_count); // One JUMPDEST
    try testing.expectEqual(@as(u32, 0), stats.invalid_opcode_count); // All valid opcodes
    try testing.expectEqual(@as(u32, 2), stats.push_instruction_count); // Two PUSH1s
    try testing.expectEqual(@as(u32, 1), stats.jump_instruction_count); // One JUMP
    try testing.expectEqual(@as(u32, 1), stats.call_instruction_count); // One CALL
    try testing.expectEqual(@as(u32, 1), stats.create_instruction_count); // One CREATE
    try testing.expect(stats.complexity_score > 0);
}

test "Bytecode C API: Opcode utilities" {
    // Test opcode name resolution
    const stop_name = bytecode_c.evm_bytecode_opcode_name(0x00);
    try testing.expect(std.mem.eql(u8, std.mem.span(stop_name), "STOP"));
    
    const add_name = bytecode_c.evm_bytecode_opcode_name(0x01);
    try testing.expect(std.mem.eql(u8, std.mem.span(add_name), "ADD"));
    
    const push1_name = bytecode_c.evm_bytecode_opcode_name(0x60);
    try testing.expect(std.mem.eql(u8, std.mem.span(push1_name), "PUSH1"));
    
    const invalid_name = bytecode_c.evm_bytecode_opcode_name(0x0C);
    try testing.expect(std.mem.eql(u8, std.mem.span(invalid_name), "INVALID"));
    
    // Test opcode validation
    try testing.expectEqual(@as(c_int, 1), bytecode_c.evm_bytecode_is_valid_opcode(0x00)); // STOP
    try testing.expectEqual(@as(c_int, 1), bytecode_c.evm_bytecode_is_valid_opcode(0x01)); // ADD
    try testing.expectEqual(@as(c_int, 1), bytecode_c.evm_bytecode_is_valid_opcode(0x60)); // PUSH1
    try testing.expectEqual(@as(c_int, 0), bytecode_c.evm_bytecode_is_valid_opcode(0x0C)); // Invalid
}

test "Bytecode C API: Error handling" {
    // Test null pointer handling
    try testing.expectEqual(@as(usize, 0), bytecode_c.evm_bytecode_get_length(null));
    try testing.expectEqual(@as(u8, 0xFF), bytecode_c.evm_bytecode_get_opcode_at(null, 0));
    
    // Test invalid bytecode creation
    const empty_handle = bytecode_c.evm_bytecode_create(&[_]u8{}, 0);
    try testing.expect(empty_handle == null);
    
    const too_large = [_]u8{0x00} ** 25000; // Larger than max allowed
    const large_handle = bytecode_c.evm_bytecode_create(&too_large, too_large.len);
    try testing.expect(large_handle == null);
    
    // Test error string conversion
    const success_str = bytecode_c.evm_bytecode_error_string(bytecode_c.EVM_BYTECODE_SUCCESS);
    try testing.expect(std.mem.eql(u8, std.mem.span(success_str), "Success"));
    
    const null_ptr_str = bytecode_c.evm_bytecode_error_string(bytecode_c.EVM_BYTECODE_ERROR_NULL_POINTER);
    try testing.expect(std.mem.eql(u8, std.mem.span(null_ptr_str), "Null pointer"));
}

test "Bytecode C API: Built-in tests" {
    // Test the built-in C API tests
    try testing.expectEqual(@as(c_int, 0), bytecode_c.evm_bytecode_test_basic());
    try testing.expectEqual(@as(c_int, 0), bytecode_c.evm_bytecode_test_opcodes());
}
