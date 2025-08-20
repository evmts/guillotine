//! Control flow operations for the Ethereum Virtual Machine
//!
//! This module implements control flow opcodes including STOP, JUMP, JUMPI,
//! PC, JUMPDEST, RETURN, REVERT, and INVALID.
//!
//! ## Architecture Note
//! All jumps are handled inline by the interpreter with targets resolved at
//! analysis time. Both JUMP and JUMPI are encoded as no-op instructions with
//! their control-flow baked into the instruction stream.
//!
//! ## Gas Costs
//! - STOP, JUMPDEST: 0 gas
//! - PC: 2 gas
//! - JUMP, JUMPI: 8 gas
//! - RETURN, REVERT: dynamic based on returned data size
//! - INVALID: consumes all remaining gas

const std = @import("std");
const Log = @import("../log.zig");
const ExecutionError = @import("execution_error.zig");
const Frame = @import("../stack_frame.zig").StackFrame;
// AccessList import removed - using Host interface instead
const GasConstants = @import("primitives").GasConstants;
const primitives = @import("primitives");
const from_u256 = primitives.Address.from_u256;

/// STOP opcode (0x00) - Halt execution
///
/// Halts execution of the current context and returns successfully with no data.
/// Stack: [] → [] (execution ends)
pub fn op_stop(frame: *Frame) ExecutionError.Error!void {

    // Debug: log when we hit STOP to understand why ERC20 isn't returning data
    Log.debug("STOP opcode at stack_size={}, current output len={}", .{ frame.stack.size(), if (frame.output_buffer.len > 0) frame.output_buffer.len else 0 });

    return ExecutionError.Error.STOP;
}

// JUMP and JUMPI are removed; see interpreter for inlined handling.

pub fn op_pc(frame: *Frame) ExecutionError.Error!void {
    _ = frame;

    // PC opcode pushes the current program counter onto the stack
    // This should never be called - PC is handled by storing the value in the instruction
    // If we get here, it's a bug in the analysis
    unreachable;
}

/// GAS opcode (0x5A) - Get amount of available gas
///
/// Pushes the amount of gas remaining in the current execution context.
/// Stack: [] → [gas_remaining]
pub fn op_gas(frame: *Frame) ExecutionError.Error!void {
    frame.stack.append_unsafe(@as(u256, @intCast(frame.gas_remaining)));
}

/// JUMPDEST opcode (0x5B) - Mark valid jump destination
///
/// This is a no-op that marks a valid destination for JUMP/JUMPI.
/// Has no effect on execution or stack.
/// Stack: [] → []
pub fn op_jumpdest(frame: *Frame) ExecutionError.Error!void {
    _ = frame;
    // No-op, just marks valid jump destination
}

/// RETURN opcode (0xF3) - Halt execution and return data
///
/// Halts execution and returns data from memory. The returned data becomes
/// available to the caller.
/// Stack: [offset, size] → [] (execution ends)
pub fn op_return(frame: *Frame) ExecutionError.Error!void {

    std.debug.assert(frame.stack.size() >= 2);

    // Use batch pop for performance - pop 2 values at once
    // EVM stack is [offset, size] with OFFSET on top
    const values = frame.stack.pop2_unsafe();
    Log.debug("RETURN pop2 result: a={}, b={}", .{ values.a, values.b });
    const offset = values.b; // Top (offset)
    const size = values.a; // Second from top (size)

    Log.debug("RETURN opcode: offset={}, size={}", .{ offset, size });

    if (size == 0) {
        @branchHint(.unlikely);
        Log.debug("RETURN setting empty output", .{});
        try frame.set_output(&[_]u8{});
    } else {
        if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
            @branchHint(.unlikely);
            return ExecutionError.Error.OutOfOffset;
        }

        const offset_usize = @as(usize, @intCast(offset));
        const size_usize = @as(usize, @intCast(size));

        // Calculate memory expansion gas cost
        const end = offset_usize + size_usize;
        if (end > offset_usize) { // Check for overflow
            try frame.memory.charge_and_ensure(frame, @as(u64, @intCast(end)));
        }

        // Get data from memory
        const data = try frame.memory.get_slice(offset_usize, size_usize);

        Log.debug("RETURN reading {} bytes from memory[{}..{}]", .{ size_usize, offset_usize, offset_usize + size_usize });
        if (size_usize <= 32) {
            Log.debug("RETURN data: {x}", .{std.fmt.fmtSliceHexLower(data)});
        } else {
            Log.debug("RETURN data (first 32 bytes): {x}", .{std.fmt.fmtSliceHexLower(data[0..32])});
        }

        // Note: The memory gas cost already protects against excessive memory use.
        // Set the output data that will be returned to the caller
        Log.debug("RETURN about to call frame.set_output with {} bytes", .{data.len});
        try frame.set_output(data);

        Log.debug("RETURN data set to host output, size: {}", .{data.len});
    }

    Log.debug("RETURN opcode complete, about to return RETURN error", .{});
    return ExecutionError.Error.RETURN; // RETURN ends execution normally with data
}

/// REVERT opcode (0xFD) - Halt execution and revert state changes
///
/// Halts execution, reverts all state changes made in the current context,
/// and returns data from memory. The returned data is available to the caller.
/// Stack: [offset, size] → [] (execution ends)
pub fn op_revert(frame: *Frame) ExecutionError.Error!void {
    if (frame.stack.size() < 2) {
        return ExecutionError.Error.StackUnderflow;
    }

    // Use batch pop for performance - pop 2 values at once
    // EVM stack is [offset, size] with OFFSET on top
    const values = frame.stack.pop2_unsafe();
    const offset = values.b; // Top (offset)
    const size = values.a; // Second from top (size)

    if (size == 0) {
        @branchHint(.unlikely);
        try frame.set_output(&[_]u8{});
    } else {
        if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
            @branchHint(.unlikely);
            return ExecutionError.Error.OutOfOffset;
        }

        const offset_usize = @as(usize, @intCast(offset));
        const size_usize = @as(usize, @intCast(size));

        // Calculate memory expansion gas cost
        const end = offset_usize + size_usize;
        if (end > offset_usize) { // Check for overflow
            try frame.memory.charge_and_ensure(frame, @as(u64, @intCast(end)));
        }

        // Get data from memory
        const data = try frame.memory.get_slice(offset_usize, size_usize);

        // Note: The memory gas cost already protects against excessive memory use.
        // Set the output data that will be returned to the caller
        try frame.set_output(data);
    }

    return ExecutionError.Error.REVERT;
}

/// INVALID opcode (0xFE) - Invalid instruction
///
/// Represents an invalid opcode. Consumes all remaining gas and causes
/// execution to fail with an error.
/// Stack: [] → [] (execution fails)
pub fn op_invalid(frame: *Frame) ExecutionError.Error!void {

    // INVALID opcode consumes all remaining gas
    frame.gas_remaining = 0;

    return ExecutionError.Error.InvalidOpcode;
}

/// Pre-Cancun SELFDESTRUCT - destroys contract and transfers balance
pub fn op_selfdestruct_legacy(frame: *Frame) ExecutionError.Error!void {

    // Check if we're in a static call
    if (frame.host.get_is_static()) {
        @branchHint(.unlikely);
        return ExecutionError.Error.WriteProtection;
    }

    std.debug.assert(frame.stack.size() >= 1);

    // Use unsafe pop since bounds checking is done by jump_table
    const recipient_u256 = try frame.stack.pop();
    const recipient = from_u256(recipient_u256);

    // EIP-2929: Check if recipient address is cold and consume appropriate gas
    // Note: Jump table already consumes base SELFDESTRUCT gas cost
    const access_cost = try frame.access_address(recipient);
    const is_cold = access_cost == GasConstants.ColdAccountAccessCost;
    if (is_cold) {
        @branchHint(.likely);
        // Cold address access costs more (2600 gas)
        try frame.consume_gas(GasConstants.ColdAccountAccessCost);
    }

    // Mark contract for destruction at end of transaction
    frame.host.mark_for_destruction(frame.contract_address, recipient) catch {
        return ExecutionError.Error.OutOfMemory;
    };

    // Halt execution
    return ExecutionError.Error.STOP;
}

/// Cancun+ SELFDESTRUCT - only works on contracts created in same transaction (EIP-6780)
pub fn op_selfdestruct(frame: *Frame) ExecutionError.Error!void {

    // Check if we're in a static call
    if (frame.host.get_is_static()) {
        @branchHint(.unlikely);
        return ExecutionError.Error.WriteProtection;
    }

    std.debug.assert(frame.stack.size() >= 1);

    // Use unsafe pop since bounds checking is done by jump_table
    const recipient_u256 = try frame.stack.pop();
    const recipient = from_u256(recipient_u256);

    // EIP-2929: Check if recipient address is cold and consume appropriate gas
    // Note: Jump table already consumes base SELFDESTRUCT gas cost
    const access_cost = try frame.access_address(recipient);
    const is_cold = access_cost == GasConstants.ColdAccountAccessCost;
    if (is_cold) {
        @branchHint(.likely);
        // Cold address access costs more (2600 gas)
        try frame.consume_gas(GasConstants.ColdAccountAccessCost);
    }

    // EIP-6780: Post-Cancun, SELFDESTRUCT only works on contracts created in same transaction
    // Check if contract was created in the current transaction
    if (!frame.host.was_created_in_tx(frame.contract_address)) {
        // Contract not created in this tx - SELFDESTRUCT becomes no-op
        // Still consumes gas but does nothing
        return ExecutionError.Error.STOP;
    }

    // Mark contract for destruction at end of transaction
    frame.host.mark_for_destruction(frame.contract_address, recipient) catch {
        return ExecutionError.Error.OutOfMemory;
    };

    // Halt execution
    return ExecutionError.Error.STOP;
}

// TODO_DELETE: All fuzz testing functions need to be updated for new ExecutionContext pattern
// These functions are currently broken due to the signature changes
// Fuzz testing functions for control flow operations
// pub fn fuzz_control_operations(allocator: std.mem.Allocator, operations: []const FuzzControlOperation) !void {
//     // TODO: Update to use ExecutionContext pattern
// }

// TODO_DELETE: These structs are part of the broken fuzz testing code
// const FuzzControlOperation = struct {
//     op_type: ControlOpType,
//     destination: u256 = 0,
//     condition: u256 = 0,
//     offset: u256 = 0,
//     size: u256 = 0,
//     recipient: u256 = 0,
//     initial_pc: ?usize = null,
// };
//
// const ControlOpType = enum {
//     stop,
//     jump,
//     jumpi,
//     pc,
//     jumpdest,
//     return_op,
//     revert,
//     invalid,
//     selfdestruct,
// };

// TODO_DELETE: This function is broken and needs to be updated for ExecutionContext
// fn execute_control_operation(op_type: ControlOpType, context: Frame) ExecutionError.Error!void {
//     // TODO: Update to use ExecutionContext pattern
// }

// TODO_DELETE: This function is broken and needs to be updated for ExecutionContext
// fn validate_control_result(frame: *const Frame, op: FuzzControlOperation, result: ExecutionError.Error!void) !void {
//     // TODO: Update to use ExecutionContext pattern and new signatures
// }

// test "fuzz_control_basic_operations" {
//     const allocator = std.testing.allocator;
//
//     const operations = [_]FuzzControlOperation{
//         .{ .op_type = .stop },
//         .{ .op_type = .jumpdest },
//         .{ .op_type = .pc },
//         .{ .op_type = .jump, .destination = 10 }, // Valid JUMPDEST
//         .{ .op_type = .jumpi, .destination = 20, .condition = 1 }, // Valid conditional jump
//         .{ .op_type = .jumpi, .destination = 20, .condition = 0 }, // False condition
//         .{ .op_type = .return_op, .offset = 0, .size = 32 },
//         .{ .op_type = .revert, .offset = 0, .size = 16 },
//         .{ .op_type = .invalid },
//         .{ .op_type = .selfdestruct, .recipient = 0x123456789ABCDEF0 },
//     };
//
//     try fuzz_control_operations(allocator, &operations);
// }

// test "fuzz_control_jump_validation" {
//     const allocator = std.testing.allocator;
//
//     const operations = [_]FuzzControlOperation{
//         // Valid jump destinations
//         .{ .op_type = .jump, .destination = 10 },
//         .{ .op_type = .jump, .destination = 20 },
//         .{ .op_type = .jump, .destination = 100 },
//
//         // Invalid jump destinations
//         .{ .op_type = .jump, .destination = 5 }, // Not a JUMPDEST
//         .{ .op_type = .jump, .destination = 15 }, // Not a JUMPDEST
//         .{ .op_type = .jump, .destination = 1000 }, // Out of bounds
//         .{ .op_type = .jump, .destination = std.math.maxInt(u256) }, // Max value
//
//         // Conditional jumps with various conditions
//         .{ .op_type = .jumpi, .destination = 10, .condition = 1 },
//         .{ .op_type = .jumpi, .destination = 10, .condition = 0 },
//         .{ .op_type = .jumpi, .destination = 5, .condition = 1 }, // Invalid dest
//         .{ .op_type = .jumpi, .destination = 5, .condition = 0 }, // Invalid dest, false condition
//     };
//
//     try fuzz_control_operations(allocator, &operations);
// }

// test "fuzz_control_memory_operations" {
//     const allocator = std.testing.allocator;
//
//     const operations = [_]FuzzControlOperation{
//         // Basic memory operations
//         .{ .op_type = .return_op, .offset = 0, .size = 0 }, // Empty return
//         .{ .op_type = .return_op, .offset = 0, .size = 1 }, // Single byte
//         .{ .op_type = .return_op, .offset = 0, .size = 32 }, // Word
//         .{ .op_type = .return_op, .offset = 16, .size = 16 }, // Offset return
//
//         .{ .op_type = .revert, .offset = 0, .size = 0 }, // Empty revert
//         .{ .op_type = .revert, .offset = 0, .size = 32 }, // Word revert
//         .{ .op_type = .revert, .offset = 8, .size = 24 }, // Offset revert
//
//         // Edge cases
//         .{ .op_type = .return_op, .offset = 0, .size = 1024 }, // Large return
//         .{ .op_type = .revert, .offset = 0, .size = 1024 }, // Large revert
//         .{ .op_type = .return_op, .offset = 1000, .size = 24 }, // High offset
//         .{ .op_type = .revert, .offset = 1000, .size = 24 }, // High offset
//     };
//
//     try fuzz_control_operations(allocator, &operations);
// }

// test "fuzz_control_edge_cases" {
//     const allocator = std.testing.allocator;
//
//     const operations = [_]FuzzControlOperation{
//         // PC at different positions
//         .{ .op_type = .pc, .initial_pc = 0 },
//         .{ .op_type = .pc, .initial_pc = 100 },
//         .{ .op_type = .pc, .initial_pc = 255 },
//
//         // Jump edge cases
//         .{ .op_type = .jump, .destination = 0 }, // Jump to start
//         .{ .op_type = .jumpi, .destination = 0, .condition = 1 },
//         .{ .op_type = .jumpi, .destination = 0, .condition = 0 },
//
//         // Memory edge cases
//         .{ .op_type = .return_op, .offset = std.math.maxInt(u32), .size = 0 }, // Max offset
//         .{ .op_type = .revert, .offset = std.math.maxInt(u32), .size = 0 }, // Max offset
//
//         // Selfdestruct with different recipients
//         .{ .op_type = .selfdestruct, .recipient = 0 },
//         .{ .op_type = .selfdestruct, .recipient = std.math.maxInt(u256) },
//     };
//
//     try fuzz_control_operations(allocator, &operations);
// }

// test "fuzz_control_random_operations" {
//     const global = struct {
//         fn testControlRandomOperations(input: []const u8) anyerror!void {
//             if (input.len < 10) return;
//
//             const allocator = std.testing.allocator;
//             const op_types = [_]ControlOpType{ .stop, .jump, .jumpi, .pc, .jumpdest, .return_op, .revert, .invalid, .selfdestruct };
//
//             var operations = std.ArrayList(FuzzControlOperation).init(allocator);
//             defer operations.deinit();
//
//             // Generate multiple operations from fuzz input
//             const num_ops = @min((input.len / 10) + 1, 20); // 1-20 operations
//
//             for (0..num_ops) |i| {
//                 const base_idx = (i * 10) % input.len;
//                 if (base_idx + 9 >= input.len) break;
//
//                 const op_type_idx = input[base_idx] % op_types.len;
//                 const op_type = op_types[op_type_idx];
//
//                 const destination = std.mem.readInt(u16, input[base_idx+1..base_idx+3], .little); // Keep destinations reasonable
//                 const condition = std.mem.readInt(u64, input[base_idx+1..base_idx+9], .little);
//                 const offset = std.mem.readInt(u16, input[base_idx+3..base_idx+5], .little) % 2048; // Keep offsets reasonable
//                 const size = std.mem.readInt(u16, input[base_idx+5..base_idx+7], .little) % 1024; // Keep sizes reasonable
//                 const recipient = std.mem.readInt(u64, input[base_idx+1..base_idx+9], .little);
//
//                 try operations.append(.{
//                     .op_type = op_type,
//                     .destination = destination,
//                     .condition = condition,
//                     .offset = offset,
//                     .size = size,
//                     .recipient = recipient,
//                 });
//             }
//
//             try fuzz_control_operations(allocator, operations.items);
//         }
//     };
//     try std.testing.fuzz(global.testControlRandomOperations, .{});
// }
