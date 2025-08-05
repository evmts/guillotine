const std = @import("std");
const Frame = @import("../frame/frame.zig");
const BlockMetadata = @import("../frame/code_analysis.zig").BlockMetadata;
const ExecutionError = @import("../execution/execution_error.zig");
const Operation = @import("../opcodes/operation.zig");
const Log = @import("../log.zig");

/// Check if a block can use the fast execution path.
///
/// A block can use the fast path if it:
/// - Has no JUMP/JUMPI instructions (no control flow changes)
/// - Has no CALL/CREATE/DELEGATECALL (no external calls)
/// - Has no SSTORE (no state changes that need individual tracking)
/// - Has no dynamic gas operations
///
/// These blocks can be executed as a single batch without any
/// intermediate checks or state updates.
pub fn can_use_fast_path(
    code: []const u8,
    block_start: usize,
    block_end: usize,
) bool {
    var pc = block_start;
    while (pc < block_end and pc < code.len) {
        const opcode = code[pc];
        
        // Check for opcodes that prevent fast path
        switch (opcode) {
            // Control flow changes
            0x56, 0x57 => return false, // JUMP, JUMPI
            
            // External calls
            0xf1, 0xf2, 0xf4, 0xf5, 0xfa => return false, // CALL, CALLCODE, DELEGATECALL, STATICCALL, CREATE2
            0xf0 => return false, // CREATE
            
            // State changes with dynamic gas
            0x55 => return false, // SSTORE
            
            // Self destruct
            0xff => return false, // SELFDESTRUCT
            
            // Dynamic gas operations
            0x20, 0x31, 0x32, 0x37, 0x39, 0x3b, 0x3c, 0x3f => return false, // SHA3, BALANCE, ORIGIN, CALLDATACOPY, CODECOPY, EXTCODESIZE, EXTCODECOPY, EXTCODEHASH
            0xa0, 0xa1, 0xa2, 0xa3, 0xa4 => return false, // LOG0-LOG4
            
            else => {},
        }
        
        // Advance PC
        if (opcode >= 0x60 and opcode <= 0x7f) {
            // PUSH instruction
            const push_size = opcode - 0x60 + 1;
            pc += 1 + push_size;
        } else {
            pc += 1;
        }
    }
    
    return true;
}

/// Execute a fast-path block.
///
/// This executes all instructions in a block without any intermediate
/// validation or gas checks. This is only safe for blocks that have
/// been verified to contain no jumps, calls, or dynamic operations.
///
/// SAFETY: The block must have been validated with validate_block()
/// and verified with can_use_fast_path() before calling this function.
pub fn execute_fast_block(
    frame: *Frame,
    interpreter: Operation.Interpreter,
    table: *const @import("jump_table.zig").JumpTable,
    block_end: usize,
) ExecutionError.Error!void {
    Log.debug("execute_fast_block: Executing fast path from pc={} to pc={}", .{ frame.pc, block_end });
    
    while (frame.pc < block_end and frame.pc < frame.contract.code_size) {
        const opcode = frame.contract.get_op(frame.pc);
        const operation = table.get_operation(opcode);
        
        // Execute without any checks - block already validated
        const result = try operation.execute(frame.pc, interpreter, frame);
        
        // Update PC
        const old_pc = frame.pc;
        if (frame.pc == old_pc) {
            frame.pc += result.bytes_consumed;
        }
    }
    
    Log.debug("execute_fast_block: Fast path execution completed at pc={}", .{frame.pc});
}

test "can_use_fast_path detects simple arithmetic blocks" {
    // Simple arithmetic block: PUSH1 0x05 PUSH1 0x03 ADD
    const code = &[_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01 };
    try std.testing.expect(can_use_fast_path(code, 0, code.len));
}

test "can_use_fast_path rejects blocks with jumps" {
    // Block with JUMP: PUSH1 0x05 JUMP
    const code = &[_]u8{ 0x60, 0x05, 0x56 };
    try std.testing.expect(!can_use_fast_path(code, 0, code.len));
    
    // Block with JUMPI: PUSH1 0x05 PUSH1 0x01 JUMPI
    const code2 = &[_]u8{ 0x60, 0x05, 0x60, 0x01, 0x57 };
    try std.testing.expect(!can_use_fast_path(code2, 0, code2.len));
}

test "can_use_fast_path rejects blocks with calls" {
    // Block with CALL (simplified)
    const code = &[_]u8{ 0xf1 };
    try std.testing.expect(!can_use_fast_path(code, 0, code.len));
    
    // Block with CREATE
    const code2 = &[_]u8{ 0xf0 };
    try std.testing.expect(!can_use_fast_path(code2, 0, code2.len));
}

test "can_use_fast_path rejects blocks with state changes" {
    // Block with SSTORE: PUSH1 0x01 PUSH1 0x00 SSTORE
    const code = &[_]u8{ 0x60, 0x01, 0x60, 0x00, 0x55 };
    try std.testing.expect(!can_use_fast_path(code, 0, code.len));
}

test "can_use_fast_path accepts memory operations" {
    // Memory operations are allowed: PUSH1 0x20 PUSH1 0x00 MSTORE
    const code = &[_]u8{ 0x60, 0x20, 0x60, 0x00, 0x52 };
    try std.testing.expect(can_use_fast_path(code, 0, code.len));
    
    // MLOAD is also allowed: PUSH1 0x00 MLOAD
    const code2 = &[_]u8{ 0x60, 0x00, 0x51 };
    try std.testing.expect(can_use_fast_path(code2, 0, code2.len));
}

test "can_use_fast_path handles partial blocks" {
    // Full bytecode with multiple operations
    const code = &[_]u8{
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x02, // PUSH1 0x02
        0x01,       // ADD
        0x56,       // JUMP (at position 5)
        0x60, 0x03, // PUSH1 0x03
    };
    
    // First block (0-5) should be fast path eligible
    try std.testing.expect(can_use_fast_path(code, 0, 5));
    
    // Block containing JUMP should not be fast path eligible
    try std.testing.expect(!can_use_fast_path(code, 0, 6));
}

test "can_use_fast_path rejects dynamic gas operations" {
    // SHA3/KECCAK256
    const code1 = &[_]u8{ 0x20 };
    try std.testing.expect(!can_use_fast_path(code1, 0, code1.len));
    
    // LOG0
    const code2 = &[_]u8{ 0xa0 };
    try std.testing.expect(!can_use_fast_path(code2, 0, code2.len));
    
    // BALANCE
    const code3 = &[_]u8{ 0x31 };
    try std.testing.expect(!can_use_fast_path(code3, 0, code3.len));
}