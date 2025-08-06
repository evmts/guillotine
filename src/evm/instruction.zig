const std = @import("std");
const Operation = @import("opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const Frame = @import("frame/frame.zig");
const CodeAnalysis = @import("frame/code_analysis.zig");

// Use the existing BlockMetadata from code_analysis.zig
pub const BlockMetrics = CodeAnalysis.BlockMetadata;

pub const Instruction = struct {
    opcode_fn: ?Operation.ExecutionFunc,
    arg: union(enum) {
        none,
        block_metrics: BlockMetrics,
        push_value: u256,
        jump_target: [*:null]const Instruction,
        gas_cost: u32,
    },

    pub fn execute(instructions: [*:null]const Instruction, frame: *Frame) ExecutionError.Error!?[*:null]const Instruction {
        const self = instructions[0];
        
        const opcode_fn = self.opcode_fn orelse return null;
        
        const interpreter: Operation.Interpreter = frame.vm;
        const state: Operation.State = frame;
        
        const result = try opcode_fn(frame.pc, interpreter, state);
        _ = result;
        
        return instructions + 1;
    }
};

test "Instruction struct creation" {
    const inst = Instruction{
        .opcode_fn = null,
        .arg = .none,
    };
    try std.testing.expect(inst.opcode_fn == null);
    try std.testing.expect(inst.arg == .none);
}

test "Instruction with block metrics" {
    const metrics = BlockMetrics{
        .gas_cost = 3,
        .stack_req = 2,
        .stack_max = 1,
    };
    
    const inst = Instruction{
        .opcode_fn = null,
        .arg = .{ .block_metrics = metrics },
    };
    
    try std.testing.expectEqual(@as(u32, 3), inst.arg.block_metrics.gas_cost);
    try std.testing.expectEqual(@as(i16, 2), inst.arg.block_metrics.stack_req);
    try std.testing.expectEqual(@as(i16, 1), inst.arg.block_metrics.stack_max);
}

test "BlockMetrics exists and has correct layout" {
    // Verify BlockMetrics (BlockMetadata) is 8 bytes as expected
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(BlockMetrics));
    
    // Verify it's properly aligned
    try std.testing.expect(@alignOf(BlockMetrics) >= 4);
    
    // Verify field offsets match expected layout
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(BlockMetrics, "gas_cost"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(BlockMetrics, "stack_req"));
    try std.testing.expectEqual(@as(usize, 6), @offsetOf(BlockMetrics, "stack_max"));
}

test "Instruction with push value" {
    const inst = Instruction{
        .opcode_fn = null,
        .arg = .{ .push_value = 42 },
    };
    
    try std.testing.expectEqual(@as(u256, 42), inst.arg.push_value);
}

test "Instruction with gas cost" {
    const inst = Instruction{
        .opcode_fn = null,
        .arg = .{ .gas_cost = 21000 },
    };
    
    try std.testing.expectEqual(@as(u32, 21000), inst.arg.gas_cost);
}

test "Null-terminated instruction stream" {
    var instructions = [_]Instruction{
        .{ .opcode_fn = null, .arg = .none },
        .{ .opcode_fn = null, .arg = .none },
        .{ .opcode_fn = null, .arg = .none },
    };
    
    const ptr: [*:null]const Instruction = @ptrCast(&instructions);
    try std.testing.expect(ptr[0].opcode_fn == null);
}