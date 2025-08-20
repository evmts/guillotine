//! Compatibility wrapper for the new SimpleAnalysis system
//! This file provides backward compatibility for code that imports the old CodeAnalysis
//! while redirecting to the new SimpleAnalysis from analysis2.zig

const std = @import("std");
const SimpleAnalysis = @import("evm/analysis2.zig").SimpleAnalysis;
// InstructionMetadata no longer exists - using bucketed system now
const InstructionMetadata = struct { _unused: u64 = 0 };

/// Compatibility wrapper that provides the old CodeAnalysis interface
pub const CodeAnalysis = struct {
    analysis: SimpleAnalysis,
    metadata: []InstructionMetadata,
    block_gas_costs: []u64,
    allocator: std.mem.Allocator,
    code: []const u8, // Compatibility field for old interface
    code_len: usize, // Compatibility field for old interface
    instructions: []const u8, // Compatibility field - maps to bytecode for now
    size2_instructions: []const u8, // Compatibility field for instruction slices
    size8_instructions: []const u8, // Compatibility field for instruction slices
    size16_instructions: []const u8, // Compatibility field for instruction slices
    size0_counts: @import("size_buckets.zig").Size0Counts, // Compatibility field
    size2_counts: @import("size_buckets.zig").Size2Counts, // Compatibility field
    size8_counts: @import("size_buckets.zig").Size8Counts, // Compatibility field
    size16_counts: @import("size_buckets.zig").Size16Counts, // Compatibility field
    pc_to_block_start: []const u8, // Compatibility field for PC to block start mapping
    jumpdest_array: @import("size_buckets.zig").JumpdestArray, // Compatibility field for jump destination array
    inst_jump_type: []const u8, // Compatibility field for instruction jump types
    inst_to_pc: []const u8, // Compatibility field for instruction to PC mapping

    /// Create analysis from bytecode (old interface compatibility)
    pub fn from_code(allocator: std.mem.Allocator, code: []const u8, _jump_table: anytype) !CodeAnalysis {
        _ = _jump_table; // Unused in new system

        const result = try SimpleAnalysis.analyze(allocator, code);

        // Create empty metadata array for compatibility
        const metadata = try allocator.alloc(InstructionMetadata, result.analysis.inst_count);
        @memset(metadata, InstructionMetadata{});

        return CodeAnalysis{
            .analysis = result.analysis,
            .metadata = metadata,
            .block_gas_costs = result.block_gas_costs,
            .allocator = allocator,
            .code = code,
            .code_len = code.len,
            .instructions = code,
            .size2_instructions = &.{},
            .size8_instructions = &.{},
            .size16_instructions = &.{},
            .size0_counts = std.mem.zeroes(@import("size_buckets.zig").Size0Counts),
            .size2_counts = std.mem.zeroes(@import("size_buckets.zig").Size2Counts),
            .size8_counts = std.mem.zeroes(@import("size_buckets.zig").Size8Counts),
            .size16_counts = std.mem.zeroes(@import("size_buckets.zig").Size16Counts),
            .pc_to_block_start = &.{},
            .jumpdest_array = @import("size_buckets.zig").JumpdestArray.init(),
            .inst_jump_type = &.{},
            .inst_to_pc = &.{},
        };
    }

    /// Cleanup function for compatibility
    pub fn deinit(self: *CodeAnalysis) void {
        self.analysis.deinit(self.allocator);
        self.allocator.free(self.metadata);
        self.allocator.free(self.block_gas_costs);
    }

    /// Forward other methods to the inner analysis
    pub fn getPc(self: *const CodeAnalysis, inst_idx: u16) u16 {
        return self.analysis.getPc(inst_idx);
    }

    pub fn getInstIdx(self: *const CodeAnalysis, pc: u16) u16 {
        return self.analysis.getInstIdx(pc);
    }
};
