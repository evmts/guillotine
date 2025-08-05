/// Advanced code analysis with BEGINBLOCK injection for optimized execution.
///
/// This module extends the standard code analysis by injecting BEGINBLOCK
/// instructions at the start of each basic block. This enables the interpreter
/// to perform bulk validation of gas and stack requirements, significantly
/// improving performance for block-based execution.
///
/// ## Design Philosophy
///
/// Following the evmone "Advanced" interpreter approach:
/// 1. Analyze bytecode to identify basic blocks
/// 2. Inject BEGINBLOCK at the start of each block
/// 3. Pre-calculate block metadata (gas, stack requirements)
/// 4. Execute blocks with minimal per-instruction overhead
///
/// ## Compatibility
///
/// This analysis maintains full EVM compatibility. The BEGINBLOCK instructions
/// are internal only and don't affect the observable behavior of contracts.

const std = @import("std");
const BitVec64 = @import("bitvec.zig").BitVec64;
const BlockMetadata = @import("code_analysis.zig").BlockMetadata;
const CodeAnalysis = @import("code_analysis.zig");
const intrinsic = @import("../opcodes/intrinsic.zig");
const opcode = @import("../opcodes/opcode.zig");
const jump_table = @import("../jump_table/jump_table.zig");
const primitives = @import("primitives");

/// Instruction with optional block metadata.
///
/// This represents either a regular EVM opcode or an intrinsic BEGINBLOCK
/// instruction with its associated block metadata.
pub const AdvancedInstruction = struct {
    /// The opcode byte (EVM opcode or intrinsic)
    opcode: u8,
    
    /// For BEGINBLOCK instructions, contains the block metadata
    /// For regular instructions, this is undefined
    block_metadata: BlockMetadata = undefined,
    
    /// For PUSH instructions, contains the immediate data
    /// Empty slice for non-PUSH instructions
    immediate_data: []const u8 = &[_]u8{},
};

/// Advanced code analysis result with BEGINBLOCK injection.
pub const AdvancedCodeAnalysis = struct {
    /// The rewritten bytecode with BEGINBLOCK instructions
    instructions: []AdvancedInstruction,
    
    /// Mapping from original PC to instruction index
    pc_to_instruction: []u32,
    
    /// Jump destination mapping (original PC -> instruction index)
    jumpdest_map: std.AutoHashMap(usize, u32),
    
    /// Original code analysis data
    base_analysis: CodeAnalysis,
    
    /// Allocator used for this analysis
    allocator: std.mem.Allocator,
    
    /// Clean up allocated memory.
    pub fn deinit(self: *AdvancedCodeAnalysis) void {
        self.allocator.free(self.instructions);
        self.allocator.free(self.pc_to_instruction);
        self.jumpdest_map.deinit();
        self.base_analysis.deinit(self.allocator);
    }
};

/// Analyzes bytecode and creates an advanced representation with BEGINBLOCK injection.
///
/// This function:
/// 1. Performs standard block analysis
/// 2. Creates a new instruction stream with BEGINBLOCK at each block start
/// 3. Maintains mappings for jump resolution
///
/// ## Parameters
/// - `allocator`: Memory allocator
/// - `code`: Original EVM bytecode
///
/// ## Returns
/// AdvancedCodeAnalysis with injected BEGINBLOCK instructions
pub fn analyze_with_beginblock(allocator: std.mem.Allocator, code: []const u8) !AdvancedCodeAnalysis {
    // First, perform standard block analysis
    var base_analysis = try CodeAnalysis.analyze_bytecode_blocks(allocator, code);
    errdefer base_analysis.deinit(allocator);
    
    // Count instructions needed (original + BEGINBLOCK injections)
    var instruction_count: usize = 0;
    var pc: usize = 0;
    while (pc < code.len) {
        const op = code[pc];
        instruction_count += 1;
        
        // Add space for BEGINBLOCK at block starts (except position 0)
        if (pc > 0 and base_analysis.block_starts.isSetUnchecked(pc)) {
            instruction_count += 1;
        }
        
        // Skip PUSH data
        if (opcode.is_push(op)) {
            pc += 1 + opcode.get_push_size(op);
        } else {
            pc += 1;
        }
    }
    
    // Add BEGINBLOCK at position 0
    instruction_count += 1;
    
    // Allocate instruction array
    var instructions = try allocator.alloc(AdvancedInstruction, instruction_count);
    errdefer allocator.free(instructions);
    
    // Allocate PC to instruction mapping
    var pc_to_instruction = try allocator.alloc(u32, code.len);
    errdefer allocator.free(pc_to_instruction);
    @memset(pc_to_instruction, std.math.maxInt(u32)); // Initialize to invalid
    
    // Create jump destination map
    var jumpdest_map = std.AutoHashMap(usize, u32).init(allocator);
    errdefer jumpdest_map.deinit();
    
    // Second pass: build instruction stream with BEGINBLOCK injection
    var instr_idx: u32 = 0;
    var current_block: u16 = 0;
    pc = 0;
    
    // Always start with BEGINBLOCK for block 0
    instructions[instr_idx] = .{
        .opcode = @intFromEnum(intrinsic.IntrinsicOpcodes.BEGINBLOCK),
        .block_metadata = base_analysis.block_metadata[0],
    };
    instr_idx += 1;
    
    while (pc < code.len) {
        // Check if we're starting a new block (except at position 0)
        if (pc > 0 and base_analysis.block_starts.isSetUnchecked(pc)) {
            current_block += 1;
            
            // Inject BEGINBLOCK
            instructions[instr_idx] = .{
                .opcode = @intFromEnum(intrinsic.IntrinsicOpcodes.BEGINBLOCK),
                .block_metadata = base_analysis.block_metadata[current_block],
            };
            instr_idx += 1;
        }
        
        // Record PC to instruction mapping
        pc_to_instruction[pc] = instr_idx;
        
        const op = code[pc];
        
        // Record jump destinations
        if (op == @intFromEnum(opcode.Enum.JUMPDEST)) {
            try jumpdest_map.put(pc, instr_idx);
        }
        
        // Add the regular instruction
        if (opcode.is_push(op)) {
            const push_size = opcode.get_push_size(op);
            const data_start = pc + 1;
            const data_end = @min(data_start + push_size, code.len);
            
            instructions[instr_idx] = .{
                .opcode = op,
                .immediate_data = code[data_start..data_end],
            };
            
            pc += 1 + push_size;
        } else {
            instructions[instr_idx] = .{
                .opcode = op,
            };
            pc += 1;
        }
        
        instr_idx += 1;
    }
    
    return AdvancedCodeAnalysis{
        .instructions = instructions,
        .pc_to_instruction = pc_to_instruction,
        .jumpdest_map = jumpdest_map,
        .base_analysis = base_analysis,
        .allocator = allocator,
    };
}

/// Find the instruction index for a given PC.
///
/// Used for jump resolution in the advanced interpreter.
pub fn pc_to_instruction_index(analysis: *const AdvancedCodeAnalysis, pc: usize) ?u32 {
    if (pc >= analysis.pc_to_instruction.len) return null;
    const idx = analysis.pc_to_instruction[pc];
    return if (idx == std.math.maxInt(u32)) null else idx;
}

/// Check if a PC is a valid jump destination.
pub fn is_valid_jumpdest(analysis: *const AdvancedCodeAnalysis, pc: usize) bool {
    return analysis.jumpdest_map.contains(pc);
}

test "BEGINBLOCK injection at block boundaries" {
    const allocator = std.testing.allocator;
    
    // Test bytecode with multiple blocks:
    // Block 0: PUSH1 0x04 PUSH1 0x02
    // Block 1: JUMPDEST ADD STOP
    const code = [_]u8{
        0x60, 0x04, // PUSH1 0x04
        0x60, 0x02, // PUSH1 0x02  
        0x5b,       // JUMPDEST (starts new block)
        0x01,       // ADD
        0x00,       // STOP
    };
    
    var analysis = try analyze_with_beginblock(allocator, &code);
    defer analysis.deinit();
    
    // Verify instruction count (original 5 + 2 BEGINBLOCK)
    try std.testing.expectEqual(@as(usize, 7), analysis.instructions.len);
    
    // Verify BEGINBLOCK at position 0
    try std.testing.expectEqual(
        @intFromEnum(intrinsic.IntrinsicOpcodes.BEGINBLOCK),
        analysis.instructions[0].opcode
    );
    
    // Verify instructions
    try std.testing.expectEqual(@as(u8, 0x60), analysis.instructions[1].opcode); // PUSH1
    try std.testing.expectEqual(@as(u8, 0x60), analysis.instructions[2].opcode); // PUSH1
    
    // Verify BEGINBLOCK before JUMPDEST
    try std.testing.expectEqual(
        @intFromEnum(intrinsic.IntrinsicOpcodes.BEGINBLOCK),
        analysis.instructions[3].opcode
    );
    
    try std.testing.expectEqual(@as(u8, 0x5b), analysis.instructions[4].opcode); // JUMPDEST
    try std.testing.expectEqual(@as(u8, 0x01), analysis.instructions[5].opcode); // ADD
    try std.testing.expectEqual(@as(u8, 0x00), analysis.instructions[6].opcode); // STOP
    
    // Verify jump destination mapping
    try std.testing.expect(analysis.is_valid_jumpdest(&analysis, 4)); // PC 4 = JUMPDEST
}

test "BEGINBLOCK metadata propagation" {
    const allocator = std.testing.allocator;
    
    // Simple bytecode to test metadata
    const code = [_]u8{
        0x60, 0x01, // PUSH1 0x01 (3 gas)
        0x60, 0x02, // PUSH1 0x02 (3 gas)
        0x01,       // ADD (3 gas)
        0x00,       // STOP (0 gas)
    };
    
    var analysis = try analyze_with_beginblock(allocator, &code);
    defer analysis.deinit();
    
    // Verify BEGINBLOCK has correct metadata
    const beginblock = analysis.instructions[0];
    try std.testing.expectEqual(
        @intFromEnum(intrinsic.IntrinsicOpcodes.BEGINBLOCK),
        beginblock.opcode
    );
    
    // Verify block metadata (gas cost = 9)
    try std.testing.expectEqual(@as(u32, 9), beginblock.block_metadata.gas_cost);
    try std.testing.expectEqual(@as(i16, 0), beginblock.block_metadata.stack_req);
    try std.testing.expectEqual(@as(i16, 1), beginblock.block_metadata.stack_max);
}