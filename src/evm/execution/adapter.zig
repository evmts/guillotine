const ExecutionError = @import("execution_error.zig");
const ExecutionContext = @import("../frame.zig").ExecutionContext;
const Operation = @import("../opcodes/operation.zig");
const memory = @import("memory.zig");

/// Adapter that allows calling either a legacy handler (fn(*ExecutionContext) !void)
/// or a migrated handler (fn(*anyopaque) !void) through a single entry point.
pub fn call_op(comptime OpFn: anytype, context: *anyopaque) ExecutionError.Error!void {
    const FnInfo = @typeInfo(@TypeOf(OpFn)).Fn;
    const ParamType = FnInfo.params[0].type.?;

    if (ParamType == *ExecutionContext) {
        const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
        return OpFn(frame);
    } else if (ParamType == *anyopaque) {
        return OpFn(context);
    } else {
        @compileError("Unsupported opcode handler parameter type for adapter");
    }
}

/// Adapter for op_returndatasize which uses the old Operation signature
pub fn op_returndatasize_adapter(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    _ = try memory.op_returndatasize(0, @ptrCast(frame), @ptrCast(frame));
}

/// Adapter for op_returndatacopy which uses the old Operation signature
pub fn op_returndatacopy_adapter(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    _ = try memory.op_returndatacopy(0, @ptrCast(frame), @ptrCast(frame));
}
