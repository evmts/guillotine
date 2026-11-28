/// Synchronization logic for MinimalEvm execution with Frame operations
/// Handles execution of MinimalEvm steps to match Frame's synthetic opcodes
const std = @import("std");
const MinimalEvm = @import("minimal_evm.zig").MinimalEvm;
const UnifiedOpcode = @import("../opcodes/opcode.zig").UnifiedOpcode;

/// Number of bytecode instructions the Frame handler for `opcode` executes, which is
/// the number of steps the sidecar takes to stay level with it.
pub fn instructionsCovered(comptime opcode: UnifiedOpcode) u8 {
    return switch (opcode) {
        .PUSH_ADD_INLINE, .PUSH_ADD_POINTER, .PUSH_SUB_INLINE, .PUSH_SUB_POINTER => 2,
        .PUSH_MUL_INLINE, .PUSH_MUL_POINTER, .PUSH_DIV_INLINE, .PUSH_DIV_POINTER => 2,
        .PUSH_AND_INLINE, .PUSH_AND_POINTER, .PUSH_OR_INLINE, .PUSH_OR_POINTER => 2,
        .PUSH_XOR_INLINE, .PUSH_XOR_POINTER => 2,
        .PUSH_MLOAD_INLINE, .PUSH_MLOAD_POINTER, .PUSH_MSTORE_INLINE, .PUSH_MSTORE_POINTER => 2,
        .PUSH_MSTORE8_INLINE, .PUSH_MSTORE8_POINTER => 2,
        .JUMP_TO_STATIC_LOCATION, .JUMPI_TO_STATIC_LOCATION => 2,
        .ISZERO_JUMPI, .PUSH_ADD_DUP1_INLINE, .PUSH_ADD_DUP1_POINTER => 3,
        // Block entry and the invalid-jump trap are not bytecode instructions.
        .BLOCK_BEGIN, .INVALID_JUMP_TARGET => 0,
        else => if (@backingInt(opcode) <= 0xFF)
            1
        else
            @compileError("minimal_evm_sync: unmapped synthetic opcode " ++ @tagName(opcode)),
    };
}

/// Advance the sidecar by the bytecode instructions the Frame handler for `opcode` is
/// about to execute.
///
/// A step error halts the sidecar: the error is handed to the tracer
/// (`recordSidecarStepError`) and no later step runs. That alone is not a divergence,
/// because Frame may halt on the same instruction. The tracer compares the two at
/// frame exit (`Tracer.onInterpretExit`), and a Frame that executes another
/// instruction past a halted sidecar is reported here (`reportSidecarOverrun`).
pub fn executeMinimalEvmForOpcode(tracer: anytype, evm: *MinimalEvm, comptime opcode: UnifiedOpcode) void {
    const steps = comptime instructionsCovered(opcode);
    if (steps == 0) return;
    if (tracer.sidecar_error != null) {
        tracer.reportSidecarOverrun(@tagName(opcode));
        return;
    }
    var taken: u8 = 0;
    while (taken < steps) : (taken += 1) {
        const pc = evm.getPC();
        evm.step() catch |err| {
            tracer.recordSidecarStepError(@tagName(opcode), pc, err);
            return;
        };
    }
}

test "instructionsCovered maps every handler to the instructions it covers" {
    try std.testing.expectEqual(@as(u8, 1), comptime instructionsCovered(.ADD));
    try std.testing.expectEqual(@as(u8, 2), comptime instructionsCovered(.PUSH_MSTORE_INLINE));
    try std.testing.expectEqual(@as(u8, 3), comptime instructionsCovered(.ISZERO_JUMPI));
    try std.testing.expectEqual(@as(u8, 0), comptime instructionsCovered(.BLOCK_BEGIN));
    try std.testing.expectEqual(@as(u8, 0), comptime instructionsCovered(.INVALID_JUMP_TARGET));
}
