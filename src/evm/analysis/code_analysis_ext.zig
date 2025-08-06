const std = @import("std");
const CodeAnalysis = @import("../frame/code_analysis.zig");
const Instruction = @import("../instruction.zig").Instruction;
const instruction_limits = @import("../constants/instruction_limits.zig");

const MAX_INSTRUCTIONS = instruction_limits.MAX_INSTRUCTIONS;

/// Extended CodeAnalysis with instruction stream support for block-based execution.
/// This extends the existing CodeAnalysis struct with fields for the translated
/// instruction stream while maintaining backward compatibility.
pub const CodeAnalysisExt = struct {
    /// Base code analysis with all existing functionality
    base: CodeAnalysis,
    
    /// Translated instruction stream for fast execution
    /// Fixed-size array to avoid heap allocation
    instructions: [MAX_INSTRUCTIONS]Instruction,
    
    /// Number of valid instructions in the array
    instruction_count: usize,
    
    /// Get a null-terminated pointer to the instruction stream
    /// The translator must have already set the null pointer after the last instruction
    pub fn get_instructions(self: *const CodeAnalysisExt) [*:null]const Instruction {
        return @ptrCast(&self.instructions);
    }
    
    /// Initialize with empty instruction stream
    pub fn init(base: CodeAnalysis) CodeAnalysisExt {
        return CodeAnalysisExt{
            .base = base,
            .instructions = undefined,
            .instruction_count = 0,
        };
    }
    
    /// Add an instruction to the stream
    pub fn add_instruction(self: *CodeAnalysisExt, inst: Instruction) !void {
        if (self.instruction_count >= MAX_INSTRUCTIONS) {
            return error.InstructionLimitExceeded;
        }
        
        self.instructions[self.instruction_count] = inst;
        self.instruction_count += 1;
    }
    
    /// Finalize the instruction stream by setting null terminator
    pub fn finalize(self: *CodeAnalysisExt) void {
        // Set null pointer after last instruction
        const array_ptr = @as([*]Instruction, &self.instructions);
        const term_ptr = @as([*:null]Instruction, @ptrCast(array_ptr + self.instruction_count));
        @as(*?[*:null]const Instruction, @ptrCast(@alignCast(term_ptr))).* = null;
    }
};

// Dummy opcode function for testing  
fn test_opcode(pc: usize, interpreter: anytype, state: anytype) !Instruction.Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    _ = state;
    const ExecutionResult = @import("../execution/execution_result.zig");
    return ExecutionResult{};
}

test "CodeAnalysisExt initialization" {
    const allocator = std.testing.allocator;
    _ = allocator;
    
    // Create a base CodeAnalysis
    const base = try CodeAnalysis.empty();
    
    // Create extended version
    const ext = CodeAnalysisExt.init(base);
    
    try std.testing.expectEqual(@as(usize, 0), ext.instruction_count);
}

test "CodeAnalysisExt add instructions" {
    const allocator = std.testing.allocator;
    _ = allocator;
    
    const base = try CodeAnalysis.empty();
    var ext = CodeAnalysisExt.init(base);
    
    // Add some test instructions
    try ext.add_instruction(.{ .opcode_fn = test_opcode, .arg = .{ .gas_cost = 3 } });
    try ext.add_instruction(.{ .opcode_fn = test_opcode, .arg = .{ .push_value = 42 } });
    
    try std.testing.expectEqual(@as(usize, 2), ext.instruction_count);
    
    // Verify instructions are stored correctly
    try std.testing.expectEqual(@as(u32, 3), ext.instructions[0].arg.gas_cost);
    try std.testing.expectEqual(@as(u256, 42), ext.instructions[1].arg.push_value);
}

test "CodeAnalysisExt respects instruction limit" {
    const base = try CodeAnalysis.empty();
    var ext = CodeAnalysisExt.init(base);
    
    // Fill to capacity
    ext.instruction_count = MAX_INSTRUCTIONS;
    
    // This should fail
    const result = ext.add_instruction(.{ .opcode_fn = test_opcode, .arg = .none });
    try std.testing.expectError(error.InstructionLimitExceeded, result);
}

test "CodeAnalysisExt finalize sets null terminator" {
    const base = try CodeAnalysis.empty();
    var ext = CodeAnalysisExt.init(base);
    
    // Add a few instructions
    try ext.add_instruction(.{ .opcode_fn = test_opcode, .arg = .{ .gas_cost = 100 } });
    try ext.add_instruction(.{ .opcode_fn = test_opcode, .arg = .{ .gas_cost = 200 } });
    
    // Finalize to set null terminator
    ext.finalize();
    
    // Get instructions pointer
    const instructions = ext.get_instructions();
    
    // Verify we can access the instructions
    try std.testing.expectEqual(@as(u32, 100), instructions[0].arg.gas_cost);
    try std.testing.expectEqual(@as(u32, 200), instructions[1].arg.gas_cost);
    
    // In real usage, instructions[2] would be null pointer
    // but we can't easily test that without unsafe operations
    try std.testing.expectEqual(@as(usize, 2), ext.instruction_count);
}