const std = @import("std");

/// FFI bindings to the Rust BN254 (arkworks) implementation
/// This provides production-grade, audited elliptic curve operations
/// for Ethereum precompiles (ECADD, ECMUL, ECPAIRING)
const c = @cImport({
    @cInclude("bn254_wrapper.h");
});

pub const BN254Error = error{
    InvalidInput,
    InvalidPoint,
    InvalidScalar,
    ComputationFailed,
};

pub const BLS12381Error = error{
    InvalidInput,
    InvalidPoint,
    InvalidScalar,
    ComputationFailed,
};

fn bn254ResultToError(result: c_int) BN254Error!void {
    return switch (result) {
        c.BN254_SUCCESS => {},
        c.BN254_INVALID_INPUT => BN254Error.InvalidInput,
        c.BN254_INVALID_POINT => BN254Error.InvalidPoint,
        c.BN254_INVALID_SCALAR => BN254Error.InvalidScalar,
        c.BN254_COMPUTATION_FAILED => BN254Error.ComputationFailed,
        else => BN254Error.ComputationFailed,
    };
}

fn bls12381ResultToError(result: c_int) BLS12381Error!void {
    return switch (result) {
        c.BLS12_381_SUCCESS => {},
        c.BLS12_381_INVALID_INPUT => BLS12381Error.InvalidInput,
        c.BLS12_381_INVALID_POINT => BLS12381Error.InvalidPoint,
        c.BLS12_381_INVALID_SCALAR => BLS12381Error.InvalidScalar,
        c.BLS12_381_COMPUTATION_FAILED => BLS12381Error.ComputationFailed,
        else => BLS12381Error.ComputationFailed,
    };
}

/// Initialize the BN254 library (idempotent)
pub fn init() BN254Error!void {
    const result = c.bn254_init();
    try bn254ResultToError(result);
}

/// Perform elliptic curve scalar multiplication (ECMUL - precompile 0x07)
/// Input: 96 bytes (x: 32 bytes, y: 32 bytes, scalar: 32 bytes)
/// Output: 64 bytes (result_x: 32 bytes, result_y: 32 bytes)
pub fn ecmul(input: []const u8, output: []u8) BN254Error!void {
    if (output.len < 64) return BN254Error.InvalidInput;

    const result = c.bn254_ecmul(
        input.ptr,
        @intCast(input.len),
        output.ptr,
        @intCast(output.len),
    );
    try bn254ResultToError(result);
}

/// Perform elliptic curve pairing check (ECPAIRING - precompile 0x08)
/// Input: multiple of 192 bytes (G1 point: 64 bytes, G2 point: 128 bytes)
/// Output: 32 bytes (0x00...00 for false, 0x00...01 for true)
pub fn ecpairing(input: []const u8, output: []u8) BN254Error!void {
    if (output.len < 32) return BN254Error.InvalidInput;

    const result = c.bn254_ecpairing(
        input.ptr,
        @intCast(input.len),
        output.ptr,
        @intCast(output.len),
    );
    try bn254ResultToError(result);
}

/// Get expected output size for ECMUL (64 bytes)
pub fn ecmulOutputSize() u32 {
    return c.bn254_ecmul_output_size();
}

/// Get expected output size for ECPAIRING (32 bytes)
pub fn ecpairingOutputSize() u32 {
    return c.bn254_ecpairing_output_size();
}

/// Validate ECMUL input format
pub fn validateEcmulInput(input: []const u8) BN254Error!void {
    const result = c.bn254_ecmul_validate_input(input.ptr, @intCast(input.len));
    try bn254ResultToError(result);
}

/// Validate ECPAIRING input format
pub fn validateEcpairingInput(input: []const u8) BN254Error!void {
    const result = c.bn254_ecpairing_validate_input(input.ptr, @intCast(input.len));
    try bn254ResultToError(result);
}

// BLS12-381 Operations (EIP-2537)

/// Perform BLS12-381 G1 addition
/// Input: 256 bytes (two G1 points with padding)
/// Output: 128 bytes (result G1 point with padding)
pub fn bls12381G1Add(input: []const u8, output: []u8) BLS12381Error!void {
    if (output.len < 128) return BLS12381Error.InvalidInput;

    const result = c.bls12_381_g1_add(
        input.ptr,
        @intCast(input.len),
        output.ptr,
        @intCast(output.len),
    );
    try bls12381ResultToError(result);
}

/// Perform BLS12-381 G1 scalar multiplication
/// Input: 160 bytes (G1 point with padding + scalar)
/// Output: 128 bytes (result G1 point with padding)
pub fn bls12381G1Mul(input: []const u8, output: []u8) BLS12381Error!void {
    if (output.len < 128) return BLS12381Error.InvalidInput;

    const result = c.bls12_381_g1_mul(
        input.ptr,
        @intCast(input.len),
        output.ptr,
        @intCast(output.len),
    );
    try bls12381ResultToError(result);
}

/// Perform BLS12-381 G1 multi-scalar multiplication
/// Input: multiple of 160 bytes (G1 points with scalars)
/// Output: 128 bytes (result G1 point with padding)
pub fn bls12381G1Multiexp(input: []const u8, output: []u8) BLS12381Error!void {
    if (output.len < 128) return BLS12381Error.InvalidInput;

    const result = c.bls12_381_g1_multiexp(
        input.ptr,
        @intCast(input.len),
        output.ptr,
        @intCast(output.len),
    );
    try bls12381ResultToError(result);
}

/// Perform BLS12-381 pairing check
/// Input: multiple of 384 bytes (G1 and G2 point pairs)
/// Output: 32 bytes (0x00...00 for false, 0x00...01 for true)
pub fn bls12381Pairing(input: []const u8, output: []u8) BLS12381Error!void {
    if (output.len < 32) return BLS12381Error.InvalidInput;

    const result = c.bls12_381_pairing(
        input.ptr,
        @intCast(input.len),
        output.ptr,
        @intCast(output.len),
    );
    try bls12381ResultToError(result);
}

/// Get expected output size for BLS12-381 G1 operations (128 bytes)
pub fn bls12381G1OutputSize() u32 {
    return c.bls12_381_g1_output_size();
}

/// Get expected output size for BLS12-381 pairing (32 bytes)
pub fn bls12381PairingOutputSize() u32 {
    return c.bls12_381_pairing_output_size();
}

test "constants are correct" {
    try std.testing.expect(ecmulOutputSize() == 64);
    try std.testing.expect(ecpairingOutputSize() == 32);
    try std.testing.expect(bls12381G1OutputSize() == 128);
    try std.testing.expect(bls12381PairingOutputSize() == 32);
}
