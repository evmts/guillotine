const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const Opcode = @import("../opcodes/opcode.zig");
const Stack = @import("../stack/stack.zig");

/// Basic block analysis for EVM bytecode optimization.
///
/// This module implements evmone-style basic block analysis to pre-compute
/// gas costs and stack requirements at the block level, improving cache
/// efficiency and reducing runtime overhead.
///
/// ## Basic Block Definition
/// A basic block is a sequence of instructions with:
/// - Single entry point (JUMPDEST or start of code)
/// - Single exit point (JUMP, JUMPI, STOP, RETURN, REVERT, or end)
/// - No jumps or jump destinations in the middle
///
/// ## Optimization Benefits
/// By analyzing at the block level, we can:
/// - Pre-compute total gas costs for straight-line code
/// - Validate stack requirements once per block
/// - Optimize instruction dispatch within blocks
/// - Improve branch prediction by grouping related code
pub const BasicBlock = struct {
    /// Starting program counter for this block
    start_pc: u32,
    
    /// Ending program counter (exclusive)
    end_pc: u32,
    
    /// Total constant gas cost for all instructions in the block
    base_gas_cost: u64,
    
    /// Minimum stack height required to execute this block
    stack_required: u16,
    
    /// Maximum stack growth during block execution
    stack_max_growth: u16,
    
    /// Net stack height change after block execution
    stack_height_change: i16,
    
    /// Whether this block contains state-modifying operations
    modifies_state: bool,
    
    /// Whether this block can halt execution
    can_halt: bool,
    
    /// Type of block terminator
    terminator: BlockTerminator,
};

/// How a basic block terminates
pub const BlockTerminator = enum {
    /// Block ends with a JUMP instruction
    jump,
    
    /// Block ends with a JUMPI instruction
    jumpi,
    
    /// Block ends with STOP/RETURN/REVERT
    halt,
    
    /// Block ends at a JUMPDEST (falls through)
    fallthrough,
    
    /// Block ends at end of bytecode
    end_of_code,
    
    /// Block ends with an invalid opcode
    invalid,
};

/// Result of bytecode analysis
pub const BlockAnalysisResult = struct {
    /// Array of basic blocks in bytecode order
    blocks: []BasicBlock,
    
    /// Map from PC to block index for quick lookup
    pc_to_block: std.AutoHashMap(u32, u32),
    
    /// Set of valid jump destinations
    valid_jumpdests: std.DynamicBitSet,
    
    /// Total number of instructions analyzed
    instruction_count: u32,
    
    /// Allocator used for this analysis
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *BlockAnalysisResult) void {
        self.allocator.free(self.blocks);
        self.pc_to_block.deinit();
        self.valid_jumpdests.deinit();
    }
    
    /// Get the basic block containing the given PC
    pub fn getBlock(self: *const BlockAnalysisResult, pc: u32) ?*const BasicBlock {
        const block_idx = self.pc_to_block.get(pc) orelse return null;
        return &self.blocks[block_idx];
    }
};

/// Analyze bytecode and identify basic blocks with pre-computed metadata
pub fn analyzeBlocks(allocator: std.mem.Allocator, bytecode: []const u8, jump_table: *const @import("../jump_table/jump_table.zig")) !BlockAnalysisResult {
    var blocks = std.ArrayList(BasicBlock).init(allocator);
    defer blocks.deinit();
    
    var pc_to_block = std.AutoHashMap(u32, u32).init(allocator);
    errdefer pc_to_block.deinit();
    
    var valid_jumpdests = try std.DynamicBitSet.initEmpty(allocator, bytecode.len);
    errdefer valid_jumpdests.deinit();
    
    // First pass: identify all jump destinations
    var pc: usize = 0;
    while (pc < bytecode.len) {
        const opcode = bytecode[pc];
        
        if (opcode == 0x5b) { // JUMPDEST
            valid_jumpdests.set(pc);
        }
        
        // Skip PUSH data
        if (opcode >= 0x60 and opcode <= 0x7f) {
            const push_size = opcode - 0x5f;
            pc += push_size;
        }
        pc += 1;
    }
    
    // Second pass: identify basic blocks
    var block_starts = std.ArrayList(u32).init(allocator);
    defer block_starts.deinit();
    
    try block_starts.append(0); // First instruction starts a block
    
    pc = 0;
    while (pc < bytecode.len) {
        const opcode = bytecode[pc];
        
        // Skip PUSH data
        var instr_size: usize = 1;
        if (opcode >= 0x60 and opcode <= 0x7f) {
            instr_size += opcode - 0x5f;
        }
        
        // Check if next instruction starts a new block
        const next_pc = pc + instr_size;
        if (next_pc < bytecode.len) {
            // New block after jump/halt instructions
            switch (opcode) {
                0x56, // JUMP
                0x57, // JUMPI
                0x00, // STOP
                0xf3, // RETURN
                0xfd, // REVERT
                0xff, // SELFDESTRUCT
                => {
                    try block_starts.append(@intCast(next_pc));
                },
                else => {},
            }
            
            // New block at jump destinations
            if (valid_jumpdests.isSet(next_pc)) {
                try block_starts.append(@intCast(next_pc));
            }
        }
        
        pc = next_pc;
    }
    
    // Sort and deduplicate block starts
    std.sort.sort(u32, block_starts.items, {}, std.sort.asc(u32));
    var unique_starts = std.ArrayList(u32).init(allocator);
    defer unique_starts.deinit();
    
    var last_start: ?u32 = null;
    for (block_starts.items) |start| {
        if (last_start == null or start != last_start.?) {
            try unique_starts.append(start);
            last_start = start;
        }
    }
    
    // Third pass: analyze each basic block
    var instruction_count: u32 = 0;
    for (unique_starts.items, 0..) |start_pc, i| {
        const end_pc = if (i + 1 < unique_starts.items.len)
            unique_starts.items[i + 1]
        else
            @as(u32, @intCast(bytecode.len));
        
        const block = try analyzeBasicBlock(bytecode, start_pc, end_pc, jump_table);
        
        // Map all PCs in this block to the block index
        pc = start_pc;
        while (pc < end_pc) {
            try pc_to_block.put(@intCast(pc), @intCast(blocks.items.len));
            
            const opcode = bytecode[pc];
            var instr_size: usize = 1;
            if (opcode >= 0x60 and opcode <= 0x7f) {
                instr_size += opcode - 0x5f;
            }
            
            instruction_count += 1;
            pc += instr_size;
        }
        
        try blocks.append(block);
    }
    
    return BlockAnalysisResult{
        .blocks = try blocks.toOwnedSlice(),
        .pc_to_block = pc_to_block,
        .valid_jumpdests = valid_jumpdests,
        .instruction_count = instruction_count,
        .allocator = allocator,
    };
}

/// Analyze a single basic block
fn analyzeBasicBlock(bytecode: []const u8, start_pc: u32, end_pc: u32, jump_table: *const @import("../jump_table/jump_table.zig")) !BasicBlock {
    var block = BasicBlock{
        .start_pc = start_pc,
        .end_pc = end_pc,
        .base_gas_cost = 0,
        .stack_required = 0,
        .stack_max_growth = 0,
        .stack_height_change = 0,
        .modifies_state = false,
        .can_halt = false,
        .terminator = .fallthrough,
    };
    
    var pc = start_pc;
    var current_stack_height: i32 = 0;
    var max_stack_height: i32 = 0;
    var min_stack_required: i32 = 0;
    
    while (pc < end_pc) {
        const opcode = bytecode[pc];
        const operation = jump_table.get_operation(opcode);
        
        // Track gas costs
        block.base_gas_cost += operation.constant_gas;
        
        // Track stack requirements
        const stack_pops = @as(i32, @intCast(operation.min_stack));
        const stack_pushes = if (operation.max_stack < Stack.CAPACITY) 
            @as(i32, @intCast(Stack.CAPACITY - operation.max_stack))
        else 
            0;
        
        // Update minimum required stack height
        const required_for_this_op = current_stack_height + stack_pops;
        if (required_for_this_op > min_stack_required) {
            min_stack_required = required_for_this_op;
        }
        
        // Update current stack height
        current_stack_height = current_stack_height - stack_pops + stack_pushes;
        
        // Track maximum growth
        if (current_stack_height > max_stack_height) {
            max_stack_height = current_stack_height;
        }
        
        // Track state modifications
        switch (opcode) {
            0x55, // SSTORE
            0xf0, // CREATE
            0xf5, // CREATE2
            0xff, // SELFDESTRUCT
            0xa0...0xa4, // LOG0-LOG4
            => {
                block.modifies_state = true;
            },
            else => {},
        }
        
        // Determine block terminator
        switch (opcode) {
            0x56 => block.terminator = .jump,
            0x57 => block.terminator = .jumpi,
            0x00, 0xf3, 0xfd, 0xff => {
                block.terminator = .halt;
                block.can_halt = true;
            },
            else => {},
        }
        
        // Skip to next instruction
        if (opcode >= 0x60 and opcode <= 0x7f) {
            pc += opcode - 0x5f;
        }
        pc += 1;
    }
    
    // Set final block metadata
    block.stack_required = @intCast(@max(0, min_stack_required));
    block.stack_max_growth = @intCast(@max(0, max_stack_height));
    block.stack_height_change = @intCast(current_stack_height);
    
    return block;
}

test "basic block analysis" {
    const allocator = std.testing.allocator;
    const JumpTable = @import("../jump_table/jump_table.zig");
    
    // Test bytecode with multiple blocks:
    // Block 1: PUSH1 0x05, PUSH1 0x00, JUMPI (conditional jump)
    // Block 2: PUSH1 0x42, STOP
    // Block 3: JUMPDEST, PUSH1 0x00, SSTORE
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 0x05
        0x60, 0x00, // PUSH1 0x00  
        0x57,       // JUMPI
        0x60, 0x42, // PUSH1 0x42
        0x00,       // STOP
        0x5b,       // JUMPDEST
        0x60, 0x00, // PUSH1 0x00
        0x55,       // SSTORE
    };
    
    const jump_table = JumpTable.DEFAULT;
    var result = try analyzeBlocks(allocator, &bytecode, &jump_table);
    defer result.deinit();
    
    // Should have 3 basic blocks
    try std.testing.expectEqual(@as(usize, 3), result.blocks.len);
    
    // Block 1: PUSH1, PUSH1, JUMPI
    const block1 = &result.blocks[0];
    try std.testing.expectEqual(@as(u32, 0), block1.start_pc);
    try std.testing.expectEqual(@as(u32, 5), block1.end_pc);
    try std.testing.expectEqual(BlockTerminator.jumpi, block1.terminator);
    try std.testing.expectEqual(@as(i16, 0), block1.stack_height_change); // +2 -2 = 0
    
    // Block 2: PUSH1, STOP
    const block2 = &result.blocks[1];
    try std.testing.expectEqual(@as(u32, 5), block2.start_pc);
    try std.testing.expectEqual(@as(u32, 8), block2.end_pc);
    try std.testing.expectEqual(BlockTerminator.halt, block2.terminator);
    try std.testing.expect(block2.can_halt);
    
    // Block 3: JUMPDEST, PUSH1, SSTORE
    const block3 = &result.blocks[2];
    try std.testing.expectEqual(@as(u32, 8), block3.start_pc);
    try std.testing.expectEqual(@as(u32, 12), block3.end_pc);
    try std.testing.expect(block3.modifies_state);
    try std.testing.expectEqual(@as(i16, -1), block3.stack_height_change); // +1 -2 = -1
    
    // Test PC to block mapping
    try std.testing.expectEqual(@as(u32, 0), result.pc_to_block.get(0).?);
    try std.testing.expectEqual(@as(u32, 0), result.pc_to_block.get(2).?);
    try std.testing.expectEqual(@as(u32, 1), result.pc_to_block.get(5).?);
    try std.testing.expectEqual(@as(u32, 2), result.pc_to_block.get(8).?);
}