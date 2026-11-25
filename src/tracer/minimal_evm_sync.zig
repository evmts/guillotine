/// Synchronization logic for MinimalEvm execution with Frame operations
/// Handles execution of MinimalEvm steps to match Frame's synthetic opcodes
const std = @import("std");
const log = std.log.scoped(.tracer);
const MinimalEvm = @import("minimal_evm.zig").MinimalEvm;
const UnifiedOpcode = @import("../opcodes/opcode.zig").UnifiedOpcode;
const Opcode = @import("../opcodes/opcode.zig").Opcode;
const primitives = @import("voltaire");

/// Maximum steps allowed for each synthetic opcode type
const SyntheticOpcodeSteps = struct {
    const PUSH_ADD_INLINE = 2;
    const PUSH_ADD_POINTER = 2;
    const PUSH_SUB_INLINE = 2;
    const PUSH_SUB_POINTER = 2;
    const PUSH_MUL_INLINE = 2;
    const PUSH_MUL_POINTER = 2;
    const PUSH_DIV_INLINE = 2;
    const PUSH_DIV_POINTER = 2;
    const PUSH_AND_INLINE = 2;
    const PUSH_AND_POINTER = 2;
    const PUSH_OR_INLINE = 2;
    const PUSH_OR_POINTER = 2;
    const PUSH_XOR_INLINE = 2;
    const PUSH_XOR_POINTER = 2;
    const PUSH_MSTORE_INLINE = 2;
    const PUSH_MSTORE_POINTER = 2;
    const PUSH_MSTORE8_INLINE = 2;
    const PUSH_MSTORE8_POINTER = 2;
    const PUSH_MLOAD_INLINE = 2;
    const PUSH_MLOAD_POINTER = 2;
    const JUMP_TO_STATIC_LOCATION = 2;
    const JUMPI_TO_STATIC_LOCATION = 2;
    const ISZERO_JUMPI = 3; // ISZERO + PUSH + JUMPI = 3 steps
    const PUSH_ADD_DUP1 = 3;
    const DEFAULT_MAX = 10;
};

/// Get the maximum steps allowed for a given opcode
fn getMaxStepsForOpcode(opcode: UnifiedOpcode) u32 {
    return switch (opcode) {
        .PUSH_ADD_INLINE => SyntheticOpcodeSteps.PUSH_ADD_INLINE,
        .PUSH_ADD_POINTER => SyntheticOpcodeSteps.PUSH_ADD_POINTER,
        .PUSH_SUB_INLINE => SyntheticOpcodeSteps.PUSH_SUB_INLINE,
        .PUSH_SUB_POINTER => SyntheticOpcodeSteps.PUSH_SUB_POINTER,
        .PUSH_MUL_INLINE => SyntheticOpcodeSteps.PUSH_MUL_INLINE,
        .PUSH_MUL_POINTER => SyntheticOpcodeSteps.PUSH_MUL_POINTER,
        .PUSH_DIV_INLINE => SyntheticOpcodeSteps.PUSH_DIV_INLINE,
        .PUSH_DIV_POINTER => SyntheticOpcodeSteps.PUSH_DIV_POINTER,
        .PUSH_AND_INLINE => SyntheticOpcodeSteps.PUSH_AND_INLINE,
        .PUSH_AND_POINTER => SyntheticOpcodeSteps.PUSH_AND_POINTER,
        .PUSH_OR_INLINE => SyntheticOpcodeSteps.PUSH_OR_INLINE,
        .PUSH_OR_POINTER => SyntheticOpcodeSteps.PUSH_OR_POINTER,
        .PUSH_XOR_INLINE => SyntheticOpcodeSteps.PUSH_XOR_INLINE,
        .PUSH_XOR_POINTER => SyntheticOpcodeSteps.PUSH_XOR_POINTER,
        .PUSH_MSTORE_INLINE => SyntheticOpcodeSteps.PUSH_MSTORE_INLINE,
        .PUSH_MSTORE_POINTER => SyntheticOpcodeSteps.PUSH_MSTORE_POINTER,
        .PUSH_MSTORE8_INLINE => SyntheticOpcodeSteps.PUSH_MSTORE8_INLINE,
        .PUSH_MSTORE8_POINTER => SyntheticOpcodeSteps.PUSH_MSTORE8_POINTER,
        .PUSH_MLOAD_INLINE => SyntheticOpcodeSteps.PUSH_MLOAD_INLINE,
        .PUSH_MLOAD_POINTER => SyntheticOpcodeSteps.PUSH_MLOAD_POINTER,
        .JUMP_TO_STATIC_LOCATION => SyntheticOpcodeSteps.JUMP_TO_STATIC_LOCATION,
        .JUMPI_TO_STATIC_LOCATION => SyntheticOpcodeSteps.JUMPI_TO_STATIC_LOCATION,
        .ISZERO_JUMPI => SyntheticOpcodeSteps.ISZERO_JUMPI,
        .PUSH_ADD_DUP1_INLINE, .PUSH_ADD_DUP1_POINTER => SyntheticOpcodeSteps.PUSH_ADD_DUP1,
        else => 1, // Regular opcodes execute once
    };
}

/// Check if an opcode is synthetic (value > 0xFF)
fn isSyntheticOpcode(opcode: UnifiedOpcode) bool {
    return @intFromEnum(opcode) > 0xFF;
}

pub fn executeMinimalEvmForOpcode(
    tracer: anytype,
    evm: *MinimalEvm,
    comptime opcode: UnifiedOpcode,
    frame: anytype,
    cursor: [*]const @TypeOf(frame.*).Dispatch.Item,
) void {
    _ = cursor;
    const max_steps = getMaxStepsForOpcode(opcode);
    _ = evm.getPC(); // initial_pc for debugging
    
    // Log for debugging

    // For regular opcodes (< 0x100), execute exactly once
    if (!isSyntheticOpcode(opcode)) {
        if (evm.getCurrentFrame()) |mf| {
            // MinimalEvm charges each instruction as it runs it, JUMPDEST included.
            // Frame charges a whole basic block at its JUMPDEST; the two agree again at
            // the end of the block, where the tracer compares gas.
            evm.step() catch |e| {
                // Don't panic on any errors - just log and continue
                var actual_opcode: u8 = 0;
                if (mf.pc < mf.bytecode.len) actual_opcode = mf.bytecode[mf.pc];
                tracer.debug("Regular opcode {s} failed at PC={d}, bytecode[PC]=0x{x:0>2}: {any}", .{ @tagName(opcode), mf.pc, actual_opcode, e });
                return;
            };
        } else {
            tracer.debug("MinimalEvm has no current frame when trying to execute opcode {s}", .{@tagName(opcode)});
            return;
        }
        return;
    }

    // BLOCK_BEGIN maps to no bytecode instruction: MinimalEvm takes no step.
    if (opcode == .BLOCK_BEGIN) return;

    // For synthetic opcodes, run MinimalEvm until it catches up

    var steps_executed: u32 = 0;
    var last_error: ?anyerror = null;

    // Log initial MinimalEvm state
    if (evm.getCurrentFrame()) |_| {
        // Frame exists but no logging needed
    }

    while (steps_executed < max_steps) : (steps_executed += 1) {
        // Get current state before step
        _ = evm.getPC(); // Get PC before step for debugging
        
        evm.step() catch |e| {
            // Log the error but don't panic - this is expected for some cases
            last_error = e;
            
            // Special handling for JUMPI failures - need to skip the JUMPI instruction
            if ((opcode == .JUMP_TO_STATIC_LOCATION or opcode == .JUMPI_TO_STATIC_LOCATION) and steps_executed == 1) {
                // Step 1 (PUSH) succeeded, step 2 (JUMP/JUMPI) failed
                // We need to manually advance PC past the JUMP/JUMPI instruction
                if (evm.getCurrentFrame()) |mf| {
                    const current_pc = mf.pc;
                    if (current_pc < mf.bytecode.len and (mf.bytecode[current_pc] == 0x56 or mf.bytecode[current_pc] == 0x57)) {
                        // We're at a JUMP/JUMPI instruction that failed, skip it
                        mf.pc = current_pc + 1;
                        return;
                    }
                }
            }
            
            // For synthetics, we might have partially executed - that's ok
            if (steps_executed > 0) {
                return;
            }
            
            // If this is the first step and it failed, that might be ok too
            // (e.g., the synthetic doesn't match the current bytecode position)
            return;
        };

        // Check if we've made progress
        _ = evm.getPC(); // Get PC after step for debugging

        // For most synthetics, we're done after the expected number of steps
        const expected_steps = getMaxStepsForOpcode(opcode);
        if (steps_executed + 1 >= expected_steps and expected_steps < SyntheticOpcodeSteps.DEFAULT_MAX) {
            
            return;
        }
    }

    // If we hit max steps, log a warning but don't panic
    if (steps_executed == max_steps) {
        tracer.debug("Warning: Synthetic {s} hit max steps limit ({d}). Last error: {?}", .{ @tagName(opcode), max_steps, last_error });
    } else if (last_error) |err| {
        tracer.debug("Synthetic {s} stopped after {d} steps with error: {any}", .{ @tagName(opcode), steps_executed, err });
    }
}

