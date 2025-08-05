const std = @import("std");
const Stack = @import("../stack/stack.zig");
const ExecutionError = @import("../execution/execution_error.zig");
const Opcode = @import("../opcodes/opcode.zig");
const stack_height_changes = @import("../opcodes/stack_height_changes.zig");
const Log = @import("../log.zig");
const primitives = @import("primitives");

const STACK_CAPACITY = 1024; // EVM stack capacity

/// Basic block analysis for optimized stack validation.
///
/// A basic block is a sequence of instructions with:
/// - A single entry point (start of block or jump destination)
/// - A single exit point (end of block, jump, or terminating instruction)
/// - No branches within the block
///
/// By pre-analyzing basic blocks, we can:
/// 1. Validate stack requirements once per block instead of per instruction
/// 2. Skip validation for straight-line code sequences
/// 3. Pre-compute net stack effects for entire blocks
/// 4. Detect stack underflow/overflow at analysis time for many cases
///
/// This significantly reduces runtime validation overhead, especially for
/// contracts with long sequences of arithmetic or stack operations.
pub const BasicBlockAnalysis = struct {
    /// Information about a single basic block
    pub const BasicBlock = struct {
        /// Starting program counter of the block
        start_pc: u32,
        
        /// Ending program counter (inclusive)
        end_pc: u32,
        
        /// Minimum stack depth required at block entry
        min_stack_entry: u16,
        
        /// Maximum stack depth allowed at block entry to avoid overflow
        max_stack_entry: u16,
        
        /// Net stack change after executing the entire block
        net_stack_change: i16,
        
        /// Whether this block ends with a terminating instruction (STOP, RETURN, etc.)
        is_terminal: bool,
        
        /// Whether this block ends with a jump (static or dynamic)
        ends_with_jump: bool,
        
        /// For static jumps, the target PC (null for dynamic jumps)
        static_jump_target: ?u32,
        
        /// Total gas cost for the block (if all operations have constant gas)
        total_gas_cost: ?u64,
    };
    
    /// Array of basic blocks in the bytecode
    blocks: []BasicBlock,
    
    /// Map from PC to block index for O(1) lookup
    /// Each entry maps a PC to the index of its containing block
    pc_to_block_map: []u32,
    
    /// Allocator used for memory management
    allocator: std.mem.Allocator,
    
    /// Analyzes bytecode and creates basic block information.
    ///
    /// This function scans the bytecode to identify basic block boundaries
    /// and pre-computes stack validation information for each block.
    pub fn analyze(allocator: std.mem.Allocator, bytecode: []const u8) !BasicBlockAnalysis {
        var blocks = std.ArrayList(BasicBlock).init(allocator);
        defer blocks.deinit();
        
        var pc_to_block = try allocator.alloc(u32, bytecode.len);
        errdefer allocator.free(pc_to_block);
        
        var current_block_start: u32 = 0;
        var pc: u32 = 0;
        
        while (pc < bytecode.len) {
            const opcode = bytecode[pc];
            const is_block_end = isBlockEnd(opcode);
            
            // Handle PUSH instructions specially - they have immediate data
            const instruction_size = if (opcode >= 0x60 and opcode <= 0x7f) 
                1 + (opcode - 0x5f) // PUSH1-PUSH32
            else 
                1;
            
            // Mark PCs as belonging to current block
            var i: u32 = 0;
            while (i < instruction_size and pc + i < bytecode.len) : (i += 1) {
                pc_to_block[pc + i] = @intCast(blocks.items.len);
            }
            
            // If this instruction ends a block, analyze and save it
            if (is_block_end or pc + instruction_size >= bytecode.len) {
                const block = try analyzeBlock(bytecode[current_block_start..pc + instruction_size]);
                try blocks.append(.{
                    .start_pc = current_block_start,
                    .end_pc = pc,
                    .min_stack_entry = block.min_stack_entry,
                    .max_stack_entry = block.max_stack_entry,
                    .net_stack_change = block.net_stack_change,
                    .is_terminal = block.is_terminal,
                    .ends_with_jump = block.ends_with_jump,
                    .static_jump_target = block.static_jump_target,
                    .total_gas_cost = block.total_gas_cost,
                });
                
                current_block_start = pc + instruction_size;
            }
            
            pc += instruction_size;
            
            // JUMPDEST starts a new block
            if (pc < bytecode.len and bytecode[pc] == 0x5b) {
                // Save current block if we haven't already
                if (current_block_start < pc) {
                    const block = try analyzeBlock(bytecode[current_block_start..pc]);
                    try blocks.append(.{
                        .start_pc = current_block_start,
                        .end_pc = pc - 1,
                        .min_stack_entry = block.min_stack_entry,
                        .max_stack_entry = block.max_stack_entry,
                        .net_stack_change = block.net_stack_change,
                        .is_terminal = block.is_terminal,
                        .ends_with_jump = block.ends_with_jump,
                        .static_jump_target = block.static_jump_target,
                        .total_gas_cost = block.total_gas_cost,
                    });
                }
                current_block_start = pc;
            }
        }
        
        return BasicBlockAnalysis{
            .blocks = try blocks.toOwnedSlice(),
            .pc_to_block_map = pc_to_block,
            .allocator = allocator,
        };
    }
    
    /// Analyzes a single basic block to compute stack requirements.
    fn analyzeBlock(bytecode: []const u8) !BasicBlock {
        var min_stack_depth: i16 = 0;  // Minimum depth reached (can be negative)
        var current_depth: i16 = 0;    // Current stack depth relative to entry
        var max_stack_depth: i16 = 0;  // Maximum depth reached
        var total_gas: u64 = 0;
        var has_dynamic_gas = false;
        
        var pc: usize = 0;
        const last_opcode = if (bytecode.len > 0) bytecode[bytecode.len - 1] else 0x00;
        
        while (pc < bytecode.len) {
            const opcode = bytecode[pc];
            
            // Get stack requirements for this opcode
            const spec = getOpcodeSpec(opcode);
            if (spec) |s| {
                // Track minimum depth needed (for underflow check)
                const depth_before_pop = current_depth - @as(i16, @intCast(s.min_stack));
                if (depth_before_pop < min_stack_depth) {
                    min_stack_depth = depth_before_pop;
                }
                
                // Apply stack height change
                const height_change = stack_height_changes.get_stack_height_change(opcode);
                current_depth += height_change;
                
                // Track maximum depth reached (for overflow check)
                if (current_depth > max_stack_depth) {
                    max_stack_depth = current_depth;
                }
                
                // Track gas
                if (s.constant_gas) |gas| {
                    total_gas += gas;
                } else {
                    has_dynamic_gas = true;
                }
            }
            
            // Handle PUSH instructions
            if (opcode >= 0x60 and opcode <= 0x7f) {
                pc += 1 + (opcode - 0x5f);
            } else {
                pc += 1;
            }
        }
        
        // Calculate requirements
        // min_stack_entry: We need at least abs(min_stack_depth) items on entry
        const min_entry = if (min_stack_depth < 0) @abs(min_stack_depth) else 0;
        
        // max_stack_entry: Entry stack + max growth must not exceed capacity
        const max_entry = if (max_stack_depth > 0)
            @as(u16, @intCast(STACK_CAPACITY)) - @as(u16, @intCast(max_stack_depth))
        else
            @as(u16, @intCast(STACK_CAPACITY));
        
        return BasicBlock{
            .start_pc = 0,
            .end_pc = @intCast(bytecode.len - 1),
            .min_stack_entry = @intCast(min_entry),
            .max_stack_entry = max_entry,
            .net_stack_change = current_depth,
            .is_terminal = isTerminal(last_opcode),
            .ends_with_jump = (last_opcode == 0x56 or last_opcode == 0x57),
            .static_jump_target = null, // TODO: Extract static jump targets
            .total_gas_cost = if (has_dynamic_gas) null else total_gas,
        };
    }
    
    /// Gets opcode specification using hardcoded values to avoid dependency loop.
    fn getOpcodeSpec(opcode: u8) ?struct {
        min_stack: u32,
        max_stack: u32,
        constant_gas: ?u64,
    } {
        // For basic block analysis, we only need approximate gas costs
        // The exact values are handled by the jump table at runtime
        return switch (opcode) {
            // Stop
            0x00 => .{ .min_stack = 0, .max_stack = STACK_CAPACITY, .constant_gas = 0 },
            
            // Arithmetic
            0x01...0x07, 0x0a, 0x0b => .{ .min_stack = 2, .max_stack = STACK_CAPACITY, .constant_gas = 3 },
            0x08, 0x09 => .{ .min_stack = 3, .max_stack = STACK_CAPACITY, .constant_gas = 8 },
            
            // Comparison & Bitwise
            0x10...0x14, 0x16...0x18, 0x1a...0x1d => .{ .min_stack = 2, .max_stack = STACK_CAPACITY, .constant_gas = 3 },
            0x15, 0x19 => .{ .min_stack = 1, .max_stack = STACK_CAPACITY, .constant_gas = 3 },
            
            // SHA3
            0x20 => .{ .min_stack = 2, .max_stack = STACK_CAPACITY, .constant_gas = 30 },
            
            // Environmental
            0x30, 0x32...0x34, 0x36, 0x38, 0x3a, 0x3d => .{ .min_stack = 0, .max_stack = STACK_CAPACITY - 1, .constant_gas = 2 },
            0x31, 0x35, 0x3b, 0x3f => .{ .min_stack = 1, .max_stack = STACK_CAPACITY, .constant_gas = null },
            0x37, 0x39, 0x3e => .{ .min_stack = 3, .max_stack = STACK_CAPACITY, .constant_gas = null },
            0x3c => .{ .min_stack = 4, .max_stack = STACK_CAPACITY, .constant_gas = null },
            
            // Block
            0x40 => .{ .min_stack = 1, .max_stack = STACK_CAPACITY, .constant_gas = 20 },
            0x41...0x48, 0x4a => .{ .min_stack = 0, .max_stack = STACK_CAPACITY - 1, .constant_gas = 2 },
            0x49 => .{ .min_stack = 1, .max_stack = STACK_CAPACITY, .constant_gas = 3 },
            
            // Stack, Memory, Storage
            0x50 => .{ .min_stack = 1, .max_stack = STACK_CAPACITY, .constant_gas = 2 },
            0x51, 0x54, 0x5c => .{ .min_stack = 1, .max_stack = STACK_CAPACITY, .constant_gas = null },
            0x52, 0x53, 0x55, 0x5d => .{ .min_stack = 2, .max_stack = STACK_CAPACITY, .constant_gas = null },
            0x56 => .{ .min_stack = 1, .max_stack = STACK_CAPACITY, .constant_gas = 8 },
            0x57 => .{ .min_stack = 2, .max_stack = STACK_CAPACITY, .constant_gas = 10 },
            0x58...0x5a => .{ .min_stack = 0, .max_stack = STACK_CAPACITY - 1, .constant_gas = 2 },
            0x5b => .{ .min_stack = 0, .max_stack = STACK_CAPACITY, .constant_gas = 1 },
            0x5e => .{ .min_stack = 3, .max_stack = STACK_CAPACITY, .constant_gas = null },
            0x5f => .{ .min_stack = 0, .max_stack = STACK_CAPACITY - 1, .constant_gas = 2 },
            
            // PUSH operations
            0x60...0x7f => .{
                .min_stack = 0,
                .max_stack = STACK_CAPACITY - 1,
                .constant_gas = 3,
            },
            
            // DUP operations
            0x80...0x8f => blk: {
                const n = opcode - 0x7f;
                break :blk .{
                    .min_stack = n,
                    .max_stack = STACK_CAPACITY - 1,
                    .constant_gas = 3,
                };
            },
            
            // SWAP operations  
            0x90...0x9f => blk: {
                const n = opcode - 0x8f;
                break :blk .{
                    .min_stack = n + 1,
                    .max_stack = STACK_CAPACITY,
                    .constant_gas = 3,
                };
            },
            
            // LOG operations
            0xa0...0xa4 => blk: {
                const n = opcode - 0xa0;
                break :blk .{
                    .min_stack = n + 2,
                    .max_stack = STACK_CAPACITY,
                    .constant_gas = @as(u64, 375) + @as(u64, 375) * @as(u64, n),
                };
            },
            
            // System operations
            0xf0 => .{ .min_stack = 3, .max_stack = STACK_CAPACITY - 1, .constant_gas = null },
            0xf1, 0xf2 => .{ .min_stack = 7, .max_stack = STACK_CAPACITY - 1, .constant_gas = null },
            0xf3, 0xfd => .{ .min_stack = 2, .max_stack = STACK_CAPACITY, .constant_gas = null },
            0xf4, 0xfa => .{ .min_stack = 6, .max_stack = STACK_CAPACITY - 1, .constant_gas = null },
            0xf5 => .{ .min_stack = 4, .max_stack = STACK_CAPACITY - 1, .constant_gas = null },
            0xfe => .{ .min_stack = 0, .max_stack = STACK_CAPACITY, .constant_gas = 0 },
            0xff => .{ .min_stack = 1, .max_stack = STACK_CAPACITY, .constant_gas = null },
            
            else => null,
        };
    }
    
    /// Checks if an opcode ends a basic block.
    fn isBlockEnd(opcode: u8) bool {
        return switch (opcode) {
            0x00, // STOP
            0x56, // JUMP
            0x57, // JUMPI
            0xf3, // RETURN
            0xfd, // REVERT
            0xfe, // INVALID
            0xff, // SELFDESTRUCT
            => true,
            else => false,
        };
    }
    
    /// Checks if an opcode is a terminating instruction.
    fn isTerminal(opcode: u8) bool {
        return switch (opcode) {
            0x00, // STOP
            0xf3, // RETURN
            0xfd, // REVERT
            0xfe, // INVALID
            0xff, // SELFDESTRUCT
            => true,
            else => false,
        };
    }
    
    /// Validates stack requirements for a given PC using basic block analysis.
    ///
    /// This is the optimized validation function that replaces per-opcode validation
    /// with block-level validation when possible.
    pub fn validateStackAtPc(
        self: *const BasicBlockAnalysis,
        pc: usize,
        stack_size: usize,
    ) ExecutionError.Error!void {
        if (pc >= self.pc_to_block_map.len) {
            return ExecutionError.Error.InvalidOpcode;
        }
        
        const block_idx = self.pc_to_block_map[pc];
        if (block_idx >= self.blocks.len) {
            return ExecutionError.Error.InvalidOpcode;
        }
        
        const block = self.blocks[block_idx];
        
        // If we're at the start of a block, validate entry requirements
        if (pc == block.start_pc) {
            if (stack_size < block.min_stack_entry) {
                return ExecutionError.Error.StackUnderflow;
            }
            if (stack_size > block.max_stack_entry) {
                return ExecutionError.Error.StackOverflow;
            }
            // Stack is valid for the entire block!
            return;
        }
        
        // If we're in the middle of a block, we need to compute requirements
        // from the block start to current PC
        // In practice, this shouldn't happen often as we typically enter at block boundaries
        // For now, fall back to regular validation
        Log.debug("BasicBlock: Mid-block entry at PC {}, falling back to regular validation", .{pc});
    }
    
    /// Gets the basic block containing a given PC.
    pub fn getBlockAtPc(self: *const BasicBlockAnalysis, pc: usize) ?*const BasicBlock {
        if (pc >= self.pc_to_block_map.len) return null;
        
        const block_idx = self.pc_to_block_map[pc];
        if (block_idx >= self.blocks.len) return null;
        
        return &self.blocks[block_idx];
    }
    
    /// Releases all memory allocated by this analysis.
    pub fn deinit(self: *BasicBlockAnalysis) void {
        self.allocator.free(self.blocks);
        self.allocator.free(self.pc_to_block_map);
    }
};

// Tests
const testing = std.testing;

test "basic block analysis simple sequence" {
    const allocator = testing.allocator;
    
    // Simple sequence: PUSH1 0x05, PUSH1 0x0A, ADD, POP
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x0a, // PUSH1 10  
        0x01,       // ADD
        0x50,       // POP
    };
    
    var analysis = try BasicBlockAnalysis.analyze(allocator, &bytecode);
    defer analysis.deinit();
    
    // Should have one block
    try testing.expectEqual(@as(usize, 1), analysis.blocks.len);
    
    const block = analysis.blocks[0];
    try testing.expectEqual(@as(u32, 0), block.start_pc);
    try testing.expectEqual(@as(u32, 5), block.end_pc);
    try testing.expectEqual(@as(u16, 0), block.min_stack_entry); // No underflow possible
    try testing.expectEqual(@as(u16, STACK_CAPACITY), block.max_stack_entry); // Net effect is 0
    try testing.expectEqual(@as(i16, 0), block.net_stack_change); // +1 +1 -1 -1 = 0
    try testing.expect(!block.is_terminal);
    try testing.expect(!block.ends_with_jump);
}

test "basic block analysis with jumps" {
    const allocator = testing.allocator;
    
    // Code with jump: PUSH1 0x08, JUMP, INVALID, JUMPDEST, PUSH1 0x01, STOP
    const bytecode = [_]u8{
        0x60, 0x08, // PUSH1 8
        0x56,       // JUMP
        0xfe,       // INVALID
        0x5b,       // JUMPDEST
        0x60, 0x01, // PUSH1 1
        0x00,       // STOP
    };
    
    var analysis = try BasicBlockAnalysis.analyze(allocator, &bytecode);
    defer analysis.deinit();
    
    // Should have 3 blocks: [PUSH JUMP], [INVALID], [JUMPDEST PUSH STOP]
    try testing.expectEqual(@as(usize, 3), analysis.blocks.len);
    
    // First block ends with jump
    try testing.expect(analysis.blocks[0].ends_with_jump);
    
    // Last block is terminal
    try testing.expect(analysis.blocks[2].is_terminal);
}

test "basic block stack validation" {
    const allocator = testing.allocator;
    
    // Sequence that requires 2 stack items: DUP2, ADD
    const bytecode = [_]u8{
        0x81, // DUP2 (needs 2 items)
        0x01, // ADD (needs 2 items)
    };
    
    var analysis = try BasicBlockAnalysis.analyze(allocator, &bytecode);
    defer analysis.deinit();
    
    const block = analysis.blocks[0];
    try testing.expectEqual(@as(u16, 2), block.min_stack_entry); // Needs at least 2 items
    try testing.expectEqual(@as(u16, STACK_CAPACITY - 1), block.max_stack_entry); // Grows by 1 then shrinks by 1
    try testing.expectEqual(@as(i16, 0), block.net_stack_change); // +1 -1 = 0
    
    // Test validation
    try testing.expectError(ExecutionError.Error.StackUnderflow, analysis.validateStackAtPc(0, 1));
    try analysis.validateStackAtPc(0, 2); // Should succeed
    try analysis.validateStackAtPc(0, 100); // Should succeed
}

test "basic block gas calculation" {
    const allocator = testing.allocator;
    
    // Sequence with known gas costs
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1 (3 gas)
        0x60, 0x02, // PUSH1 2 (3 gas)
        0x01,       // ADD (3 gas)
        0x50,       // POP (2 gas)
    };
    
    var analysis = try BasicBlockAnalysis.analyze(allocator, &bytecode);
    defer analysis.deinit();
    
    const block = analysis.blocks[0];
    try testing.expect(block.total_gas_cost != null);
    try testing.expectEqual(@as(u64, 11), block.total_gas_cost.?); // 3+3+3+2 = 11
}