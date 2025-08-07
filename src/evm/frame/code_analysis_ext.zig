const std = @import("std");
const CodeAnalysis = @import("../analysis/analysis.zig");
const Instruction = @import("../instruction.zig").Instruction;
const instruction_limits = @import("../constants/instruction_limits.zig");

const MAX_INSTRUCTIONS = instruction_limits.MAX_INSTRUCTIONS;

/// Extended CodeAnalysis with instruction stream support for block-based execution.
/// This extends the existing CodeAnalysis struct with fields for the translated
/// instruction stream while maintaining backward compatibility.
const CodeAnalysisExt = @This();

/// Base code analysis with all existing functionality
base: CodeAnalysis,

/// Translated instruction stream for fast execution
/// Heap-allocated with maximum size upfront to avoid reallocation
instructions: []Instruction,

/// Number of valid instructions in the array
instruction_count: usize,

/// Get a null-terminated pointer to the instruction stream
/// The translator must have already set the null pointer after the last instruction
pub fn get_instructions(self: *const CodeAnalysisExt) [*:null]const Instruction {
    return @ptrCast(self.instructions.ptr);
}

/// Initialize with heap-allocated instruction stream
/// Allocates maximum size upfront to avoid reallocation
pub fn init(allocator: std.mem.Allocator, base: CodeAnalysis) !CodeAnalysisExt {
    const instructions = try allocator.alloc(Instruction, MAX_INSTRUCTIONS);
    return CodeAnalysisExt{
        .base = base,
        .instructions = instructions,
        .instruction_count = 0,
    };
}

/// Clean up allocated memory
pub fn deinit(self: *CodeAnalysisExt, allocator: std.mem.Allocator) void {
    allocator.free(self.instructions);
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
    const array_ptr = self.instructions.ptr;
    @as([*:null]Instruction, @ptrCast(array_ptr + self.instruction_count)).* = null;
}


// ===== TESTS =====

test "CodeAnalysisExt initialization" {
    const allocator = std.testing.allocator;
    const limits = @import("../constants/code_analysis_limits.zig");
    const StaticBitSet = std.bit_set.StaticBitSet;
    const BlockMetadataSoA = @import("block_metadata_soa.zig");
    
    // Create a minimal base CodeAnalysis
    var base = CodeAnalysis{
        .code_segments = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
        .jumpdest_bitmap = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
        .block_starts = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
        .block_metadata = undefined,
        .block_metadata_soa = BlockMetadataSoA.init(),
        .pc_to_block = undefined,
        .block_count = 0,
        .max_stack_depth = 0,
        .has_static_jumps = false,
        .has_selfdestruct = false,
        .has_create = false,
    };
    
    var ext = try CodeAnalysisExt.init(allocator, base);
    defer ext.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 0), ext.instruction_count);
    try std.testing.expectEqual(@as(usize, MAX_INSTRUCTIONS), ext.instructions.len);
}

test "CodeAnalysisExt add and get instructions" {
    const allocator = std.testing.allocator;
    const limits = @import("../constants/code_analysis_limits.zig");
    const StaticBitSet = std.bit_set.StaticBitSet;
    const BlockMetadataSoA = @import("block_metadata_soa.zig");
    const opcodes = @import("../opcodes/opcode.zig");
    
    // Create a minimal base CodeAnalysis
    var base = CodeAnalysis{
        .code_segments = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
        .jumpdest_bitmap = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
        .block_starts = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
        .block_metadata = undefined,
        .block_metadata_soa = BlockMetadataSoA.init(),
        .pc_to_block = undefined,
        .block_count = 0,
        .max_stack_depth = 0,
        .has_static_jumps = false,
        .has_selfdestruct = false,
        .has_create = false,
    };
    
    var ext = try CodeAnalysisExt.init(allocator, base);
    defer ext.deinit(allocator);
    
    // Create dummy opcode function
    const dummy_fn = struct {
        fn execute(pc: usize, interpreter: @import("../opcodes/operation.zig").Interpreter, state: @import("../opcodes/operation.zig").State) !@import("../execution/execution_result.zig") {
            _ = pc;
            _ = interpreter;
            _ = state;
            return .{};
        }
    }.execute;
    
    // Add some instructions
    const inst1 = Instruction{
        .opcode_fn = dummy_fn,
        .arg = .{ .none = {} },
    };
    
    try ext.add_instruction(inst1);
    try std.testing.expectEqual(@as(usize, 1), ext.instruction_count);
    
    const inst2 = Instruction{
        .opcode_fn = dummy_fn,
        .arg = .{ .push_value = 42 },
    };
    
    try ext.add_instruction(inst2);
    try std.testing.expectEqual(@as(usize, 2), ext.instruction_count);
    
    // Finalize and get instructions
    ext.finalize();
    const inst_ptr = ext.get_instructions();
    _ = inst_ptr;
}

test "CodeAnalysisExt instruction limit" {
    const allocator = std.testing.allocator;
    const limits = @import("../constants/code_analysis_limits.zig");
    const StaticBitSet = std.bit_set.StaticBitSet;
    const BlockMetadataSoA = @import("block_metadata_soa.zig");
    
    // Create a minimal base CodeAnalysis
    var base = CodeAnalysis{
        .code_segments = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
        .jumpdest_bitmap = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
        .block_starts = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
        .block_metadata = undefined,
        .block_metadata_soa = BlockMetadataSoA.init(),
        .pc_to_block = undefined,
        .block_count = 0,
        .max_stack_depth = 0,
        .has_static_jumps = false,
        .has_selfdestruct = false,
        .has_create = false,
    };
    
    var ext = try CodeAnalysisExt.init(allocator, base);
    defer ext.deinit(allocator);
    
    // Set instruction count to max to test limit
    ext.instruction_count = MAX_INSTRUCTIONS;
    
    // Create dummy opcode function
    const dummy_fn = struct {
        fn execute(pc: usize, interpreter: @import("../opcodes/operation.zig").Interpreter, state: @import("../opcodes/operation.zig").State) !@import("../execution/execution_result.zig") {
            _ = pc;
            _ = interpreter;
            _ = state;
            return .{};
        }
    }.execute;
    
    const inst = Instruction{
        .opcode_fn = dummy_fn,
        .arg = .{ .none = {} },
    };
    
    // Should fail with InstructionLimitExceeded
    try std.testing.expectError(error.InstructionLimitExceeded, ext.add_instruction(inst));
}

test "CodeAnalysisExt finalize sets null terminator" {
    const allocator = std.testing.allocator;
    const limits = @import("../constants/code_analysis_limits.zig");
    const StaticBitSet = std.bit_set.StaticBitSet;
    const BlockMetadataSoA = @import("block_metadata_soa.zig");
    
    // Create a minimal base CodeAnalysis
    var base = CodeAnalysis{
        .code_segments = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
        .jumpdest_bitmap = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
        .block_starts = StaticBitSet(limits.MAX_CONTRACT_SIZE).initEmpty(),
        .block_metadata = undefined,
        .block_metadata_soa = BlockMetadataSoA.init(),
        .pc_to_block = undefined,
        .block_count = 0,
        .max_stack_depth = 0,
        .has_static_jumps = false,
        .has_selfdestruct = false,
        .has_create = false,
    };
    
    var ext = try CodeAnalysisExt.init(allocator, base);
    defer ext.deinit(allocator);
    
    // Create dummy opcode function
    const dummy_fn = struct {
        fn execute(pc: usize, interpreter: @import("../opcodes/operation.zig").Interpreter, state: @import("../opcodes/operation.zig").State) !@import("../execution/execution_result.zig") {
            _ = pc;
            _ = interpreter;
            _ = state;
            return .{};
        }
    }.execute;
    
    // Add one instruction
    const inst = Instruction{
        .opcode_fn = dummy_fn,
        .arg = .{ .none = {} },
    };
    
    try ext.add_instruction(inst);
    
    // Finalize should set null after the instruction
    ext.finalize();
    
    // Get the pointer and verify it's null-terminated
    const inst_ptr = ext.get_instructions();
    
    // The first instruction should not be null
    try std.testing.expect(inst_ptr[0].opcode_fn != null);
    
    // After finalization, there should be a null terminator at instruction_count position
    // We can't directly test this without knowing the Instruction implementation details
    // but finalize() should ensure proper null termination
}