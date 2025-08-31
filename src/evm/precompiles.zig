/// Ethereum precompiled contracts implementation
///
/// Precompiles are special contracts with addresses 0x01-0x0A (and beyond) that provide
/// cryptographic functions and other utilities natively implemented for efficiency:
/// - 0x01: ecRecover - ECDSA signature recovery
/// - 0x02: sha256 - SHA-256 hash function
/// - 0x03: ripemd160 - RIPEMD-160 hash function
/// - 0x04: identity - data copy function
/// - 0x05: modexp - modular exponentiation
/// - 0x06: ecAdd - BN254 elliptic curve addition
/// - 0x07: ecMul - BN254 elliptic curve multiplication
/// - 0x08: ecPairing - BN254 pairing check
/// - 0x09: blake2f - BLAKE2F compression function
/// - 0x0A: pointEvaluation - KZG point evaluation (EIP-4844)
///
/// These contracts have deterministic gas costs and behavior across all EVM implementations.
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
// Use the real crypto and build_options modules
const crypto = @import("crypto");
const build_options = @import("build_options");

/// Precompile addresses (Ethereum mainnet)
pub const ECRECOVER_ADDRESS = primitives.Address.from_u256(1);
pub const SHA256_ADDRESS = primitives.Address.from_u256(2);
pub const RIPEMD160_ADDRESS = primitives.Address.from_u256(3);
pub const IDENTITY_ADDRESS = primitives.Address.from_u256(4);
pub const MODEXP_ADDRESS = primitives.Address.from_u256(5);
pub const ECADD_ADDRESS = primitives.Address.from_u256(6);
pub const ECMUL_ADDRESS = primitives.Address.from_u256(7);
pub const ECPAIRING_ADDRESS = primitives.Address.from_u256(8);
pub const BLAKE2F_ADDRESS = primitives.Address.from_u256(9);
pub const POINT_EVALUATION_ADDRESS = primitives.Address.from_u256(10);

/// BLS12-381 precompile addresses (EIP-2537)
pub const BLS12_381_G1_ADD_ADDRESS = primitives.Address.from_u256(0x0B);
pub const BLS12_381_G1_MUL_ADDRESS = primitives.Address.from_u256(0x0C);
pub const BLS12_381_G1_MULTIEXP_ADDRESS = primitives.Address.from_u256(0x0D);
pub const BLS12_381_G2_ADD_ADDRESS = primitives.Address.from_u256(0x0E);
pub const BLS12_381_G2_MUL_ADDRESS = primitives.Address.from_u256(0x0F);
pub const BLS12_381_G2_MULTIEXP_ADDRESS = primitives.Address.from_u256(0x10);
pub const BLS12_381_PAIRING_ADDRESS = primitives.Address.from_u256(0x11);
pub const BLS12_381_MAP_FP_TO_G1_ADDRESS = primitives.Address.from_u256(0x12);

/// Precompile error types
pub const PrecompileError = error{
    InvalidInput,
    OutOfGas,
    ExecutionError,
    OutOfMemory,
    NoSpaceLeft,
    DivisionByZero,
    AllocationFailed,
    NotImplemented,
    InvalidBase,
    InvalidCharacter,
    InvalidLength,
};

/// Precompile output result
pub const PrecompileOutput = struct {
    /// Output data from the precompile
    output: []const u8,
    /// Gas consumed by the precompile
    gas_used: u64,
    /// Whether the precompile succeeded
    success: bool,
};

/// Check if an address is a precompile
pub fn is_precompile(address: Address) bool {
    // Check if the address is one of the known precompile addresses
    // Precompiles are at addresses:
    // 0x01-0x0A: Standard precompiles (ECRECOVER through POINT_EVALUATION)
    // 0x0B-0x12: BLS12-381 precompiles (EIP-2537)
    
    // Check if all bytes except the last one are zero
    for (address.bytes[0..19]) |byte| {
        if (byte != 0) return false;
    }
    // Check if the last byte is between 1 and 18 (0x12)
    return address.bytes[19] >= 1 and address.bytes[19] <= 0x12;
}

/// Execute a precompile based on its address
/// Not safe to call without checking is_precompile first
pub fn execute_precompile(
    allocator: std.mem.Allocator,
    address: Address,
    input: []const u8,
    gas_limit: u64,
) PrecompileError!PrecompileOutput {
    // TODO this should be removed and this method considered unsafe in ReleaseFast
    if (!is_precompile(address)) return PrecompileOutput{
        .output = &.{},
        .gas_used = 0,
        .success = false,
    };
    std.debug.assert(is_precompile(address));
    const precompile_id = address.bytes[19];
    return switch (precompile_id) {
        1 => execute_ecrecover(allocator, input, gas_limit),
        2 => execute_sha256(allocator, input, gas_limit),
        3 => execute_ripemd160(allocator, input, gas_limit),
        4 => execute_identity(allocator, input, gas_limit),
        5 => execute_modexp(allocator, input, gas_limit),
        6 => execute_ecadd(allocator, input, gas_limit),
        7 => execute_ecmul(allocator, input, gas_limit),
        8 => execute_ecpairing(allocator, input, gas_limit),
        9 => execute_blake2f(allocator, input, gas_limit),
        10 => execute_point_evaluation(allocator, input, gas_limit),
        0x0B => execute_bls12_381_g1_add(allocator, input, gas_limit),
        0x0C => execute_bls12_381_g1_mul(allocator, input, gas_limit),
        0x0D => execute_bls12_381_g1_multiexp(allocator, input, gas_limit),
        0x0E => execute_bls12_381_g2_add(allocator, input, gas_limit),
        0x0F => execute_bls12_381_g2_mul(allocator, input, gas_limit),
        0x10 => execute_bls12_381_g2_multiexp(allocator, input, gas_limit),
        0x11 => execute_bls12_381_pairing(allocator, input, gas_limit),
        0x12 => execute_bls12_381_map_fp_to_g1(allocator, input, gas_limit),
        else => PrecompileOutput{
            .output = &.{},
            .gas_used = 0,
            .success = false,
        },
    };
}

/// Gas costs for precompiles (in gas units)
pub const GasCosts = struct {
    pub const ECRECOVER = 3000;
    pub const SHA256_BASE = 60;
    pub const SHA256_PER_WORD = 12;
    pub const RIPEMD160_BASE = 600;
    pub const RIPEMD160_PER_WORD = 120;
    pub const IDENTITY_BASE = 15;
    pub const IDENTITY_PER_WORD = 3;
    pub const MODEXP_MIN = 200;
    pub const ECADD = 150;
    pub const ECMUL = 6000;
    pub const ECPAIRING_BASE = 45000;
    pub const ECPAIRING_PER_PAIR = 34000;
    pub const BLAKE2F_PER_ROUND = 1;
    pub const POINT_EVALUATION = 50000;
    
    // BLS12-381 gas costs (EIP-2537)
    pub const BLS12_381_G1_ADD = 500;
    pub const BLS12_381_G1_MUL = 12000;
    pub const BLS12_381_G1_MULTIEXP_BASE = 12000;
    pub const BLS12_381_G2_ADD = 800;
    pub const BLS12_381_G2_MUL = 45000;
    pub const BLS12_381_G2_MULTIEXP_BASE = 55000;
    pub const BLS12_381_PAIRING_BASE = 65000;
    pub const BLS12_381_PAIRING_PER_PAIR = 43000;
    pub const BLS12_381_MAP_FP_TO_G1 = 5500;
};

/// 0x01: ecRecover - ECDSA signature recovery
/// Recovers the public key from ECDSA signature and message hash
/// Input: 32 bytes hash + 32 bytes v + 32 bytes r + 32 bytes s (128 bytes total)
/// Output: 32 bytes (20-byte address + 12 zero bytes padding)
pub fn execute_ecrecover(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) PrecompileError!PrecompileOutput {
    const required_gas = GasCosts.ECRECOVER;
    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    var padded_input: [128]u8 = [_]u8{0} ** 128;
    const copy_len = @min(input.len, 128);
    @memcpy(padded_input[0..copy_len], input[0..copy_len]);

    // Parse input: hash(32) + v(32) + r(32) + s(32)
    const hash = padded_input[0..32];
    const v_bytes = padded_input[32..64];
    const r_bytes = padded_input[64..96];
    const s_bytes = padded_input[96..128];

    // Parse v - must be 27 or 28
    var v: u8 = 0;
    for (v_bytes) |byte| {
        if (byte != 0) {
            if (v != 0) {
                // Multiple non-zero bytes in v, invalid
                const empty_output = try allocator.alloc(u8, 32);
                @memset(empty_output, 0);
                return PrecompileOutput{
                    .output = empty_output,
                    .gas_used = required_gas,
                    .success = true,
                };
            }
            v = byte;
        }
    }

    if (v != 27 and v != 28) {
        const empty_output = try allocator.alloc(u8, 32);
        @memset(empty_output, 0);
        return PrecompileOutput{
            .output = empty_output,
            .gas_used = required_gas,
            .success = true,
        };
    }

    // Parse r and s as u256
    const r = bytesToU256(r_bytes);
    const s = bytesToU256(s_bytes);

    // Convert v to recovery_id (0 or 1)
    const recovery_id = v - 27;

    // Use the actual secp256k1 implementation from crypto module
    const address = crypto.secp256k1.unaudited_recover_address(hash, recovery_id, r, s) catch {
        // Return zero address on recovery failure
        const empty_output = try allocator.alloc(u8, 32);
        @memset(empty_output, 0);
        return PrecompileOutput{
            .output = empty_output,
            .gas_used = required_gas,
            .success = true,
        };
    };

    // Format output: 20-byte address + 12 zero bytes padding
    const output = try allocator.alloc(u8, 32);
    @memset(output, 0);
    @memcpy(output[12..32], &address.bytes);

    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

/// 0x02: sha256 - SHA-256 hash function
/// Input: arbitrary bytes
/// Output: 32-byte SHA-256 hash
pub fn execute_sha256(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) PrecompileError!PrecompileOutput {
    const word_count = (input.len + 31) / 32;
    const required_gas = GasCosts.SHA256_BASE + word_count * GasCosts.SHA256_PER_WORD;

    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    // Compute SHA-256 hash
    const output = try allocator.alloc(u8, 32);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &hash, .{});
    @memcpy(output, &hash);

    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

/// 0x03: ripemd160 - RIPEMD-160 hash function
/// Input: arbitrary bytes
/// Output: 32-byte result (20-byte RIPEMD-160 hash + 12 zero bytes padding)
pub fn execute_ripemd160(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) PrecompileError!PrecompileOutput {
    const word_count = (input.len + 31) / 32;
    const required_gas = GasCosts.RIPEMD160_BASE + word_count * GasCosts.RIPEMD160_PER_WORD;

    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    const output = try allocator.alloc(u8, 32);
    @memset(output, 0);

    // Use the actual RIPEMD160 implementation from crypto module
    var hasher = crypto.Ripemd160.RIPEMD160.init();
    hasher.update(input);
    const hash = hasher.final();

    // Copy the 20-byte hash to the output with 12 bytes of padding at the front
    @memcpy(output[12..32], &hash);

    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

/// 0x04: identity - Data copy function
/// Input: arbitrary bytes
/// Output: exact copy of input
pub fn execute_identity(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) PrecompileError!PrecompileOutput {
    const word_count = (input.len + 31) / 32;
    const required_gas = GasCosts.IDENTITY_BASE + word_count * GasCosts.IDENTITY_PER_WORD;

    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    const output = try allocator.dupe(u8, input);
    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

/// 0x05: modexp - Modular exponentiation
/// Input: base_len(32) + exp_len(32) + mod_len(32) + base + exp + mod
/// Output: result of (base^exp) % mod
pub fn execute_modexp(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) PrecompileError!PrecompileOutput {
    if (input.len < 96) {
        const empty_output = try allocator.alloc(u8, 0);
        return PrecompileOutput{
            .output = empty_output,
            .gas_used = GasCosts.MODEXP_MIN,
            .success = true,
        };
    }

    // Parse lengths
    const base_len = bytesToU32(input[0..32]);
    const exp_len = bytesToU32(input[32..64]);
    const mod_len = bytesToU32(input[64..96]);

    // Validate input length
    const expected_len = 96 + base_len + exp_len + mod_len;
    if (input.len < expected_len) {
        const empty_output = try allocator.alloc(u8, 0);
        return PrecompileOutput{
            .output = empty_output,
            .gas_used = GasCosts.MODEXP_MIN,
            .success = true,
        };
    }

    // Extract base, exp, mod
    var offset: usize = 96;
    const base = input[offset .. offset + base_len];
    offset += base_len;
    const exp = input[offset .. offset + exp_len];
    offset += exp_len;
    const mod = input[offset .. offset + mod_len];

    // Handle special cases
    if (mod_len == 0) {
        const empty_output = try allocator.alloc(u8, 0);
        return PrecompileOutput{
            .output = empty_output,
            .gas_used = GasCosts.MODEXP_MIN,
            .success = true,
        };
    }

    // Calculate gas cost (simplified version)
    const max_len = @max(@max(base_len, exp_len), mod_len);
    const complexity = (max_len * max_len) / 64;
    const required_gas = @max(GasCosts.MODEXP_MIN, complexity);

    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    // Perform modular exponentiation
    const output = try allocator.alloc(u8, mod_len);

    // Use the actual modexp implementation from crypto module
    crypto.ModExp.unaudited_modexp(allocator, base, exp, mod, output) catch {
        // On error, return zeros (following EVM spec)
        @memset(output, 0);
        return PrecompileOutput{
            .output = output,
            .gas_used = required_gas,
            .success = true,
        };
    };

    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

/// 0x06: ecAdd - BN254 elliptic curve addition
/// Input: 128 bytes (x1, y1, x2, y2 as 32-byte big-endian)
/// Output: 64 bytes (x, y coordinates of sum)
pub fn execute_ecadd(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) PrecompileError!PrecompileOutput {
    const required_gas = GasCosts.ECADD;
    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    // Pad input to 128 bytes
    var padded_input: [128]u8 = [_]u8{0} ** 128;
    const copy_len = @min(input.len, 128);
    @memcpy(padded_input[0..copy_len], input[0..copy_len]);

    if (build_options.no_bn254) {
        // BN254 operations disabled - return error
        const output = try allocator.alloc(u8, 64);
        @memset(output, 0);
        return PrecompileOutput{
            .output = output,
            .gas_used = required_gas,
            .success = false,
        };
    }

    // Parse points
    const x1 = bytesToU256(padded_input[0..32]);
    const y1 = bytesToU256(padded_input[32..64]);
    const x2 = bytesToU256(padded_input[64..96]);
    const y2 = bytesToU256(padded_input[96..128]);

    const output = try allocator.alloc(u8, 64);

    // Handle identity shortcuts per EVM spec behavior expectations in tests:
    // If one operand is the point at infinity (encoded as all zeros), return the other point.
    if (x2 == 0 and y2 == 0) {
        u256ToBytes(x1, output[0..32]);
        u256ToBytes(y1, output[32..64]);
        return PrecompileOutput{ .output = output, .gas_used = required_gas, .success = true };
    }
    if (x1 == 0 and y1 == 0) {
        u256ToBytes(x2, output[0..32]);
        u256ToBytes(y2, output[32..64]);
        return PrecompileOutput{ .output = output, .gas_used = required_gas, .success = true };
    }

    // Use the actual BN254 implementation from crypto module
    const g1_x1 = crypto.bn254.FpMont.init(x1);
    const g1_y1 = crypto.bn254.FpMont.init(y1);
    const g1_x2 = crypto.bn254.FpMont.init(x2);
    const g1_y2 = crypto.bn254.FpMont.init(y2);

    // Create G1 points
    const point1 = crypto.bn254.G1{ .x = g1_x1, .y = g1_y1, .z = crypto.bn254.FpMont.ONE };
    const point2 = crypto.bn254.G1{ .x = g1_x2, .y = g1_y2, .z = crypto.bn254.FpMont.ONE };

    // Check if points are on curve
    if (!point1.isOnCurve() or !point2.isOnCurve()) {
        @memset(output, 0);
        return PrecompileOutput{
            .output = output,
            .gas_used = required_gas,
            .success = true,
        };
    }

    // Perform addition
    const result = point1.add(&point2);

    // Convert back to affine coordinates and bytes
    const result_affine = result.toAffine();
    const result_x = result_affine.x.toStandardRepresentation();
    const result_y = result_affine.y.toStandardRepresentation();

    u256ToBytes(result_x, output[0..32]);
    u256ToBytes(result_y, output[32..64]);

    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

/// 0x07: ecMul - BN254 elliptic curve multiplication
/// Input: 96 bytes (x, y, scalar as 32-byte big-endian)
/// Output: 64 bytes (x, y coordinates of product)
pub fn execute_ecmul(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) PrecompileError!PrecompileOutput {
    const required_gas = GasCosts.ECMUL;
    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    // Pad input to 96 bytes
    var padded_input: [96]u8 = [_]u8{0} ** 96;
    const copy_len = @min(input.len, 96);
    @memcpy(padded_input[0..copy_len], input[0..copy_len]);

    if (build_options.no_bn254) {
        // BN254 operations disabled - return error
        const output = try allocator.alloc(u8, 64);
        @memset(output, 0);
        return PrecompileOutput{
            .output = output,
            .gas_used = required_gas,
            .success = false,
        };
    }

    // Parse point and scalar
    const x = bytesToU256(padded_input[0..32]);
    const y = bytesToU256(padded_input[32..64]);
    const scalar = bytesToU256(padded_input[64..96]);

    const output = try allocator.alloc(u8, 64);

    // Handle scalar or point identity edge cases explicitly
    if (scalar == 0 or (x == 0 and y == 0)) {
        @memset(output, 0);
        return PrecompileOutput{ .output = output, .gas_used = required_gas, .success = true };
    }

    // Use the actual BN254 implementation from crypto module
    const g1_x = crypto.bn254.FpMont.init(x);
    const g1_y = crypto.bn254.FpMont.init(y);

    // Create G1 point
    const point = crypto.bn254.G1{ .x = g1_x, .y = g1_y, .z = crypto.bn254.FpMont.ONE };

    // Check if point is on curve
    if (!point.isOnCurve()) {
        @memset(output, 0);
        return PrecompileOutput{
            .output = output,
            .gas_used = required_gas,
            .success = true,
        };
    }

    // Perform scalar multiplication
    const result = point.mul_by_int(scalar);

    // Convert back to affine coordinates and bytes
    const result_affine = result.toAffine();
    const result_x = result_affine.x.toStandardRepresentation();
    const result_y = result_affine.y.toStandardRepresentation();

    u256ToBytes(result_x, output[0..32]);
    u256ToBytes(result_y, output[32..64]);

    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

/// 0x08: ecPairing - BN254 pairing check
/// Input: pairs of G1 and G2 points (192 bytes per pair)
/// Output: 32 bytes (1 if pairing is valid, 0 otherwise)
pub fn execute_ecpairing(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) PrecompileError!PrecompileOutput {
    if (input.len % 192 != 0) {
        const output = try allocator.alloc(u8, 32);
        @memset(output, 0);
        return PrecompileOutput{
            .output = output,
            .gas_used = GasCosts.ECPAIRING_BASE,
            .success = true,
        };
    }

    const pair_count = input.len / 192;
    const required_gas = GasCosts.ECPAIRING_BASE + pair_count * GasCosts.ECPAIRING_PER_PAIR;

    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    if (build_options.no_bn254) {
        // BN254 operations disabled - return error
        const output = try allocator.alloc(u8, 32);
        @memset(output, 0);
        return PrecompileOutput{
            .output = output,
            .gas_used = required_gas,
            .success = false,
        };
    }

    const output = try allocator.alloc(u8, 32);
    @memset(output, 0);

    if (pair_count == 0) {
        // Empty input means pairing is valid
        output[31] = 1;
        return PrecompileOutput{
            .output = output,
            .gas_used = required_gas,
            .success = true,
        };
    }

    // Declare the external C function from bn254_wrapper
    const c = struct {
        extern fn bn254_ecpairing(
            input: [*]const u8,
            input_len: c_uint,
            output: [*]u8,
            output_len: c_uint,
        ) callconv(.c) c_int;

        const BN254_SUCCESS = 0;
    };

    // Call the Rust BN254 implementation
    const result = c.bn254_ecpairing(input.ptr, @intCast(input.len), output.ptr, @intCast(output.len));

    if (result != c.BN254_SUCCESS) {
        // Invalid input or computation failed
        @memset(output, 0);
        return PrecompileOutput{
            .output = output,
            .gas_used = required_gas,
            .success = false,
        };
    }

    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

/// 0x09: blake2f - BLAKE2F compression function
/// Input: rounds(4) + h(64) + m(128) + t(16) + f(1) = 213 bytes
/// Output: 64 bytes (BLAKE2b state)
pub fn execute_blake2f(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) PrecompileError!PrecompileOutput {
    if (input.len != 213) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = 0,
            .success = false,
        };
    }

    // Parse rounds from first 4 bytes (big-endian)
    const rounds = (@as(u32, input[0]) << 24) |
        (@as(u32, input[1]) << 16) |
        (@as(u32, input[2]) << 8) |
        @as(u32, input[3]);

    const required_gas = rounds * GasCosts.BLAKE2F_PER_ROUND;
    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    // Validate final block indicator (must be 0 or 1)
    const f = input[212];
    if (f != 0 and f != 1) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = 0,
            .success = false,
        };
    }

    const output = try allocator.alloc(u8, 64);

    // Parse input components
    const h_bytes = input[4..68]; // 64 bytes state (8 x u64)
    const m_bytes = input[68..196]; // 128 bytes message (16 x u64)
    const t_bytes = input[196..212]; // 16 bytes counter (2 x u64)

    // Convert bytes to u64 arrays (little-endian as per spec)
    var h: [8]u64 = undefined;
    var m: [16]u64 = undefined;
    var t: [2]u64 = undefined;

    for (0..8) |i| {
        h[i] = std.mem.readInt(u64, h_bytes[i * 8 ..][0..8], .little);
    }
    for (0..16) |i| {
        m[i] = std.mem.readInt(u64, m_bytes[i * 8 ..][0..8], .little);
    }
    t[0] = std.mem.readInt(u64, t_bytes[0..8], .little);
    t[1] = std.mem.readInt(u64, t_bytes[8..16], .little);

    // Use the actual blake2f implementation from crypto module
    crypto.Blake2.unaudited_blake2f_compress(&h, &m, t, f != 0, rounds);

    // Convert result back to bytes (little-endian)
    for (0..8) |i| {
        std.mem.writeInt(u64, output[i * 8 ..][0..8], h[i], .little);
    }

    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

/// 0x0A: pointEvaluation - KZG point evaluation (EIP-4844)
/// Input: 192 bytes (versioned_hash + z + y + commitment + proof)
/// Output: 64 bytes (FIELD_ELEMENTS_PER_BLOB + BLS_MODULUS)
pub fn execute_point_evaluation(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) PrecompileError!PrecompileOutput {
    const required_gas = GasCosts.POINT_EVALUATION;
    if (gas_limit < required_gas) {
        return PrecompileOutput{ .output = &.{}, .gas_used = gas_limit, .success = false };
    }

    if (input.len != 192) {
        return PrecompileOutput{ .output = &.{}, .gas_used = required_gas, .success = false };
    }

    // Parse input: versioned_hash(32) + z(32) + y(32) + commitment(48) + proof(48)
    const versioned_hash = input[0..32];
    const z_bytes = input[32..64];
    const y_bytes = input[64..96];
    const commitment_bytes = input[96..144];
    const proof_bytes = input[144..192];

    // Validate versioned hash and that it corresponds to the commitment
    const primitives_mod = primitives; // alias
    const Blob = primitives_mod.Blob;
    if (versioned_hash[0] != Blob.BLOB_COMMITMENT_VERSION_KZG) {
        return PrecompileOutput{ .output = &.{}, .gas_used = required_gas, .success = false };
    }
    var commitment_arr: Blob.BlobCommitment = undefined;
    @memcpy(commitment_arr[0..], commitment_bytes);
    const expected_vh = Blob.commitment_to_versioned_hash(commitment_arr);
    if (!std.mem.eql(u8, expected_vh.bytes[0..], versioned_hash)) {
        return PrecompileOutput{ .output = &.{}, .gas_used = required_gas, .success = false };
    }

    // Ensure KZG settings are initialized; try lazy init from default path if not
    const kzg_setup = @import("kzg_setup.zig");
    if (!kzg_setup.isInitialized()) {
        kzg_setup.init(allocator, "data/kzg/trusted_setup.txt") catch {
            return PrecompileOutput{ .output = &.{}, .gas_used = required_gas, .success = false };
        };
    }

    // Perform KZG verification
    
    // Convert inputs to c_kzg types
    var z: crypto.c_kzg.Bytes32 = undefined;
    var y: crypto.c_kzg.Bytes32 = undefined;
    var commitment: crypto.c_kzg.KZGCommitment = undefined;
    var proof: crypto.c_kzg.KZGProof = undefined;
    
    @memcpy(&z, z_bytes);
    @memcpy(&y, y_bytes);
    @memcpy(&commitment, commitment_bytes);
    @memcpy(&proof, proof_bytes);
    
    // Verify the KZG proof
    const valid = crypto.c_kzg.verifyKZGProof(&commitment, &z, &y, &proof) catch {
        return PrecompileOutput{ .output = &.{}, .gas_used = required_gas, .success = false };
    };
    
    if (!valid) {
        return PrecompileOutput{ .output = &.{}, .gas_used = required_gas, .success = false };
    }
    
    // Success - return empty output
    return PrecompileOutput{ 
        .output = &.{}, 
        .gas_used = required_gas, 
        .success = true 
    };
}

// Utility functions for byte manipulation
/// 0x0B: BLS12-381 G1 addition
pub fn execute_bls12_381_g1_add(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) PrecompileError!PrecompileOutput {
    const required_gas = GasCosts.BLS12_381_G1_ADD;
    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    const output = try allocator.alloc(u8, 128);
    errdefer allocator.free(output);

    crypto.bls12_381.g1_add(input, output) catch {
        allocator.free(output);
        return PrecompileOutput{
            .output = &.{},
            .gas_used = required_gas,
            .success = false,
        };
    };

    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

/// 0x0C: BLS12-381 G1 scalar multiplication
pub fn execute_bls12_381_g1_mul(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) PrecompileError!PrecompileOutput {
    const required_gas = GasCosts.BLS12_381_G1_MUL;
    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    const output = try allocator.alloc(u8, 128);
    errdefer allocator.free(output);

    crypto.bls12_381.g1_mul(input, output) catch {
        allocator.free(output);
        return PrecompileOutput{
            .output = &.{},
            .gas_used = required_gas,
            .success = false,
        };
    };

    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

/// 0x0D: BLS12-381 G1 multi-exponentiation
pub fn execute_bls12_381_g1_multiexp(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) PrecompileError!PrecompileOutput {
    // Dynamic gas based on number of pairs
    const num_pairs = input.len / 160;
    const required_gas = GasCosts.BLS12_381_G1_MULTIEXP_BASE * num_pairs;
    
    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    const output = try allocator.alloc(u8, 128);
    errdefer allocator.free(output);

    crypto.bls12_381.g1_multiexp(input, output) catch {
        allocator.free(output);
        return PrecompileOutput{
            .output = &.{},
            .gas_used = required_gas,
            .success = false,
        };
    };

    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

/// 0x0E: BLS12-381 G2 addition (not implemented in Rust wrapper yet)
pub fn execute_bls12_381_g2_add(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) PrecompileError!PrecompileOutput {
    _ = allocator;
    _ = input;
    _ = gas_limit;
    return PrecompileError.NotImplemented;
}

/// 0x0F: BLS12-381 G2 scalar multiplication (not implemented in Rust wrapper yet)
pub fn execute_bls12_381_g2_mul(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) PrecompileError!PrecompileOutput {
    _ = allocator;
    _ = input;
    _ = gas_limit;
    return PrecompileError.NotImplemented;
}

/// 0x10: BLS12-381 G2 multi-exponentiation (not implemented in Rust wrapper yet)
pub fn execute_bls12_381_g2_multiexp(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) PrecompileError!PrecompileOutput {
    _ = allocator;
    _ = input;
    _ = gas_limit;
    return PrecompileError.NotImplemented;
}

/// 0x11: BLS12-381 pairing
pub fn execute_bls12_381_pairing(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) PrecompileError!PrecompileOutput {
    // Dynamic gas based on number of pairs
    const num_pairs = input.len / 384;
    const required_gas = GasCosts.BLS12_381_PAIRING_BASE + GasCosts.BLS12_381_PAIRING_PER_PAIR * num_pairs;
    
    if (gas_limit < required_gas) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    const output = try allocator.alloc(u8, 32);
    errdefer allocator.free(output);

    crypto.bls12_381.pairing(input, output) catch {
        allocator.free(output);
        return PrecompileOutput{
            .output = &.{},
            .gas_used = required_gas,
            .success = false,
        };
    };

    return PrecompileOutput{
        .output = output,
        .gas_used = required_gas,
        .success = true,
    };
}

/// 0x12: BLS12-381 map field element to G1 (not implemented in Rust wrapper yet)
pub fn execute_bls12_381_map_fp_to_g1(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) PrecompileError!PrecompileOutput {
    _ = allocator;
    _ = input;
    _ = gas_limit;
    return PrecompileError.NotImplemented;
}

fn bytesToU256(bytes: []const u8) u256 {
    var result: u256 = 0;
    for (bytes) |byte| {
        result = (result << 8) | byte;
    }
    return result;
}

fn bytesToU32(bytes: []const u8) u32 {
    // Interpret a big-endian 32-byte field length, retaining only lower 32 bits.
    // This handles Ethereum’s 32-byte length encoding where only the last byte is often set.
    var result: u32 = 0;
    for (bytes) |byte| {
        result = (result << 8) | byte;
    }
    return result;
}

fn u256ToBytes(value: u256, output: []u8) void {
    var v = value;
    var i = output.len;
    while (i > 0) {
        i -= 1;
        output[i] = @intCast(v & 0xFF);
        v >>= 8;
    }
}

test "is_precompile detects valid precompile addresses" {
    const testing = std.testing;

    // Test valid precompile addresses
    try testing.expect(is_precompile(ECRECOVER_ADDRESS));
    try testing.expect(is_precompile(SHA256_ADDRESS));
    try testing.expect(is_precompile(RIPEMD160_ADDRESS));
    try testing.expect(is_precompile(IDENTITY_ADDRESS));
    try testing.expect(is_precompile(MODEXP_ADDRESS));
    try testing.expect(is_precompile(ECADD_ADDRESS));
    try testing.expect(is_precompile(ECMUL_ADDRESS));
    try testing.expect(is_precompile(ECPAIRING_ADDRESS));
    try testing.expect(is_precompile(BLAKE2F_ADDRESS));
    try testing.expect(is_precompile(POINT_EVALUATION_ADDRESS));

    // Test BLS12-381 precompile addresses (EIP-2537)
    try testing.expect(is_precompile(BLS12_381_G1_ADD_ADDRESS));
    try testing.expect(is_precompile(BLS12_381_G1_MUL_ADDRESS));
    try testing.expect(is_precompile(BLS12_381_G1_MULTIEXP_ADDRESS));
    try testing.expect(is_precompile(BLS12_381_G2_ADD_ADDRESS));
    try testing.expect(is_precompile(BLS12_381_G2_MUL_ADDRESS));
    try testing.expect(is_precompile(BLS12_381_G2_MULTIEXP_ADDRESS));
    try testing.expect(is_precompile(BLS12_381_PAIRING_ADDRESS));
    try testing.expect(is_precompile(BLS12_381_MAP_FP_TO_G1_ADDRESS));

    // Test invalid addresses
    try testing.expect(!is_precompile(primitives.Address.from_u256(0)));
    try testing.expect(!is_precompile(primitives.Address.from_u256(0x13))); // Beyond BLS12-381
    try testing.expect(!is_precompile(primitives.Address.from_u256(100)));
}

test "execute_identity precompile" {
    const testing = std.testing;

    const input = "Hello, World!";
    const result = try execute_identity(testing.allocator, input, 1000);
    defer testing.allocator.free(result.output);

    try testing.expect(result.success);
    try testing.expectEqualSlices(u8, input, result.output);
    try testing.expect(result.gas_used == GasCosts.IDENTITY_BASE + GasCosts.IDENTITY_PER_WORD);
}

test "execute_sha256 precompile" {
    const testing = std.testing;

    const input = "abc";
    const result = try execute_sha256(testing.allocator, input, 1000);
    defer testing.allocator.free(result.output);

    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);

    // Expected SHA-256 hash of "abc"
    const expected = [_]u8{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    };
    try testing.expectEqualSlices(u8, &expected, result.output);
}

test "execute_ecrecover invalid signature" {
    const testing = std.testing;

    // Invalid input (all zeros)
    const input = [_]u8{0} ** 128;
    const result = try execute_ecrecover(testing.allocator, &input, GasCosts.ECRECOVER + 100);
    defer testing.allocator.free(result.output);

    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    // Should return all zeros for invalid signature
    for (result.output) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "execute_modexp simple case" {
    const testing = std.testing;

    // 3^4 mod 5 = 81 mod 5 = 1
    var input: [128]u8 = [_]u8{0} ** 128;

    // base_len = 1 (32 bytes, big-endian)
    input[31] = 1;
    // exp_len = 1 (32 bytes, big-endian)
    input[63] = 1;
    // mod_len = 1 (32 bytes, big-endian)
    input[95] = 1;
    // base = 3
    input[96] = 3;
    // exp = 4
    input[97] = 4;
    // mod = 5
    input[98] = 5;

    const result = try execute_modexp(testing.allocator, input[0..99], 1000);
    defer testing.allocator.free(result.output);

    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 1), result.output.len);
    try testing.expectEqual(@as(u8, 1), result.output[0]);
}

test "execute_blake2f invalid input length" {
    const testing = std.testing;

    const input = [_]u8{0} ** 100; // Wrong length
    const result = try execute_blake2f(testing.allocator, &input, 1000);

    try testing.expect(!result.success);
    try testing.expectEqual(@as(usize, 0), result.output.len);
}

test "precompile gas cost calculations" {
    const testing = std.testing;

    // Test SHA256 gas cost scaling
    const small_input = "a";
    const large_input = "a" ** 100;

    const small_result = try execute_sha256(testing.allocator, small_input, 10000);
    defer testing.allocator.free(small_result.output);

    const large_result = try execute_sha256(testing.allocator, large_input, 10000);
    defer testing.allocator.free(large_result.output);

    // Large input should cost more gas
    try testing.expect(large_result.gas_used > small_result.gas_used);
}

test "precompile insufficient gas" {
    const testing = std.testing;

    const input = "test";

    // Test with insufficient gas
    const result = try execute_identity(testing.allocator, input, 5); // Too little gas

    try testing.expect(!result.success);
    try testing.expectEqual(@as(usize, 0), result.output.len);
}

test "execute_ripemd160 precompile" {
    const testing = std.testing;

    const input = "abc";
    const result = try execute_ripemd160(testing.allocator, input, 1000);
    defer testing.allocator.free(result.output);

    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    
    // Expected RIPEMD-160 hash of "abc" (20 bytes hash + 12 zero padding)
    const expected = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x8e, 0xb2, 0x08, 0xf7, 0xe0, 0x5d, 0x98, 0x7a, 0x9b, 0x04,
        0x4a, 0x8e, 0x98, 0xc6, 0xb0, 0x87, 0xf1, 0x5a, 0x0b, 0xfc,
    };
    try testing.expectEqualSlices(u8, &expected, result.output);
}

test "execute_ecadd precompile" {
    const testing = std.testing;
    
    // Test: identity + identity = identity
    var input = [_]u8{0} ** 128;
    // Both points are identity (all zeros)
    
    const result = try execute_ecadd(testing.allocator, &input, GasCosts.ECADD + 100);
    defer testing.allocator.free(result.output);
    
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 64), result.output.len);
    // Result should be identity (all zeros)
    for (result.output) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "execute_ecmul precompile" {
    const testing = std.testing;
    
    // Test: identity * 5 = identity
    var input = [_]u8{0} ** 96;
    // Point is identity (first 64 bytes all zeros)
    // Scalar is 5 (last 32 bytes)
    input[95] = 5;
    
    const result = try execute_ecmul(testing.allocator, &input, GasCosts.ECMUL + 100);
    defer testing.allocator.free(result.output);
    
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 64), result.output.len);
    // Result should be identity (all zeros)
    for (result.output) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "execute_ecpairing precompile - empty input" {
    const testing = std.testing;
    
    // Empty input should return success with 1 (true)
    const input = &[_]u8{};
    const result = try execute_ecpairing(testing.allocator, input, GasCosts.ECPAIRING_BASE);
    defer testing.allocator.free(result.output);
    
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    // Should return 1 (true) for empty pairing
    try testing.expectEqual(@as(u8, 1), result.output[31]);
    for (result.output[0..31]) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "execute_blake2f precompile" {
    const testing = std.testing;
    
    // Valid blake2f input (213 bytes)
    var input = [_]u8{0} ** 213;
    // rounds (4 bytes)
    input[3] = 12; // 12 rounds
    // h (64 bytes) - initial hash values
    // m (128 bytes) - message block
    // t (16 bytes) - offset counters
    // f (1 byte) - final block flag
    input[212] = 1; // final block
    
    const result = try execute_blake2f(testing.allocator, &input, 1000);
    defer testing.allocator.free(result.output);
    
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 64), result.output.len);
    try testing.expectEqual(@as(u64, 12), result.gas_used); // 12 rounds * 1 gas per round
}

test "execute_modexp edge cases" {
    const testing = std.testing;
    
    // Test: 0^0 mod 5 = 1 (by convention)
    var input: [128]u8 = [_]u8{0} ** 128;
    
    // base_len = 1
    input[31] = 1;
    // exp_len = 1
    input[63] = 1;
    // mod_len = 1
    input[95] = 1;
    // base = 0 (already zero)
    // exp = 0 (already zero)
    // mod = 5
    input[98] = 5;
    
    const result = try execute_modexp(testing.allocator, &input, 10000);
    defer testing.allocator.free(result.output);
    
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 1), result.output.len);
    // 0^0 mod 5 = 1
    try testing.expectEqual(@as(u8, 1), result.output[0]);
}

test "execute_ecrecover valid signature" {
    const testing = std.testing;
    
    // This is a real signature from Ethereum mainnet
    // Message hash, v, r, s values from a known transaction
    var input = [_]u8{0} ** 128;
    
    // Message hash (32 bytes)
    const hash = [_]u8{
        0x7c, 0x80, 0xc6, 0x8e, 0x60, 0x3b, 0xf0, 0x9a,
        0xca, 0x17, 0xa5, 0x73, 0xe2, 0xb2, 0x11, 0x42,
        0xed, 0xfb, 0x8e, 0x8d, 0xed, 0x9b, 0xea, 0xb6,
        0x6e, 0x0a, 0x23, 0xbe, 0xbd, 0x02, 0x3c, 0x23,
    };
    @memcpy(input[0..32], &hash);
    
    // v = 27 (recovery id)
    input[63] = 27;
    
    // r (32 bytes) 
    const r = [_]u8{
        0xa8, 0x89, 0xc0, 0xea, 0x64, 0xd6, 0xb8, 0xef,
        0x9a, 0x8a, 0x01, 0x96, 0x4f, 0x2f, 0x20, 0x18,
        0x44, 0xfb, 0x60, 0x7f, 0xf0, 0x83, 0xb8, 0xc9,
        0x42, 0x50, 0x5f, 0xd1, 0xa8, 0xee, 0xa6, 0x60,
    };
    @memcpy(input[64..96], &r);
    
    // s (32 bytes)
    const s = [_]u8{
        0x2a, 0x55, 0x0e, 0x6f, 0x48, 0xfb, 0x9d, 0x95,
        0x92, 0xab, 0x48, 0xca, 0x80, 0xf6, 0x77, 0x64,
        0x6c, 0x7f, 0xe7, 0x5e, 0x86, 0x2a, 0xfa, 0xb8,
        0xd2, 0xbc, 0x2e, 0xc8, 0x07, 0x1f, 0xfb, 0x10,
    };
    @memcpy(input[96..128], &s);
    
    const result = try execute_ecrecover(testing.allocator, &input, GasCosts.ECRECOVER + 100);
    defer testing.allocator.free(result.output);
    
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    // Should return a valid address (20 bytes) with 12 bytes of zero padding
    // We just check that it's not all zeros
    var all_zero = true;
    for (result.output[12..32]) |byte| {
        if (byte != 0) {
            all_zero = false;
            break;
        }
    }
    try testing.expect(!all_zero);
}

test "execute_ecadd invalid point" {
    const testing = std.testing;
    
    // Test with invalid point (not on curve)
    var input = [_]u8{0} ** 128;
    // Set x coordinate to 1, y coordinate to 1 (not on curve)
    input[31] = 1;
    input[63] = 1;
    
    const result = try execute_ecadd(testing.allocator, &input, GasCosts.ECADD + 100);
    
    // Should fail with invalid point
    try testing.expect(!result.success);
}

test "execute_ecmul invalid scalar" {
    const testing = std.testing;
    
    // Test with scalar larger than curve order
    var input = [_]u8{0} ** 96;
    // Set all scalar bytes to 0xFF (larger than curve order)
    @memset(input[64..96], 0xFF);
    
    const result = try execute_ecmul(testing.allocator, &input, GasCosts.ECMUL + 100);
    defer testing.allocator.free(result.output);
    
    // Should still work (scalar is reduced modulo curve order)
    try testing.expect(result.success);
}

test "execute_ecpairing wrong input length" {
    const testing = std.testing;
    
    // Input length must be multiple of 192 bytes
    var input = [_]u8{0} ** 100; // Invalid length
    
    const result = try execute_ecpairing(testing.allocator, &input, 100000);
    
    try testing.expect(!result.success);
}

test "execute_blake2f invalid final flag" {
    const testing = std.testing;
    
    // Valid length but invalid final flag
    var input = [_]u8{0} ** 213;
    input[212] = 2; // Invalid flag (must be 0 or 1)
    
    const result = try execute_blake2f(testing.allocator, &input, 1000);
    
    try testing.expect(!result.success);
}

test "execute_modexp with zero modulus" {
    const testing = std.testing;
    
    // Test: 5^3 mod 0 should fail
    var input: [128]u8 = [_]u8{0} ** 128;
    
    // base_len = 1
    input[31] = 1;
    // exp_len = 1
    input[63] = 1;
    // mod_len = 1
    input[95] = 1;
    // base = 5
    input[96] = 5;
    // exp = 3
    input[97] = 3;
    // mod = 0 (already zero)
    
    const result = try execute_modexp(testing.allocator, &input, 10000);
    defer testing.allocator.free(result.output);
    
    try testing.expect(result.success);
    // Result should be 0 when modulus is 0
    try testing.expectEqual(@as(usize, 1), result.output.len);
    try testing.expectEqual(@as(u8, 0), result.output[0]);
}

test "execute_point_evaluation without kzg setup" {
    const testing = std.testing;
    
    // Try to use point evaluation without KZG setup
    const kzg_setup = @import("kzg_setup.zig");
    
    // Skip if already initialized
    if (kzg_setup.isInitialized()) {
        return;
    }
    
    var input = [_]u8{0} ** 192;
    const result = try execute_point_evaluation(testing.allocator, &input, GasCosts.POINT_EVALUATION + 100);
    
    // Should fail without KZG setup
    try testing.expect(!result.success);
}

test "precompile address boundary checks" {
    const testing = std.testing;
    
    // Test addresses at boundaries
    try testing.expect(is_precompile(ECRECOVER_ADDRESS)); // 0x01
    try testing.expect(is_precompile(POINT_EVALUATION_ADDRESS)); // 0x0A
    
    // Test addresses outside range
    try testing.expect(!is_precompile(primitives.Address.ZERO));
    try testing.expect(is_precompile([_]u8{0} ** 19 ++ [_]u8{0x0B})); // 0x0B is a valid BLS12-381 precompile
    try testing.expect(!is_precompile([_]u8{0} ** 19 ++ [_]u8{0x13})); // 0x13 is beyond valid precompiles
    try testing.expect(!is_precompile([_]u8{0xFF} ** 20)); // Max address
}

test "execute_all_precompiles smoke test" {
    const testing = std.testing;
    
    // Test that execute function correctly dispatches to all precompiles
    const addresses = [_]primitives.Address.Address{
        ECRECOVER_ADDRESS,
        SHA256_ADDRESS,
        RIPEMD160_ADDRESS,
        IDENTITY_ADDRESS,
        MODEXP_ADDRESS,
        ECADD_ADDRESS,
        ECMUL_ADDRESS,
        ECPAIRING_ADDRESS,
        BLAKE2F_ADDRESS,
        POINT_EVALUATION_ADDRESS,
    };
    
    for (addresses) |addr| {
        const result = try execute_precompile(testing.allocator, addr, &[_]u8{}, 100000);
        defer if (result.output.len > 0) testing.allocator.free(result.output);
        
        // All should at least not error (may fail due to invalid input)
        try testing.expect(result.gas_used <= 100000);
    }
}
