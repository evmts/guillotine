const std = @import("std");
const builtin = @import("builtin");
const ExecutionError = @import("../execution/execution_error.zig");
const StackFrame = @import("../stack_frame.zig").StackFrame;
const Log = @import("../log.zig");
const SimpleAnalysis = @import("analysis2.zig").SimpleAnalysis;
const analysis2 = @import("analysis2.zig");

const SAFE = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;

pub const Error = ExecutionError.Error;

// Function pointer type for tailcall dispatch - using StackFrame signature like interpret3
const TailcallFunc = *const fn (frame: *StackFrame) Error!noreturn;

// Removed - now using SimpleAnalysis from analysis2.zig

// Removed - now using opcode_mod.is_valid_opcode() instead

// TODO we need to be prices about storage at the end
const EXTRA_BUFFER = 8192;

// Main interpret function - gets code from frame.analysis.bytecode
pub fn interpret2(frame: *StackFrame) Error!noreturn {
    const code = frame.analysis.bytecode;
    if (code.len > std.math.maxInt(u16)) {
        std.log.err("Bytecode length {} exceeds maximum supported size {}", .{ code.len, std.math.maxInt(u16) });
        unreachable; // Hard limit due to u16 PC indexing
    }

    const estimated_size = code.len * 100 + EXTRA_BUFFER;
    const buffer = try std.heap.page_allocator.alloc(u8, estimated_size);
    defer std.heap.page_allocator.free(buffer);
    var fba = std.heap.FixedBufferAllocator.init(buffer);
    const allocator = fba.allocator();

    const prep = try analysis2.prepare(allocator, code);
    var analysis = prep.analysis;
    defer analysis.deinit(allocator);
    const metadata = prep.metadata;
    defer allocator.free(metadata);
    const ops_slice = prep.ops;

    frame.analysis = analysis;
    frame.metadata = metadata;
    frame.ops = ops_slice;
    frame.ip = 0;

    if (ops_slice.len == 0) {
        unreachable;
    }

    // Add tailcall system tracking
    if (comptime SAFE) {
        frame.tailcall_iterations = 0;
    }

    Log.debug("[interpret2] Starting execution with {} ops", .{ops_slice.len});

    // This Evm will recursively tail-call functions until an Error is thrown. Error will be thrown even in success cases
    const first_op: TailcallFunc = @ptrCast(@alignCast(frame.ops[0]));
    return try (@call(.always_tail, first_op, .{frame}));
}
