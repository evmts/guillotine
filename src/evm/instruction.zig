const std = @import("std");
const builtin = @import("builtin");
const ExecutionError = @import("execution/execution_error.zig");
const ExecutionFunc = @import("execution_func.zig").ExecutionFunc;

// Execution-classification used by analysis helpers
pub const JumpType = enum { jump, jumpi, other };

// Packed instruction header: tag + id into per-variant payload arrays.
pub const Tag = enum(u8) {
    noop,
    word,
    jump_pc,
    jump_unresolved,
    conditional_jump_idx,
    conditional_jump_pc,
    conditional_jump_unresolved,
    conditional_jump_invalid,
    pc,
    block_info,
    dynamic_gas,
    exec,
};

// 32-bit packed header gives roomy id space while staying very compact
pub const Instruction = packed struct(u32) {
    tag: Tag,
    id: u24,
};

/// Comptime function that returns the struct type for a given tag
pub fn InstructionType(comptime tag: Tag) type {
    return switch (tag) {
        .noop => NoopInstruction,
        .jump_pc => JumpPcInstruction,
        .conditional_jump_unresolved => ConditionalJumpUnresolvedInstruction,
        .conditional_jump_invalid => ConditionalJumpInvalidInstruction,
        .exec => ExecInstruction,
        .conditional_jump_pc => ConditionalJumpPcInstruction,
        .word => WordInstruction,
        .pc => PcInstruction,
        .block_info => BlockInstruction,
        .dynamic_gas => DynamicGasInstruction,
        .jump_unresolved => unreachable, // Handled specially
        .conditional_jump_idx => unreachable, // Not used
    };
}

/// Returns the size category for a given tag
pub fn getInstructionSize(comptime tag: Tag) usize {
    const size = switch (tag) {
        .noop => @sizeOf(NoopInstruction),
        .conditional_jump_unresolved => @sizeOf(ConditionalJumpUnresolvedInstruction),
        .conditional_jump_invalid => @sizeOf(ConditionalJumpInvalidInstruction),
        .jump_pc => @sizeOf(JumpPcInstruction),
        .conditional_jump_pc => @sizeOf(ConditionalJumpPcInstruction),
        .pc => @sizeOf(PcInstruction),
        .exec => @sizeOf(ExecInstruction),
        .block_info => @sizeOf(BlockInstruction),
        .dynamic_gas => @sizeOf(DynamicGasInstruction),
        .word => @sizeOf(WordInstruction),
        .jump_unresolved, .conditional_jump_idx => 0, // Special handling
    };
    
    // Validate that the size is a valid bucket size
    // Valid bucket sizes are: 0, 2, 4, 8, 16
    if (size != 0 and size != 2 and size != 4 and size != 8 and size != 16) {
        @compileError("Invalid instruction size - must be 0, 2, 4, 8, or 16 bytes");
    }
    
    return size;
}

// Compact reference to bytes in analyzed contract `code`.
// - `start_pc` is the byte offset within `code`
// - `len` is the number of immediate bytes (0..32)
pub const WordRef = struct {
    start_pc: u16,
    len: u16,
};

/// Block information for BEGINBLOCK instructions.
/// Contains pre-calculated validation data for an entire basic block.
pub const BlockInfo = struct {
    gas_cost: u32 = 0,
    stack_req: u16 = 0,
    stack_max_growth: u16 = 0,
};

/// Function signature for dynamic gas calculation.
pub const DynamicGasFunc = *const fn (frame: *anyopaque) ExecutionError.Error!u64;

/// Information for opcodes that have dynamic gas costs
pub const DynamicGas = struct {
    gas_fn: DynamicGasFunc,
    exec_fn: ExecutionFunc,
};

/// Execution instruction with function pointer only
pub const ExecInstruction = struct {
    exec_fn: ExecutionFunc,
};

/// Noop instruction (no data needed, tag is sufficient)
pub const NoopInstruction = struct {};

/// Block instruction with validation data only
pub const BlockInstruction = struct {
    gas_cost: u32,
    stack_req: u16,
    stack_max_growth: u16,
};

/// Dynamic gas instruction with gas function and exec function
pub const DynamicGasInstruction = struct {
    gas_fn: DynamicGasFunc,
    exec_fn: ExecutionFunc,
};

/// Conditional jump to invalid destination (no data needed, tag is sufficient)
pub const ConditionalJumpInvalidInstruction = struct {};

/// PC instruction with PC value only
pub const PcInstruction = struct {
    pc_value: u16,
};

/// Conditional jump with known target index
pub const ConditionalJumpPcInstruction = struct {
    jump_idx: u16, // instruction index to jump to if condition is true
};

/// Word instruction with bytecode slice only
pub const WordInstruction = struct {
    word_bytes: []const u8, // Slice view into bytecode (1-32 bytes)
};

/// Jump PC instruction with target index
pub const JumpPcInstruction = struct {
    jump_idx: u16, // instruction index to jump to
};

/// Conditional jump with unresolved target (no data needed, tag is sufficient)
pub const ConditionalJumpUnresolvedInstruction = struct {};

pub fn NoopHandler(context: *anyopaque) ExecutionError.Error!void {
    _ = context;
    return;
}

// ============================================================================
// Compile-time layout assertions for instruction payloads and header
comptime {
    // Enum storage expectations
    if (@sizeOf(Tag) != 1) @compileError("Tag enum must be 1 byte (enum(u8))");
    if (@sizeOf(JumpType) > 1) @compileError("JumpType should be compact (<=1 byte)");
    // Header must remain tightly packed: 4 bytes
    if (@sizeOf(Instruction) != 4) @compileError("Instruction must be exactly 4 bytes");

    // 0-byte group (tag-only instructions)
    if (@sizeOf(NoopInstruction) != 0) @compileError("NoopInstruction must be 0 bytes");
    if (@sizeOf(ConditionalJumpUnresolvedInstruction) != 0) @compileError("ConditionalJumpUnresolvedInstruction must be 0 bytes");
    if (@sizeOf(ConditionalJumpInvalidInstruction) != 0) @compileError("ConditionalJumpInvalidInstruction must be 0 bytes");

    // 2-byte bucket group
    if (@sizeOf(JumpPcInstruction) != 2) @compileError("JumpPcInstruction must be 2 bytes");
    if (@sizeOf(ConditionalJumpPcInstruction) != 2) @compileError("ConditionalJumpPcInstruction must be 2 bytes");
    if (@sizeOf(PcInstruction) != 2) @compileError("PcInstruction must be 2 bytes");

    // Validate instruction sizes fit in bucket system
    // ExecInstruction: single function pointer (4 or 8 bytes)
    const exec_size = @sizeOf(ExecInstruction);
    if (exec_size != 4 and exec_size != 8) @compileError("ExecInstruction must be 4 or 8 bytes");
    
    // BlockInstruction: u32 + u16 + u16 = 8 bytes
    if (@sizeOf(BlockInstruction) != 8) @compileError("BlockInstruction must be 8 bytes");

    // DynamicGasInstruction: two function pointers (8 or 16 bytes)
    const dynamic_size = @sizeOf(DynamicGasInstruction);
    if (dynamic_size != 8 and dynamic_size != 16) @compileError("DynamicGasInstruction must be 8 or 16 bytes");
    
    // WordInstruction: slice (8 or 16 bytes)
    const word_size = @sizeOf(WordInstruction);
    if (word_size != 8 and word_size != 16) @compileError("WordInstruction must be 8 or 16 bytes");

    // Size table sanity check
    if (getInstructionSize(.noop) != @sizeOf(NoopInstruction)) @compileError("noop size mismatch");
    if (getInstructionSize(.jump_pc) != @sizeOf(JumpPcInstruction)) @compileError("jump_pc size mismatch");
    if (getInstructionSize(.conditional_jump_unresolved) != @sizeOf(ConditionalJumpUnresolvedInstruction)) @compileError("conditional_jump_unresolved size mismatch");
    if (getInstructionSize(.conditional_jump_invalid) != @sizeOf(ConditionalJumpInvalidInstruction)) @compileError("conditional_jump_invalid size mismatch");
    if (getInstructionSize(.exec) != @sizeOf(ExecInstruction)) @compileError("exec size mismatch");
    if (getInstructionSize(.conditional_jump_pc) != @sizeOf(ConditionalJumpPcInstruction)) @compileError("conditional_jump_pc size mismatch");
    if (getInstructionSize(.pc) != @sizeOf(PcInstruction)) @compileError("pc size mismatch");
    if (getInstructionSize(.block_info) != @sizeOf(BlockInstruction)) @compileError("block_info size mismatch");
    if (getInstructionSize(.dynamic_gas) != @sizeOf(DynamicGasInstruction)) @compileError("dynamic_gas size mismatch");
    if (getInstructionSize(.word) != @sizeOf(WordInstruction)) @compileError("word size mismatch");
}
