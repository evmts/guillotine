const std = @import("std");
const Operation = @import("opcodes/operation.zig");
const ExecutionError = @import("execution/execution_error.zig");
const Frame = @import("frame/frame.zig");
const CodeAnalysis = @import("frame/code_analysis.zig");

pub const Instruction = struct {
    opcode_fn: Operation.ExecutionFunc,
    arg: union(enum) {
        none,
        push_value: u256,
        jump_target: *const Instruction,
        gas_cost: u32,
    },
};
