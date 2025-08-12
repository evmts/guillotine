const ExecutionError = @import("execution_error.zig");
const Frame = @import("../frame.zig").Frame;
const Operation = @import("../opcodes/operation.zig");
const Stack = @import("../stack/stack.zig");
const GasConstants = @import("primitives").GasConstants;
const std = @import("std");

/// Wrapper for opcode handlers that accept Frame
pub fn call_ctx(comptime OpFn: *const fn (*Frame) ExecutionError.Error!void, context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    return OpFn(frame);
}

/// Wrapper for opcode handlers that accept *anyopaque
pub fn call_any(comptime OpFn: *const fn (*anyopaque) ExecutionError.Error!void, context: *anyopaque) ExecutionError.Error!void {
    return OpFn(context);
}

/// Adapter for op_returndatasize - push the size of return data to stack
pub fn op_returndatasize_adapter(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));

    if (frame.stack.size() >= Stack.CAPACITY) {
        @branchHint(.cold);
        unreachable;
    }

    // Push result unsafely - bounds checking is done in jump_table.zig
    try frame.stack.append(@as(u256, @intCast(frame.host.get_output().len)));
}

/// Adapter for op_returndatacopy - copy return data to memory
pub fn op_returndatacopy_adapter(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));

    if (frame.stack.size() < 3) {
        @branchHint(.cold);
        unreachable;
    }

    // Pop three values unsafely - bounds checking is done in jump_table.zig
    // EVM stack order: [..., size, data_offset, mem_offset] (top to bottom)
    const mem_offset = try frame.stack.pop();
    const data_offset = try frame.stack.pop();
    const size = try frame.stack.pop();

    if (size == 0) {
        @branchHint(.unlikely);
        return;
    }

    // Check bounds
    if (mem_offset > std.math.maxInt(usize) or data_offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }
    const mem_offset_usize = @as(usize, @intCast(mem_offset));
    const data_offset_usize = @as(usize, @intCast(data_offset));
    const size_usize = @as(usize, @intCast(size));

    // Check bounds
    const output = frame.host.get_output();
    if (data_offset_usize + size_usize > output.len) {
        @branchHint(.unlikely);
        return ExecutionError.Error.ReturnDataOutOfBounds;
    }

    // Calculate memory expansion gas cost
    const new_size = mem_offset_usize + size_usize;
    const new_size_u64 = @as(u64, @intCast(new_size));
    const gas_cost = frame.memory.get_expansion_cost(new_size_u64);
    try frame.consume_gas(gas_cost);

    // Dynamic gas for copy operation
    const word_size = (size_usize + 31) / 32;
    try frame.consume_gas(GasConstants.CopyGas * word_size);

    // Ensure memory is available
    _ = try frame.memory.ensure_context_capacity(new_size);

    // Copy return data to memory
    try frame.memory.set_data(mem_offset_usize, output[data_offset_usize .. data_offset_usize + size_usize]);
}
