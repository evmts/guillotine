const std = @import("std");
const ExecutionFunc = @import("execution_func.zig").ExecutionFunc;

pub const Instruction = struct {
    opcode_fn: ExecutionFunc,
    arg: union(enum) {
        none,
        push_value: u256,
        jump_target: *const Instruction,
        gas_cost: u32,
    },
};
