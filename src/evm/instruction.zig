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
        const self = instructions[0];
        
        // Check if we've reached the end
        if (self.opcode_fn == null) {
            return null;
        }
        
        // Get the interpreter and state from the frame
        const interpreter: Operation.Interpreter = frame.vm;
        const state: Operation.State = frame;
        
        // Check if this is a JUMP or JUMPI with a resolved target
        const execution = @import("execution/package.zig");
        if (self.opcode_fn == execution.control.op_jump and self.arg == .jump_target) {
            // Use block-based jump with pre-resolved target
            const dest = frame.stack.pop_unsafe();
            
            // Validate jump destination
            if (!frame.contract.valid_jumpdest(frame.allocator, dest)) {
                return ExecutionError.Error.InvalidJump;
            }
            
            // Jump to the pre-resolved target
            return @ptrCast(self.arg.jump_target);
        } else if (self.opcode_fn == execution.control.op_jumpi and self.arg == .jump_target) {
            // Use block-based conditional jump
            const dest = frame.stack.pop_unsafe();
            const condition = frame.stack.pop_unsafe();
            
            // If condition is false, continue to next instruction
            if (condition == 0) {
                return instructions + 1;
            }
            
            // Validate jump destination
            if (!frame.contract.valid_jumpdest(frame.allocator, dest)) {
                return ExecutionError.Error.InvalidJump;
            }
            
            // Jump to the pre-resolved target
            return @ptrCast(self.arg.jump_target);
        } else {
            // Execute the opcode function normally
            const result = try self.opcode_fn.?(frame.pc, interpreter, state);
            _ = result;
            
            // Advance to next instruction
            return instructions + 1;
        }
    }
};

// Tests moved to test/evm/instruction_test.zig to avoid circular dependencies
