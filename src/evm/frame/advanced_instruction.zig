const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("../execution/execution_error.zig");

/// Advanced instruction format that co-locates opcode metadata and arguments
/// for improved cache efficiency, inspired by evmone's implementation.
///
/// This structure stores everything needed for instruction execution in a
/// single cache-friendly location, avoiding pointer chasing and improving
/// spatial locality during EVM execution.
///
/// ## Design Rationale
/// Traditional EVM implementations often scatter instruction data:
/// - Operation metadata in jump table
/// - Arguments read from bytecode during execution
/// - Gas costs calculated dynamically
///
/// By co-locating this data, we achieve:
/// - Better cache utilization (single cache line access)
/// - Reduced memory indirection
/// - Faster instruction dispatch
/// - Pre-computed gas costs for basic blocks
pub const AdvancedInstruction = struct {
    /// Function pointer for instruction execution
    fn_ptr: Operation.ExecutionFunc,
    
    /// Pre-computed gas cost for this instruction
    /// (includes both constant and dynamic costs when possible)
    gas_cost: u64,
    
    /// Instruction-specific data stored in a union for space efficiency
    /// Different instruction types use different fields
    arg: union {
        /// For PUSH operations: the value to push (up to 32 bytes)
        push_value: u256,
        
        /// For small PUSH operations (PUSH1-PUSH8): optimized storage
        small_push_value: u64,
        
        /// For JUMP/JUMPI: pre-validated jump destination
        jump_dest: u32,
        
        /// For DUP/SWAP: the position to duplicate/swap
        stack_pos: u8,
        
        /// For LOG operations: number of topics (0-4)
        log_topics: u8,
        
        /// Generic numeric argument for other instructions
        number: u64,
        
        /// For block-relative instructions: reference to basic block
        block: BlockInfo,
        
        /// No argument needed
        none: void,
    },
    
    /// Metadata packed into a single byte for space efficiency
    metadata: packed struct {
        /// Number of bytes this instruction occupies in bytecode
        size: u3,
        
        /// Whether this instruction can cause a jump
        is_jump: bool,
        
        /// Whether this instruction is a jump destination
        is_jumpdest: bool,
        
        /// Whether this instruction modifies state
        writes_state: bool,
        
        /// Whether this instruction can halt execution
        can_halt: bool,
        
        /// Reserved for future use
        reserved: u1 = 0,
    },
};

/// Basic block information for block-level optimizations
pub const BlockInfo = struct {
    /// Starting PC of this basic block
    start_pc: u32,
    
    /// Length of the basic block in instructions
    length: u16,
    
    /// Total gas cost for the entire block
    total_gas: u64,
    
    /// Stack height delta for the block
    stack_delta: i8,
    
    /// Maximum stack growth within the block
    max_stack_growth: u8,
};

/// Advanced code analysis result containing pre-processed instructions
pub const AdvancedAnalysis = struct {
    /// Array of analyzed instructions
    instructions: []AdvancedInstruction,
    
    /// Jump destination validity map (for JUMPI validation)
    jump_dests: std.DynamicBitSet,
    
    /// Basic blocks for block-level optimization
    blocks: []BlockInfo,
    
    /// Allocator used for this analysis
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *AdvancedAnalysis) void {
        self.allocator.free(self.instructions);
        self.jump_dests.deinit();
        self.allocator.free(self.blocks);
    }
};

/// Analyze bytecode and create advanced instruction format
pub fn analyzeCode(allocator: std.mem.Allocator, bytecode: []const u8) !AdvancedAnalysis {
    var instructions = std.ArrayList(AdvancedInstruction).init(allocator);
    defer instructions.deinit();
    
    var jump_dests = try std.DynamicBitSet.initEmpty(allocator, bytecode.len);
    errdefer jump_dests.deinit();
    
    var blocks = std.ArrayList(BlockInfo).init(allocator);
    defer blocks.deinit();
    
    var pc: usize = 0;
    var current_block_start: u32 = 0;
    var current_block_gas: u64 = 0;
    
    // First pass: identify jump destinations
    while (pc < bytecode.len) {
        const opcode = bytecode[pc];
        
        if (opcode == 0x5b) { // JUMPDEST
            jump_dests.set(pc);
            
            // End current block and start new one
            if (pc > current_block_start) {
                try blocks.append(.{
                    .start_pc = current_block_start,
                    .length = @intCast(pc - current_block_start),
                    .total_gas = current_block_gas,
                    .stack_delta = 0, // TODO: Calculate actual delta
                    .max_stack_growth = 0, // TODO: Calculate actual growth
                });
                current_block_start = @intCast(pc);
                current_block_gas = 0;
            }
        }
        
        // Skip PUSH data
        if (opcode >= 0x60 and opcode <= 0x7f) {
            const push_size = opcode - 0x5f;
            pc += push_size;
        }
        pc += 1;
    }
    
    // Second pass: create advanced instructions
    pc = 0;
    while (pc < bytecode.len) {
        const opcode = bytecode[pc];
        var instr = AdvancedInstruction{
            .fn_ptr = undefined, // Will be set based on opcode
            .gas_cost = 0, // Will be calculated
            .arg = .{ .none = {} },
            .metadata = .{
                .size = 1,
                .is_jump = false,
                .is_jumpdest = false,
                .writes_state = false,
                .can_halt = false,
            },
        };
        
        // Handle specific opcodes
        switch (opcode) {
            // PUSH operations
            0x60...0x7f => {
                const push_size = opcode - 0x5f;
                instr.metadata.size = push_size + 1;
                
                if (push_size <= 8) {
                    // Optimized small push
                    var value: u64 = 0;
                    var i: usize = 0;
                    while (i < push_size and pc + 1 + i < bytecode.len) : (i += 1) {
                        value = (value << 8) | bytecode[pc + 1 + i];
                    }
                    instr.arg = .{ .small_push_value = value };
                } else {
                    // Full push value
                    var value: u256 = 0;
                    var i: usize = 0;
                    while (i < push_size and pc + 1 + i < bytecode.len) : (i += 1) {
                        value = (value << 8) | bytecode[pc + 1 + i];
                    }
                    instr.arg = .{ .push_value = value };
                }
            },
            
            // DUP operations
            0x80...0x8f => {
                const dup_pos = opcode - 0x7f;
                instr.arg = .{ .stack_pos = dup_pos };
            },
            
            // SWAP operations
            0x90...0x9f => {
                const swap_pos = opcode - 0x8f;
                instr.arg = .{ .stack_pos = swap_pos };
            },
            
            // LOG operations
            0xa0...0xa4 => {
                const topics = opcode - 0xa0;
                instr.arg = .{ .log_topics = topics };
            },
            
            // JUMP
            0x56 => {
                instr.metadata.is_jump = true;
                instr.metadata.can_halt = true;
            },
            
            // JUMPI
            0x57 => {
                instr.metadata.is_jump = true;
            },
            
            // JUMPDEST
            0x5b => {
                instr.metadata.is_jumpdest = true;
            },
            
            // State-modifying operations
            0x55, // SSTORE
            0xf0, // CREATE
            0xf5, // CREATE2
            0xff, // SELFDESTRUCT
            => {
                instr.metadata.writes_state = true;
            },
            
            // Halting operations
            0x00, // STOP
            0xf3, // RETURN
            0xfd, // REVERT
            => {
                instr.metadata.can_halt = true;
            },
            
            else => {},
        }
        
        try instructions.append(instr);
        pc += instr.metadata.size;
    }
    
    return AdvancedAnalysis{
        .instructions = try instructions.toOwnedSlice(),
        .jump_dests = jump_dests,
        .blocks = try blocks.toOwnedSlice(),
        .allocator = allocator,
    };
}

test "advanced instruction analysis" {
    const allocator = std.testing.allocator;
    
    // Test bytecode: PUSH1 0x42, DUP1, ADD, STOP
    const bytecode = [_]u8{ 0x60, 0x42, 0x80, 0x01, 0x00 };
    
    var analysis = try analyzeCode(allocator, &bytecode);
    defer analysis.deinit();
    
    try std.testing.expectEqual(@as(usize, 4), analysis.instructions.len);
    
    // Check PUSH1 instruction
    const push_instr = analysis.instructions[0];
    try std.testing.expectEqual(@as(u64, 0x42), push_instr.arg.small_push_value);
    try std.testing.expectEqual(@as(u3, 2), push_instr.metadata.size);
    
    // Check DUP1 instruction
    const dup_instr = analysis.instructions[1];
    try std.testing.expectEqual(@as(u8, 1), dup_instr.arg.stack_pos);
    
    // Check STOP instruction
    const stop_instr = analysis.instructions[3];
    try std.testing.expect(stop_instr.metadata.can_halt);
}