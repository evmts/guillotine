/// Memory-optimized instruction implementations with pre-calculated expansion costs.
///
/// This module provides specialized implementations of memory operations that:
/// 1. Use pre-calculated expansion costs from analysis phase
/// 2. Eliminate runtime gas calculations for static accesses
/// 3. Provide fast paths for common memory patterns
///
/// ## Key Optimizations:
/// - Pre-calculated gas costs stored in instruction args
/// - Direct memory access without bounds checking for known-safe operations
/// - Specialized functions for common patterns (e.g., PUSH + PUSH + MSTORE)

const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const instruction_stream = @import("instruction_stream.zig");
const primitives = @import("primitives");
const Log = @import("../log.zig");

const Instruction = instruction_stream.Instruction;
const AdvancedExecutionState = instruction_stream.AdvancedExecutionState;
const next_instruction = instruction_stream.next_instruction;

/// MLOAD with pre-calculated expansion cost
pub fn op_mload_precalc(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const offset = state.stack.pop_unsafe();
    
    // Use pre-calculated expansion cost from instruction arg
    const expansion_cost = instr.arg.data;
    state.gas_left.* -= @as(i64, @intCast(expansion_cost));
    if (state.gas_left.* < 0) {
        state.exit_status = ExecutionError.Error.OutOfGas;
        return null;
    }
    
    // Direct memory read - expansion already accounted for
    const data = state.memory.*.get_u256(@intCast(offset)) catch {
        state.exit_status = ExecutionError.Error.OutOfMemory;
        return null;
    };
    state.stack.append_unsafe(data);
    return next_instruction(instr);
}

/// MSTORE with pre-calculated expansion cost
pub fn op_mstore_precalc(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const value = state.stack.pop_unsafe();
    const offset = state.stack.pop_unsafe();
    
    // Use pre-calculated expansion cost from instruction arg
    const expansion_cost = instr.arg.data;
    state.gas_left.* -= @as(i64, @intCast(expansion_cost));
    if (state.gas_left.* < 0) {
        state.exit_status = ExecutionError.Error.OutOfGas;
        return null;
    }
    
    // Direct memory write - expansion already accounted for
    state.memory.*.set_u256(@intCast(offset), value) catch {
        state.exit_status = ExecutionError.Error.OutOfMemory;
        return null;
    };
    return next_instruction(instr);
}

/// MSTORE8 with pre-calculated expansion cost
pub fn op_mstore8_precalc(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const value = state.stack.pop_unsafe();
    const offset = state.stack.pop_unsafe();
    
    // Use pre-calculated expansion cost from instruction arg
    const expansion_cost = instr.arg.data;
    state.gas_left.* -= @as(i64, @intCast(expansion_cost));
    if (state.gas_left.* < 0) {
        state.exit_status = ExecutionError.Error.OutOfGas;
        return null;
    }
    
    // Direct memory write - expansion already accounted for
    const byte_val: u8 = @truncate(value & 0xFF);
    const data = [_]u8{byte_val};
    state.memory.*.set_data(@intCast(offset), &data) catch {
        state.exit_status = ExecutionError.Error.OutOfMemory;
        return null;
    };
    return next_instruction(instr);
}

/// CALLDATACOPY with pre-calculated expansion cost
pub fn op_calldatacopy_precalc(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const dest_offset = state.stack.pop_unsafe();
    const src_offset = state.stack.pop_unsafe();
    const size = state.stack.pop_unsafe();
    
    if (size > 0) {
        // Use pre-calculated expansion cost from instruction arg
        const expansion_cost = instr.arg.data;
        state.gas_left.* -= @as(i64, @intCast(expansion_cost));
        if (state.gas_left.* < 0) {
            state.exit_status = ExecutionError.Error.OutOfGas;
            return null;
        }
        
        const dest = @as(usize, @intCast(dest_offset));
        const src = @as(usize, @intCast(src_offset));
        const len = @as(usize, @intCast(size));
        
        // Direct copy - expansion already accounted for
        state.memory.*.set_data_bounded(dest, state.frame.input, src, len) catch {
            state.exit_status = ExecutionError.Error.OutOfMemory;
            return null;
        };
    }
    
    return next_instruction(instr);
}

/// Superinstruction: PUSH + PUSH + MSTORE (common pattern)
pub fn op_push_push_mstore(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    // Extract both push values and expansion cost from packed arg
    // Layout: [expansion_cost:16][offset:24][value:24]
    const packed_value = instr.arg.data;
    const expansion_cost = packed_value >> 48;
    const offset = (packed_value >> 24) & 0xFFFFFF;
    const value = packed_value & 0xFFFFFF;
    
    // Apply expansion cost
    state.gas_left.* -= @as(i64, @intCast(expansion_cost));
    if (state.gas_left.* < 0) {
        state.exit_status = ExecutionError.Error.OutOfGas;
        return null;
    }
    
    // Direct memory write
    state.memory.*.set_u256(@intCast(offset), value) catch {
        state.exit_status = ExecutionError.Error.OutOfMemory;
        return null;
    };
    
    return next_instruction(instr);
}

/// MLOAD with known zero memory (optimization for uninitialized reads)
pub fn op_mload_zero(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    _ = state.stack.pop_unsafe(); // Consume offset
    
    // We know this will read zeros, so just push 0
    state.stack.append_unsafe(0);
    
    // Still need to account for memory expansion
    const expansion_cost = instr.arg.data;
    state.gas_left.* -= @as(i64, @intCast(expansion_cost));
    if (state.gas_left.* < 0) {
        state.exit_status = ExecutionError.Error.OutOfGas;
        return null;
    }
    
    return next_instruction(instr);
}

/// RETURN/REVERT with pre-calculated memory cost
pub fn op_return_precalc(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const offset = state.stack.pop_unsafe();
    const size = state.stack.pop_unsafe();
    
    if (size > 0) {
        // Use pre-calculated expansion cost from instruction arg
        const expansion_cost = instr.arg.data;
        state.gas_left.* -= @as(i64, @intCast(expansion_cost));
        if (state.gas_left.* < 0) {
            state.exit_status = ExecutionError.Error.OutOfGas;
            return null;
        }
        
        const mem_data = state.memory.*.get_slice(@intCast(offset), @intCast(size)) catch {
            state.exit_status = ExecutionError.Error.OutOfMemory;
            return null;
        };
        const data = state.vm.allocator.alloc(u8, @intCast(size)) catch {
            state.exit_status = ExecutionError.Error.OutOfMemory;
            return null;
        };
        @memcpy(data, mem_data);
        state.frame.output = data;
    }
    
    state.exit_status = ExecutionError.Error.STOP;
    return null;
}

/// Memory operation with dynamic offset but static size
/// This is common for array access patterns
pub fn op_mload_dynamic_offset_static_size(instr: *const Instruction, state: *AdvancedExecutionState) ?*const Instruction {
    const offset = state.stack.pop_unsafe();
    
    // Check if offset + 32 would exceed current memory
    const required_size = offset + 32;
    const current_size = @as(u64, @intCast(state.memory.*.context_size()));
    
    if (required_size > current_size) {
        // Calculate expansion cost at runtime (can't pre-calculate with dynamic offset)
        const expansion_cost = state.memory.*.get_expansion_cost(required_size);
        state.gas_left.* -= @as(i64, @intCast(expansion_cost));
        if (state.gas_left.* < 0) {
            state.exit_status = ExecutionError.Error.OutOfGas;
            return null;
        }
    }
    
    const data = state.memory.*.get_u256(@intCast(offset)) catch {
        state.exit_status = ExecutionError.Error.OutOfMemory;
        return null;
    };
    state.stack.append_unsafe(data);
    return next_instruction(instr);
}

/// Check if memory operation can use pre-calculated expansion
pub fn can_precalculate_expansion(
    static_offset: ?u64,
    static_size: ?u64,
    current_memory_size: u64,
) bool {
    _ = current_memory_size; // May be used in future
    if (static_offset == null or static_size == null) return false;
    
    // Can pre-calculate if we know the exact memory requirement
    const required_size = static_offset.? + static_size.?;
    
    // Avoid overflow
    if (required_size < static_offset.?) return false;
    
    // Must be within reasonable bounds
    return required_size <= std.math.maxInt(u32);
}

test "pre-calculated memory expansion" {
    const testing = std.testing;
    const Memory = @import("../memory/memory.zig");
    const Stack = @import("../stack/stack.zig");
    
    // Create test state
    const allocator = testing.allocator;
    var memory = try Memory.init_default(allocator);
    defer memory.deinit();
    
    var stack = Stack.init();
    var gas_left: i64 = 100000;
    
    // Mock state
    var state = AdvancedExecutionState{
        .stack = &stack,
        .memory = &memory,
        .gas_left = &gas_left,
        .vm = undefined,
        .frame = undefined,
        .exit_status = null,
        .push_values = &.{},
    };
    
    // Test MSTORE with pre-calculated cost
    // Storing at offset 0 should have expansion cost for 32 bytes
    try stack.push(0x42); // value
    try stack.push(0);    // offset
    
    const expansion_cost: u64 = 3; // Cost for first word
    const instr = Instruction{
        .fn_ptr = &op_mstore_precalc,
        .arg = .{ .data = expansion_cost },
    };
    
    const next = op_mstore_precalc(&instr, &state);
    try testing.expect(next != null);
    try testing.expect(state.exit_status == null);
    try testing.expectEqual(@as(i64, 99997), gas_left); // 100000 - 3
    
    // Verify memory was written
    const stored_value = try memory.get_u256(0);
    try testing.expectEqual(@as(u256, 0x42), stored_value);
}