const std = @import("std");
const Operation = @import("opcodes/operation.zig");
const ExecutionError = @import("execution/execution_error.zig");
const Frame = @import("frame/frame.zig");
const CodeAnalysis = @import("frame/code_analysis.zig");

// Use the existing BlockMetadata from code_analysis.zig
pub const BlockMetrics = CodeAnalysis.BlockMetadata;

pub const Instruction = struct {
    opcode_fn: ?Operation.ExecutionFunc,  // Optional - null indicates end of stream
    arg: union(enum) {
        none,
        block_metrics: BlockMetrics,
        push_value: u256,
        jump_target: *const Instruction,
        gas_cost: u32,
    },

    pub fn execute(instructions: [*]const Instruction, frame: *Frame) ExecutionError.Error!?[*]const Instruction {
        const log = std.log.scoped(.instruction);
        const self = instructions[0];
        
        log.debug("execute: ptr={*}, opcode_fn={any}, arg={}, pc={}, stack_size={}", .{
            instructions, self.opcode_fn, self.arg, frame.pc, frame.stack.size
        });
        
        // Check if we've reached the end
        if (self.opcode_fn == null) {
            log.debug("execute: Reached null opcode_fn, returning null", .{});
            return null;
        }
        
        // Get the execution module
        const execution = @import("execution/package.zig");
        
        // Check if this is a PUSH instruction with embedded value
        if (self.arg == .push_value) {
            log.debug("execute: PUSH with embedded value={}", .{self.arg.push_value});
            // For PUSH instructions, just push the embedded value and don't call opcode
            try frame.stack.append(self.arg.push_value);
            // Update PC to skip over the push bytes (for compatibility)
            if (self.opcode_fn == execution.stack.op_push0) {
                frame.pc += 1;
                log.debug("execute: PUSH0 - advanced PC by 1 to {}", .{frame.pc});
            } else if (self.opcode_fn == execution.stack.op_push1) {
                frame.pc += 2;
                log.debug("execute: PUSH1 - advanced PC by 2 to {}", .{frame.pc});
            } else {
                // For other PUSH ops, advance PC appropriately
                // This is a bit hacky but needed for compatibility
                frame.pc += 1; // At minimum advance by 1
                log.debug("execute: PUSH(other) - advanced PC by 1 to {}", .{frame.pc});
            }
            log.debug("execute: Returning next instruction at +1", .{});
            return instructions + 1;
        }
        
        // Get the interpreter and state from the frame
        const interpreter: Operation.Interpreter = frame.vm;
        const state: Operation.State = frame;
        
        // Check if this is a JUMP or JUMPI with a resolved target
        if (self.opcode_fn == execution.control.op_jump and self.arg == .jump_target) {
            log.debug("execute: JUMP with resolved target", .{});
            // Use block-based jump with pre-resolved target
            const dest = frame.stack.pop_unsafe();
            log.debug("execute: JUMP destination={}", .{dest});
            
            // Validate jump destination
            if (!frame.contract.valid_jumpdest(frame.allocator, dest)) {
                log.err("execute: Invalid JUMP destination {}", .{dest});
                return ExecutionError.Error.InvalidJump;
            }
            
            // Jump to the pre-resolved target
            log.debug("execute: Jumping to pre-resolved target", .{});
            return @ptrCast(self.arg.jump_target);
        } else if (self.opcode_fn == execution.control.op_jumpi and self.arg == .jump_target) {
            log.debug("execute: JUMPI with resolved target", .{});
            // Use block-based conditional jump
            const dest = frame.stack.pop_unsafe();
            const condition = frame.stack.pop_unsafe();
            log.debug("execute: JUMPI dest={}, condition={}", .{dest, condition});
            
            // If condition is false, continue to next instruction
            if (condition == 0) {
                log.debug("execute: JUMPI condition false, continuing", .{});
                return instructions + 1;
            }
            
            // Validate jump destination
            if (!frame.contract.valid_jumpdest(frame.allocator, dest)) {
                log.err("execute: Invalid JUMPI destination {}", .{dest});
                return ExecutionError.Error.InvalidJump;
            }
            
            // Jump to the pre-resolved target
            log.debug("execute: JUMPI jumping to pre-resolved target", .{});
            return @ptrCast(self.arg.jump_target);
        } else {
            // Execute the opcode function normally
            log.debug("execute: Calling opcode function at pc={}", .{frame.pc});
            // Note: This may return an error like STOP, REVERT, etc. which propagates up
            const result = try self.opcode_fn.?(frame.pc, interpreter, state);
            
            // Update frame PC based on the result
            frame.pc += result.bytes_consumed;
            log.debug("execute: Opcode consumed {} bytes, new pc={}", .{result.bytes_consumed, frame.pc});
            
            // Advance to next instruction
            log.debug("execute: Returning next instruction at +1", .{});
            return instructions + 1;
        }
    }
};

// Tests moved to test/evm/instruction_test.zig to avoid circular dependencies
