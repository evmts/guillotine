const std = @import("std");
const Frame = @import("frame.zig");
const Stack = @import("../stack/stack.zig");
const primitives = @import("primitives");

/// Function that executes instruction and returns next instruction pointer
/// Returns null to signal execution termination
pub const ThreadedExecFunc = *const fn (
    instr: *const ThreadedInstruction,
    state: *Frame
) ?*const ThreadedInstruction;

/// Unified instruction representation combining operation and argument
pub const ThreadedInstruction = struct {
    /// Function that executes instruction and returns next
    exec_fn: ThreadedExecFunc,
    
    /// Pre-extracted/computed argument
    arg: InstructionArg,
    
    /// Metadata for optimization
    meta: InstructionMeta,
};

/// Pre-extracted or computed instruction arguments
pub const InstructionArg = union(enum) {
    /// No argument
    none: void,
    
    /// Small push value (PUSH1-PUSH8) - stored directly
    small_push: u64,
    
    /// Large push value (PUSH9-PUSH32) - index into push_values array
    large_push_idx: u32,
    
    /// PC value for PC opcode
    pc_value: u32,
    
    /// Gas correction for GAS opcode
    gas_correction: i32,
    
    /// Block info for block boundaries
    block_info: BlockInfo,
    
    /// Pre-validated jump target index
    jump_dest_idx: u32,
};

/// Instruction metadata packed for efficiency
pub const InstructionMeta = packed struct {
    /// Original bytecode size (1-33 bytes)
    size: u6,
    /// Whether this starts a new block
    is_block_start: bool,
    /// Reserved for future use
    reserved: u1 = 0,
};

/// Block execution information
pub const BlockInfo = struct {
    /// Total gas cost for the block
    gas_cost: u32,
    /// Minimum stack size required
    stack_req: u16,
    /// Maximum stack growth in block
    stack_max_growth: u16,
};

/// Analysis result for threaded execution
pub const ThreadedAnalysis = struct {
    /// Array of threaded instructions
    instructions: []ThreadedInstruction,
    
    /// Storage for large PUSH values (PUSH9-PUSH32)
    push_values: []const primitives.U256,
    
    /// Jump destination mapping (PC -> instruction index)
    jumpdest_map: std.AutoHashMap(u32, u32),
    
    /// Block information array
    blocks: []const BlockInfo,
    
    /// Deinitialize the analysis
    pub fn deinit(self: *ThreadedAnalysis, allocator: std.mem.Allocator) void {
        allocator.free(self.instructions);
        if (self.push_values.len > 0) {
            allocator.free(self.push_values);
        }
        self.jumpdest_map.deinit();
        if (self.blocks.len > 0) {
            allocator.free(self.blocks);
        }
    }
};