const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const Vm = @import("../evm.zig");
const gas_constants = @import("../constants/gas_constants.zig");
const primitives = @import("primitives");

// Compile-time verification that this file is being used
const COMPILE_TIME_LOG_VERSION = "2024_LOG_FIX_V2";

// Import Log struct from VM
const Log = Vm.Log;

// Import helper functions from error_mapping

pub fn make_log(comptime num_topics: u8) fn (usize, *Operation.Interpreter, *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    return struct {
        pub fn log(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
            _ = pc;

            const frame = @as(*Frame, @ptrCast(@alignCast(state)));
            const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

            // Check if we're in a static call
            if (frame.is_static) {
                @branchHint(.unlikely);
                return ExecutionError.Error.WriteProtection;
            }

            // REVM EXACT MATCH: Pop offset first, then len (revm: popn!([offset, len]))
            const offset = try frame.stack.pop();
            const size = try frame.stack.pop();

            // Early bounds checking to avoid unnecessary topic pops on invalid input
            if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
                @branchHint(.unlikely);
                return ExecutionError.Error.OutOfOffset;
            }

            // Stack-allocated topics array - zero heap allocations for LOG operations
            var topics: [4]u256 = undefined;
            // Pop N topics in reverse order (LIFO stack order) for efficient processing
            for (0..num_topics) |i| {
                topics[num_topics - 1 - i] = try frame.stack.pop();
            }

            const offset_usize = @as(usize, @intCast(offset));
            const size_usize = @as(usize, @intCast(size));

            if (size_usize == 0) {
                @branchHint(.unlikely);
                // Empty data - emit empty log without memory operations
                try vm.emit_log(frame.contract.address, topics[0..num_topics], &[_]u8{});
                return Operation.ExecutionResult{};
            }

            // Convert to usize for memory operations

            // Note: Base LOG gas (375) and topic gas (375 * N) are handled by jump table as constant_gas
            // We only need to handle dynamic costs: memory expansion and data bytes

            // 1. Calculate memory expansion gas cost
            const current_size = frame.memory.context_size();
            const new_size = offset_usize + size_usize;
            const memory_gas = gas_constants.memory_gas_cost(current_size, new_size);

            // Memory expansion gas calculated

            try frame.consume_gas(memory_gas);

            // 2. Dynamic gas for data
            const byte_cost = gas_constants.LogDataGas * size_usize;

            // Calculate dynamic gas for data

            try frame.consume_gas(byte_cost);

            // Gas consumed successfully

            // Ensure memory is available
            _ = try frame.memory.ensure_context_capacity(offset_usize + size_usize);

            // Get log data
            const data = try frame.memory.get_slice(offset_usize, size_usize);

            // Emit log with data

            // Add log
            try vm.emit_log(frame.contract.address, topics[0..num_topics], data);

            return Operation.ExecutionResult{};
        }
    }.log;
}

// Runtime dispatch version for LOG operations (used in ReleaseSmall mode)
pub fn log_n(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));
    const opcode = frame.contract.code[pc];
    const num_topics = opcode - 0xa0; // LOG0 is 0xa0

    // Check if we're in a static call
    if (frame.is_static) {
        @branchHint(.unlikely);
        return ExecutionError.Error.WriteProtection;
    }

    // Pop offset and size
    const offset = try frame.stack.pop();
    const size = try frame.stack.pop();

    // Early bounds checking for better error handling
    const offset_usize = std.math.cast(usize, offset) orelse return ExecutionError.Error.InvalidOffset;
    const size_usize = std.math.cast(usize, size) orelse return ExecutionError.Error.InvalidSize;

    // Stack-allocated topics array - zero heap allocations for LOG operations
    var topics: [4]u256 = undefined;
    // Pop N topics in reverse order for efficient processing
    for (0..num_topics) |i| {
        topics[num_topics - 1 - i] = try frame.stack.pop();
    }

    if (size_usize == 0) {
        @branchHint(.unlikely);
        // Empty data - emit empty log without memory operations
        try vm.emit_log(frame.contract.address, topics[0..num_topics], &[_]u8{});
        return Operation.ExecutionResult{};
    }

    // 1. Calculate memory expansion gas cost
    const current_size = frame.memory.context_size();
    const new_size = offset_usize + size_usize;
    const memory_gas = gas_constants.memory_gas_cost(current_size, new_size);

    try frame.consume_gas(memory_gas);

    // 2. Dynamic gas for data
    const byte_cost = gas_constants.LogDataGas * size_usize;
    try frame.consume_gas(byte_cost);

    // Ensure memory is available
    _ = try frame.memory.ensure_context_capacity(offset_usize + size_usize);

    // Get log data
    const data = try frame.memory.get_slice(offset_usize, size_usize);

    // Emit the log
    try vm.emit_log(frame.contract.address, topics[0..num_topics], data);

    return Operation.ExecutionResult{};
}

// LOG operations are now generated directly in jump_table.zig using make_log()
