const std = @import("std");
const builtin = @import("builtin");
const ExecutionError = @import("../execution/execution_error.zig");
const StackFrame = @import("../stack_frame.zig").StackFrame;
const tailcalls = @import("tailcalls.zig");
const Log = @import("../log.zig");
const analysis2 = @import("analysis2.zig");
const PrefetchOptions = @import("std").builtin.PrefetchOptions;

const SAFE = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

pub const Error = ExecutionError.Error;

// Main interpret function - gets code from frame.analysis.bytecode
pub fn interpret2(frame: *StackFrame) Error!noreturn {
    const code = frame.analysis.bytecode;
    if (code.len > std.math.maxInt(u16)) {
        std.log.err("Bytecode length {} exceeds maximum supported size {}", .{ code.len, std.math.maxInt(u16) });
        unreachable; // Hard limit due to u16 PC indexing
    }

    // Use a static buffer that will persist for the execution
    // This is similar to the original approach but uses analysis2.prepare
    var static_buffer: [1024 * 1024]u8 = undefined; // 1MB should be enough for most code
    var fba = std.heap.FixedBufferAllocator.init(&static_buffer);
    const allocator = fba.allocator();

    const prep_result = try analysis2.prepare(allocator, code);

    frame.analysis = prep_result.analysis;
    frame.metadata = prep_result.metadata;
    frame.ops = prep_result.ops;
    frame.ip = 0;

    if (prep_result.ops.len == 0) unreachable;

    Log.debug("[interpret2] Starting execution with {} ops", .{prep_result.ops.len});

    // Start tailcall execution
    const first_op: *const fn (*StackFrame) Error!noreturn = @ptrCast(@alignCast(frame.ops[0]));
    return try (@call(.always_tail, first_op, .{frame}));
}

// Execute function for external use
pub fn execute(frame: *StackFrame) Error!void {
    _ = try interpret2(frame);
}
