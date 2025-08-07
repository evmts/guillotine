const std = @import("std");
const ExecutionFunc = @import("execution_func.zig").ExecutionFunc;

pub const JumpType = enum {
    jump,       // Unconditional jump (JUMP)
    jumpi,      // Conditional jump (JUMPI)  
    other,      // Other jump targets (for future use)
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

pub const Instruction = struct {
    opcode_fn: ExecutionFunc,
    arg: union(enum) {
        none,
        push_value: u256,
        jump_target: JumpTarget,
        gas_cost: u32,
        block_info: BlockInfo,
    },
};
