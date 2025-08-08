const ExecutionError = @import("execution_error.zig");
const ExecutionContext = @import("../frame.zig").ExecutionContext;
const Operation = @import("../opcodes/operation.zig");
const memory = @import("memory.zig");

/// Wrapper for opcode handlers that accept *ExecutionContext
pub fn call_ctx(comptime OpFn: *const fn (*ExecutionContext) ExecutionError.Error!void, context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    return OpFn(frame);
}

/// Wrapper for opcode handlers that accept *anyopaque
pub fn call_any(comptime OpFn: *const fn (*anyopaque) ExecutionError.Error!void, context: *anyopaque) ExecutionError.Error!void {
    return OpFn(context);
}

/// Adapter for op_returndatasize which uses the old Operation signature
pub fn op_returndatasize_adapter(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    _ = try memory.op_returndatasize(0, @ptrCast(@alignCast(frame)), frame);
}

/// Adapter for op_returndatacopy which uses the old Operation signature
pub fn op_returndatacopy_adapter(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    _ = try memory.op_returndatacopy(0, @ptrCast(@alignCast(frame)), frame);
}
