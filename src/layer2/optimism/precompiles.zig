//! Optimism-specific precompile modifications.
//!
//! This module provides precompile overrides for Optimism hardforks:
//! - Fjord+: P256verify precompile for secp256r1 signature verification (RIP-7212)
//! - Granite+: BN128 pairing precompile with input size limit
//!
//! Based on the Rust implementation from op-revm:
//! https://github.com/bluealloy/revm/blob/main/crates/op-revm/src/precompile.rs

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const spec_mod = @import("spec.zig");
const OpSpecId = spec_mod.OpSpecId;

// Import precompile types from evm_config to avoid circular dependency
const evm_config = @import("../../evm_config.zig");
const PrecompileOverride = evm_config.PrecompileOverride;
const PrecompileOutput = evm_config.PrecompileOutput;

// P256verify constants (RIP-7212)
// Address: 0x0000000000000000000000000000000000000100
pub const P256_VERIFY_ADDRESS: Address = Address.fromU256(0x0000000000000000000000000000000000000100);
pub const P256_VERIFY_GAS: u64 = 3450;
pub const P256_INPUT_SIZE: usize = 160; // hash(32) + r(32) + s(32) + x(32) + y(32)

// BN128 pairing constants for Granite
// Address: 0x0000000000000000000000000000000000000008
pub const BN128_PAIRING_ADDRESS: Address = Address.fromU256(0x0000000000000000000000000000000000000008);
pub const BN128_MAX_PAIRS: usize = 64;
pub const BN128_PAIR_SIZE: usize = 192; // 6 * 32 bytes per pair
pub const BN128_MAX_INPUT: usize = BN128_MAX_PAIRS * BN128_PAIR_SIZE; // 12,288 bytes

/// P256verify precompile (RIP-7212).
///
/// Verifies a secp256r1 (P-256/NIST P-256) signature. This is used for
/// WebAuthn/passkey support in smart contract wallets.
///
/// Input format (160 bytes):
/// - bytes 0-31: message hash
/// - bytes 32-63: signature r value
/// - bytes 64-95: signature s value
/// - bytes 96-127: public key x coordinate
/// - bytes 128-159: public key y coordinate
///
/// Output:
/// - 32 bytes containing 1 if signature is valid, empty otherwise
///
/// NOTE: This implementation is stubbed - actual P256 crypto not yet available
/// in the primitives package. Returns invalid for all inputs until crypto is added.
pub fn p256Verify(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) anyerror!PrecompileOutput {
    // Check gas
    if (gas_limit < P256_VERIFY_GAS) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    // Invalid input length returns empty (not an error)
    if (input.len != P256_INPUT_SIZE) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = P256_VERIFY_GAS,
            .success = true,
        };
    }

    // Parse input components
    const hash = input[0..32];
    const r = input[32..64];
    const s = input[64..96];
    const x = input[96..128];
    const y = input[128..160];

    // Verify secp256r1 signature
    // TODO: Implement actual P256 verification when crypto library is available
    // For now, stub returns false (invalid signature) for all inputs
    const valid = verifyP256Signature(hash, r, s, x, y);

    if (valid) {
        // Return 32 bytes with value 1
        var output = try allocator.alloc(u8, 32);
        @memset(output[0..31], 0);
        output[31] = 1;
        return PrecompileOutput{
            .output = output,
            .gas_used = P256_VERIFY_GAS,
            .success = true,
        };
    }

    // Invalid signature returns empty output
    return PrecompileOutput{
        .output = &.{},
        .gas_used = P256_VERIFY_GAS,
        .success = true,
    };
}

/// Stub for P256 signature verification.
/// Returns false until actual crypto implementation is available.
fn verifyP256Signature(
    hash: *const [32]u8,
    r: *const [32]u8,
    s: *const [32]u8,
    x: *const [32]u8,
    y: *const [32]u8,
) bool {
    // Suppress unused parameter warnings
    _ = hash;
    _ = r;
    _ = s;
    _ = x;
    _ = y;

    // TODO: Implement actual secp256r1 verification
    // Once primitives package has P256 support:
    // return crypto.p256.verify(hash, r, s, x, y) catch false;
    return false;
}

/// BN128 pairing precompile with Granite input limit.
///
/// Granite hardfork limits the BN128 pairing precompile to a maximum of
/// 64 pairs (12,288 bytes input). This prevents DoS attacks using excessive
/// pairing operations.
///
/// This is a wrapper that enforces the limit then delegates to the standard
/// BN128 pairing implementation.
pub fn bn128PairingWithLimit(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
) anyerror!PrecompileOutput {
    // Granite enforces max 64 pairs
    if (input.len > BN128_MAX_INPUT) {
        // Return failure for inputs exceeding limit
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    // Delegate to standard BN128 pairing implementation
    // Import from precompiles module
    const precompiles = @import("precompiles");
    return precompiles.bn128Pairing(allocator, input, gas_limit);
}

/// Get Optimism-specific precompile overrides based on hardfork spec.
///
/// This function returns precompile overrides that should be applied
/// when running with the given OpSpecId:
/// - Fjord+: Adds P256verify at address 0x100
/// - Granite+: Overrides BN128 pairing at address 0x08 with input limit
///
/// Usage:
/// ```zig
/// const config = EvmConfig{
///     .layer2_config = .{ .optimism = .{ .spec = .FJORD } },
///     .precompile_overrides = getOptimismPrecompileOverrides(.FJORD),
/// };
/// ```
pub fn getOptimismPrecompileOverrides(comptime spec: OpSpecId) []const PrecompileOverride {
    comptime {
        var count: usize = 0;

        // Count overrides
        if (spec.isAtLeast(.FJORD)) count += 1;
        if (spec.isAtLeast(.GRANITE)) count += 1;

        if (count == 0) return &.{};

        var overrides: [count]PrecompileOverride = undefined;
        var idx: usize = 0;

        // Fjord+: Add P256verify
        if (spec.isAtLeast(.FJORD)) {
            overrides[idx] = .{
                .address = P256_VERIFY_ADDRESS,
                .execute = &p256Verify,
            };
            idx += 1;
        }

        // Granite+: Override BN128 pairing with input limit
        if (spec.isAtLeast(.GRANITE)) {
            overrides[idx] = .{
                .address = BN128_PAIRING_ADDRESS,
                .execute = &bn128PairingWithLimit,
            };
            idx += 1;
        }

        return &overrides;
    }
}

// Tests

test "P256verify - insufficient gas" {
    const result = try p256Verify(std.testing.allocator, &[_]u8{0} ** 160, 100);
    try std.testing.expectEqual(@as(u64, 100), result.gas_used);
    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
}

test "P256verify - invalid input length" {
    // Too short
    const result_short = try p256Verify(std.testing.allocator, &[_]u8{0} ** 100, 5000);
    try std.testing.expectEqual(@as(u64, P256_VERIFY_GAS), result_short.gas_used);
    try std.testing.expect(result_short.success);
    try std.testing.expectEqual(@as(usize, 0), result_short.output.len);

    // Too long
    const result_long = try p256Verify(std.testing.allocator, &[_]u8{0} ** 200, 5000);
    try std.testing.expectEqual(@as(u64, P256_VERIFY_GAS), result_long.gas_used);
    try std.testing.expect(result_long.success);
    try std.testing.expectEqual(@as(usize, 0), result_long.output.len);
}

test "P256verify - valid input length (stub returns invalid)" {
    const result = try p256Verify(std.testing.allocator, &[_]u8{0} ** 160, 5000);
    try std.testing.expectEqual(@as(u64, P256_VERIFY_GAS), result.gas_used);
    try std.testing.expect(result.success);
    // Stub always returns empty (invalid signature)
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
}

test "BN128 pairing limit - input too large" {
    // Create input larger than limit
    var large_input: [BN128_MAX_INPUT + 192]u8 = undefined;
    @memset(&large_input, 0);

    const result = try bn128PairingWithLimit(std.testing.allocator, &large_input, 100000);
    try std.testing.expect(!result.success);
}

test "constants - P256 address" {
    try std.testing.expectEqual(@as(u256, 0x100), P256_VERIFY_ADDRESS.toU256());
}

test "constants - BN128 pairing address" {
    try std.testing.expectEqual(@as(u256, 0x08), BN128_PAIRING_ADDRESS.toU256());
}

test "constants - BN128 max input" {
    try std.testing.expectEqual(@as(usize, 12288), BN128_MAX_INPUT);
    try std.testing.expectEqual(@as(usize, 64), BN128_MAX_PAIRS);
    try std.testing.expectEqual(@as(usize, 192), BN128_PAIR_SIZE);
}

test "getOptimismPrecompileOverrides - pre-Fjord returns empty" {
    const overrides = getOptimismPrecompileOverrides(.ECOTONE);
    try std.testing.expectEqual(@as(usize, 0), overrides.len);
}

test "getOptimismPrecompileOverrides - Fjord adds P256" {
    const overrides = getOptimismPrecompileOverrides(.FJORD);
    try std.testing.expectEqual(@as(usize, 1), overrides.len);
    try std.testing.expectEqual(P256_VERIFY_ADDRESS.toU256(), overrides[0].address.toU256());
}

test "getOptimismPrecompileOverrides - Granite adds both" {
    const overrides = getOptimismPrecompileOverrides(.GRANITE);
    try std.testing.expectEqual(@as(usize, 2), overrides.len);
}
