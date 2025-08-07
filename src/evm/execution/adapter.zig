const ExecutionError = @import("execution_error.zig");
const ExecutionContext = @import("../frame.zig").ExecutionContext;
const Operation = @import("../opcodes/operation.zig");

/// Call either a legacy handler (fn(*ExecutionContext) !void)
/// or a migrated handler (fn(*anyopaque) !void) using a single entry point.
pub fn call_op(comptime OpFn: anytype, context: *anyopaque) ExecutionError.Error!void {
    const FnInfo = @typeInfo(@TypeOf(OpFn)).Fn;
    const ParamType = FnInfo.params[0].type.?;

    if (ParamType == *ExecutionContext) {
        const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
        return OpFn(frame);
    } else if (ParamType == *anyopaque) {
        return OpFn(context);
    } else {
        @compileError("Unsupported opcode handler parameter type");
    }
}

/// Call an old-style handler with signature (usize, *Evm, *Frame) !ExecutionResult
/// This is for operations that haven't been migrated yet
pub fn call_old_op(comptime OpFn: anytype, context: *anyopaque) ExecutionError.Error!void {
    // For now, we need to extract the frame and interpreter from context
    // Since this is a temporary adapter, we'll cast context as ExecutionContext
    const frame = @as(*ExecutionContext, @ptrCast(@alignCast(context)));
    
    // Call the old-style function with dummy values
    // TODO: This needs proper implementation when we have the right context structure
    _ = OpFn(0, undefined, frame) catch |err| {
        return err;
    };
}