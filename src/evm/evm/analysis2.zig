const std = @import("std");
const Opcode = @import("../opcodes/opcode.zig").Enum;

/// Simple analysis result for tailcall dispatch with precomputed mappings
pub const SimpleAnalysis = struct {
    /// Mapping from instruction index to PC value
    inst_to_pc: []usize,
    /// Mapping from PC to instruction index (MAX_USIZE if not an instruction start)
    pc_to_inst: []usize,
    /// Reference to the original bytecode for reading push values
    bytecode: []const u8,
    /// Total number of instructions
    inst_count: usize,
    /// Mapping from instruction index to known jump destination instruction index
    /// Used for PUSH_THEN_JUMP optimization. MAX_USIZE means not a known jump.
    known_jumps: []usize,
    
    pub const MAX_USIZE: usize = std.math.maxInt(usize);
    
    pub fn deinit(self: *SimpleAnalysis, allocator: std.mem.Allocator) void {
        allocator.free(self.inst_to_pc);
        allocator.free(self.pc_to_inst);
        allocator.free(self.known_jumps);
    }
    
    /// Get the PC value for a given instruction index
    pub fn getPc(self: *const SimpleAnalysis, inst_idx: usize) usize {
        if (inst_idx >= self.inst_count) return MAX_USIZE;
        return self.inst_to_pc[inst_idx];
    }
    
    /// Get the instruction index for a given PC
    pub fn getInstIdx(self: *const SimpleAnalysis, pc: usize) usize {
        if (pc >= self.pc_to_inst.len) return MAX_USIZE;
        return self.pc_to_inst[pc];
    }
    
    /// Get the known jump destination for an instruction (if it's a PUSH_THEN_JUMP pattern)
    pub fn getKnownJump(self: *const SimpleAnalysis, inst_idx: usize) usize {
        if (inst_idx >= self.inst_count) return MAX_USIZE;
        return self.known_jumps[inst_idx];
    }
    
    /// Build analysis from bytecode
    pub fn analyze(allocator: std.mem.Allocator, code: []const u8) !SimpleAnalysis {
        var inst_to_pc_list = std.ArrayList(usize).init(allocator);
        defer inst_to_pc_list.deinit();
        
        var pc_to_inst = try allocator.alloc(usize, code.len);
        @memset(pc_to_inst, MAX_USIZE);
        
        // First pass: build instruction mappings
        var pc: usize = 0;
        var inst_idx: usize = 0;
        
        while (pc < code.len) {
            const byte = code[pc];
            
            // Record instruction start
            try inst_to_pc_list.append(pc);
            pc_to_inst[pc] = inst_idx;
            
            // Handle PUSH instructions
            if (byte >= 0x60 and byte <= 0x7F) {
                const push_size = byte - 0x5F;
                pc += 1 + push_size;
            } else if (byte == 0x5F) {
                // PUSH0
                pc += 1;
            } else {
                pc += 1;
            }
            
            inst_idx += 1;
        }
        
        const inst_to_pc = try inst_to_pc_list.toOwnedSlice();
        const total_instructions = inst_idx;
        
        // Allocate known_jumps array
        var known_jumps = try allocator.alloc(usize, total_instructions);
        @memset(known_jumps, MAX_USIZE);
        
        // Second pass: detect PUSH+JUMP patterns and validate jump destinations
        inst_idx = 0;
        while (inst_idx < total_instructions) : (inst_idx += 1) {
            const inst_pc = inst_to_pc[inst_idx];
            if (inst_pc >= code.len) continue;
            
            const byte = code[inst_pc];
            
            // Check if this is a PUSH instruction
            if (byte >= 0x60 and byte <= 0x7F) {
                const push_size = byte - 0x5F;
                
                // Check if the next instruction is JUMP (0x56)
                const next_inst_idx = inst_idx + 1;
                if (next_inst_idx < total_instructions) {
                    const next_pc = inst_to_pc[next_inst_idx];
                    if (next_pc < code.len and code[next_pc] == 0x56) {
                        // Found PUSH+JUMP pattern, extract the push value
                        var push_value: usize = 0;
                        const value_start = inst_pc + 1;
                        var i: usize = 0;
                        while (i < push_size and value_start + i < code.len) : (i += 1) {
                            push_value = (push_value << 8) | code[value_start + i];
                        }
                        
                        // Validate that the jump destination is a JUMPDEST (0x5B)
                        if (push_value < code.len and code[push_value] == 0x5B) {
                            // Get the instruction index of the jump destination
                            const dest_inst_idx = pc_to_inst[push_value];
                            if (dest_inst_idx != MAX_USIZE) {
                                // Store the known jump: from PUSH instruction to JUMPDEST instruction
                                known_jumps[inst_idx] = dest_inst_idx;
                            }
                        }
                    }
                }
            }
        }
        
        return SimpleAnalysis{
            .inst_to_pc = inst_to_pc,
            .pc_to_inst = pc_to_inst,
            .bytecode = code,
            .inst_count = total_instructions,
            .known_jumps = known_jumps,
        };
    }
};

test "SimpleAnalysis detects PUSH+JUMP fusion opportunity" {
    const allocator = std.testing.allocator;
    
    // Bytecode: PUSH1 0x04 JUMP STOP JUMPDEST ADD
    const code = &[_]u8{
        0x60, 0x04, // PUSH1 0x04
        0x56,       // JUMP
        0x00,       // STOP
        0x5B,       // JUMPDEST
        0x01,       // ADD
    };
    
    var analysis = try SimpleAnalysis.analyze(allocator, code);
    defer analysis.deinit(allocator);
    
    // PUSH1 is at instruction index 0
    // JUMP is at instruction index 1
    // JUMPDEST is at instruction index 3
    const push_inst_idx: usize = 0;
    const known_jump_dest = analysis.getKnownJump(push_inst_idx);
    
    // Should detect the known jump from PUSH to JUMPDEST
    try std.testing.expect(known_jump_dest != SimpleAnalysis.MAX_USIZE);
    try std.testing.expectEqual(@as(usize, 3), known_jump_dest);
}

test "SimpleAnalysis does not fuse dynamic jumps" {
    const allocator = std.testing.allocator;
    
    // Bytecode: PUSH1 0x05 PUSH1 0x01 SUB JUMP JUMPDEST ADD
    // This pushes 5, subtracts 1 to get 4, then jumps (dynamic)
    const code = &[_]u8{
        0x60, 0x05, // PUSH1 0x05
        0x60, 0x01, // PUSH1 0x01
        0x03,       // SUB
        0x56,       // JUMP
        0x5B,       // JUMPDEST
        0x01,       // ADD
    };
    
    var analysis = try SimpleAnalysis.analyze(allocator, code);
    defer analysis.deinit(allocator);
    
    // SUB is at instruction index 2
    // JUMP is at instruction index 3
    // Since JUMP doesn't follow a PUSH directly, no fusion
    const sub_inst_idx: usize = 2;
    const known_jump_dest = analysis.getKnownJump(sub_inst_idx);
    
    // Should not detect a known jump for SUB instruction
    try std.testing.expectEqual(SimpleAnalysis.MAX_USIZE, known_jump_dest);
}

test "SimpleAnalysis does not fuse invalid jump destinations" {
    const allocator = std.testing.allocator;
    
    // Bytecode: PUSH1 0x04 JUMP STOP ADD (no JUMPDEST at 0x04)
    const code = &[_]u8{
        0x60, 0x04, // PUSH1 0x04
        0x56,       // JUMP
        0x00,       // STOP
        0x01,       // ADD (not a JUMPDEST)
    };
    
    var analysis = try SimpleAnalysis.analyze(allocator, code);
    defer analysis.deinit(allocator);
    
    // PUSH1 is at instruction index 0
    const push_inst_idx: usize = 0;
    const known_jump_dest = analysis.getKnownJump(push_inst_idx);
    
    // Should not detect a known jump since destination is not JUMPDEST
    try std.testing.expectEqual(SimpleAnalysis.MAX_USIZE, known_jump_dest);
}

test "SimpleAnalysis correctly maps PC to instruction index" {
    const allocator = std.testing.allocator;
    
    // Bytecode with various PUSH sizes
    const code = &[_]u8{
        0x60, 0x01,       // PUSH1 0x01 (PC 0-1)
        0x61, 0x00, 0x02, // PUSH2 0x0002 (PC 2-4)
        0x5B,             // JUMPDEST (PC 5)
        0x01,             // ADD (PC 6)
    };
    
    var analysis = try SimpleAnalysis.analyze(allocator, code);
    defer analysis.deinit(allocator);
    
    // Check PC to instruction mappings
    try std.testing.expectEqual(@as(usize, 0), analysis.getInstIdx(0)); // PUSH1
    try std.testing.expectEqual(@as(usize, 1), analysis.getInstIdx(2)); // PUSH2
    try std.testing.expectEqual(@as(usize, 2), analysis.getInstIdx(5)); // JUMPDEST
    try std.testing.expectEqual(@as(usize, 3), analysis.getInstIdx(6)); // ADD
    
    // Check that data bytes don't map to instructions
    try std.testing.expectEqual(SimpleAnalysis.MAX_USIZE, analysis.getInstIdx(1)); // PUSH1 data
    try std.testing.expectEqual(SimpleAnalysis.MAX_USIZE, analysis.getInstIdx(3)); // PUSH2 data
    try std.testing.expectEqual(SimpleAnalysis.MAX_USIZE, analysis.getInstIdx(4)); // PUSH2 data
}