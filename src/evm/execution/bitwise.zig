const std = @import("std");
const ExecutionError = @import("execution_error.zig");
const ExecutionContext = @import("../frame.zig").ExecutionContext;
const primitives = @import("primitives");

pub fn op_and(context: *ExecutionContext) ExecutionError.Error!void {
    std.debug.assert(context.frame.stack.size() >= 2);
    const b = context.frame.stack.pop_unsafe();
    const a = context.frame.stack.peek_unsafe().*;
    context.frame.stack.set_top_unsafe(a & b);
}

pub fn op_or(context: *ExecutionContext) ExecutionError.Error!void {
    std.debug.assert(context.frame.stack.size() >= 2);
    const b = context.frame.stack.pop_unsafe();
    const a = context.frame.stack.peek_unsafe().*;
    context.frame.stack.set_top_unsafe(a | b);
}

pub fn op_xor(context: *ExecutionContext) ExecutionError.Error!void {
    std.debug.assert(context.frame.stack.size() >= 2);
    const b = context.frame.stack.pop_unsafe();
    const a = context.frame.stack.peek_unsafe().*;
    context.frame.stack.set_top_unsafe(a ^ b);
}

pub fn op_not(context: *ExecutionContext) ExecutionError.Error!void {
    std.debug.assert(context.frame.stack.size() >= 1);
    const a = context.frame.stack.peek_unsafe().*;
    context.frame.stack.set_top_unsafe(~a);
}

pub fn op_byte(context: *ExecutionContext) ExecutionError.Error!void {
    std.debug.assert(context.frame.stack.size() >= 2);
    const i = context.frame.stack.pop_unsafe();
    const val = context.frame.stack.peek_unsafe().*;

    const result = if (i >= 32) 0 else blk: {
        const i_usize = @as(usize, @intCast(i));
        const shift_amount = (31 - i_usize) * 8;
        break :blk (val >> @intCast(shift_amount)) & 0xFF;
    };

    context.frame.stack.set_top_unsafe(result);
}

pub fn op_shl(context: *ExecutionContext) ExecutionError.Error!void {
    std.debug.assert(context.frame.stack.size() >= 2);
    const shift = context.frame.stack.pop_unsafe();
    const value = context.frame.stack.peek_unsafe().*;

    const result = if (shift >= 256) 0 else value << @intCast(shift);

    context.frame.stack.set_top_unsafe(result);
}

pub fn op_shr(context: *ExecutionContext) ExecutionError.Error!void {
    std.debug.assert(context.frame.stack.size() >= 2);
    const shift = context.frame.stack.pop_unsafe();
    const value = context.frame.stack.peek_unsafe().*;

    const result = if (shift >= 256) 0 else value >> @intCast(shift);

    context.frame.stack.set_top_unsafe(result);
}

pub fn op_sar(context: *ExecutionContext) ExecutionError.Error!void {
    std.debug.assert(context.frame.stack.size() >= 2);
    const shift = context.frame.stack.pop_unsafe();
    const value = context.frame.stack.peek_unsafe().*;

    const result = if (shift >= 256) blk: {
        const sign_bit = value >> 255;
        break :blk if (sign_bit == 1) @as(u256, std.math.maxInt(u256)) else @as(u256, 0);
    } else blk: {
        const shift_amount = @as(u8, @intCast(shift));
        const value_i256 = @as(i256, @bitCast(value));
        const result_i256 = value_i256 >> shift_amount;
        break :blk @as(u256, @bitCast(result_i256));
    };

    context.frame.stack.set_top_unsafe(result);
}
