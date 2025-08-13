const std = @import("std");
const ExecutionFunc = @import("execution_func.zig").ExecutionFunc;
const ExecutionError = @import("execution/execution_error.zig");
const Frame = @import("frame.zig").Frame;

pub const JumpType = enum {
    jump, // Unconditional jump (JUMP)
    jumpi, // Conditional jump (JUMPI)
    other, // Other jump targets (for future use)
};

pub const JumpTarget = struct {
    instruction: *const Instruction,
    jump_type: JumpType,
};

/// Block information for BEGINBLOCK instructions.
/// Contains pre-calculated validation data for an entire basic block.
pub const BlockInfo = struct {
    /// Total static gas cost for all instructions in the block
    gas_cost: u32 = 0,
    /// Minimum stack height required to execute entire block
    stack_req: u16 = 0,
    /// Maximum stack growth during block execution
    stack_max_growth: u16 = 0,
};

/// Function signature for dynamic gas calculation.
/// Takes a frame and returns the additional gas cost to charge.
/// This is used for opcodes with runtime-dependent gas costs.
pub const DynamicGasFunc = *const fn (frame: *Frame) ExecutionError.Error!u64;

/// Information for opcodes that have dynamic gas costs
pub const DynamicGas = struct {
    /// Static gas cost to charge first
    static_cost: u32,
    /// Function to calculate additional dynamic gas
    gas_fn: ?DynamicGasFunc,
};

pub const Instruction = struct {
    opcode_fn: ExecutionFunc,
    arg: union(enum) {
        none,
        push_value: u256,
        jump_target: JumpTarget,
        gas_cost: u32,
        block_info: BlockInfo,
        dynamic_gas: DynamicGas,
        pc_value: u16, // For PC opcode - stores the program counter value

        // Synthetic operation variants for pattern fusion
        push_add_fusion: u256, // immediate for PUSH+ADD
        push_sub_fusion: u256, // immediate for PUSH+SUB
        push_mul_fusion: u256, // immediate for PUSH+MUL
        push_div_fusion: u256, // immediate for PUSH+DIV
        push_push_result: u256, // precomputed PUSH+PUSH+op result
        keccak_precomputed: struct {
            word_count: u64,
            gas_cost: u64,
        },
        keccak_immediate_size: struct {
            size: u64,
            word_count: u64,
            gas_cost: u64,
        },
    },

    pub const STOP: Instruction = .{ .opcode_fn = StopHandler, .arg = .none };
};

pub fn StopHandler(context: *anyopaque) ExecutionError.Error!void {
    _ = context;
    return ExecutionError.Error.STOP;
}
