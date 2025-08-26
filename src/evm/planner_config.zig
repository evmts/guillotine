/// Planner configuration for bytecode analysis and optimization strategies
/// 
/// Configures the bytecode planner behavior including:
/// - Platform-specific optimizations (32-bit vs 64-bit)
/// - Optimization level (minimal, advanced, debug)
/// - Instruction fusion and inlining strategies
/// - Memory usage vs performance trade-offs
/// 
/// Different configurations enable varying levels of bytecode optimization,
/// from minimal analysis for size-constrained environments to aggressive
/// optimization for high-performance execution.
const std = @import("std");

/// Compile-time configuration for the planner.
pub const PlannerConfig = struct {
    const Self = @This();

    /// EVM word type (mirrors runtime WordType).
    WordType: type = u256,
    /// Maximum allowed bytecode size used to pick PcType.
    maxBytecodeSize: u32 = 24_576,
    /// Optional: future cache control (no cache is implemented yet).
    enableLruCache: bool = true,
    /// Vector length for SIMD (number of u8 lanes); defaults to target suggestion.
    /// When null, scalar path is used.
    vector_length: ?comptime_int = std.simd.suggestVectorLength(u8),
    /// Match stack sizing philosophy with stack.zig / FrameConfig.
    stack_size: u12 = 1024,
    /// Compile-time toggle: inject generic trace handlers around opcodes.
    inject_tracing: bool = false,

    /// PcType: chosen program-counter type (u16 or u32) from maxBytecodeSize.
    pub fn PcType(comptime self: Self) type {
        return if (self.maxBytecodeSize <= std.math.maxInt(u16)) u16 else u32;
    }
    /// StackIndexType: unsigned stack index type (u4/u8/u12) from stack_size.
    pub fn StackIndexType(comptime self: Self) type {
        return if (self.stack_size <= std.math.maxInt(u4))
            u4
        else if (self.stack_size <= std.math.maxInt(u8))
            u8
        else if (self.stack_size <= std.math.maxInt(u12))
            u12
        else
            @compileError("PlannerConfig stack_size is too large to model compactly");
    }
    /// StackHeightType: signed stack height type (one extra bit for deltas).
    pub fn StackHeightType(comptime self: Self) type {
        const IndexT = self.StackIndexType();
        return std.meta.Int(.signed, @bitSizeOf(IndexT) + 1);
    }
    pub fn validate(comptime self: Self) void {
        if (self.stack_size > 4095) @compileError("stack_size cannot exceed 4095");
        if (@bitSizeOf(self.WordType) > 512) @compileError("WordType cannot exceed u512");
        if (self.maxBytecodeSize > 65535) @compileError("maxBytecodeSize must be <= 65535");
    }
};
