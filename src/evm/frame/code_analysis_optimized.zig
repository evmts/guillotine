const std = @import("std");
const BlockMetadata = @import("block_metadata.zig");
const BlockMetadataHeap = @import("block_metadata_heap.zig");

// Constants for limits
const MAX_CONTRACT_SIZE = 24576; // 24KB max contract size
const MAX_BLOCKS = 10000; // Maximum number of basic blocks

/// Optimized code analysis with heap allocation and memory management.
///
/// This version uses heap allocation for large structures and can free
/// intermediate data that's only needed during analysis, not execution.
const CodeAnalysisOptimized = @This();

/// ===== Data needed during execution =====

/// Bitmap of valid JUMPDEST positions (MUST KEEP for JUMP/JUMPI)
jumpdest_bitmap: []u8,

/// Block metadata with exact size allocation
block_metadata: BlockMetadataHeap,

/// Flags for contract properties
has_dynamic_jumps: bool,
has_static_jumps: bool,
has_selfdestruct: bool,
has_create: bool,
max_stack_depth: u16,

/// ===== Intermediate data (can be freed after analysis) =====

/// Code segments marking code vs data (freed after jumpdest_bitmap is built)
code_segments: ?[]u8,

/// Block starts bitmap (freed after block metadata is built)
block_starts: ?[]u8,

/// PC to block mapping (can be freed if embedded in instructions)
pc_to_block: ?[]u16,

/// Allocator for memory management
allocator: std.mem.Allocator,

/// Initialize with worst-case allocation for analysis phase
pub fn init(allocator: std.mem.Allocator) !CodeAnalysisOptimized {
    // Allocate worst-case for bitmaps (will be freed later)
    const bitmap_size = (MAX_CONTRACT_SIZE + 7) / 8; // bits to bytes
    
    const jumpdest_bitmap = try allocator.alloc(u8, bitmap_size);
    errdefer allocator.free(jumpdest_bitmap);
    @memset(jumpdest_bitmap, 0);
    
    const code_segments = try allocator.alloc(u8, bitmap_size);
    errdefer allocator.free(code_segments);
    @memset(code_segments, 0);
    
    const block_starts = try allocator.alloc(u8, bitmap_size);
    errdefer {
        allocator.free(jumpdest_bitmap);
        allocator.free(code_segments);
    }
    @memset(block_starts, 0);
    
    const pc_to_block = try allocator.alloc(u16, MAX_CONTRACT_SIZE);
    errdefer {
        allocator.free(jumpdest_bitmap);
        allocator.free(code_segments);
        allocator.free(block_starts);
    }
    @memset(pc_to_block, 0);
    
    // Start with dummy block metadata, will be right-sized later
    const block_metadata = try BlockMetadataHeap.init(allocator, 1);
    errdefer {
        allocator.free(jumpdest_bitmap);
        allocator.free(code_segments);
        allocator.free(block_starts);
        allocator.free(pc_to_block);
    }
    
    return CodeAnalysisOptimized{
        .jumpdest_bitmap = jumpdest_bitmap,
        .block_metadata = block_metadata,
        .has_dynamic_jumps = false,
        .has_static_jumps = false,
        .has_selfdestruct = false,
        .has_create = false,
        .max_stack_depth = 0,
        .code_segments = code_segments,
        .block_starts = block_starts,
        .pc_to_block = pc_to_block,
        .allocator = allocator,
    };
}

/// Free intermediate structures that are only needed during analysis
pub fn freeIntermediateStructures(self: *CodeAnalysisOptimized) void {
    // Free code segments (only needed to build jumpdest_bitmap)
    if (self.code_segments) |segments| {
        self.allocator.free(segments);
        self.code_segments = null;
    }
    
    // Free block starts (only needed to build block metadata)
    if (self.block_starts) |starts| {
        self.allocator.free(starts);
        self.block_starts = null;
    }
    
    // Free pc_to_block if not needed (can be embedded in instructions)
    if (self.pc_to_block) |mapping| {
        self.allocator.free(mapping);
        self.pc_to_block = null;
    }
}

/// Right-size block metadata after analysis determines actual block count
pub fn resizeBlockMetadata(self: *CodeAnalysisOptimized, actual_block_count: u16) !void {
    // Free old metadata
    self.block_metadata.deinit();
    
    // Allocate exact size needed
    self.block_metadata = try BlockMetadataHeap.init(self.allocator, actual_block_count);
}

/// Clean up all allocated memory
pub fn deinit(self: *CodeAnalysisOptimized) void {
    self.allocator.free(self.jumpdest_bitmap);
    self.block_metadata.deinit();
    
    // Free any remaining intermediate structures
    if (self.code_segments) |segments| {
        self.allocator.free(segments);
    }
    if (self.block_starts) |starts| {
        self.allocator.free(starts);
    }
    if (self.pc_to_block) |mapping| {
        self.allocator.free(mapping);
    }
}

/// Helper to check if a position is a valid jumpdest
pub fn isValidJumpdest(self: *const CodeAnalysisOptimized, pc: usize) bool {
    if (pc >= MAX_CONTRACT_SIZE) return false;
    const byte_index = pc / 8;
    const bit_index = @as(u3, @intCast(pc % 8));
    return (self.jumpdest_bitmap[byte_index] & (@as(u8, 1) << bit_index)) != 0;
}

/// Helper to set a jumpdest position
pub fn setJumpdest(self: *CodeAnalysisOptimized, pc: usize) void {
    if (pc >= MAX_CONTRACT_SIZE) return;
    const byte_index = pc / 8;
    const bit_index = @as(u3, @intCast(pc % 8));
    self.jumpdest_bitmap[byte_index] |= (@as(u8, 1) << bit_index);
}

/// Helper to check if a position is code (vs data)
pub fn isCode(self: *const CodeAnalysisOptimized, pc: usize) bool {
    const segments = self.code_segments orelse return false;
    if (pc >= MAX_CONTRACT_SIZE) return false;
    const byte_index = pc / 8;
    const bit_index = @as(u3, @intCast(pc % 8));
    return (segments[byte_index] & (@as(u8, 1) << bit_index)) != 0;
}

/// Helper to mark a position as code
pub fn setCode(self: *CodeAnalysisOptimized, pc: usize) void {
    const segments = self.code_segments orelse return;
    if (pc >= MAX_CONTRACT_SIZE) return;
    const byte_index = pc / 8;
    const bit_index = @as(u3, @intCast(pc % 8));
    segments[byte_index] |= (@as(u8, 1) << bit_index);
}

test "CodeAnalysisOptimized initialization and cleanup" {
    const allocator = std.testing.allocator;
    
    var analysis = try CodeAnalysisOptimized.init(allocator);
    defer analysis.deinit();
    
    // Verify initial state
    try std.testing.expect(analysis.code_segments != null);
    try std.testing.expect(analysis.block_starts != null);
    try std.testing.expect(analysis.pc_to_block != null);
    try std.testing.expectEqual(false, analysis.has_dynamic_jumps);
}

test "CodeAnalysisOptimized free intermediate structures" {
    const allocator = std.testing.allocator;
    
    var analysis = try CodeAnalysisOptimized.init(allocator);
    defer analysis.deinit();
    
    // Verify structures exist
    try std.testing.expect(analysis.code_segments != null);
    try std.testing.expect(analysis.block_starts != null);
    try std.testing.expect(analysis.pc_to_block != null);
    
    // Free intermediate structures
    analysis.freeIntermediateStructures();
    
    // Verify they're freed
    try std.testing.expect(analysis.code_segments == null);
    try std.testing.expect(analysis.block_starts == null);
    try std.testing.expect(analysis.pc_to_block == null);
}

test "CodeAnalysisOptimized resize block metadata" {
    const allocator = std.testing.allocator;
    
    var analysis = try CodeAnalysisOptimized.init(allocator);
    defer analysis.deinit();
    
    // Initial metadata has size 1
    try std.testing.expectEqual(@as(u16, 1), analysis.block_metadata.count);
    
    // Resize to actual count
    try analysis.resizeBlockMetadata(50);
    try std.testing.expectEqual(@as(u16, 50), analysis.block_metadata.count);
    
    // Can resize again
    try analysis.resizeBlockMetadata(100);
    try std.testing.expectEqual(@as(u16, 100), analysis.block_metadata.count);
}

test "CodeAnalysisOptimized jumpdest operations" {
    const allocator = std.testing.allocator;
    
    var analysis = try CodeAnalysisOptimized.init(allocator);
    defer analysis.deinit();
    
    // Test setting and checking jumpdests
    analysis.setJumpdest(100);
    analysis.setJumpdest(200);
    analysis.setJumpdest(300);
    
    try std.testing.expect(analysis.isValidJumpdest(100));
    try std.testing.expect(analysis.isValidJumpdest(200));
    try std.testing.expect(analysis.isValidJumpdest(300));
    try std.testing.expect(!analysis.isValidJumpdest(150));
    try std.testing.expect(!analysis.isValidJumpdest(0));
}

test "CodeAnalysisOptimized code segment operations" {
    const allocator = std.testing.allocator;
    
    var analysis = try CodeAnalysisOptimized.init(allocator);
    defer analysis.deinit();
    
    // Mark some positions as code
    analysis.setCode(0);
    analysis.setCode(1);
    analysis.setCode(2);
    analysis.setCode(100);
    
    try std.testing.expect(analysis.isCode(0));
    try std.testing.expect(analysis.isCode(1));
    try std.testing.expect(analysis.isCode(2));
    try std.testing.expect(analysis.isCode(100));
    try std.testing.expect(!analysis.isCode(3));
    try std.testing.expect(!analysis.isCode(99));
    
    // After freeing intermediate structures, isCode should return false
    analysis.freeIntermediateStructures();
    try std.testing.expect(!analysis.isCode(0));
}