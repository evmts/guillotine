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
    
    // NEW: Free block-related allocations
    if (self.block_metadata.len > 0) {
        allocator.free(self.block_metadata);
    }
    if (self.pc_to_block.len > 0) {
        allocator.free(self.pc_to_block);
    }
    self.block_starts.deinit(allocator);
    
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
    };
    defer analysis.deinit(allocator);
    
    // Verify fields are accessible
    try std.testing.expectEqual(@as(u16, 10), analysis.block_count);
    try std.testing.expectEqual(@as(usize, 10), analysis.block_metadata.len);
    try std.testing.expectEqual(@as(usize, 100), analysis.pc_to_block.len);
    
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
    };
    
    // Should not crash on deinit
    analysis.deinit(allocator);
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
        };
        defer analysis.deinit(allocator);
        
        // Verify fields are correctly set
        try std.testing.expectEqual(tc.blocks, analysis.block_count);
        try std.testing.expectEqual(tc.blocks, analysis.block_metadata.len);
        try std.testing.expectEqual(tc.size, analysis.pc_to_block.len);
    }
}
