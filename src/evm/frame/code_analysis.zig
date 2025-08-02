const std = @import("std");
const bitvec = @import("bitvec.zig");
const BitVec64 = bitvec.BitVec64;
const Operation = @import("../opcodes/operation.zig");

/// Type of instruction that terminates a block
pub const BlockTerminator = enum {
    jump,
    jumpi,
    stop,
    return_,
    revert,
    selfdestruct,
    invalid,
    fall_through,
};

/// Metadata for a basic block in the bytecode
pub const BlockInfo = struct {
    /// Total gas cost for all instructions in this block
    gas_cost: u32,
    /// Required stack height at block entry
    stack_req: u16,
    /// Maximum stack growth within the block
    stack_max_growth: u16,
    /// PC of first instruction in block
    start_pc: u32,
    /// PC of last instruction in block (inclusive)
    end_pc: u32,
    /// Type of block terminator
    terminator: BlockTerminator,
    /// For static jumps: validated target block index
    static_jump_target: ?u32 = null,
    /// Whether static jump (if any) is valid
    static_jump_valid: bool = false,
};

/// Pre-computed operation info including stack validation data
pub const PcToOpEntry = struct {
    operation: *const Operation.Operation,
    opcode_byte: u8,
    // Pre-computed validation info to avoid re-fetching from operation
    min_stack: u32,
    max_stack: u32,
    constant_gas: u64,
    undefined: bool,
};

/// Pre-extracted instruction arguments for cache efficiency
pub const InstructionArg = union(enum) {
    /// No argument
    none: void,
    
    /// Small push value (PUSH1-PUSH8) - stored directly
    small_push: u64,
    
    /// Large push value (PUSH9-PUSH32) - index into push_values array
    large_push_idx: u32,
    
    /// Block info for block-aware execution
    block: struct {
        /// Index into blocks array
        block_idx: u32,
        /// Whether this is first instruction in block
        is_block_start: bool,
    },
    
    /// Static jump destination (pre-validated)
    static_jump: u32,
};

/// Extended PC-to-operation entry with pre-extracted arguments
pub const ExtendedPcToOpEntry = struct {
    /// Original fields from PcToOpEntry
    operation: *const Operation.Operation,
    opcode_byte: u8,
    min_stack: u32,
    max_stack: u32,
    constant_gas: u64,
    undefined: bool,
    
    /// NEW: Pre-extracted argument
    arg: InstructionArg,
    
    /// NEW: Actual instruction size (1-33 bytes)
    size: u8,
};

/// Advanced code analysis for EVM bytecode optimization.
///
/// This structure holds pre-computed analysis results for a contract's bytecode,
/// enabling efficient execution by pre-identifying jump destinations, code segments,
/// and other properties that would otherwise need to be computed at runtime.
///
/// The analysis is performed once when a contract is first loaded and cached for
/// subsequent executions, significantly improving performance for frequently-used
/// contracts.
///
/// ## Fields
/// - `code_segments`: Bit vector marking which bytes are executable code vs data
/// - `jumpdest_positions`: Sorted array of valid JUMPDEST positions for O(log n) validation
/// - `block_gas_costs`: Optional pre-computed gas costs for basic blocks
/// - `max_stack_depth`: Maximum stack depth required by the contract
/// - `has_dynamic_jumps`: Whether the code contains JUMP/JUMPI with dynamic targets
/// - `has_static_jumps`: Whether the code contains JUMP/JUMPI with static targets
/// - `has_selfdestruct`: Whether the code contains SELFDESTRUCT opcode
/// - `has_create`: Whether the code contains CREATE/CREATE2 opcodes
///
/// ## Performance
/// - Jump destination validation: O(log n) using binary search
/// - Code segment checking: O(1) using bit vector
/// - Enables dead code elimination and other optimizations
///
/// ## Memory Management
/// The analysis owns its allocated memory and must be properly cleaned up
/// using the `deinit` method to prevent memory leaks.
const CodeAnalysis = @This();

/// Bit vector marking which bytes in the bytecode are executable code vs data.
///
/// Each bit corresponds to a byte in the contract bytecode:
/// - 1 = executable code byte
/// - 0 = data byte (e.g., PUSH arguments)
///
/// This is critical for JUMPDEST validation since jump destinations
/// must point to actual code, not data bytes within PUSH instructions.
code_segments: BitVec64,

/// Sorted array of all valid JUMPDEST positions in the bytecode.
///
/// Pre-sorted to enable O(log n) binary search validation of jump targets.
/// Only positions marked as code (not data) and containing the JUMPDEST
/// opcode (0x5B) are included.
jumpdest_positions: []const u32,

/// Optional pre-computed gas costs for each basic block.
///
/// When present, enables advanced gas optimization by pre-calculating
/// the gas cost of straight-line code sequences between jumps.
/// This is an optional optimization that may not be computed for all contracts.
block_gas_costs: ?[]const u32,

/// Maximum stack depth required by any execution path in the contract.
///
/// Pre-computed through static analysis to enable early detection of
/// stack overflow conditions. A value of 0 indicates the depth wasn't analyzed.
max_stack_depth: u16,

/// Indicates whether the contract contains JUMP/JUMPI opcodes with dynamic targets.
///
/// Dynamic jumps (where the target is computed at runtime) prevent certain
/// optimizations and require full jump destination validation at runtime.
has_dynamic_jumps: bool,

/// Indicates whether the contract contains JUMP/JUMPI opcodes with static targets.
///
/// Static jumps (where the target is a constant) can be pre-validated
/// and optimized during analysis.
has_static_jumps: bool,

/// Indicates whether the contract contains the SELFDESTRUCT opcode (0xFF).
///
/// Contracts with SELFDESTRUCT require special handling for state management
/// and cannot be marked as "pure" or side-effect free.
has_selfdestruct: bool,

/// Indicates whether the contract contains CREATE or CREATE2 opcodes.
///
/// Contracts that can deploy other contracts require additional
/// gas reservation and state management considerations.
has_create: bool,

/// Pre-computed PC-to-operation mapping with validation data.
///
/// This table eliminates the double indirection of bytecode[pc] -> opcode -> operation
/// by providing direct operation pointers and pre-cached validation data for each
/// program counter position. This significantly improves execution performance.
pc_to_op_entries: ?[]const PcToOpEntry,

/// NEW: Extended entries with pre-extracted instruction arguments.
/// When available, provides superior cache efficiency over pc_to_op_entries.
extended_entries: ?[]const ExtendedPcToOpEntry = null,

/// NEW: Storage for PUSH9-PUSH32 values.
/// Separate array improves cache locality for common case (no large pushes).
large_push_values: ?[]const u256 = null,

/// Array of block information for block-level execution.
///
/// Each block represents a sequence of instructions that execute linearly
/// without branching. This enables validation and gas consumption at the
/// block level rather than per-instruction.
blocks: ?[]const BlockInfo,

/// Mapping from PC to block index.
///
/// For each program counter position, stores the index of the block
/// containing that instruction. Enables O(1) block lookup during execution.
pc_to_block: ?[]const u32,

/// Releases all memory allocated by this code analysis.
///
/// This method must be called when the analysis is no longer needed to prevent
/// memory leaks. It safely handles all owned resources including:
/// - The code segments bit vector
/// - The jumpdest positions array
/// - The optional block gas costs array
///
/// ## Parameters
/// - `self`: The analysis instance to clean up
/// - `allocator`: The same allocator used to create the analysis resources
///
/// ## Safety
/// After calling deinit, the analysis instance should not be used again.
/// All pointers to analysis data become invalid.
///
/// ## Example
/// ```zig
/// var analysis = try analyze_code(allocator, bytecode);
/// defer analysis.deinit(allocator);
/// ```
pub fn deinit(self: *CodeAnalysis, allocator: std.mem.Allocator) void {
    self.code_segments.deinit(allocator);
    if (self.jumpdest_positions.len > 0) {
        allocator.free(self.jumpdest_positions);
    }
    if (self.block_gas_costs) |costs| {
        allocator.free(costs);
    }
    if (self.pc_to_op_entries) |entries| {
        allocator.free(entries);
    }
    if (self.blocks) |blocks| {
        allocator.free(blocks);
    }
    if (self.pc_to_block) |pc_map| {
        allocator.free(pc_map);
    }
}

test "BlockInfo stores block metadata compactly" {
    const expectEqual = std.testing.expectEqual;
    
    const block = BlockInfo{
        .gas_cost = 21000,
        .stack_req = 2,
        .stack_max_growth = 3,
        .start_pc = 0,
        .end_pc = 10,
        .terminator = .stop,
    };
    
    try expectEqual(@as(u32, 21000), block.gas_cost);
    try expectEqual(@as(u16, 2), block.stack_req);
    try expectEqual(@as(u16, 3), block.stack_max_growth);
    try expectEqual(@as(u32, 0), block.start_pc);
    try expectEqual(@as(u32, 10), block.end_pc);
    try expectEqual(BlockTerminator.stop, block.terminator);
}

test "BlockInfo handles static jump targets" {
    const expectEqual = std.testing.expectEqual;
    const expect = std.testing.expect;
    
    const block = BlockInfo{
        .gas_cost = 100,
        .stack_req = 0,
        .stack_max_growth = 2,
        .start_pc = 0,
        .end_pc = 5,
        .terminator = .jump,
        .static_jump_target = 10,
        .static_jump_valid = true,
    };
    
    try expect(block.static_jump_target != null);
    try expectEqual(@as(u32, 10), block.static_jump_target.?);
    try expect(block.static_jump_valid);
}

test "CodeAnalysis includes block information" {
    const allocator = std.testing.allocator;
    const expect = std.testing.expect;
    const expectEqual = std.testing.expectEqual;
    const Contract = @import("contract.zig");
    
    // PUSH1 0x02 PUSH1 0x03 ADD STOP
    const code = [_]u8{0x60, 0x02, 0x60, 0x03, 0x01, 0x00};
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&code, &hash);
    
    var jump_table = @import("../jump_table/jump_table.zig").init(.CANCUN);
    const analysis = try Contract.analyze_code(allocator, &code, hash, &jump_table);
    defer {
        // Need to cast away const for cleanup
        var mut_analysis = @constCast(analysis);
        mut_analysis.deinit(allocator);
        allocator.destroy(mut_analysis);
    }
    
    try expect(analysis.blocks != null);
    try expectEqual(@as(usize, 1), analysis.blocks.?.len);
    try expectEqual(@as(u32, 0), analysis.blocks.?[0].start_pc);
    try expectEqual(@as(u32, 5), analysis.blocks.?[0].end_pc);
    try expectEqual(BlockTerminator.stop, analysis.blocks.?[0].terminator);
}

test "PC-to-block mapping" {
    const allocator = std.testing.allocator;
    const expect = std.testing.expect;
    const expectEqual = std.testing.expectEqual;
    const Contract = @import("contract.zig");
    
    // PUSH1 0x02 JUMPDEST PUSH1 0x03 STOP
    const code = [_]u8{0x60, 0x02, 0x5b, 0x60, 0x03, 0x00};
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&code, &hash);
    
    var jump_table = @import("../jump_table/jump_table.zig").init(.CANCUN);
    const analysis = try Contract.analyze_code(allocator, &code, hash, &jump_table);
    defer {
        var mut_analysis = @constCast(analysis);
        mut_analysis.deinit(allocator);
        allocator.destroy(mut_analysis);
    }
    
    try expect(analysis.pc_to_block != null);
    try expectEqual(@as(u32, 0), analysis.pc_to_block.?[0]); // PUSH1
    try expectEqual(@as(u32, 0), analysis.pc_to_block.?[1]); // 0x02
    try expectEqual(@as(u32, 1), analysis.pc_to_block.?[2]); // JUMPDEST
    try expectEqual(@as(u32, 1), analysis.pc_to_block.?[3]); // PUSH1
    try expectEqual(@as(u32, 1), analysis.pc_to_block.?[4]); // 0x03
    try expectEqual(@as(u32, 1), analysis.pc_to_block.?[5]); // STOP
}
