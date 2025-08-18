//! Compatibility wrapper for the new SimpleAnalysis system
//! This file provides backward compatibility for code that imports the old CodeAnalysis
//! while redirecting to the new SimpleAnalysis from analysis2.zig

const std = @import("std");
const SimpleAnalysis = @import("evm/analysis2.zig").SimpleAnalysis;

/// Compatibility wrapper that provides the old CodeAnalysis interface
pub const CodeAnalysis = struct {
    analysis: SimpleAnalysis,
    metadata: []u32,
    allocator: std.mem.Allocator,
    code: []const u8, // Compatibility field for old interface
    code_len: usize, // Compatibility field for old interface
    instructions: []const u8, // Compatibility field - maps to bytecode for now
    size2_instructions: usize, // Compatibility field for instruction count

    /// Create analysis from bytecode (old interface compatibility)
    pub fn from_code(allocator: std.mem.Allocator, code: []const u8, _jump_table: anytype) !CodeAnalysis {
        _ = _jump_table; // Unused in new system
        const result = try SimpleAnalysis.analyze(allocator, code);
        return CodeAnalysis{
            .analysis = result.analysis,
            .metadata = result.metadata,
            .allocator = allocator,
            .code = code,
            .code_len = code.len,
            .instructions = code, // Map to bytecode for compatibility
            .size2_instructions = result.analysis.inst_count,
        };
    }

    /// Cleanup (old interface compatibility)
    pub fn deinit(self: *CodeAnalysis) void {
        self.analysis.deinit(self.allocator);
        self.allocator.free(self.metadata);
    }

    /// Forward other methods to the inner analysis
    pub fn getPc(self: *const CodeAnalysis, inst_idx: u16) u16 {
        return self.analysis.getPc(inst_idx);
    }

    pub fn getInstIdx(self: *const CodeAnalysis, pc: u16) u16 {
        return self.analysis.getInstIdx(pc);
    }

};