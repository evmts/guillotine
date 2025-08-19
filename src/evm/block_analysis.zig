const std = @import("std");
const BlockInfo = @import("instruction.zig").BlockInfo;
const stack_height_changes = @import("opcodes/stack_height_changes.zig");

/// Block analysis structure used during instruction stream generation.
/// Tracks the accumulated requirements for a basic block during analysis.
pub const BlockAnalysis = struct {
    /// Total static gas cost accumulated for all instructions in the block
    gas_cost: u32 = 0,
    /// Stack height requirement relative to block start
    stack_req: i16 = 0,
    /// Maximum stack growth during block execution
    stack_max_growth: i16 = 0,
    /// Current stack change from block start
    stack_change: i16 = 0,
    /// Index of the BEGINBLOCK instruction that starts this block
    begin_block_index: usize,

    /// Initialize a new block analysis at the given instruction index
    pub fn init(begin_index: usize) BlockAnalysis {
        return BlockAnalysis{
            .begin_block_index = begin_index,
        };
    }

    /// Close the current block by producing compressed information about the block
    pub fn close(self: *const BlockAnalysis) BlockInfo {
        return BlockInfo{
            .gas_cost = self.gas_cost,
            .stack_req = @intCast(@max(0, self.stack_req)),
            .stack_max_growth = @intCast(@max(0, self.stack_max_growth)),
        };
    }

    /// Update stack tracking for an operation
    pub fn updateStackTracking(self: *BlockAnalysis, opcode: u8, min_stack: u32) void {
        // Get the precise net stack change from the lookup table
        const net_change = stack_height_changes.get_stack_height_change(opcode);

        // min_stack tells us how many items the operation pops
        const stack_inputs = @as(i16, @intCast(min_stack));

        // Calculate requirement relative to block start
        const current_stack_req = stack_inputs - self.stack_change;
        self.stack_req = @max(self.stack_req, current_stack_req);

        // Update stack change using the precise net change
        self.stack_change += net_change;
        self.stack_max_growth = @max(self.stack_max_growth, self.stack_change);
    }
};