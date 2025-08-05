const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const primitives = @import("primitives");

pub fn op_and(_: usize, _: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const frame = state;
    std.debug.assert(frame.stack.size() >= 2);
    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;
    frame.stack.set_top_unsafe(a & b);
    return Operation.ExecutionResult{};
}

pub fn op_or(_: usize, _: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const frame = state;
    std.debug.assert(frame.stack.size() >= 2);
    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;
    frame.stack.set_top_unsafe(a | b);
    return Operation.ExecutionResult{};
}

pub fn op_xor(_: usize, _: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const frame = state;
    std.debug.assert(frame.stack.size() >= 2);
    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;
    frame.stack.set_top_unsafe(a ^ b);
    return Operation.ExecutionResult{};
}

pub fn op_not(_: usize, _: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const frame = state;
    std.debug.assert(frame.stack.size() >= 1);
    const a = frame.stack.peek_unsafe().*;
    frame.stack.set_top_unsafe(~a);
    return Operation.ExecutionResult{};
}

pub fn op_byte(_: usize, _: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const frame = state;
    std.debug.assert(frame.stack.size() >= 2);
    const i = frame.stack.pop_unsafe();
    const val = frame.stack.peek_unsafe().*;

    const result = if (i >= 32) 0 else blk: {
        const i_usize = @as(usize, @intCast(i));
        const shift_amount = (31 - i_usize) * 8;
        break :blk (val >> @intCast(shift_amount)) & 0xFF;
    };

    frame.stack.set_top_unsafe(result);
    return Operation.ExecutionResult{};
}

pub fn op_shl(_: usize, _: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const frame = state;
    std.debug.assert(frame.stack.size() >= 2);
    const shift = frame.stack.pop_unsafe();
    const value = frame.stack.peek_unsafe().*;

    const result = if (shift >= 256) 0 else value << @intCast(shift);

    frame.stack.set_top_unsafe(result);
    return Operation.ExecutionResult{};
}

pub fn op_shr(_: usize, _: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const frame = state;
    std.debug.assert(frame.stack.size() >= 2);
    const shift = frame.stack.pop_unsafe();
    const value = frame.stack.peek_unsafe().*;

    const result = if (shift >= 256) 0 else value >> @intCast(shift);

    frame.stack.set_top_unsafe(result);
    return Operation.ExecutionResult{};
}

pub fn op_sar(_: usize, _: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const frame = state;
    std.debug.assert(frame.stack.size() >= 2);
    const shift = frame.stack.pop_unsafe();
    const value = frame.stack.peek_unsafe().*;

    const result = if (shift >= 256) blk: {
        const sign_bit = value >> 255;
        break :blk if (sign_bit == 1) @as(u256, std.math.maxInt(u256)) else @as(u256, 0);
    } else blk: {
        const shift_amount = @as(u8, @intCast(shift));
        const value_i256 = @as(i256, @bitCast(value));
        const result_i256 = value_i256 >> shift_amount;
        break :blk @as(u256, @bitCast(result_i256));
    };

    frame.stack.set_top_unsafe(result);
    return Operation.ExecutionResult{};
}
