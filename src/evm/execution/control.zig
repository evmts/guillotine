const std = @import("std");
const Log = @import("../log.zig");
const ExecutionError = @import("execution_error.zig");
const Frame = @import("../frame.zig").Frame;
const AccessList = @import("../access_list/access_list.zig");
const GasConstants = @import("primitives").GasConstants;
const primitives = @import("primitives");
const from_u256 = primitives.Address.from_u256;

pub fn op_stop(context: *anyopaque) ExecutionError.Error!void {
    _ = context;

    return ExecutionError.Error.STOP;
}

// DEPRECATED: JUMP is now handled directly in interpret.zig via .jump_target instruction type
// This function is no longer called and should be deleted
pub fn op_jump(context: *anyopaque) ExecutionError.Error!void {
    _ = context;
    // JUMP is handled inline by the interpreter based on pre-resolved targets
    // in the instruction stream; this function must never be called.
    unreachable;
}

// DEPRECATED: JUMPI is now handled directly in interpret.zig via .jump_target instruction type
// This function is no longer called and should be deleted
pub fn op_jumpi(context: *anyopaque) ExecutionError.Error!void {
    _ = context;
    // JUMPI is handled inline by the interpreter based on pre-resolved targets
    // in the instruction stream; this function must never be called.
    unreachable;
}

pub fn op_pc(context: *anyopaque) ExecutionError.Error!void {
    _ = context;

    // PC opcode pushes the current program counter onto the stack
    // This should never be called - PC is handled by storing the value in the instruction
    // If we get here, it's a bug in the analysis
    unreachable;
}

pub fn op_jumpdest(context: *anyopaque) ExecutionError.Error!void {
    _ = context;

    // No-op, just marks valid jump destination
}

pub fn op_return(context: *anyopaque) ExecutionError.Error!void {
    const ctx = @as(*Frame, @ptrCast(@alignCast(context)));
    const frame = ctx;

    std.debug.assert(frame.stack.size() >= 2);

    // Use batch pop for performance - pop 2 values at once
    // Stack order (top to bottom): [offset, size] with offset on top
    const values = try frame.stack.pop2();
    const offset = values.b; // Top
    const size = values.a; // Second from top

    Log.debug("RETURN opcode: offset={}, size={}", .{ offset, size });

    if (size == 0) {
        @branchHint(.unlikely);
        frame.output = &[_]u8{};
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
            const memory_gas = frame.memory.get_expansion_cost(@as(u64, @intCast(end)));
            try frame.consume_gas(memory_gas);

            _ = try frame.memory.ensure_context_capacity(end);
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
        frame.output = data;

        Log.debug("RETURN data set to frame.output, size: {}", .{data.len});
    }

    Log.debug("RETURN opcode complete, about to return STOP error", .{});
    return ExecutionError.Error.STOP; // RETURN ends execution normally
}

pub fn op_revert(context: *anyopaque) ExecutionError.Error!void {
    const ctx = @as(*Frame, @ptrCast(@alignCast(context)));
    const frame = ctx;

    std.debug.assert(frame.stack.size() >= 2);

    // Use batch pop for performance - pop 2 values at once
    // Stack order (top to bottom): [offset, size] with offset on top
    const values = try frame.stack.pop2();
    const offset = values.b; // Top
    const size = values.a; // Second from top

    if (size == 0) {
        @branchHint(.unlikely);
        frame.output = &[_]u8{};
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
            const memory_gas = frame.memory.get_expansion_cost(@as(u64, @intCast(end)));
            try frame.consume_gas(memory_gas);

            _ = try frame.memory.ensure_context_capacity(end);
        }

        // Get data from memory
        const data = try frame.memory.get_slice(offset_usize, size_usize);

        // Note: The memory gas cost already protects against excessive memory use.
        // Set the output data that will be returned to the caller
        frame.output = data;
    }

    return ExecutionError.Error.REVERT;
}

pub fn op_invalid(context: *anyopaque) ExecutionError.Error!void {
    const ctx = @as(*Frame, @ptrCast(@alignCast(context)));
    const frame = ctx;

    // Debug: op_invalid entered
    // INVALID opcode consumes all remaining gas
    frame.gas_remaining = 0;
    // Debug: op_invalid returning InvalidOpcode

    return ExecutionError.Error.InvalidOpcode;
}

pub fn op_selfdestruct(context: *anyopaque) ExecutionError.Error!void {
    const ctx = @as(*Frame, @ptrCast(@alignCast(context)));
    const frame = ctx;

    // Check if we're in a static call
    if (frame.is_static) {
        @branchHint(.unlikely);
        return ExecutionError.Error.WriteProtection;
    }

    std.debug.assert(frame.stack.size() >= 1);

    // Use unsafe pop since bounds checking is done by jump_table
    const recipient_u256 = try frame.stack.pop();
    const recipient = from_u256(recipient_u256);

    // EIP-2929: Check if recipient address is cold and consume appropriate gas
    // Note: Jump table already consumes base SELFDESTRUCT gas cost
    const access_cost = frame.access_list.access_address(recipient) catch |err| switch (err) {
        error.OutOfMemory => return ExecutionError.Error.OutOfGas,
    };
    const is_cold = access_cost == AccessList.COLD_ACCOUNT_ACCESS_COST;
    if (is_cold) {
        @branchHint(.likely);
        // Cold address access costs more (2600 gas)
        try frame.consume_gas(GasConstants.ColdAccountAccessCost);
    }

    // EIP-6780: Post-Cancun, SELFDESTRUCT only works on contracts created in same transaction
    if (frame.is_eip6780) {
        // Check if contract was created in the current transaction
        if (frame.created_contracts) |created| {
            if (!created.was_created_in_tx(frame.contract_address)) {
                // Contract not created in this tx - SELFDESTRUCT becomes no-op
                // Still consumes gas but does nothing
                return ExecutionError.Error.STOP;
            }
        } else {
            // No created contracts tracker means no contracts created in this tx
            // SELFDESTRUCT becomes no-op
            return ExecutionError.Error.STOP;
        }
    }

    // Mark contract for destruction at end of transaction
    try frame.mark_for_destruction(recipient);

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
