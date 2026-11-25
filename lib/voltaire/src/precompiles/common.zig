const std = @import("std");

/// Precompile result
pub const PrecompileResult = struct {
    output: []u8,
    gas_used: u64,

    pub fn deinit(self: PrecompileResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
    }
};

/// Precompile error types
pub const PrecompileError = error{
    InvalidInput,
    InvalidSignature,
    InvalidPoint,
    InvalidPairing,
    OutOfGas,
    UnsupportedPrecompile,
    // Keccak errors (from keccak_asm)
    ExecutionError,
    StateError,
    MemoryError,
    InvalidOutputSize,
    /// POINT_EVALUATION ran before the KZG trusted setup was loaded. This is a
    /// node configuration fault, not a consensus failure of the call.
    TrustedSetupNotLoaded,
    Unknown,
} || std.mem.Allocator.Error;
