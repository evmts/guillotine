const ExecutionError = @import("execution_error.zig");
const ExecutionContext = @import("../frame.zig").ExecutionContext;

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
