const std = @import("std");
const primitives = @import("primitives");
const Dispatch = @import("dispatch.zig").Dispatch;

/// Trace hook executed before each operation
pub fn trace_before_handler(comptime FrameType: type, self: *FrameType, dispatch: Dispatch) FrameType.Error!FrameType.Success {
    if (comptime FrameType.config.TracerType == null) return error.InvalidOpcode;
    
    // When tracing is enabled, PC metadata is stored in the previous dispatch item
    // The dispatch sequence is: [PC metadata][trace_before_handler][opcode][...]
    // We're at trace_before_handler, so PC is at position -1
    const pc_metadata = dispatch.schedule[-1].pc;
    const pc: u32 = @intCast(pc_metadata.value);
    
    // Update frame's current_pc if it has that field
    if (comptime @TypeOf(self.current_pc) != void) {
        self.current_pc = pc;
    }
    
    // Get opcode from bytecode
    const opcode: u8 = if (pc < self.bytecode.data.len) self.bytecode.data[pc] else 0;

    // Call tracer beforeOp - this will set paused=true if we hit a breakpoint or are in step mode
    self.tracer.beforeOp(pc, opcode, FrameType, self);
    
    // Check if tracer decided to pause (breakpoint hit or step mode)
    if (comptime @hasDecl(@TypeOf(self.tracer), "paused")) {
        if (@field(self.tracer, "paused")) {
            // Save where to resume execution (skip to actual opcode, not the PC metadata)
            if (comptime @hasDecl(@TypeOf(self.tracer), "setResumeDispatch")) {
                // Next dispatch points to the actual opcode handler
                self.tracer.setResumeDispatch(dispatch.getNext());
            }
            return error.ExecutionPaused;
        }
    }
    
    // Continue to next handler (actual opcode execution)
    const next_dispatch = dispatch.getNext();
    return dispatchNext(FrameType, next_dispatch.schedule[0].opcode_handler, self, next_dispatch);
}

/// Trace hook executed after each operation
pub fn trace_after_handler(comptime FrameType: type, self: *FrameType, dispatch: Dispatch) FrameType.Error!FrameType.Success {
    if (comptime FrameType.config.TracerType == null) return error.InvalidOpcode;
    
    // Get current PC from frame (was set by trace_before_handler)
    const pc: u32 = if (comptime @TypeOf(self.current_pc) != void) self.current_pc else 0;
    
    // Get opcode from bytecode
    const opcode: u8 = if (pc < self.bytecode.data.len) self.bytecode.data[pc] else 0;

    // Call tracer afterOp
    self.tracer.afterOp(pc, opcode, FrameType, self);
    
    // Continue to next instruction
    const next_dispatch = dispatch.getNext();
    if (next_dispatch.schedule == null) return FrameType.Success.Stop;
    return dispatchNext(FrameType, next_dispatch.schedule[0].opcode_handler, self, next_dispatch);
}

/// Helper for dispatch continuation
fn dispatchNext(comptime FrameType: type, handler: anytype, self: *FrameType, dispatch: Dispatch) FrameType.Error!FrameType.Success {
    return handler(self, dispatch);
}