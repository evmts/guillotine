const std = @import("std");
const bitvec = @import("bitvec.zig");
const BitVec64 = bitvec.BitVec64;

/// Block metadata for efficient block-based execution.
///
/// This packed struct contains critical information about each basic block
/// in the bytecode, enabling batch validation of gas and stack operations.
/// The struct is exactly 8 bytes for cache efficiency and atomic loads.
///
/// ## Fields
/// - `gas_cost`: Total gas required to execute all operations in the block
/// - `stack_req`: Minimum stack items required at block entry (can be negative)
/// - `stack_max`: Maximum stack growth during block execution
///
/// ## Performance
/// The 8-byte size ensures the struct fits in a CPU register and can be
/// loaded atomically, matching EVMOne's optimization approach.
pub const BlockMetadata = packed struct {
    gas_cost: u32,      // Total gas for block (4 bytes)
    stack_req: i16,     // Min stack items needed (2 bytes)  
    stack_max: i16,     // Max stack growth (2 bytes)
};

/// Memory expansion information for a block
/// Stores pre-calculated memory expansion costs for static accesses
pub const MemoryExpansionInfo = struct {
    /// Maximum memory size accessed in this block (0 if no memory access)
    max_memory_size: u64,
    /// Pre-calculated memory expansion gas cost for this block
    /// Only valid if all memory accesses in block are static
    expansion_gas_cost: u64,
    /// Whether all memory accesses in this block are static (known at compile time)
    is_static: bool,
};

// Debug assertions for safety
comptime {
    std.debug.assert(@sizeOf(BlockMetadata) == 8);
    std.debug.assert(@alignOf(BlockMetadata) >= 4); // Ensure proper alignment
    
    // Verify field offsets match EVMOne layout
    std.debug.assert(@offsetOf(BlockMetadata, "gas_cost") == 0);
    std.debug.assert(@offsetOf(BlockMetadata, "stack_req") == 4);
    std.debug.assert(@offsetOf(BlockMetadata, "stack_max") == 6);
}

/// Advanced code analysis for EVM bytecode optimization.
///
/// This structure holds pre-computed analysis results for a contract's bytecode,
/// enabling efficient execution by pre-identifying jump destinations, code segments,
/// and other properties that would otherwise need to be computed at runtime.
///
/// The analysis is performed once when a contract is first loaded and cached for
/// subsequent executions, significantly improving performance for frequently-used
/// contracts.
///
/// ## Fields
/// - `code_segments`: Bit vector marking which bytes are executable code vs data
/// - `jumpdest_bitmap`: Bitmap of valid JUMPDEST positions for O(1) validation
/// - `block_gas_costs`: Optional pre-computed gas costs for basic blocks
/// - `max_stack_depth`: Maximum stack depth required by the contract
/// - `has_dynamic_jumps`: Whether the code contains JUMP/JUMPI with dynamic targets
/// - `has_static_jumps`: Whether the code contains JUMP/JUMPI with static targets
/// - `has_selfdestruct`: Whether the code contains SELFDESTRUCT opcode
/// - `has_create`: Whether the code contains CREATE/CREATE2 opcodes
///
/// ## Performance
/// - Jump destination validation: O(1) using bitmap lookup
/// - Code segment checking: O(1) using bit vector
/// - Enables dead code elimination and other optimizations
///
/// ## Memory Management
/// The analysis owns its allocated memory and must be properly cleaned up
/// using the `deinit` method to prevent memory leaks.
const CodeAnalysis = @This();
const JumpAnalysis = @import("jump_analysis.zig").JumpAnalysis;

/// Bit vector marking which bytes in the bytecode are executable code vs data.
///
/// Each bit corresponds to a byte in the contract bytecode:
/// - 1 = executable code byte
/// - 0 = data byte (e.g., PUSH arguments)
///
/// This is critical for JUMPDEST validation since jump destinations
/// must point to actual code, not data bytes within PUSH instructions.
code_segments: BitVec64,

/// Bitmap marking all valid JUMPDEST positions in the bytecode.
///
/// Each bit corresponds to a byte position in the code:
/// - 1 = valid JUMPDEST at this position
/// - 0 = not a valid JUMPDEST
///
/// This enables O(1) jump destination validation instead of O(log n) binary search.
jumpdest_bitmap: BitVec64,

/// Optional pre-computed gas costs for each basic block.
///
/// When present, enables advanced gas optimization by pre-calculating
/// the gas cost of straight-line code sequences between jumps.
/// This is an optional optimization that may not be computed for all contracts.
block_gas_costs: ?[]const u32,

/// Maximum stack depth required by any execution path in the contract.
///
/// Pre-computed through static analysis to enable early detection of
/// stack overflow conditions. A value of 0 indicates the depth wasn't analyzed.
max_stack_depth: u16,

/// Indicates whether the contract contains JUMP/JUMPI opcodes with dynamic targets.
///
/// Dynamic jumps (where the target is computed at runtime) prevent certain
/// optimizations and require full jump destination validation at runtime.
has_dynamic_jumps: bool,

/// Indicates whether the contract contains JUMP/JUMPI opcodes with static targets.
///
/// Static jumps (where the target is a constant) can be pre-validated
/// and optimized during analysis.
has_static_jumps: bool,

/// Indicates whether the contract contains the SELFDESTRUCT opcode (0xFF).
///
/// Contracts with SELFDESTRUCT require special handling for state management
/// and cannot be marked as "pure" or side-effect free.
has_selfdestruct: bool,

/// Indicates whether the contract contains CREATE or CREATE2 opcodes.
///
/// Contracts that can deploy other contracts require additional
/// gas reservation and state management considerations.
has_create: bool,

/// Bit vector marking the start positions of basic blocks.
///
/// Each bit corresponds to a byte position in the bytecode:
/// - 1 = start of a new basic block
/// - 0 = continuation of current block
///
/// Basic blocks are sequences of instructions with single entry/exit points,
/// enabling batch gas and stack validation for performance optimization.
block_starts: BitVec64,

/// Array of metadata for each basic block in the bytecode.
///
/// Each entry contains the gas cost and stack requirements for one block,
/// indexed by block number. This enables the interpreter to validate entire
/// blocks at once instead of per-instruction validation.
block_metadata: []BlockMetadata,

/// Maps each bytecode position (PC) to its containing block index.
///
/// This lookup table enables O(1) determination of which block contains
/// any given instruction, critical for efficient block-based execution.
/// Values are limited to u16 to save memory (max 65535 blocks per contract).
pc_to_block: []u16,

/// Total number of basic blocks identified in the bytecode.
///
/// Limited to u16 as contracts larger than 24KB are rejected, and typical
/// contracts have far fewer than 65535 blocks. Most contracts have < 1000 blocks.
block_count: u16,

/// Pre-computed jump destination analysis for O(1) validation.
///
/// This optional field contains analyzed jump information that enables
/// fast validation of static jumps without runtime checks.
jump_analysis: ?*JumpAnalysis,

/// Pre-computed block start positions for O(1) block boundary lookup.
///
/// Each entry contains the PC where a block starts, indexed by block number.
/// This eliminates the need for linear scanning in find_block_start.
/// Example: block_start_positions[5] = 128 means block 5 starts at PC 128.
block_start_positions: []usize,

/// Pre-calculated memory expansion information for each block.
///
/// Indexed by block number, contains memory expansion costs and metadata.
/// This enables the interpreter to skip runtime memory expansion calculations
/// for blocks with static memory accesses.
memory_expansion_info: []MemoryExpansionInfo,

/// Releases all memory allocated by this code analysis.
///
/// This method must be called when the analysis is no longer needed to prevent
/// memory leaks. It safely handles all owned resources including:
/// - The code segments bit vector
/// - The jumpdest bitmap
/// - The optional block gas costs array
///
/// ## Parameters
/// - `self`: The analysis instance to clean up
/// - `allocator`: The same allocator used to create the analysis resources
///
/// ## Safety
/// After calling deinit, the analysis instance should not be used again.
/// All pointers to analysis data become invalid.
///
/// ## Example
/// ```zig
/// var analysis = try analyze_code(allocator, bytecode);
/// defer analysis.deinit(allocator);
/// ```
pub fn deinit(self: *CodeAnalysis, allocator: std.mem.Allocator) void {
    // Existing deallocations
    self.code_segments.deinit(allocator);
    self.jumpdest_bitmap.deinit(allocator);
    if (self.block_gas_costs) |costs| {
        allocator.free(costs);
    }
    
    // Free block-related allocations
    if (self.block_metadata.len > 0) {
        allocator.free(self.block_metadata);
    }
    if (self.pc_to_block.len > 0) {
        allocator.free(self.pc_to_block);
    }
    self.block_starts.deinit(allocator);
    
    // Free jump analysis if present
    if (self.jump_analysis) |analysis| {
        analysis.deinit();
        allocator.destroy(analysis);
    }
    
    // Free block start positions
    if (self.block_start_positions.len > 0) {
        allocator.free(self.block_start_positions);
    }
    
    // Free memory expansion info
    if (self.memory_expansion_info.len > 0) {
        allocator.free(self.memory_expansion_info);
    }
    
    // Memory best practice: zero out pointers after free
    self.* = undefined;
}

test "BlockMetadata is exactly 8 bytes and properly aligned" {
    try std.testing.expectEqual(8, @sizeOf(BlockMetadata));
    try std.testing.expect(@alignOf(BlockMetadata) >= 4);
    
    // Test field access
    const block = BlockMetadata{ .gas_cost = 100, .stack_req = -5, .stack_max = 10 };
    try std.testing.expectEqual(@as(u32, 100), block.gas_cost);
    try std.testing.expectEqual(@as(i16, -5), block.stack_req);
    try std.testing.expectEqual(@as(i16, 10), block.stack_max);
}

test "BlockMetadata handles extreme values" {
    // Test maximum values
    const max_block = BlockMetadata{
        .gas_cost = std.math.maxInt(u32),
        .stack_req = std.math.maxInt(i16),
        .stack_max = std.math.maxInt(i16),
    };
    try std.testing.expectEqual(@as(u32, 4_294_967_295), max_block.gas_cost);
    
    // Test minimum values
    const min_block = BlockMetadata{
        .gas_cost = 0,
        .stack_req = std.math.minInt(i16),
        .stack_max = std.math.minInt(i16),
    };
    try std.testing.expectEqual(@as(i16, -32768), min_block.stack_req);
}

test "CodeAnalysis with block data initializes and deinits correctly" {
    const allocator = std.testing.allocator;
    
    var analysis = CodeAnalysis{
        .code_segments = try BitVec64.init(allocator, 100),
        .jumpdest_bitmap = try BitVec64.init(allocator, 100),
        .block_starts = try BitVec64.init(allocator, 100),
        .block_metadata = try allocator.alloc(BlockMetadata, 10),
        .pc_to_block = try allocator.alloc(u16, 100),
        .block_count = 10,
        .max_stack_depth = 0,
        .has_dynamic_jumps = false,
        .has_static_jumps = false,
        .has_selfdestruct = false,
        .has_create = false,
        .block_gas_costs = null,
        .jump_analysis = null,
        .block_start_positions = try allocator.alloc(usize, 10),
        .memory_expansion_info = try allocator.alloc(MemoryExpansionInfo, 10),
    };
    defer analysis.deinit(allocator);
    
    // Verify fields are accessible
    try std.testing.expectEqual(@as(u16, 10), analysis.block_count);
    try std.testing.expectEqual(@as(usize, 10), analysis.block_metadata.len);
    try std.testing.expectEqual(@as(usize, 100), analysis.pc_to_block.len);
    try std.testing.expectEqual(@as(usize, 10), analysis.memory_expansion_info.len);
    
    // Test pc_to_block mapping
    analysis.pc_to_block[50] = 5;
    try std.testing.expectEqual(@as(u16, 5), analysis.pc_to_block[50]);
}

test "CodeAnalysis deinit handles partially initialized state" {
    const allocator = std.testing.allocator;
    
    // Test with empty block data
    var analysis = CodeAnalysis{
        .code_segments = try BitVec64.init(allocator, 10),
        .jumpdest_bitmap = try BitVec64.init(allocator, 10),
        .block_starts = BitVec64{
            .bits = &[_]u64{},
            .size = 0,
            .owned = false,
            .cached_ptr = undefined,
        }, // Empty
        .block_metadata = &[_]BlockMetadata{},
        .pc_to_block = &[_]u16{},
        .block_count = 0,
        .max_stack_depth = 0,
        .has_dynamic_jumps = false,
        .has_static_jumps = false,
        .has_selfdestruct = false,
        .has_create = false,
        .block_gas_costs = null,
        .jump_analysis = null,
        .block_start_positions = &[_]usize{},
        .memory_expansion_info = &[_]MemoryExpansionInfo{},
    };
    
    // Should not crash on deinit
    analysis.deinit(allocator);
}

test "Block analysis correctly identifies basic blocks" {
    const allocator = std.testing.allocator;
    
    // Test bytecode with multiple basic blocks:
    // Block 0: PUSH1 0x10 PUSH1 0x20 ADD
    // Block 1: JUMPDEST PUSH1 0x30 MUL
    // Block 2: JUMPDEST STOP
    const code = &[_]u8{
        0x60, 0x10, // PUSH1 0x10
        0x60, 0x20, // PUSH1 0x20
        0x01,       // ADD
        0x5b,       // JUMPDEST (starts block 1)
        0x60, 0x30, // PUSH1 0x30
        0x02,       // MUL
        0x5b,       // JUMPDEST (starts block 2)
        0x00,       // STOP
    };
    
    var analysis = try analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);
    
    // Verify block count
    try std.testing.expectEqual(@as(u16, 3), analysis.block_count);
    
    // Verify block starts
    try std.testing.expect(!analysis.block_starts.isSetUnchecked(0)); // Block 0 starts at 0 (implicit)
    try std.testing.expect(!analysis.block_starts.isSetUnchecked(1));
    try std.testing.expect(!analysis.block_starts.isSetUnchecked(2));
    try std.testing.expect(!analysis.block_starts.isSetUnchecked(3));
    try std.testing.expect(!analysis.block_starts.isSetUnchecked(4));
    try std.testing.expect(analysis.block_starts.isSetUnchecked(5)); // Block 1 starts at JUMPDEST
    try std.testing.expect(!analysis.block_starts.isSetUnchecked(6));
    try std.testing.expect(!analysis.block_starts.isSetUnchecked(7));
    try std.testing.expect(!analysis.block_starts.isSetUnchecked(8));
    try std.testing.expect(analysis.block_starts.isSetUnchecked(9)); // Block 2 starts at JUMPDEST
    
    // Verify PC to block mapping
    try std.testing.expectEqual(@as(u16, 0), analysis.pc_to_block[0]);
    try std.testing.expectEqual(@as(u16, 0), analysis.pc_to_block[1]);
    try std.testing.expectEqual(@as(u16, 0), analysis.pc_to_block[2]);
    try std.testing.expectEqual(@as(u16, 0), analysis.pc_to_block[3]);
    try std.testing.expectEqual(@as(u16, 0), analysis.pc_to_block[4]);
    try std.testing.expectEqual(@as(u16, 1), analysis.pc_to_block[5]);
    try std.testing.expectEqual(@as(u16, 1), analysis.pc_to_block[6]);
    try std.testing.expectEqual(@as(u16, 1), analysis.pc_to_block[7]);
    try std.testing.expectEqual(@as(u16, 1), analysis.pc_to_block[8]);
    try std.testing.expectEqual(@as(u16, 2), analysis.pc_to_block[9]);
    try std.testing.expectEqual(@as(u16, 2), analysis.pc_to_block[10]);
    
    // Verify block metadata
    try std.testing.expectEqual(@as(usize, 3), analysis.block_metadata.len);
    
    // Block 0: PUSH1 (3) + PUSH1 (3) + ADD (3) = 9 gas
    try std.testing.expectEqual(@as(u32, 9), analysis.block_metadata[0].gas_cost);
    try std.testing.expectEqual(@as(i16, 0), analysis.block_metadata[0].stack_req);
    try std.testing.expectEqual(@as(i16, 1), analysis.block_metadata[0].stack_max); // Pushes 2, pops 2, net +1
    
    // Block 1: JUMPDEST (1) + PUSH1 (3) + MUL (5) = 9 gas
    try std.testing.expectEqual(@as(u32, 9), analysis.block_metadata[1].gas_cost);
    try std.testing.expectEqual(@as(i16, 1), analysis.block_metadata[1].stack_req); // Needs 1 from previous block
    try std.testing.expectEqual(@as(i16, 1), analysis.block_metadata[1].stack_max); // Has 1, pushes 1, pops 2, net 0
    
    // Block 2: JUMPDEST (1) + STOP (0) = 1 gas
    try std.testing.expectEqual(@as(u32, 1), analysis.block_metadata[2].gas_cost);
    try std.testing.expectEqual(@as(i16, 0), analysis.block_metadata[2].stack_req);
    try std.testing.expectEqual(@as(i16, 0), analysis.block_metadata[2].stack_max);
}

test "Block analysis handles jumps correctly" {
    const allocator = std.testing.allocator;
    
    // Test bytecode with conditional and unconditional jumps:
    // PUSH1 0x08 PUSH1 0x01 EQ PUSH1 0x0a JUMPI STOP JUMPDEST PUSH1 0x42 STOP
    const code = &[_]u8{
        0x60, 0x08, // PUSH1 0x08
        0x60, 0x01, // PUSH1 0x01
        0x14,       // EQ
        0x60, 0x0a, // PUSH1 0x0a (jump target)
        0x57,       // JUMPI (conditional jump)
        0x00,       // STOP
        0x5b,       // JUMPDEST (at position 0x0a)
        0x60, 0x42, // PUSH1 0x42
        0x00,       // STOP
    };
    
    var analysis = try analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);
    
    // Should have 3 blocks:
    // Block 0: 0-8 (up to JUMPI)
    // Block 1: 9 (STOP after JUMPI)
    // Block 2: 10-13 (JUMPDEST onwards)
    try std.testing.expectEqual(@as(u16, 3), analysis.block_count);
    
    // Verify JUMPI creates block boundaries
    try std.testing.expect(analysis.block_starts.isSetUnchecked(9)); // New block after JUMPI
    try std.testing.expect(analysis.block_starts.isSetUnchecked(10)); // JUMPDEST starts new block
}

test "Block analysis calculates gas costs correctly" {
    const allocator = std.testing.allocator;
    
    // Test with various opcodes to verify gas calculation
    const code = &[_]u8{
        0x60, 0x01, // PUSH1 (3 gas)
        0x60, 0x02, // PUSH1 (3 gas)
        0x01,       // ADD (3 gas)
        0x60, 0x03, // PUSH1 (3 gas)
        0x02,       // MUL (5 gas)
        0x5b,       // JUMPDEST (1 gas) - new block
        0x80,       // DUP1 (3 gas)
        0x50,       // POP (2 gas)
        0x00,       // STOP (0 gas)
    };
    
    var analysis = try analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);
    
    try std.testing.expectEqual(@as(u16, 2), analysis.block_count);
    
    // Block 0: 3+3+3+3+5 = 17 gas
    try std.testing.expectEqual(@as(u32, 17), analysis.block_metadata[0].gas_cost);
    
    // Block 1: 1+3+2+0 = 6 gas
    try std.testing.expectEqual(@as(u32, 6), analysis.block_metadata[1].gas_cost);
}

test "Block analysis tracks stack effects" {
    const allocator = std.testing.allocator;
    
    // Test stack tracking across blocks
    const code = &[_]u8{
        0x60, 0x01, // PUSH1 (stack: +1)
        0x60, 0x02, // PUSH1 (stack: +1)
        0x60, 0x03, // PUSH1 (stack: +1)
        0x5b,       // JUMPDEST - new block, inherits stack depth 3
        0x01,       // ADD (stack: -1)
        0x02,       // MUL (stack: -1)
        0x5b,       // JUMPDEST - new block, inherits stack depth 1
        0x50,       // POP (stack: -1)
        0x00,       // STOP
    };
    
    var analysis = try analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);
    
    try std.testing.expectEqual(@as(u16, 3), analysis.block_count);
    
    // Block 0: starts with 0, max growth to 3
    try std.testing.expectEqual(@as(i16, 0), analysis.block_metadata[0].stack_req);
    try std.testing.expectEqual(@as(i16, 3), analysis.block_metadata[0].stack_max);
    
    // Block 1: needs 3 items (for ADD and MUL), ends with 1
    try std.testing.expectEqual(@as(i16, 3), analysis.block_metadata[1].stack_req);
    try std.testing.expectEqual(@as(i16, 0), analysis.block_metadata[1].stack_max); // No growth, only consumption
    
    // Block 2: needs 1 item (for POP)
    try std.testing.expectEqual(@as(i16, 1), analysis.block_metadata[2].stack_req);
    try std.testing.expectEqual(@as(i16, 0), analysis.block_metadata[2].stack_max);
}

/// Analyzes bytecode to identify basic blocks and calculate metadata for each block.
///
/// A basic block is a sequence of instructions with:
/// - Single entry point (first instruction or jump target)
/// - Single exit point (jump/stop/return or fall-through to next block)
///
/// This analysis enables block-based execution optimization by pre-calculating:
/// - Gas costs for the entire block
/// - Stack requirements and effects
/// - PC to block mapping for fast lookup
pub fn analyze_bytecode_blocks(allocator: std.mem.Allocator, code: []const u8) !CodeAnalysis {
    const opcode = @import("../opcodes/opcode.zig");
    const jump_table = @import("../jump_table/jump_table.zig");
    const jump_analysis = @import("jump_analysis.zig");
    
    // Initialize analysis structure
    var analysis = CodeAnalysis{
        .code_segments = try BitVec64.codeBitmap(allocator, code),
        .jumpdest_bitmap = try BitVec64.init(allocator, code.len),
        .block_starts = try BitVec64.init(allocator, code.len),
        .block_metadata = &[_]BlockMetadata{},
        .pc_to_block = &[_]u16{},
        .block_count = 0,
        .max_stack_depth = 0,
        .has_dynamic_jumps = false,
        .has_static_jumps = false,
        .has_selfdestruct = false,
        .has_create = false,
        .block_gas_costs = null,
        .jump_analysis = null,
        .block_start_positions = &[_]usize{},
        .memory_expansion_info = &[_]MemoryExpansionInfo{},
    };
    errdefer analysis.deinit(allocator);
    
    if (code.len == 0) return analysis;
    
    // First pass: identify JUMPDESTs and block boundaries
    var i: usize = 0;
    while (i < code.len) {
        const op = code[i];
        
        // Mark JUMPDEST positions
        if (op == @intFromEnum(opcode.Enum.JUMPDEST) and analysis.code_segments.isSetUnchecked(i)) {
            analysis.jumpdest_bitmap.setUnchecked(i);
            // JUMPDESTs always start new blocks (except at position 0)
            if (i > 0) {
                analysis.block_starts.setUnchecked(i);
            }
        }
        
        // Handle opcodes that end blocks
        switch (@as(opcode.Enum, @enumFromInt(op))) {
            .JUMP, .JUMPI => {
                analysis.has_static_jumps = true;
                // Next instruction starts new block (if exists)
                if (i + 1 < code.len) {
                    analysis.block_starts.setUnchecked(i + 1);
                }
            },
            .STOP, .RETURN, .REVERT, .INVALID, .SELFDESTRUCT => {
                if (op == @intFromEnum(opcode.Enum.SELFDESTRUCT)) {
                    analysis.has_selfdestruct = true;
                }
                // Next instruction starts new block (if exists)
                if (i + 1 < code.len) {
                    analysis.block_starts.setUnchecked(i + 1);
                }
            },
            .CREATE, .CREATE2 => {
                analysis.has_create = true;
            },
            else => {},
        }
        
        // Advance PC
        if (opcode.is_push(op)) {
            const push_bytes = opcode.get_push_size(op);
            i += 1 + push_bytes;
        } else {
            i += 1;
        }
    }
    
    // Count blocks
    var block_count: u16 = 1; // First block starts at 0 (implicit)
    i = 1;
    while (i < code.len) : (i += 1) {
        if (analysis.block_starts.isSetUnchecked(i)) {
            block_count += 1;
        }
    }
    analysis.block_count = block_count;
    
    // Allocate block metadata and pc_to_block mapping
    analysis.block_metadata = try allocator.alloc(BlockMetadata, block_count);
    errdefer allocator.free(analysis.block_metadata);
    
    analysis.pc_to_block = try allocator.alloc(u16, code.len);
    errdefer allocator.free(analysis.pc_to_block);
    
    // Allocate block start positions
    analysis.block_start_positions = try allocator.alloc(usize, block_count);
    errdefer allocator.free(analysis.block_start_positions);
    
    // Allocate memory expansion info
    analysis.memory_expansion_info = try allocator.alloc(MemoryExpansionInfo, block_count);
    errdefer allocator.free(analysis.memory_expansion_info);
    
    // Initialize memory expansion info to defaults
    for (analysis.memory_expansion_info) |*info| {
        info.* = .{
            .max_memory_size = 0,
            .expansion_gas_cost = 0,
            .is_static = true,
        };
    }
    
    // Initialize jump table for gas cost lookup
    const table = jump_table.JumpTable.init();
    
    // Second pass: analyze each block
    var current_block: u16 = 0;
    var block_start_pc: usize = 0;
    var gas_cost: u32 = 0;
    var stack_depth: i16 = 0;
    var block_stack_start: i16 = 0;
    var min_stack_in_block: i16 = 0;
    var max_stack_in_block: i16 = 0;
    
    // Memory expansion tracking
    var block_max_memory: u64 = 0;
    var block_memory_is_static = true;
    var current_memory_size: u64 = 0; // Track memory size entering the block
    
    // First block always starts at 0
    analysis.block_start_positions[0] = 0;
    
    i = 0;
    while (i < code.len) {
        // Record PC to block mapping
        analysis.pc_to_block[i] = current_block;
        
        // Check if this starts a new block (except at 0)
        if (i > 0 and analysis.block_starts.isSetUnchecked(i)) {
            // Save metadata for completed block
            analysis.block_metadata[current_block] = BlockMetadata{
                .gas_cost = gas_cost,
                .stack_req = @max(0, block_stack_start + min_stack_in_block),
                .stack_max = max_stack_in_block - block_stack_start,
            };
            
            // Save memory expansion info for completed block
            if (block_memory_is_static and block_max_memory > current_memory_size) {
                // Calculate expansion cost from current_memory_size to block_max_memory
                const new_words = (block_max_memory + 31) / 32;
                const current_words = (current_memory_size + 31) / 32;
                const new_cost = 3 * new_words + (new_words * new_words) / 512;
                const current_cost = if (current_memory_size == 0) 0 else 3 * current_words + (current_words * current_words) / 512;
                analysis.memory_expansion_info[current_block].expansion_gas_cost = new_cost - current_cost;
            }
            analysis.memory_expansion_info[current_block].max_memory_size = block_max_memory;
            analysis.memory_expansion_info[current_block].is_static = block_memory_is_static;
            
            // Start new block
            current_block += 1;
            block_start_pc = i;
            // Record block start position
            if (current_block < block_count) {
                analysis.block_start_positions[current_block] = i;
            }
            gas_cost = 0;
            // New block inherits stack depth from previous
            block_stack_start = stack_depth;
            min_stack_in_block = 0;
            max_stack_in_block = stack_depth;
            
            // Memory state for new block
            current_memory_size = block_max_memory; // New block starts with expanded memory
            block_max_memory = current_memory_size;
            block_memory_is_static = true;
        }
        
        const op = code[i];
        
        // Skip non-code bytes (PUSH data)
        if (!analysis.code_segments.isSetUnchecked(i)) {
            i += 1;
            continue;
        }
        
        // Get operation from jump table
        const operation_ptr = table.get_operation(op);
        
        // Add constant gas cost
        gas_cost = @min(gas_cost + @as(u32, @intCast(operation_ptr.constant_gas)), std.math.maxInt(u32));
        
        // Track stack effects
        const stack_inputs = @as(i16, @intCast(operation_ptr.min_stack));
        const stack_outputs: i16 = switch (@as(opcode.Enum, @enumFromInt(op))) {
            // Most operations consume min_stack and push 1
            .ADD, .MUL, .SUB, .DIV, .SDIV, .MOD, .SMOD, .EXP,
            .LT, .GT, .SLT, .SGT, .EQ, .ISZERO,
            .AND, .OR, .XOR, .NOT, .BYTE, .SHL, .SHR, .SAR,
            .KECCAK256, .ADDRESS, .BALANCE, .ORIGIN, .CALLER,
            .CALLVALUE, .CALLDATASIZE, .CODESIZE, .GASPRICE,
            .EXTCODESIZE, .RETURNDATASIZE, .EXTCODEHASH,
            .BLOCKHASH, .COINBASE, .TIMESTAMP, .NUMBER,
            .PREVRANDAO, .GASLIMIT, .CHAINID, .SELFBALANCE,
            .BASEFEE, .PC, .MSIZE, .GAS => 1,
            
            // Operations that push 0 (consume inputs, no output)
            .POP, .JUMP, .JUMPI, .SSTORE, .LOG0, .LOG1, .LOG2, .LOG3, .LOG4,
            .SELFDESTRUCT, .INVALID => 0,
            
            // Operations that push 0 but stop execution
            .STOP, .RETURN, .REVERT => 0,
            
            // Special cases
            .ADDMOD, .MULMOD => 1, // Consume 3, push 1
            .CALLDATALOAD, .SLOAD, .MLOAD => 1, // Consume 1, push 1
            .MSTORE, .MSTORE8, .CALLDATACOPY, .CODECOPY,
            .EXTCODECOPY, .RETURNDATACOPY, .MCOPY => 0, // Various consumes, no output
            
            // PUSH operations
            .PUSH0 => 1,
            .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8,
            .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16,
            .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24,
            .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => 1,
            
            // DUP operations push 1
            .DUP1, .DUP2, .DUP3, .DUP4, .DUP5, .DUP6, .DUP7, .DUP8,
            .DUP9, .DUP10, .DUP11, .DUP12, .DUP13, .DUP14, .DUP15, .DUP16 => 1,
            
            // SWAP operations: no net change
            .SWAP1, .SWAP2, .SWAP3, .SWAP4, .SWAP5, .SWAP6, .SWAP7, .SWAP8,
            .SWAP9, .SWAP10, .SWAP11, .SWAP12, .SWAP13, .SWAP14, .SWAP15, .SWAP16 => 0,
            
            // JUMPDEST: no stack effect
            .JUMPDEST => 0,
            
            // CREATE operations: consume inputs, push 1 (address)
            .CREATE, .CREATE2 => 1,
            
            // CALL operations: consume 7, push 1 (success)
            .CALL, .CALLCODE, .DELEGATECALL, .STATICCALL => 1,
            
            // Unknown/future opcodes
            else => 0,
        };
        
        // First check if we have enough stack items
        const pre_stack = stack_depth;
        
        // Calculate net stack effect
        const net_effect = stack_outputs - stack_inputs;
        stack_depth += net_effect;
        
        // Track minimum stack depth reached in block
        if (pre_stack - stack_inputs < min_stack_in_block) {
            min_stack_in_block = pre_stack - stack_inputs;
        }
        
        // Track maximum stack depth in block
        if (stack_depth > max_stack_in_block) {
            max_stack_in_block = stack_depth;
        }
        
        // Track overall max stack depth
        const abs_stack_depth = @as(u16, @intCast(@max(0, stack_depth)));
        if (abs_stack_depth > analysis.max_stack_depth) {
            analysis.max_stack_depth = abs_stack_depth;
        }
        
        // Analyze memory operations
        switch (@as(opcode.Enum, @enumFromInt(op))) {
            .MLOAD => {
                // MLOAD: offset from stack, reads 32 bytes
                // Check if we can determine offset statically
                if (i > 0) {
                    const prev_pc = i - 1;
                    if (prev_pc < code.len and code[prev_pc] >= 0x60 and code[prev_pc] <= 0x7f) {
                        // Previous instruction was PUSH, we might know the offset
                        const push_size = code[prev_pc] - 0x5f;
                        if (i >= push_size + 1) {
                            var offset: u64 = 0;
                            var j: usize = 0;
                            while (j < push_size) : (j += 1) {
                                offset = (offset << 8) | code[i - push_size + j];
                            }
                            const access_size = offset + 32;
                            if (access_size > block_max_memory) {
                                block_max_memory = access_size;
                            }
                        } else {
                            block_memory_is_static = false;
                        }
                    } else {
                        block_memory_is_static = false;
                    }
                } else {
                    block_memory_is_static = false;
                }
            },
            .MSTORE, .MSTORE8 => {
                // MSTORE: offset from stack, writes 32 bytes
                // MSTORE8: offset from stack, writes 1 byte
                const write_size: u64 = if (op == @intFromEnum(opcode.Enum.MSTORE8)) 1 else 32;
                
                // Try to determine offset statically
                if (i >= 2) {
                    // Need to look back 2 instructions for the offset (value, then offset)
                    var found_offset = false;
                    var search_pc = i - 1;
                    var pushes_found: u8 = 0;
                    var static_offset: u64 = 0;
                    
                    // Search backwards for PUSH instructions
                    while (search_pc > 0 and pushes_found < 2) : (search_pc -= 1) {
                        if (code[search_pc] >= 0x60 and code[search_pc] <= 0x7f) {
                            pushes_found += 1;
                            if (pushes_found == 2) {
                                // This is the offset PUSH
                                const push_size = code[search_pc] - 0x5f;
                                if (search_pc + push_size < i) {
                                    var offset: u64 = 0;
                                    var j: usize = 1;
                                    while (j <= push_size) : (j += 1) {
                                        offset = (offset << 8) | code[search_pc + j];
                                    }
                                    static_offset = offset;
                                    found_offset = true;
                                }
                                break;
                            }
                        }
                    }
                    
                    if (found_offset) {
                        const access_size = static_offset + write_size;
                        if (access_size > block_max_memory) {
                            block_max_memory = access_size;
                        }
                    } else {
                        block_memory_is_static = false;
                    }
                } else {
                    block_memory_is_static = false;
                }
            },
            .CALLDATACOPY, .CODECOPY, .RETURNDATACOPY, .EXTCODECOPY => {
                // These copy operations use dynamic size from stack
                // We'd need complex analysis to determine if they're static
                block_memory_is_static = false;
            },
            .MCOPY => {
                // Memory-to-memory copy, dynamic offsets and size
                block_memory_is_static = false;
            },
            .MSIZE => {
                // MSIZE just reads current size, doesn't expand
            },
            else => {},
        }
        
        // Advance PC
        if (opcode.is_push(op)) {
            const push_bytes = opcode.get_push_size(op);
            var j: usize = 1;
            while (j <= push_bytes and i + j < code.len) : (j += 1) {
                analysis.pc_to_block[i + j] = current_block;
            }
            i += 1 + push_bytes;
        } else {
            i += 1;
        }
    }
    
    // Save metadata for final block
    if (current_block < block_count) {
        analysis.block_metadata[current_block] = BlockMetadata{
            .gas_cost = gas_cost,
            .stack_req = @max(0, block_stack_start + min_stack_in_block),
            .stack_max = max_stack_in_block - block_stack_start,
        };
        
        // Save memory expansion info for final block
        if (block_memory_is_static and block_max_memory > current_memory_size) {
            const new_words = (block_max_memory + 31) / 32;
            const current_words = (current_memory_size + 31) / 32;
            const new_cost = 3 * new_words + (new_words * new_words) / 512;
            const current_cost = if (current_memory_size == 0) 0 else 3 * current_words + (current_words * current_words) / 512;
            analysis.memory_expansion_info[current_block].expansion_gas_cost = new_cost - current_cost;
        }
        analysis.memory_expansion_info[current_block].max_memory_size = block_max_memory;
        analysis.memory_expansion_info[current_block].is_static = block_memory_is_static;
    }
    
    // Perform jump analysis if there are any jumps
    if (analysis.has_static_jumps or analysis.has_dynamic_jumps) {
        const jump_analysis_ptr = try allocator.create(JumpAnalysis);
        errdefer allocator.destroy(jump_analysis_ptr);
        
        jump_analysis_ptr.* = try jump_analysis.analyze_jumps(
            allocator,
            code,
            &analysis.code_segments,
            &analysis.jumpdest_bitmap,
        );
        
        analysis.jump_analysis = jump_analysis_ptr;
        
        // Update dynamic jump flag based on detailed analysis
        if (analysis.jump_analysis.?.all_jumps_static) {
            analysis.has_dynamic_jumps = false;
        }
    }
    
    return analysis;
}

test "BlockMetadata array operations" {
    const allocator = std.testing.allocator;
    
    // Test dynamic allocation and access
    const blocks = try allocator.alloc(BlockMetadata, 100);
    defer allocator.free(blocks);
    
    // Fill with test data
    for (blocks, 0..) |*block, i| {
        block.* = BlockMetadata{
            .gas_cost = @intCast(i * 100),
            .stack_req = @intCast(i),
            .stack_max = @intCast(i * 2),
        };
    }
    
    // Verify data integrity
    try std.testing.expectEqual(@as(u32, 5000), blocks[50].gas_cost);
    try std.testing.expectEqual(@as(i16, 50), blocks[50].stack_req);
    try std.testing.expectEqual(@as(i16, 100), blocks[50].stack_max);
}

test "pc_to_block mapping edge cases" {
    const allocator = std.testing.allocator;
    
    // Test large bytecode mapping
    const mapping = try allocator.alloc(u16, 24576); // Max contract size
    defer allocator.free(mapping);
    
    // Simulate block assignments
    var current_block: u16 = 0;
    for (mapping, 0..) |*pc_block, i| {
        if (i % 100 == 0) current_block += 1; // New block every 100 bytes
        pc_block.* = current_block;
    }
    
    // Test boundary conditions
    try std.testing.expectEqual(@as(u16, 1), mapping[0]);
    try std.testing.expectEqual(@as(u16, 2), mapping[100]);
    try std.testing.expectEqual(@as(u16, 246), mapping[24500]);
}

test "Memory expansion analysis detects static memory accesses" {
    const allocator = std.testing.allocator;
    
    // Test bytecode with static memory operations:
    // PUSH1 0x20 PUSH1 0x40 MSTORE  ; Store at offset 0x40
    // PUSH1 0x60 MLOAD              ; Load from offset 0x60
    const code = &[_]u8{
        0x60, 0x20, // PUSH1 0x20 (value)
        0x60, 0x40, // PUSH1 0x40 (offset)
        0x52,       // MSTORE
        0x60, 0x60, // PUSH1 0x60
        0x51,       // MLOAD
    };
    
    var analysis = try analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);
    
    // Should have 1 block
    try std.testing.expectEqual(@as(u16, 1), analysis.block_count);
    
    // Check memory expansion info
    const mem_info = analysis.memory_expansion_info[0];
    try std.testing.expect(mem_info.is_static);
    try std.testing.expectEqual(@as(u64, 0x60 + 32), mem_info.max_memory_size); // MLOAD at 0x60 + 32 bytes
    
    // Verify expansion cost is calculated
    // Memory expands from 0 to 128 bytes (4 words)
    // Cost = 3 * 4 + (4 * 4) / 512 = 12 + 0 = 12
    try std.testing.expectEqual(@as(u64, 12), mem_info.expansion_gas_cost);
}

test "Memory expansion analysis detects dynamic memory accesses" {
    const allocator = std.testing.allocator;
    
    // Test bytecode with dynamic memory operations:
    // DUP1 MLOAD  ; Load from dynamic offset (whatever is on stack)
    const code = &[_]u8{
        0x80, // DUP1
        0x51, // MLOAD
    };
    
    var analysis = try analyze_bytecode_blocks(allocator, code);
    defer analysis.deinit(allocator);
    
    // Check memory expansion info
    const mem_info = analysis.memory_expansion_info[0];
    try std.testing.expect(!mem_info.is_static); // Should be dynamic
    try std.testing.expectEqual(@as(u64, 0), mem_info.max_memory_size);
    try std.testing.expectEqual(@as(u64, 0), mem_info.expansion_gas_cost);
}

test "BlockMetadata with contract deployment scenarios" {
    const allocator = std.testing.allocator;
    
    // Simulate analysis for different contract types
    const test_cases = .{
        .{ .size = 0, .blocks = 0 },      // Empty contract
        .{ .size = 1, .blocks = 1 },      // Minimal contract (STOP)
        .{ .size = 100, .blocks = 5 },    // Small contract
        .{ .size = 24576, .blocks = 1000 }, // Max size contract
    };
    
    inline for (test_cases) |tc| {
        var analysis = CodeAnalysis{
            .code_segments = try BitVec64.init(allocator, tc.size),
            .jumpdest_bitmap = try BitVec64.init(allocator, tc.size),
            .block_starts = try BitVec64.init(allocator, tc.size),
            .block_metadata = if (tc.blocks > 0) try allocator.alloc(BlockMetadata, tc.blocks) else &[_]BlockMetadata{},
            .pc_to_block = if (tc.size > 0) try allocator.alloc(u16, tc.size) else &[_]u16{},
            .block_count = tc.blocks,
            .max_stack_depth = 0,
            .has_dynamic_jumps = false,
            .has_static_jumps = false,
            .has_selfdestruct = false,
            .has_create = false,
            .block_gas_costs = null,
            .jump_analysis = null,
            .block_start_positions = if (tc.blocks > 0) try allocator.alloc(usize, tc.blocks) else &[_]usize{},
            .memory_expansion_info = if (tc.blocks > 0) try allocator.alloc(MemoryExpansionInfo, tc.blocks) else &[_]MemoryExpansionInfo{},
        };
        defer analysis.deinit(allocator);
        
        // Verify fields are correctly set
        try std.testing.expectEqual(tc.blocks, analysis.block_count);
        try std.testing.expectEqual(tc.blocks, analysis.block_metadata.len);
        try std.testing.expectEqual(tc.size, analysis.pc_to_block.len);
    }
}
