const std = @import("std");
const Operation = @import("opcodes/operation.zig");
const ExecutionError = @import("execution/execution_error.zig");
const Frame = @import("frame/frame.zig");
const CodeAnalysis = @import("frame/code_analysis.zig");

// Use the existing BlockMetadata from code_analysis.zig
pub const BlockMetrics = CodeAnalysis.BlockMetadata;

pub const Instruction = struct {
    opcode_fn: Operation.ExecutionFunc,  // NOT optional - pointer itself is null at end
    arg: union(enum) {
        none,
        block_metrics: BlockMetrics,
        push_value: u256,
        jump_target: [*:null]const Instruction,
        gas_cost: u32,
    },

    pub fn execute(instructions: [*:null]const Instruction, frame: *Frame) ExecutionError.Error!?[*:null]const Instruction {
        const self = instructions[0];
        
        // Get the interpreter and state from the frame
        const interpreter: Operation.Interpreter = frame.vm;
        const state: Operation.State = frame;
        
        // Execute the opcode function
        const result = try self.opcode_fn(frame.pc, interpreter, state);
        _ = result;
        
        // Advance to next instruction
        return instructions + 1;
    }
};

// Tests moved to test/evm/instruction_test.zig to avoid circular dependencies
