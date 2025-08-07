const std = @import("std");
const ExecutionContext = @import("../frame.zig").ExecutionContext;
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame.zig").Frame;
const Vm = @import("../evm.zig");
const GasConstants = @import("primitives").GasConstants;
const primitives = @import("primitives");
const Operation = @import("../opcodes/operation.zig");

// Compile-time verification that this file is being used
const COMPILE_TIME_LOG_VERSION = "2024_LOG_FIX_V2";

// Import Log struct from VM
const Log = Vm.Log;

// Import helper functions from error_mapping

pub fn make_log(comptime num_topics: u8) fn (*ExecutionContext) ExecutionError.Error!void {
    return struct {
        pub fn log(context: *ExecutionContext) ExecutionError.Error!void {

            // Check if we're in a static call
            if (context.is_static()) {
                @branchHint(.unlikely);
                return ExecutionError.Error.WriteProtection;
            }

            // REVM EXACT MATCH: Pop offset first, then len (revm: popn!([offset, len]))
            const offset = try context.stack.pop();
            const size = try context.stack.pop();

            // Early bounds checking to avoid unnecessary topic pops on invalid input
            if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
                @branchHint(.unlikely);
                return ExecutionError.Error.OutOfOffset;
            }

            // Stack-allocated topics array - zero heap allocations for LOG operations
            var topics: [4]u256 = undefined;
            // Pop N topics in reverse order (LIFO stack order) for efficient processing
            for (0..num_topics) |i| {
                topics[num_topics - 1 - i] = try context.stack.pop();
            }

            const offset_usize = @as(usize, @intCast(offset));
            const size_usize = @as(usize, @intCast(size));

            if (size_usize == 0) {
                @branchHint(.unlikely);
                // Empty data - emit empty log without memory operations
                context.host.emit_log(context.contract_address, topics[0..num_topics], &[_]u8{});
                return;
            }

            // Convert to usize for memory operations

            // Note: Base LOG gas (375) and topic gas (375 * N) are handled by jump table as constant_gas
            // We only need to handle dynamic costs: memory expansion and data bytes

            // 1. Calculate memory expansion gas cost
            const new_size = offset_usize + size_usize;
            const memory_gas = context.memory.get_expansion_cost(@as(u64, @intCast(new_size)));

            // Memory expansion gas calculated

            try context.consume_gas(memory_gas);

            // 2. Dynamic gas for data
            const byte_cost = GasConstants.LogDataGas * size_usize;

            // Calculate dynamic gas for data

            try context.consume_gas(byte_cost);

            // Gas consumed successfully

            // Ensure memory is available
            _ = try context.memory.ensure_context_capacity(offset_usize + size_usize);

            // Get log data
            const data = try context.memory.get_slice(offset_usize, size_usize);

            // Emit log with data
            context.host.emit_log(context.contract_address, topics[0..num_topics], data);
        }
    }.log;
}

// Runtime dispatch versions for LOG operations (used in ReleaseSmall mode)
// Each LOG operation gets its own function to avoid opcode detection issues

pub fn log_0(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return log_impl(0, frame);
}

pub fn log_1(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return log_impl(1, frame);
}

pub fn log_2(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return log_impl(2, frame);
}

pub fn log_3(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return log_impl(3, frame);
}

pub fn log_4(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return log_impl(4, frame);
}

// Common implementation for all LOG operations
fn log_impl(num_topics: u8, context: *ExecutionContext) ExecutionError.Error!void {
    // Check if we're in a static call
    if (context.is_static()) {
        @branchHint(.unlikely);
        return ExecutionError.Error.WriteProtection;
    }

    // Pop offset and size
    const offset = try context.stack.pop();
    const size = try context.stack.pop();

    // Early bounds checking for better error handling
    const offset_usize = std.math.cast(usize, offset) orelse return ExecutionError.Error.InvalidOffset;
    const size_usize = std.math.cast(usize, size) orelse return ExecutionError.Error.InvalidSize;

    // Stack-allocated topics array - zero heap allocations for LOG operations
    var topics: [4]u256 = undefined;
    // Pop N topics in reverse order for efficient processing
    for (0..num_topics) |i| {
        topics[num_topics - 1 - i] = try context.stack.pop();
    }

    if (size_usize == 0) {
        @branchHint(.unlikely);
        // Empty data - emit empty log without memory operations
        context.host.emit_log(context.contract_address, topics[0..num_topics], &[_]u8{});
        return;
    }

    // 1. Calculate memory expansion gas cost
    const new_size = offset_usize + size_usize;
    const memory_gas = context.memory.get_expansion_cost(@as(u64, @intCast(new_size)));

    try context.consume_gas(memory_gas);

    // 2. Dynamic gas for data
    const byte_cost = GasConstants.LogDataGas * size_usize;
    try context.consume_gas(byte_cost);

    // Ensure memory is available
    _ = try context.memory.ensure_context_capacity(offset_usize + size_usize);

    // Get log data
    const data = try context.memory.get_slice(offset_usize, size_usize);

    // Emit the log
    context.host.emit_log(context.contract_address, topics[0..num_topics], data);
}

// LOG operations are now generated directly in jump_table.zig using make_log()

// =============================================================================
// TESTS - TODO: Update to use ExecutionContext pattern
// =============================================================================

// NOTE: Tests temporarily disabled while ExecutionContext integration is completed
// The tests need to be updated to use ExecutionContext instead of the old Frame/VM pattern

