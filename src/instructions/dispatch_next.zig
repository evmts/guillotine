const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");

/// Advance to the next opcode instruction with tracking.
///
/// This is a shared helper for all instruction handlers to avoid duplicating
/// the dispatch pattern across handler files. It:
/// 1. Gets the next handler and cursor from dispatch opcode data
/// 2. Calls afterInstruction for tracing/synchronization
/// 3. Tail-calls to the next handler
pub inline fn nextInstruction(
    comptime FrameType: type,
    self: *FrameType,
    cursor: [*]const FrameType.Dispatch.Item,
    comptime opcode: FrameType.Dispatch.UnifiedOpcode,
) FrameType.Error!noreturn {
    const op_data = dispatch_opcode_data.getOpData(opcode, FrameType.Dispatch, FrameType.Dispatch.Item, cursor);
    self.afterInstruction(opcode, op_data.next_handler, op_data.next_cursor.cursor);
    return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
}
