const std = @import("std");
const builtin = @import("builtin");
const ExecutionError = @import("execution/execution_error.zig");
const ExecutionFunc = @import("execution_func.zig").ExecutionFunc;

// Execution-classification used by analysis helpers
pub const JumpType = enum { jump, jumpi, other };

// Packed instruction header: tag + id into per-variant payload arrays.
// Tags are divided into two categories:
// 1. Real EVM opcodes (0x00-0xFF) - will replace exec/dynamic_gas
// 2. Synthetic tags (>0xFF) - for control flow and special handling
pub const Tag = enum(u16) {
    // Synthetic tags for control flow (start at 0x100)
    noop = 0x100,
    word = 0x101,
    jump_pc = 0x102,
    jump_unresolved = 0x103,
    conditional_jump_idx = 0x104,
    conditional_jump_pc = 0x105,
    conditional_jump_unresolved = 0x106,
    conditional_jump_invalid = 0x107,
    pc = 0x108,
    block_info = 0x109,
    
    // Real EVM opcodes (0x00-0xFF) - value equals opcode byte
    op_stop = 0x00,
    op_add = 0x01,
    op_mul = 0x02,
    op_sub = 0x03,
    op_div = 0x04,
    op_sdiv = 0x05,
    op_mod = 0x06,
    op_smod = 0x07,
    op_addmod = 0x08,
    op_mulmod = 0x09,
    op_exp = 0x0a,
    op_signextend = 0x0b,
    
    op_lt = 0x10,
    op_gt = 0x11,
    op_slt = 0x12,
    op_sgt = 0x13,
    op_eq = 0x14,
    op_iszero = 0x15,
    op_and = 0x16,
    op_or = 0x17,
    op_xor = 0x18,
    op_not = 0x19,
    op_byte = 0x1a,
    op_shl = 0x1b,
    op_shr = 0x1c,
    op_sar = 0x1d,
    
    op_keccak256 = 0x20,
    
    op_address = 0x30,
    op_balance = 0x31,
    op_origin = 0x32,
    op_caller = 0x33,
    op_callvalue = 0x34,
    op_calldataload = 0x35,
    op_calldatasize = 0x36,
    op_calldatacopy = 0x37,
    op_codesize = 0x38,
    op_codecopy = 0x39,
    op_gasprice = 0x3a,
    op_extcodesize = 0x3b,
    op_extcodecopy = 0x3c,
    op_returndatasize = 0x3d,
    op_returndatacopy = 0x3e,
    op_extcodehash = 0x3f,
    
    op_blockhash = 0x40,
    op_coinbase = 0x41,
    op_timestamp = 0x42,
    op_number = 0x43,
    op_difficulty = 0x44,
    op_gaslimit = 0x45,
    op_chainid = 0x46,
    op_selfbalance = 0x47,
    op_basefee = 0x48,
    op_blobhash = 0x49,
    op_blobbasefee = 0x4a,
    
    op_pop = 0x50,
    op_mload = 0x51,
    op_mstore = 0x52,
    op_mstore8 = 0x53,
    op_sload = 0x54,
    op_sstore = 0x55,
    op_jump = 0x56,
    op_jumpi = 0x57,
    op_pc = 0x58,
    op_msize = 0x59,
    op_gas = 0x5a,
    op_jumpdest = 0x5b,
    op_tload = 0x5c,
    op_tstore = 0x5d,
    op_mcopy = 0x5e,
    op_push0 = 0x5f,
    
    // Push operations 0x60-0x7f handled via .word
    op_push1 = 0x60,
    op_push2 = 0x61,
    op_push3 = 0x62,
    op_push4 = 0x63,
    op_push5 = 0x64,
    op_push6 = 0x65,
    op_push7 = 0x66,
    op_push8 = 0x67,
    op_push9 = 0x68,
    op_push10 = 0x69,
    op_push11 = 0x6a,
    op_push12 = 0x6b,
    op_push13 = 0x6c,
    op_push14 = 0x6d,
    op_push15 = 0x6e,
    op_push16 = 0x6f,
    op_push17 = 0x70,
    op_push18 = 0x71,
    op_push19 = 0x72,
    op_push20 = 0x73,
    op_push21 = 0x74,
    op_push22 = 0x75,
    op_push23 = 0x76,
    op_push24 = 0x77,
    op_push25 = 0x78,
    op_push26 = 0x79,
    op_push27 = 0x7a,
    op_push28 = 0x7b,
    op_push29 = 0x7c,
    op_push30 = 0x7d,
    op_push31 = 0x7e,
    op_push32 = 0x7f,
    
    // Dup operations 0x80-0x8f
    op_dup1 = 0x80,
    op_dup2 = 0x81,
    op_dup3 = 0x82,
    op_dup4 = 0x83,
    op_dup5 = 0x84,
    op_dup6 = 0x85,
    op_dup7 = 0x86,
    op_dup8 = 0x87,
    op_dup9 = 0x88,
    op_dup10 = 0x89,
    op_dup11 = 0x8a,
    op_dup12 = 0x8b,
    op_dup13 = 0x8c,
    op_dup14 = 0x8d,
    op_dup15 = 0x8e,
    op_dup16 = 0x8f,
    
    // Swap operations 0x90-0x9f
    op_swap1 = 0x90,
    op_swap2 = 0x91,
    op_swap3 = 0x92,
    op_swap4 = 0x93,
    op_swap5 = 0x94,
    op_swap6 = 0x95,
    op_swap7 = 0x96,
    op_swap8 = 0x97,
    op_swap9 = 0x98,
    op_swap10 = 0x99,
    op_swap11 = 0x9a,
    op_swap12 = 0x9b,
    op_swap13 = 0x9c,
    op_swap14 = 0x9d,
    op_swap15 = 0x9e,
    op_swap16 = 0x9f,
    
    // Log operations 0xa0-0xa4
    op_log0 = 0xa0,
    op_log1 = 0xa1,
    op_log2 = 0xa2,
    op_log3 = 0xa3,
    op_log4 = 0xa4,
    
    // System operations 0xf0-0xff
    op_create = 0xf0,
    op_call = 0xf1,
    op_callcode = 0xf2,
    op_return = 0xf3,
    op_delegatecall = 0xf4,
    op_create2 = 0xf5,
    op_staticcall = 0xfa,
    op_revert = 0xfd,
    op_invalid = 0xfe,
    op_selfdestruct = 0xff,
};

// 32-bit packed header gives roomy id space while staying very compact
pub const Instruction = packed struct(u32) {
    tag: Tag,  // Now 16 bits to accommodate all opcodes
    id: u16,   // Reduced to 16 bits, still plenty of space
};

/// Comptime function that returns the struct type for a given tag
pub fn InstructionType(comptime tag: Tag) type {
    // Check if it's a real opcode first
    if (comptime isRealOpcode(tag)) {
        // Real opcodes don't have payload types - they use direct dispatch
        return void;
    }
    
    return switch (tag) {
        .noop => NoopInstruction,
        .jump_pc => JumpPcInstruction,
        .conditional_jump_unresolved => ConditionalJumpUnresolvedInstruction,
        .conditional_jump_invalid => ConditionalJumpInvalidInstruction,
        .conditional_jump_pc => ConditionalJumpPcInstruction,
        .word => WordInstruction,
        .pc => PcInstruction,
        .block_info => BlockInstruction,
        .jump_unresolved => unreachable, // Handled specially
        .conditional_jump_idx => unreachable, // Not used
        else => unreachable, // Real opcodes don't have payloads
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
        .block_info => @sizeOf(BlockInstruction),
        .word => @sizeOf(WordInstruction),
        .jump_unresolved, .conditional_jump_idx => 0, // Special handling
        // All real opcodes don't have instruction sizes (will use direct dispatch)
        else => if (isRealOpcode(tag)) 0 else unreachable,
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

/// Noop instruction (no data needed, tag is sufficient)
pub const NoopInstruction = struct {};

/// Block instruction with validation data only
pub const BlockInstruction = struct {
    gas_cost: u32,
    stack_req: u16,
    stack_max_growth: u16,
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
// Helper functions for working with tags
pub inline fn isRealOpcode(tag: Tag) bool {
    return @intFromEnum(tag) <= 0xFF;
}

pub inline fn isSynthetic(tag: Tag) bool {
    const val = @intFromEnum(tag);
    return val >= 0x100 and val < 0xFFF0;
}

pub inline fn isLegacy(tag: Tag) bool {
    const val = @intFromEnum(tag);
    return val >= 0xFFF0;
}

pub inline fn opcodeToTag(opcode: u8) Tag {
    return @enumFromInt(@as(u16, opcode));
}

comptime {
    // Enum storage expectations
    if (@sizeOf(Tag) != 2) @compileError("Tag enum must be 2 bytes (enum(u16))");
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
    // BlockInstruction: u32 + u16 + u16 = 8 bytes
    if (@sizeOf(BlockInstruction) != 8) @compileError("BlockInstruction must be 8 bytes");
    
    // WordInstruction: slice (8 or 16 bytes)
    const word_size = @sizeOf(WordInstruction);
    if (word_size != 8 and word_size != 16) @compileError("WordInstruction must be 8 or 16 bytes");

    // Size table sanity check
    if (getInstructionSize(.noop) != @sizeOf(NoopInstruction)) @compileError("noop size mismatch");
    if (getInstructionSize(.jump_pc) != @sizeOf(JumpPcInstruction)) @compileError("jump_pc size mismatch");
    if (getInstructionSize(.conditional_jump_unresolved) != @sizeOf(ConditionalJumpUnresolvedInstruction)) @compileError("conditional_jump_unresolved size mismatch");
    if (getInstructionSize(.conditional_jump_invalid) != @sizeOf(ConditionalJumpInvalidInstruction)) @compileError("conditional_jump_invalid size mismatch");
    if (getInstructionSize(.conditional_jump_pc) != @sizeOf(ConditionalJumpPcInstruction)) @compileError("conditional_jump_pc size mismatch");
    if (getInstructionSize(.pc) != @sizeOf(PcInstruction)) @compileError("pc size mismatch");
    if (getInstructionSize(.block_info) != @sizeOf(BlockInstruction)) @compileError("block_info size mismatch");
    if (getInstructionSize(.word) != @sizeOf(WordInstruction)) @compileError("word size mismatch");
}
