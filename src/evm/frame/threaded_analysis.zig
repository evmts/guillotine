const std = @import("std");
const primitives = @import("primitives");
const opcode = @import("../opcodes/opcode.zig");
const JumpTable = @import("../jump_table/jump_table.zig");
const ThreadedInstruction = @import("threaded_instruction.zig").ThreadedInstruction;
const ThreadedAnalysis = @import("threaded_instruction.zig").ThreadedAnalysis;
const InstructionArg = @import("threaded_instruction.zig").InstructionArg;
const InstructionMeta = @import("threaded_instruction.zig").InstructionMeta;
const BlockInfo = @import("threaded_instruction.zig").BlockInfo;
const threaded_ops = @import("../execution/threaded_ops.zig");
const Log = @import("../log.zig");

/// Block analyzer for tracking gas and stack requirements
const BlockAnalyzer = struct {
    gas_used: u32 = 0,
    stack_req: i32 = 0,
    stack_change: i32 = 0,
    stack_max_growth: i32 = 0,
    instruction_count: u32 = 0,
    
    fn addInstruction(self: *BlockAnalyzer, operation: *const @import("../opcodes/operation.zig").Operation) void {
        self.gas_used += @intCast(operation.constant_gas);
        
        // Update stack requirements
        const min_stack: i32 = @intCast(operation.min_stack);
        self.stack_req = @max(self.stack_req, min_stack - self.stack_change);
        
        // Calculate stack effect
        const inputs: i32 = @intCast(operation.min_stack);
        const outputs: i32 = if (operation.max_stack >= operation.min_stack) 
            @as(i32, @intCast(operation.max_stack - operation.min_stack + 1))
        else 
            1;
        
        self.stack_change += outputs - inputs;
        self.stack_max_growth = @max(self.stack_max_growth, self.stack_change);
        self.instruction_count += 1;
    }
    
    fn finalize(self: *BlockAnalyzer) BlockInfo {
        return BlockInfo{
            .gas_cost = self.gas_used,
            .stack_req = @intCast(@max(0, self.stack_req)),
            .stack_max_growth = @intCast(@max(0, self.stack_max_growth)),
        };
    }
    
    fn reset(self: *BlockAnalyzer) void {
        self.* = BlockAnalyzer{};
    }
    
    fn shouldSplit(self: *BlockAnalyzer) bool {
        // Split blocks at reasonable sizes for cache efficiency
        return self.instruction_count >= 32 or self.gas_used >= 10000;
    }
};

/// Analyze bytecode and create threaded instruction stream
pub fn analyzeThreaded(
    allocator: std.mem.Allocator,
    code: []const u8,
    code_hash: primitives.Hash,
    jump_table: *const JumpTable.JumpTable,
) !ThreadedAnalysis {
    _ = code_hash;
    
    var instructions = std.ArrayList(ThreadedInstruction).init(allocator);
    defer instructions.deinit();
    
    var push_values = std.ArrayList(primitives.U256).init(allocator);
    defer push_values.deinit();
    
    var jumpdest_map = std.AutoHashMap(u32, u32).init(allocator);
    errdefer jumpdest_map.deinit();
    
    var blocks = std.ArrayList(BlockInfo).init(allocator);
    defer blocks.deinit();
    
    var block_analyzer = BlockAnalyzer{};
    var i: usize = 0;
    
    while (i < code.len) {
        const op = code[i];
        const operation = jump_table.table[op];
        
        // Check for block boundaries
        if (op == @intFromEnum(opcode.Enum.JUMPDEST) or block_analyzer.shouldSplit()) {
            if (instructions.items.len > 0) {
                // Insert block begin instruction
                const block_info = block_analyzer.finalize();
                try blocks.append(block_info);
                try instructions.append(.{
                    .exec_fn = threaded_ops.opx_beginblock_threaded,
                    .arg = .{ .block_info = block_info },
                    .meta = .{ .size = 0, .is_block_start = true },
                });
            }
            block_analyzer.reset();
            
            // Record jump destination
            if (op == @intFromEnum(opcode.Enum.JUMPDEST)) {
                try jumpdest_map.put(@intCast(i), @intCast(instructions.items.len));
            }
        }
        
        // Build instruction based on opcode
        var instr = ThreadedInstruction{
            .exec_fn = threaded_ops.getThreadedFunction(op),
            .arg = .{ .none = {} },
            .meta = .{ .size = 1, .is_block_start = false },
        };
        
        // Extract arguments for specific opcodes
        switch (op) {
            @intFromEnum(opcode.Enum.PUSH1)...@intFromEnum(opcode.Enum.PUSH32) => {
                const push_size = op - @intFromEnum(opcode.Enum.PUSH0);
                instr.meta.size = @intCast(1 + push_size);
                
                if (i + push_size < code.len) {
                    if (push_size <= 8) {
                        // Small push - embed directly
                        var value: u64 = 0;
                        for (0..push_size) |j| {
                            if (i + 1 + j < code.len) {
                                value = (value << 8) | code[i + 1 + j];
                            }
                        }
                        instr.arg = .{ .small_push = value };
                        instr.exec_fn = threaded_ops.op_push_small_threaded;
                    } else {
                        // Large push - store separately
                        var value: primitives.U256 = 0;
                        for (0..push_size) |j| {
                            if (i + 1 + j < code.len) {
                                value = (value << 8) | code[i + 1 + j];
                            }
                        }
                        instr.arg = .{ .large_push_idx = @intCast(push_values.items.len) };
                        try push_values.append(value);
                        instr.exec_fn = threaded_ops.op_push_large_threaded;
                    }
                }
            },
            
            @intFromEnum(opcode.Enum.PC) => {
                instr.arg = .{ .pc_value = @intCast(i) };
                instr.exec_fn = threaded_ops.op_pc_threaded;
            },
            
            @intFromEnum(opcode.Enum.GAS) => {
                instr.arg = .{ .gas_correction = @intCast(block_analyzer.gas_used) };
                instr.exec_fn = threaded_ops.op_gas_threaded;
            },
            
            else => {},
        }
        
        // Update block analysis
        block_analyzer.addInstruction(operation);
        
        try instructions.append(instr);
        i += instr.meta.size;
    }
    
    // Finalize last block
    if (instructions.items.len > 0 and block_analyzer.instruction_count > 0) {
        const block_info = block_analyzer.finalize();
        try blocks.append(block_info);
        
        // Insert final block instruction at the beginning of the last block
        const last_block_start = instructions.items.len - block_analyzer.instruction_count;
        try instructions.insert(last_block_start, .{
            .exec_fn = threaded_ops.opx_beginblock_threaded,
            .arg = .{ .block_info = block_info },
            .meta = .{ .size = 0, .is_block_start = true },
        });
    }
    
    return ThreadedAnalysis{
        .instructions = try instructions.toOwnedSlice(),
        .push_values = try push_values.toOwnedSlice(),
        .jumpdest_map = jumpdest_map,
        .blocks = try blocks.toOwnedSlice(),
    };
}