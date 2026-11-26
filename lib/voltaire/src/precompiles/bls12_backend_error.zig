//! Maps a BLS12-381 backend error to the error its precompile reports.
const std = @import("std");
const crypto = @import("crypto");
const PrecompileError = @import("common.zig").PrecompileError;

/// The precompile error for backend error `err`. `rejected` is what the
/// precompile reports for an input the backend refused.
///
/// `ComputationFailed` (FFI code 4) is not a verdict on the input: the backend
/// caught a panic or could not allocate. It maps to `ExecutionError`, which no
/// precompile uses for a rejected input, so the EVM can tell a failed host from
/// an invalid point and abort the transaction instead of failing the call.
pub fn precompileError(err: crypto.Crypto.bls12_381.Error, comptime rejected: PrecompileError) PrecompileError {
    return switch (err) {
        error.ComputationFailed => error.ExecutionError,
        error.InvalidInput, error.InvalidPoint, error.InvalidScalar => rejected,
    };
}

test "a backend failure is not reported as a rejected input" {
    try std.testing.expectEqual(@as(PrecompileError, error.ExecutionError), precompileError(error.ComputationFailed, error.InvalidPoint));
    try std.testing.expectEqual(@as(PrecompileError, error.ExecutionError), precompileError(error.ComputationFailed, error.InvalidPairing));
}

test "a rejected input keeps the precompile's own error" {
    const Error = crypto.Crypto.bls12_381.Error;
    for ([_]Error{ error.InvalidInput, error.InvalidPoint, error.InvalidScalar }) |err| {
        try std.testing.expectEqual(@as(PrecompileError, error.InvalidPoint), precompileError(err, error.InvalidPoint));
        try std.testing.expectEqual(@as(PrecompileError, error.InvalidPairing), precompileError(err, error.InvalidPairing));
    }
}
