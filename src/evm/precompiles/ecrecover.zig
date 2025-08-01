const std = @import("std");
const PrecompileResult = @import("precompile_result.zig").PrecompileResult;
const PrecompileOutput = @import("precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("precompile_result.zig").PrecompileError;
const GasConstants = @import("primitives").GasConstants;
const primitives = @import("primitives");
const crypto = @import("crypto");
const secp256k1 = crypto.secp256k1;

/// ECRECOVER precompile implementation (address 0x01)
///
/// The ECRECOVER precompile recovers the signer's address from an ECDSA signature using
/// elliptic curve cryptography. This is fundamental for Ethereum's signature verification system.
///
/// This implementation uses cryptographically correct secp256k1 signature recovery
/// with full elliptic curve arithmetic and validation.
///
/// ## Input Format (128 bytes)
/// - hash (32 bytes): Hash of the message that was signed
/// - v (32 bytes): Recovery ID (27 or 28, padded with zeros)
/// - r (32 bytes): ECDSA signature r component
/// - s (32 bytes): ECDSA signature s component
///
/// ## Output Format
/// - Success: 20-byte Ethereum address (left-padded to 32 bytes)
/// - Failure: Empty output (0 bytes)
///
/// ## Gas Cost
/// Fixed cost of 3000 gas regardless of success or failure
///
/// ## Examples
/// ```zig
/// // Valid signature recovery
/// const input = [128]u8{...}; // hash + v + r + s
/// const result = execute(&input, &output, 5000);
/// // result.output_size == 32 on success, 0 on failure
/// ```
/// Gas constant for ECRECOVER precompile - fixed cost
pub const ECRECOVER_GAS_COST: u64 = GasConstants.ECRECOVER_COST;

/// secp256k1 curve order for signature validation
const SECP256K1_ORDER: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

/// Required input size for ECRECOVER (128 bytes)
const ECRECOVER_INPUT_SIZE: usize = 128;

/// Expected output size for ECRECOVER (32 bytes)
const ECRECOVER_OUTPUT_SIZE: usize = 32;

// Input parsing constants for clearer code structure
/// Offset of hash field in input (bytes 0-31)
const HASH_OFFSET: usize = 0;
/// Size of hash field (32 bytes)
const HASH_SIZE: usize = 32;
/// Offset of v field in input (bytes 32-63)
const V_OFFSET: usize = 32;
/// Size of v field (32 bytes, though only last byte is used)
const V_SIZE: usize = 32;
/// Offset of r field in input (bytes 64-95)
const R_OFFSET: usize = 64;
/// Size of r field (32 bytes)
const R_SIZE: usize = 32;
/// Offset of s field in input (bytes 96-127)
const S_OFFSET: usize = 96;
/// Size of s field (32 bytes)
const S_SIZE: usize = 32;

// Output formatting constants
/// Offset for address in output (left-padded with 12 zero bytes)
const ADDRESS_OFFSET_IN_OUTPUT: usize = 12;
/// Size of Ethereum address (20 bytes)
const ETHEREUM_ADDRESS_SIZE: usize = 20;

/// Calculates the gas cost for ECRECOVER precompile execution
///
/// ECRECOVER has a fixed gas cost regardless of input size or execution outcome.
/// This matches the Ethereum specification and prevents timing attacks.
///
/// @param input_size Size of the input data (ignored for ECRECOVER)
/// @return Fixed gas cost of 3000
pub fn calculate_gas(input_size: usize) u64 {
    _ = input_size; // ECRECOVER has fixed cost regardless of input size
    return ECRECOVER_GAS_COST;
}

/// Calculates the gas cost with overflow protection
///
/// Since ECRECOVER has a fixed cost, overflow is not possible, but this function
/// is provided for consistency with other precompiles.
///
/// @param input_size Size of the input data (ignored)
/// @return Fixed gas cost of 3000
pub fn calculate_gas_checked(input_size: usize) !u64 {
    _ = input_size;
    return ECRECOVER_GAS_COST;
}

/// Executes the ECRECOVER precompile
///
/// This is the main entry point for ECRECOVER precompile execution. It performs:
/// 1. Gas cost validation
/// 2. Input format validation (must be exactly 128 bytes)
/// 3. Signature parameter validation
/// 4. Public key recovery (placeholder implementation)
/// 5. Address derivation from recovered public key
///
/// @param input Input data containing hash, v, r, s (must be 128 bytes)
/// @param output Output buffer to write the result (must be >= 32 bytes)
/// @param gas_limit Maximum gas available for this operation
/// @return PrecompileOutput containing success/failure and gas usage
pub fn execute(input: []const u8, output: []u8, gas_limit: u64) PrecompileOutput {
    const gas_cost = ECRECOVER_GAS_COST;

    // Check if we have enough gas - this is always the first check
    if (gas_cost > gas_limit) {
        @branchHint(.cold);
        return PrecompileOutput.failure_result(PrecompileError.OutOfGas);
    }

    // ECRECOVER requires exactly 128 bytes of input
    if (input.len != ECRECOVER_INPUT_SIZE) {
        @branchHint(.cold);
        return PrecompileOutput.success_result(gas_cost, 0); // Return empty on invalid input
    }

    // Validate output buffer size
    if (output.len < ECRECOVER_OUTPUT_SIZE) {
        @branchHint(.cold);
        return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
    }

    // Parse input components using named offsets for clarity
    const hash = input[HASH_OFFSET..HASH_OFFSET + HASH_SIZE];
    const v_bytes = input[V_OFFSET..V_OFFSET + V_SIZE];
    const r_bytes = input[R_OFFSET..R_OFFSET + R_SIZE];
    const s_bytes = input[S_OFFSET..S_OFFSET + S_SIZE];

    // Convert byte arrays to u256 values
    const v = bytes_to_u256(v_bytes);
    const r = bytes_to_u256(r_bytes);
    const s = bytes_to_u256(s_bytes);

    // Validate signature parameters
    if (!secp256k1.unaudited_validate_signature(r, s)) {
        @branchHint(.cold);
        return PrecompileOutput.success_result(gas_cost, 0); // Return empty on invalid params
    }

    // Extract recovery ID from v value
    const recovery_id = extract_recovery_id(v);
    if (recovery_id > 1) {
        @branchHint(.cold);
        return PrecompileOutput.success_result(gas_cost, 0); // Return empty on invalid recovery ID
    }

    // Recover public key from signature (placeholder implementation)
    const recovered_address = recover_address(hash, recovery_id, r, s) catch {
        @branchHint(.cold);
        return PrecompileOutput.success_result(gas_cost, 0); // Return empty on recovery failure
    };

    // Clear output buffer and write the recovered address (left-padded to 32 bytes)
    @memset(output[0..ECRECOVER_OUTPUT_SIZE], 0);
    @memcpy(output[ADDRESS_OFFSET_IN_OUTPUT..ADDRESS_OFFSET_IN_OUTPUT + ETHEREUM_ADDRESS_SIZE], &recovered_address);

    return PrecompileOutput.success_result(gas_cost, ECRECOVER_OUTPUT_SIZE);
}

/// Extracts the recovery ID from the v parameter
///
/// Handles both legacy format (27, 28) and EIP-155 format (chain_id * 2 + 35/36).
/// The recovery ID is used to determine which of the possible public keys to recover.
///
/// @param v The v parameter from the signature
/// @return Recovery ID (0 or 1) or 255 if invalid
fn extract_recovery_id(v: u256) u8 {
    // Handle legacy format (27, 28)
    if (v == 27) return 0;
    if (v == 28) return 1;

    // Handle EIP-155 format (chain_id * 2 + 35/36)
    if (v >= 35) {
        const adjusted = v - 35;
        const recovery_id = @as(u8, @intCast(adjusted % 2));
        return recovery_id;
    }

    // Invalid v value
    return 255;
}

/// Converts a 32-byte big-endian byte array to u256
///
/// This is a utility function for parsing signature components from the input data.
///
/// @param bytes 32-byte array in big-endian format
/// @return Corresponding u256 value
fn bytes_to_u256(bytes: []const u8) u256 {
    std.debug.assert(bytes.len == 32);
    return std.mem.readInt(u256, bytes[0..32], .big);
}

/// Recovers the Ethereum address from ECDSA signature components
///
/// This function implements ECDSA signature recovery using secp256k1 elliptic curve
/// cryptography to recover the public key that created the signature, then derives
/// the corresponding Ethereum address.
///
/// @param hash The hash that was signed (32 bytes)
/// @param recovery_id Recovery ID (0 or 1)
/// @param r ECDSA signature r component
/// @param s ECDSA signature s component
/// @return Recovered Ethereum address or error
fn recover_address(hash: []const u8, recovery_id: u8, r: u256, s: u256) !primitives.Address.Address {
    return secp256k1.unaudited_recover_address(hash, recovery_id, r, s);
}

/// Validates that a precompile call would succeed without executing
///
/// This function performs gas and input validation without actually executing
/// the signature recovery. Useful for transaction validation and gas estimation.
///
/// @param input_size Size of the input data
/// @param gas_limit Available gas limit
/// @return true if the call would succeed (ignoring signature validity)
pub fn validate_call(input_size: usize, gas_limit: u64) bool {
    // Check gas requirement
    if (ECRECOVER_GAS_COST > gas_limit) {
        @branchHint(.cold);
        return false;
    }

    // Check input size requirement
    return input_size == ECRECOVER_INPUT_SIZE;
}

/// Gets the expected output size for ECRECOVER
///
/// ECRECOVER always produces 32 bytes of output (address left-padded) on success,
/// or 0 bytes on failure. This function returns the success case size.
///
/// @param input_size Size of the input data (ignored)
/// @return Expected output size (32 bytes)
pub fn get_output_size(input_size: usize) usize {
    _ = input_size;
    return ECRECOVER_OUTPUT_SIZE;
}
