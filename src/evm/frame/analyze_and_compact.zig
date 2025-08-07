const std = @import("std");
const CodeAnalysisOptimized = @import("code_analysis_optimized.zig");

// Constants
const MAX_INSTRUCTIONS = 100000;

// Opcode constants
const OP_JUMPDEST: u8 = 0x5b;
const OP_JUMP: u8 = 0x56;
const OP_JUMPI: u8 = 0x57;
const OP_SELFDESTRUCT: u8 = 0xff;
const OP_CREATE: u8 = 0xf0;
const OP_CREATE2: u8 = 0xf5;
const OP_PUSH1: u8 = 0x60;
const OP_PUSH2: u8 = 0x61;
const OP_PUSH32: u8 = 0x7f;
const OP_STOP: u8 = 0x00;

// Dummy Instruction type for testing
const Instruction = struct {
    opcode: u8,
    arg: union(enum) {
        none: void,
        push_value: u64,
    },
};

/// Example of optimized analysis workflow that frees intermediate structures
/// as soon as they're no longer needed.
pub fn analyzeAndCompact(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
) !CodeAnalysisOptimized {
    // Phase 1: Initialize with worst-case allocation
    var analysis = try CodeAnalysisOptimized.init(allocator);
    errdefer analysis.deinit();
    
    // Phase 2: First pass - identify code segments and jumpdests
    var pc: usize = 0;
    var block_count: u16 = 0;
    
    while (pc < bytecode.len) {
        const opcode = bytecode[pc];
        
        // Mark as code (not data)
        analysis.setCode(pc);
        
        // Check for JUMPDEST
        if (opcode == OP_JUMPDEST) {
            analysis.setJumpdest(pc);
            block_count += 1;
        }
        
        // Check for special opcodes
        if (opcode == OP_SELFDESTRUCT) {
            analysis.has_selfdestruct = true;
        }
        if (opcode == OP_CREATE or opcode == OP_CREATE2) {
            analysis.has_create = true;
        }
        if (opcode == OP_JUMP or opcode == OP_JUMPI) {
            // For simplicity, just mark as having jumps
            // In real implementation would track if preceded by PUSH
            analysis.has_static_jumps = true;
        }
        
        // Skip PUSH data bytes
        if (opcode >= OP_PUSH1 and opcode <= OP_PUSH32) {
            const push_size = opcode - OP_PUSH1 + 1;
            var i: usize = 0;
            while (i < push_size and pc + 1 + i < bytecode.len) : (i += 1) {
                // These are data bytes, not code
                // Don't mark them as code
            }
            pc += push_size;
        }
        
        pc += 1;
    }
    
    // Phase 3: Right-size block metadata based on actual block count
    try analysis.resizeBlockMetadata(block_count);
    
    // Phase 4: Second pass - populate block metadata
    // (This would normally analyze each block's gas costs and stack effects)
    // For this example, we'll just set dummy values
    var block_idx: u16 = 0;
    pc = 0;
    while (pc < bytecode.len and block_idx < block_count) {
        if (bytecode[pc] == OP_JUMPDEST) {
            // In real implementation, would calculate actual gas and stack values
            analysis.block_metadata.setBlock(block_idx, 100, 0, 5);
            block_idx += 1;
        }
        
        // Skip PUSH data
        if (bytecode[pc] >= OP_PUSH1 and bytecode[pc] <= OP_PUSH32) {
            const push_size = bytecode[pc] - OP_PUSH1 + 1;
            pc += push_size;
        }
        pc += 1;
    }
    
    // Phase 5: FREE INTERMEDIATE STRUCTURES
    // This is the key optimization - we free structures that were only needed
    // during analysis and won't be needed during execution
    analysis.freeIntermediateStructures();
    
    return analysis;
}

/// Extended analysis that also builds instruction stream
pub fn analyzeAndCompactWithInstructions(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
) !struct {
    analysis: CodeAnalysisOptimized,
    instructions: []Instruction,
} {
    // Get base analysis
    var analysis = try analyzeAndCompact(allocator, bytecode);
    errdefer analysis.deinit();
    
    // Allocate instruction buffer (worst case)
    const instructions = try allocator.alloc(Instruction, MAX_INSTRUCTIONS);
    errdefer allocator.free(instructions);
    
    // Build instruction stream
    // (This would normally translate bytecode to instructions)
    // For this example, just create a few dummy instructions
    const inst_count: usize = 0;
    
    // ... instruction translation logic ...
    
    // Right-size instruction array to actual count
    const final_instructions = try allocator.realloc(instructions, inst_count + 1); // +1 for null terminator
    
    return .{
        .analysis = analysis,
        .instructions = final_instructions,
    };
}

test "analyzeAndCompact basic functionality" {
    const allocator = std.testing.allocator;
    
    // Simple bytecode with JUMPDEST and PUSH
    const bytecode = [_]u8{
        OP_PUSH1, 0x10,  // PUSH1 16
        OP_JUMPDEST,      // JUMPDEST
        OP_PUSH1, 0x05,  // PUSH1 5 (jump target)
        OP_JUMP,          // JUMP (static jump because preceded by PUSH1)
        OP_STOP,          // STOP
    };
    
    var analysis = try analyzeAndCompact(allocator, &bytecode);
    defer analysis.deinit();
    
    // Check that jumpdest was identified
    try std.testing.expect(analysis.isValidJumpdest(2)); // JUMPDEST at position 2
    
    // Check that intermediate structures were freed
    try std.testing.expect(analysis.code_segments == null);
    try std.testing.expect(analysis.block_starts == null);
    try std.testing.expect(analysis.pc_to_block == null);
    
    // Check flags
    try std.testing.expect(analysis.has_static_jumps);
    try std.testing.expect(!analysis.has_dynamic_jumps);
    try std.testing.expect(!analysis.has_selfdestruct);
    try std.testing.expect(!analysis.has_create);
}

test "analyzeAndCompact with special opcodes" {
    const allocator = std.testing.allocator;
    
    const bytecode = [_]u8{
        OP_PUSH1, 0x00,   // PUSH1 0
        0x80,           // DUP1
        OP_SELFDESTRUCT,  // SELFDESTRUCT
    };
    
    var analysis = try analyzeAndCompact(allocator, &bytecode);
    defer analysis.deinit();
    
    // Check that SELFDESTRUCT was detected
    try std.testing.expect(analysis.has_selfdestruct);
    try std.testing.expect(!analysis.has_create);
}

test "analyzeAndCompact memory efficiency" {
    const allocator = std.testing.allocator;
    
    // Bytecode with multiple JUMPDESTs
    const bytecode = [_]u8{
        OP_JUMPDEST,
        OP_PUSH1, 0x05,
        OP_JUMPDEST,
        OP_PUSH1, 0x08,
        OP_JUMPDEST,
        OP_STOP,
    };
    
    var analysis = try analyzeAndCompact(allocator, &bytecode);
    defer analysis.deinit();
    
    // Should have exactly 3 blocks
    try std.testing.expectEqual(@as(u16, 3), analysis.block_metadata.count);
    
    // Block metadata should be right-sized
    try std.testing.expectEqual(@as(usize, 3), analysis.block_metadata.gas_costs.len);
    
    // Intermediate structures should be freed
    try std.testing.expect(analysis.code_segments == null);
}