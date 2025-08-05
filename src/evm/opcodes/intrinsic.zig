/// Intrinsic opcodes for internal EVM optimizations.
///
/// These are not real EVM opcodes but internal instructions used by the
/// interpreter for optimization purposes. They maintain full EVM compatibility
/// while enabling advanced execution strategies.
///
/// ## BEGINBLOCK Pattern
/// 
/// The BEGINBLOCK instruction is injected at the start of every basic block
/// during code analysis. It performs bulk validation of gas and stack requirements
/// for the entire block, eliminating per-instruction checks within the block.
///
/// This follows the evmone "Advanced" interpreter design for maximum performance.

const std = @import("std");

/// Intrinsic opcodes that don't exist in the EVM specification.
/// These are used internally for optimization purposes.
pub const IntrinsicOpcodes = enum(u8) {
    /// The BEGINBLOCK instruction.
    ///
    /// This instruction is injected at the beginning of all basic blocks
    /// during analysis. It validates:
    /// - Gas requirements for the entire block
    /// - Stack underflow/overflow conditions
    /// - Other block-level preconditions
    ///
    /// We use 0xFE as it's an unused opcode in the EVM spec.
    /// (0xFE was previously INVALID, now we repurpose it internally)
    BEGINBLOCK = 0xFE,
};

/// Check if an opcode is an intrinsic (not a real EVM opcode).
pub fn is_intrinsic(opcode: u8) bool {
    return opcode == @intFromEnum(IntrinsicOpcodes.BEGINBLOCK);
}

/// Get the name of an intrinsic opcode.
pub fn get_intrinsic_name(opcode: u8) []const u8 {
    return switch (opcode) {
        @intFromEnum(IntrinsicOpcodes.BEGINBLOCK) => "BEGINBLOCK",
        else => "UNKNOWN_INTRINSIC",
    };
}