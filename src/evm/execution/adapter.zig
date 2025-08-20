const ExecutionError = @import("execution_error.zig");
const Frame = @import("../stack_frame.zig").StackFrame;
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
pub fn op_returndatasize_adapter(frame: *Frame) ExecutionError.Error!void {

    if (frame.stack.size() >= Stack.CAPACITY) {
        @branchHint(.cold);
        unreachable;
    }

    // Push result unsafely - bounds checking is done in jump_table.zig
    frame.stack.append_unsafe(@as(u256, @intCast(frame.output_buffer.len)));
}

/// Adapter for op_returndatacopy - copy return data to memory
pub fn op_returndatacopy_adapter(frame: *Frame) ExecutionError.Error!void {

    if (frame.stack.size() < 3) {
        @branchHint(.cold);
        unreachable;
    }

    // Pop three values unsafely - bounds checking is done in jump_table.zig
    // EVM stack order: [..., size, data_offset, mem_offset] (top to bottom)
    const mem_offset = frame.stack.pop_unsafe();
    const data_offset = frame.stack.pop_unsafe();
    const size = frame.stack.pop_unsafe();

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
    const output = frame.output_buffer;
    if (data_offset_usize + size_usize > output.len) {
        @branchHint(.unlikely);
        return ExecutionError.Error.ReturnDataOutOfBounds;
    }

    // Charge gas and ensure memory is available
    const new_size = mem_offset_usize + size_usize;
    try frame.memory.charge_and_ensure(frame, @as(u64, @intCast(new_size)));

    // Dynamic gas for copy operation
    const word_size = (size_usize + 31) / 32;
    try frame.consume_gas(GasConstants.CopyGas * word_size);

    // Copy return data to memory
    try frame.memory.set_data(mem_offset_usize, output[data_offset_usize .. data_offset_usize + size_usize]);
}
