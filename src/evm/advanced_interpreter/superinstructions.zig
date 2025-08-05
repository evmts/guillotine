/// Superinstruction definitions and patterns for the advanced interpreter.
///
/// This module defines common opcode sequences that can be fused into single
/// superinstructions for improved performance. By combining multiple operations
/// into a single function call, we reduce dispatch overhead and improve cache
/// locality.

const std = @import("std");
const opcode = @import("../opcodes/opcode.zig");
const instruction_stream = @import("instruction_stream.zig");
const ExecutionError = @import("../execution/execution_error.zig");
// Removed u256 alias - use the built-in u256 type directly

const Instruction = instruction_stream.Instruction;
const InstructionFn = instruction_stream.InstructionFn;
const InstructionArg = instruction_stream.InstructionArg;
const AdvancedExecutionState = instruction_stream.AdvancedExecutionState;

/// Superinstruction opcodes (using unused opcode space 0xF0-0xFE)
pub const SuperOpcode = enum(u8) {
    /// PUSH + PUSH + ADD
    PUSH_PUSH_ADD = 0xF0,
    /// PUSH + PUSH + SUB
    PUSH_PUSH_SUB = 0xF1,
    /// PUSH + PUSH + MUL
    PUSH_PUSH_MUL = 0xF2,
    /// PUSH + PUSH + DIV
    PUSH_PUSH_DIV = 0xF3,
    /// PUSH + PUSH + EQ
    PUSH_PUSH_EQ = 0xF4,
    /// PUSH + PUSH + LT
    PUSH_PUSH_LT = 0xF5,
    /// PUSH + PUSH + GT
    PUSH_PUSH_GT = 0xF6,
    /// DUP + PUSH + EQ
    DUP_PUSH_EQ = 0xF7,
    /// PUSH + MLOAD
    PUSH_MLOAD = 0xF8,
    /// PUSH + MSTORE
    PUSH_MSTORE = 0xF9,
    /// ISZERO + PUSH + JUMPI
    ISZERO_PUSH_JUMPI = 0xFA,
    /// DUP + ISZERO
    DUP_ISZERO = 0xFB,
    /// PUSH + PUSH + AND
    PUSH_PUSH_AND = 0xFC,
};

/// Pattern for detecting superinstructions
pub const Pattern = struct {
    /// Opcodes that make up this pattern
    opcodes: []const opcode.Enum,
    /// Superinstruction to emit
    super_op: SuperOpcode,
    /// Function to execute this superinstruction
    fn_ptr: InstructionFn,
    /// Whether pattern requires specific conditions (e.g., small push values)
    validator: ?*const fn (bytecode: []const u8, pc: usize) bool = null,
};

/// All supported superinstruction patterns
pub const PATTERNS = [_]Pattern{
    // Arithmetic patterns
    Pattern{
        .opcodes = &[_]opcode.Enum{ .PUSH1, .PUSH1, .ADD },
        .super_op = .PUSH_PUSH_ADD,
        .fn_ptr = &op_push_push_add,
    },
    Pattern{
        .opcodes = &[_]opcode.Enum{ .PUSH1, .PUSH1, .SUB },
        .super_op = .PUSH_PUSH_SUB,
        .fn_ptr = &op_push_push_sub,
    },
    Pattern{
        .opcodes = &[_]opcode.Enum{ .PUSH1, .PUSH1, .MUL },
        .super_op = .PUSH_PUSH_MUL,
        .fn_ptr = &op_push_push_mul,
    },
    Pattern{
        .opcodes = &[_]opcode.Enum{ .PUSH1, .PUSH1, .DIV },
        .super_op = .PUSH_PUSH_DIV,
        .fn_ptr = &op_push_push_div,
    },
    // Comparison patterns
    Pattern{
        .opcodes = &[_]opcode.Enum{ .PUSH1, .PUSH1, .EQ },
        .super_op = .PUSH_PUSH_EQ,
        .fn_ptr = &op_push_push_eq,
    },
    Pattern{
        .opcodes = &[_]opcode.Enum{ .PUSH1, .PUSH1, .LT },
        .super_op = .PUSH_PUSH_LT,
        .fn_ptr = &op_push_push_lt,
    },
    Pattern{
        .opcodes = &[_]opcode.Enum{ .PUSH1, .PUSH1, .GT },
        .super_op = .PUSH_PUSH_GT,
        .fn_ptr = &op_push_push_gt,
    },
    // DUP patterns
    Pattern{
        .opcodes = &[_]opcode.Enum{ .DUP1, .PUSH1, .EQ },
        .super_op = .DUP_PUSH_EQ,
        .fn_ptr = &op_dup_push_eq,
    },
    // Memory patterns
    Pattern{
        .opcodes = &[_]opcode.Enum{ .PUSH1, .MLOAD },
        .super_op = .PUSH_MLOAD,
        .fn_ptr = &op_push_mload,
    },
    Pattern{
        .opcodes = &[_]opcode.Enum{ .PUSH1, .MSTORE },
        .super_op = .PUSH_MSTORE,
        .fn_ptr = &op_push_mstore,
    },
    // Control flow patterns
    Pattern{
        .opcodes = &[_]opcode.Enum{ .ISZERO, .PUSH2, .JUMPI },
        .super_op = .ISZERO_PUSH_JUMPI,
        .fn_ptr = &op_iszero_push_jumpi,
    },
    // Stack patterns
    Pattern{
        .opcodes = &[_]opcode.Enum{ .DUP1, .ISZERO },
        .super_op = .DUP_ISZERO,
        .fn_ptr = &op_dup_iszero,
    },
    // Bitwise patterns
    Pattern{
        .opcodes = &[_]opcode.Enum{ .PUSH1, .PUSH1, .AND },
        .super_op = .PUSH_PUSH_AND,
        .fn_ptr = &op_push_push_and,
    },
};

/// Try to match a superinstruction pattern at the given PC
pub fn match_pattern(bytecode: []const u8, pc: usize) ?struct { pattern: Pattern, length: usize } {
    for (PATTERNS) |pattern| {
        if (matches_at(bytecode, pc, pattern)) {
            // Calculate total length of matched opcodes
            var length: usize = 0;
            var pos = pc;
            for (pattern.opcodes) |op| {
                const op_byte = @intFromEnum(op);
                length += get_opcode_size(op_byte, bytecode, pos);
                pos += get_opcode_size(op_byte, bytecode, pos);
            }
            return .{ .pattern = pattern, .length = length };
        }
    }
    return null;
}

/// Check if pattern matches at position
fn matches_at(bytecode: []const u8, pc: usize, pattern: Pattern) bool {
    var pos = pc;
    for (pattern.opcodes) |expected_op| {
        if (pos >= bytecode.len) return false;
        
        const actual_op = bytecode[pos];
        const actual_enum = @as(opcode.Enum, @enumFromInt(actual_op));
        
        // Handle PUSH variants - any PUSH matches PUSH1 in pattern
        if (expected_op == .PUSH1) {
            if (@intFromEnum(actual_enum) < @intFromEnum(opcode.Enum.PUSH1) or
                @intFromEnum(actual_enum) > @intFromEnum(opcode.Enum.PUSH8)) {
                return false;
            }
        } else if (actual_enum != expected_op) {
            return false;
        }
        
        pos += get_opcode_size(actual_op, bytecode, pos);
    }
    
    // Run validator if present
    if (pattern.validator) |validator| {
        return validator(bytecode, pc);
    }
    
    return true;
}

/// Get size of opcode including immediate data
fn get_opcode_size(op: u8, bytecode: []const u8, pc: usize) usize {
    _ = bytecode;
    _ = pc;
    const op_enum = @as(opcode.Enum, @enumFromInt(op));
    return switch (op_enum) {
        .PUSH1 => 2,
        .PUSH2 => 3,
        .PUSH3 => 4,
        .PUSH4 => 5,
        .PUSH5 => 6,
        .PUSH6 => 7,
        .PUSH7 => 8,
        .PUSH8 => 9,
        .PUSH9 => 10,
        .PUSH10 => 11,
        .PUSH11 => 12,
        .PUSH12 => 13,
        .PUSH13 => 14,
        .PUSH14 => 15,
        .PUSH15 => 16,
        .PUSH16 => 17,
        .PUSH17 => 18,
        .PUSH18 => 19,
        .PUSH19 => 20,
        .PUSH20 => 21,
        .PUSH21 => 22,
        .PUSH22 => 23,
        .PUSH23 => 24,
        .PUSH24 => 25,
        .PUSH25 => 26,
        .PUSH26 => 27,
        .PUSH27 => 28,
        .PUSH28 => 29,
        .PUSH29 => 30,
        .PUSH30 => 31,
        .PUSH31 => 32,
        .PUSH32 => 33,
        else => 1,
    };
}

/// Extract push values from bytecode for superinstruction
pub fn extract_push_values(bytecode: []const u8, pc: usize, count: usize) struct { v1: u256, v2: u256 } {
    var values = struct { v1: u256 = 0, v2: u256 = 0 }{};
    var pos = pc;
    var idx: usize = 0;
    
    while (idx < count and pos < bytecode.len) : (idx += 1) {
        const op = bytecode[pos];
        const op_enum = @as(opcode.Enum, @enumFromInt(op));
        
        if (@intFromEnum(op_enum) >= @intFromEnum(opcode.Enum.PUSH1) and
            @intFromEnum(op_enum) <= @intFromEnum(opcode.Enum.PUSH32)) {
            const n = @intFromEnum(op_enum) - @intFromEnum(opcode.Enum.PUSH1) + 1;
            const bytes = bytecode[pos + 1..][0..n];
            var value: u256 = 0;
            for (bytes) |byte| {
                value = (value << 8) | byte;
            }
            
            if (idx == 0) {
                values.v1 = value;
            } else if (idx == 1) {
                values.v2 = value;
            }
            
            pos += 1 + n;
        } else {
            pos += 1;
        }
    }
    
    return values;
}

// ============================================================================
// Superinstruction Implementations
// ============================================================================

/// Helper to get next instruction pointer
inline fn next_instruction(instr: *const Instruction) ?*const Instruction {
    const next_ptr = @intFromPtr(instr) + @sizeOf(Instruction);
    return @as(*const Instruction, @ptrFromInt(next_ptr));
}

/// PUSH + PUSH + ADD - push two values and add them
fn op_push_push_add(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    // Values are packed in arg
    const values = @as(*const [2]u64, @ptrCast(&instr.arg.data));
    const result = values[0] +% values[1];
    state.stack.append_unsafe(result);
    return next_instruction(instr);
}

/// PUSH + PUSH + SUB - push two values and subtract
fn op_push_push_sub(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const values = @as(*const [2]u64, @ptrCast(&instr.arg.data));
    const result = values[0] -% values[1];
    state.stack.append_unsafe(result);
    return next_instruction(instr);
}

/// PUSH + PUSH + MUL - push two values and multiply
fn op_push_push_mul(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const values = @as(*const [2]u64, @ptrCast(&instr.arg.data));
    const result = values[0] *% values[1];
    state.stack.append_unsafe(result);
    return next_instruction(instr);
}

/// PUSH + PUSH + DIV - push two values and divide
fn op_push_push_div(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const values = @as(*const [2]u64, @ptrCast(&instr.arg.data));
    const result = if (values[1] == 0) 0 else values[0] / values[1];
    state.stack.append_unsafe(result);
    return next_instruction(instr);
}

/// PUSH + PUSH + EQ - push two values and check equality
fn op_push_push_eq(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const values = @as(*const [2]u64, @ptrCast(&instr.arg.data));
    const result = if (values[0] == values[1]) 1 else 0;
    state.stack.append_unsafe(result);
    return next_instruction(instr);
}

/// PUSH + PUSH + LT - push two values and check less than
fn op_push_push_lt(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const values = @as(*const [2]u64, @ptrCast(&instr.arg.data));
    const result = if (values[0] < values[1]) 1 else 0;
    state.stack.append_unsafe(result);
    return next_instruction(instr);
}

/// PUSH + PUSH + GT - push two values and check greater than
fn op_push_push_gt(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const values = @as(*const [2]u64, @ptrCast(&instr.arg.data));
    const result = if (values[0] > values[1]) 1 else 0;
    state.stack.append_unsafe(result);
    return next_instruction(instr);
}

/// DUP + PUSH + EQ - duplicate top, push value, and check equality
fn op_dup_push_eq(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const top = state.stack.peek_unsafe(0);
    const push_value = instr.arg.small_push;
    const result = if (top == push_value) 1 else 0;
    state.stack.append_unsafe(result);
    return next_instruction(instr);
}

/// PUSH + MLOAD - push offset and load from memory
fn op_push_mload(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const offset = instr.arg.small_push;
    const data = state.memory.*.get_u256(@intCast(offset)) catch {
        state.exit_status = ExecutionError.Error.OutOfMemory;
        return null;
    };
    state.stack.append_unsafe(data);
    return next_instruction(instr);
}

/// PUSH + MSTORE - push offset, pop value, and store to memory
fn op_push_mstore(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const offset = instr.arg.small_push;
    const value = state.stack.pop_unsafe();
    state.memory.*.set_u256(@intCast(offset), value) catch {
        state.exit_status = ExecutionError.Error.OutOfMemory;
        return null;
    };
    return next_instruction(instr);
}

/// ISZERO + PUSH + JUMPI - check zero, push dest, conditional jump
fn op_iszero_push_jumpi(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const value = state.stack.pop_unsafe();
    const is_zero = (value == 0);
    
    if (is_zero) {
        // Jump to destination stored in arg
        const dest = instr.arg.jump_target;
        state.frame.pc = dest;
        return null; // Re-enter at jump target
    }
    
    return next_instruction(instr);
}

/// DUP + ISZERO - duplicate top and check if zero
fn op_dup_iszero(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const value = state.stack.peek_unsafe(0);
    const result = if (value == 0) 1 else 0;
    state.stack.append_unsafe(result);
    return next_instruction(instr);
}

/// PUSH + PUSH + AND - push two values and bitwise AND
fn op_push_push_and(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const values = @as(*const [2]u64, @ptrCast(&instr.arg.data));
    const result = values[0] & values[1];
    state.stack.append_unsafe(result);
    return next_instruction(instr);
}

// Tests
test "pattern matching" {
    const testing = std.testing;
    
    // Test PUSH + PUSH + ADD pattern
    const bytecode = [_]u8{ 0x60, 0x02, 0x60, 0x03, 0x01 }; // PUSH1 2, PUSH1 3, ADD
    
    const match = match_pattern(&bytecode, 0);
    try testing.expect(match != null);
    try testing.expectEqual(SuperOpcode.PUSH_PUSH_ADD, match.?.pattern.super_op);
    try testing.expectEqual(@as(usize, 5), match.?.length);
}

test "extract push values" {
    const testing = std.testing;
    
    // Test extracting two push values
    const bytecode = [_]u8{ 0x60, 0x0A, 0x60, 0x14 }; // PUSH1 10, PUSH1 20
    
    const values = extract_push_values(&bytecode, 0, 2);
    try testing.expectEqual(@as(u256, 10), values.v1);
    try testing.expectEqual(@as(u256, 20), values.v2);
}